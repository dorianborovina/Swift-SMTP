/**
 * Copyright IBM Corporation 2017
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 **/

import Foundation

// Used to send the content of an email--headers, text, and attachments.
// Should only be invoked after sending the `DATA` command to the server.
// The email is not actually sent until we have indicated that we are done sending its contents with a `CRLF CRLF`.
// This is handled by `Sender`.
struct DataSender {
    private let socket: SMTPSocket
    private let logger: SMTPLogger

    init(socket: SMTPSocket, logger: SMTPLogger) {
        self.socket = socket
        self.logger = logger
    }

    func send(_ mail: Mail) throws {
        do {
            logger.log("Starting to send email data")
            try sendHeaders(mail.headersString)
            logger.log("Email headers sent successfully")

            if mail.hasAttachment {
                logger.log("Email contains attachments, sending as multipart")
                try sendMixed(mail)
            } else {
                logger.log("Email is text-only, sending content")
                try sendText(mail.text, html: mail.html)
            }
            logger.log("Email content sent successfully")
        } catch {
            logger.logError(error, context: "Sending mail data")
            throw error
        }
    }

    func sendHeaders(_ headers: String) throws {
        logger.log("Sending email headers")
        try send(headers)
    }

    func sendText(_ text: String, html: String?) throws {
        let boundary = "Swift-SMTP-\(UUID().uuidString)"
        
        if html != nil {
            logger.log("Sending multipart alternative content (text + HTML)")
            try send("Content-Type: multipart/alternative; boundary=\"\(boundary)\"\(CRLF)")
            try send(CRLF)
        } else {
            logger.log("Sending plain text content")
        }
        
        // Plain text part
        if html != nil {
            try send("--\(boundary)\(CRLF)")
        }
        try send(CRLF)
        try send(text)
        try send(CRLF)
        
        if let html = html {
            logger.log("Sending HTML content")
            try send("--\(boundary)\(CRLF)")
            try send(CRLF)
            try send(html)
            try send(CRLF)
            
            try send("--\(boundary)--\(CRLF)")
            logger.log("HTML content sent successfully")
        }
    }

    func sendMixed(_ mail: Mail) throws {
        logger.log("Starting to send mixed content email")
        let boundary = String.makeBoundary()
        let mixedHeader = String.makeMixedHeader(boundary: boundary)

        try send(mixedHeader)
        try send(boundary.startLine)

        try sendAlternative(for: mail)

        try sendAttachments(mail.attachments, boundary: boundary)
        logger.log("Mixed content email sent successfully")
    }

    func sendAlternative(for mail: Mail) throws {
        if let alternative = mail.alternative {
            logger.log("Sending alternative content")
            let boundary = String.makeBoundary()
            let alternativeHeader = String.makeAlternativeHeader(boundary: boundary)
            try send(alternativeHeader)

            try send(boundary.startLine)
            try sendText(mail.text, html: mail.html)

            try send(boundary.startLine)
            try sendAttachment(alternative)

            try send(boundary.endLine)
            logger.log("Alternative content sent successfully")
            return
        }

        try sendText(mail.text, html: mail.html)
    }

    func sendAttachments(_ attachments: [Attachment], boundary: String) throws {
        logger.log("Starting to send \(attachments.count) attachments")
        for (index, attachment) in attachments.enumerated() {
            try send(boundary.startLine)
            logger.log("Sending attachment \(index + 1) of \(attachments.count)")
            try sendAttachment(attachment)
        }
        try send(boundary.endLine)
        logger.log("All attachments sent successfully")
    }

    func sendAttachment(_ attachment: Attachment) throws {
        var relatedBoundary = ""

        if attachment.hasRelated {
            logger.log("Sending attachment with related content")
            relatedBoundary = String.makeBoundary()
            let relatedHeader = String.makeRelatedHeader(boundary: relatedBoundary)
            try send(relatedHeader)
            try send(relatedBoundary.startLine)
        }

        let attachmentHeader = attachment.headersString + CRLF
        try send(attachmentHeader)

        switch attachment.type {
        case .data(let data, let mime, let name, _):
            logger.log("Sending data attachment: \(name) (\(mime)) - \(data.count) bytes")
            try sendData(data)
            
        case .file(let path, let mime, let name, _):
            logger.log("Sending file attachment: \(name) (\(mime)) from path: \(path)")
            try sendFile(at: path)
            
        case .html(let content, let charset, _):
            logger.log("Sending HTML attachment (charset: \(charset)) - \(content.count) characters")
            try sendHTML(content)
        }

        try send("")

        if attachment.hasRelated {
            try sendAttachments(attachment.relatedAttachments, boundary: relatedBoundary)
        }
    }

    func sendData(_ data: Data) throws {
        logger.log("Processing data attachment (\(data.count) bytes)")
        #if os(macOS)
            if let encodedData = cache.object(forKey: data as AnyObject) as? Data {
                logger.log("Using cached encoded data")
                return try send(encodedData)
            }
        #else
            if let encodedData = cache.object(forKey: NSData(data: data) as AnyObject) as? Data {
                logger.log("Using cached encoded data")
                return try send(encodedData)
            }
        #endif

        logger.log("Encoding data attachment")
        let encodedData = data.base64EncodedData(options: .lineLength76Characters)
        try send(encodedData)
        logger.log("Data attachment sent successfully")

        #if os(macOS)
            cache.setObject(encodedData as AnyObject, forKey: data as AnyObject)
        #else
            cache.setObject(NSData(data: encodedData) as AnyObject, forKey: NSData(data: data) as AnyObject)
        #endif
    }

    func sendFile(at path: String) throws {
        logger.log("Processing file attachment from: \(path)")
        #if os(macOS)
            if let data = cache.object(forKey: path as AnyObject) as? Data {
                logger.log("Using cached file data")
                return try send(data)
            }
        #else
            if let data = cache.object(forKey: NSString(string: path) as AnyObject) as? Data {
                logger.log("Using cached file data")
                return try send(data)
            }
        #endif

        guard let file = FileHandle(forReadingAtPath: path) else {
            logger.logError(SMTPError.fileNotFound(path: path), context: "Opening file attachment")
            throw SMTPError.fileNotFound(path: path)
        }

        logger.log("Reading and encoding file data")
        let data = file.readDataToEndOfFile().base64EncodedData(options: .lineLength76Characters)
        try send(data)
        file.closeFile()
        logger.log("File attachment sent successfully")

        #if os(macOS)
            cache.setObject(data as AnyObject, forKey: path as AnyObject)
        #else
            cache.setObject(NSData(data: data) as AnyObject, forKey: NSString(string: path) as AnyObject)
        #endif
    }

    func sendHTML(_ html: String) throws {
        logger.log("Processing HTML attachment")
        #if os(macOS)
            if let encodedHTML = cache.object(forKey: html as AnyObject) as? String {
                logger.log("Using cached HTML data")
                return try send(encodedHTML)
            }
        #else
            if let encodedHTML = cache.object(forKey: NSString(string: html) as AnyObject) as? String {
                logger.log("Using cached HTML data")
                return try send(encodedHTML)
            }
        #endif

        logger.log("Encoding HTML content")
        let encodedHTML = html.data(using: .utf8)?.base64EncodedData(options: .lineLength76Characters) ?? Data()
        try send(encodedHTML)
        logger.log("HTML attachment sent successfully")

        #if os(macOS)
            cache.setObject(encodedHTML as AnyObject, forKey: html as AnyObject)
        #else
            cache.setObject(NSData(data: encodedHTML) as AnyObject, forKey: NSString(string: html) as AnyObject)
        #endif
    }
}

private extension DataSender {
    func send(_ text: String) throws {
        logger.logSent(text)
        try socket.write(text)
    }

    func send(_ data: Data) throws {
        logger.logSent("(sending data: \(data.count) bytes)")
        try socket.write(data)
    }
}

private extension String {
    // Embed plain text content of emails with the proper headers so that it is entered correctly.
    var embedded: String {
        var embeddedText = ""
        embeddedText += "CONTENT-TYPE: text/plain; charset=utf-8\(CRLF)"
        embeddedText += "CONTENT-TRANSFER-ENCODING: 7bit\(CRLF)"
        embeddedText += "CONTENT-DISPOSITION: inline\(CRLF)"
        embeddedText += "\(CRLF)\(self)\(CRLF)"
        return embeddedText
    }

    // The SMTP protocol requires unique boundaries between sections of an email.
    static func makeBoundary() -> String {
        return UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    // Header for a mixed type email.
    static func makeMixedHeader(boundary: String) -> String {
        return "CONTENT-TYPE: multipart/mixed; boundary=\"\(boundary)\"\(CRLF)"
    }

    // Header for an alternative email.
    static func makeAlternativeHeader(boundary: String) -> String {
        return "CONTENT-TYPE: multipart/alternative; boundary=\"\(boundary)\"\(CRLF)"
    }

    // Header for an attachment that is related to another attachment. (Such as an image attachment that can be
    // referenced by a related HTML attachment)
    static func makeRelatedHeader(boundary: String) -> String {
        return "CONTENT-TYPE: multipart/related; boundary=\"\(boundary)\"\(CRLF)"
    }

    // Added to a boundary to indicate the beginning of the corresponding section.
    var startLine: String {
        return "--\(self)"
    }

    // Added to a boundary to indicate the end of the corresponding section.
    var endLine: String {
        return "--\(self)--"
    }
}

extension String {
    func quotedPrintableEncoded() -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!*+-/=_")
        var result = ""
        for character in self {
            if allowed.contains(character.unicodeScalars.first!) {
                result.append(character)
            } else {
                let unicode = character.unicodeScalars.first!.value
                result += String(format: "=%02X", unicode)
            }
        }
        return result
    }
}

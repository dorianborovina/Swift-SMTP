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
            // RFC 5322: a blank line separates headers from body. mail.headersString ends without a
            // trailing CRLF, so we send one CRLF here to terminate the last header line and one
            // more to produce the required blank line.
            try send(CRLF)
            try send(CRLF)
            logger.log("Email headers sent successfully")

            if !mail.attachments.isEmpty {
                logger.log("Email contains attachments, sending as multipart/mixed")
                try sendMixedBody(mail)
            } else if mail.html != nil || mail.alternative != nil {
                logger.log("Email is multipart/alternative")
                try sendAlternativeParts(mail, boundary: mail.outerBoundary)
                try send("--\(mail.outerBoundary)--\(CRLF)")
            } else {
                logger.log("Email is plain text")
                try send(mail.text)
                try send(CRLF)
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

    private func sendMixedBody(_ mail: Mail) throws {
        let outer = mail.outerBoundary

        // First section: text alone, or text + html wrapped in an alternative container.
        try send("--\(outer)\(CRLF)")

        if mail.html != nil || mail.alternative != nil {
            let inner = mail.innerBoundary
            try send("Content-Type: multipart/alternative; boundary=\"\(inner)\"\(CRLF)")
            try send(CRLF)
            try sendAlternativeParts(mail, boundary: inner)
            try send("--\(inner)--\(CRLF)")
        } else {
            try sendTextPart(mail.text)
        }

        // Remaining sections: each attachment.
        for (index, attachment) in mail.attachments.enumerated() {
            logger.log("Sending attachment \(index + 1) of \(mail.attachments.count)")
            try send("--\(outer)\(CRLF)")
            try sendAttachment(attachment)
        }

        try send("--\(outer)--\(CRLF)")
    }

    private func sendAlternativeParts(_ mail: Mail, boundary: String) throws {
        // Plain text part.
        try send("--\(boundary)\(CRLF)")
        try sendTextPart(mail.text)

        // HTML part — prefer mail.html when present, otherwise fall back to the
        // alternative HTML attachment if one was provided.
        if let html = mail.html {
            try send("--\(boundary)\(CRLF)")
            try sendHTMLPart(html)
        } else if let alternative = mail.alternative {
            try send("--\(boundary)\(CRLF)")
            try sendAttachment(alternative)
        }
    }

    private func sendTextPart(_ text: String) throws {
        try send("Content-Type: text/plain; charset=UTF-8\(CRLF)")
        try send("Content-Transfer-Encoding: 8bit\(CRLF)")
        try send(CRLF)
        try send(text)
        try send(CRLF)
    }

    private func sendHTMLPart(_ html: String) throws {
        try send("Content-Type: text/html; charset=UTF-8\(CRLF)")
        try send("Content-Transfer-Encoding: 8bit\(CRLF)")
        try send(CRLF)
        try send(html)
        try send(CRLF)
    }

    func sendAttachment(_ attachment: Attachment) throws {
        var relatedBoundary = ""

        if attachment.hasRelated {
            logger.log("Sending attachment with related content")
            relatedBoundary = String.makeBoundary()
            try send(String.makeRelatedHeader(boundary: relatedBoundary))
            try send(CRLF)
            try send("\(relatedBoundary.startLine)\(CRLF)")
        }

        try send(attachment.headersString)
        try send(CRLF)
        try send(CRLF)

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

        try send(CRLF)

        if attachment.hasRelated {
            try sendAttachments(attachment.relatedAttachments, boundary: relatedBoundary)
        }
    }

    func sendAttachments(_ attachments: [Attachment], boundary: String) throws {
        logger.log("Starting to send \(attachments.count) related attachments")
        for (index, attachment) in attachments.enumerated() {
            try send("\(boundary.startLine)\(CRLF)")
            logger.log("Sending related attachment \(index + 1) of \(attachments.count)")
            try sendAttachment(attachment)
        }
        try send("\(boundary.endLine)\(CRLF)")
        logger.log("All related attachments sent successfully")
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
    // The SMTP protocol requires unique boundaries between sections of an email.
    static func makeBoundary() -> String {
        return UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    // Header for an attachment that is related to another attachment. (Such as an image attachment that can be
    // referenced by a related HTML attachment)
    static func makeRelatedHeader(boundary: String) -> String {
        return "Content-Type: multipart/related; boundary=\"\(boundary)\"\(CRLF)"
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

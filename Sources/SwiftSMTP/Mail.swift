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

/// Represents an email that can be sent through an `SMTP` instance.
public struct Mail {
    /// A UUID for the mail.
    public let uuid = UUID().uuidString

    /// The `User` that the `Mail` will be sent from.
    public let from: User

    /// Array of `User`s to send the `Mail` to.
    public let to: [User]

    /// Array of `User`s to cc. Defaults to none.
    public let cc: [User]

    /// Array of `User`s to bcc. Defaults to none.
    public let bcc: [User]

    /// Subject of the `Mail`. Defaults to none.
    public let subject: String

    /// Text of the `Mail`. Defaults to none.
    public let text: String
    
    /// HTML content of the `Mail`. Defaults to none.
    public let html: String?

    /// Array of `Attachment`s for the `Mail`. If the `Mail` has multiple `Attachment`s that are alternatives to plain
    /// text, the last one will be used as the alternative (all the `Attachments` will still be sent). Defaults to none.
    public let attachments: [Attachment]

    /// Attachment that is an alternative to plain text.
    public let alternative: Attachment?

    /// Additional headers for the `Mail`. Header keys are capitalized and duplicate keys will overwrite each other.
    /// Defaults to none. The following will be ignored: CONTENT-TYPE, CONTENT-DISPOSITION, CONTENT-TRANSFER-ENCODING.
    public let additionalHeaders: [String: String]

    /// Logs detailed information about the mail for diagnostic purposes
    public func logDetails(_ logger: SMTPLogger) {
        logger.log("Mail Details:")
        logger.log("- Message ID: \(id)")
        logger.log("- From: \(from.mime)")
        logger.log("- To (\(to.count) recipients): \(to.map { $0.mime }.joined(separator: ", "))")
        
        if !cc.isEmpty {
            logger.log("- CC (\(cc.count) recipients): \(cc.map { $0.mime }.joined(separator: ", "))")
        }
        
        if !bcc.isEmpty {
            logger.log("- BCC (\(bcc.count) recipients): \(bcc.map { $0.mime }.joined(separator: ", "))")
        }
        
        logger.log("- Subject: \(subject)")
        logger.log("- Content Type: \(contentType)")
        
        if !text.isEmpty {
            logger.log("- Plain Text Content Length: \(text.count) characters")
        }
        
        if let html = html {
            logger.log("- HTML Content Length: \(html.count) characters")
        }
        
        if !attachments.isEmpty {
            logger.log("- Attachments (\(attachments.count)):")
            for (index, attachment) in attachments.enumerated() {
                logAttachmentDetails(attachment, index: index + 1, logger: logger)
            }
        }
        
        if let alternative = alternative {
            logger.log("- Alternative Content:")
            logAttachmentDetails(alternative, index: 1, logger: logger)
        }
        
        if !additionalHeaders.isEmpty {
            logger.log("- Additional Headers:")
            for (key, value) in additionalHeaders {
                logger.log("  • \(key): \(value)")
            }
        }
    }
    
    private func logAttachmentDetails(_ attachment: Attachment, index: Int, logger: SMTPLogger) {
        switch attachment.type {
        case .data(_, let mime, let name, let inline):
            logger.log("  \(index). Data Attachment: \(name)")
            logger.log("     - MIME Type: \(mime)")
            logger.log("     - Inline: \(inline)")
            
        case .file(let path, let mime, let name, let inline):
            logger.log("  \(index). File Attachment: \(name)")
            logger.log("     - Path: \(path)")
            logger.log("     - MIME Type: \(mime)")
            logger.log("     - Inline: \(inline)")
            
        case .html(_, let charset, let alternative):
            logger.log("  \(index). HTML Attachment")
            logger.log("     - Charset: \(charset)")
            logger.log("     - Alternative: \(alternative)")
        }
        
        if !attachment.additionalHeaders.isEmpty {
            logger.log("     - Additional Headers:")
            for (key, value) in attachment.additionalHeaders {
                logger.log("       • \(key): \(value)")
            }
        }
        
        if attachment.hasRelated {
            logger.log("     - Has \(attachment.relatedAttachments.count) related attachment(s)")
        }
    }

    public var id: String {
        return "<\(uuid).Swift-SMTP@\(hostname)>"
    }

    public var hostname: String {
        let fullEmail = from.email
        #if swift(>=4.2)
            let atIndex = fullEmail.firstIndex(of: "@")
        #else
            let atIndex = fullEmail.index(of: "@")
        #endif
        let hostStart = fullEmail.index(after: atIndex!)
        return String(fullEmail[hostStart...])
    }

    public init(from: User,
                to: [User],
                cc: [User] = [],
                bcc: [User] = [],
                subject: String = "",
                text: String = "",
                html: String? = nil,
                attachments: [Attachment] = [],
                additionalHeaders: [String: String] = [:]) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.text = text
        self.html = html

        let (alternative, attachments) = Mail.getAlternative(attachments)
        self.alternative = alternative
        self.attachments = attachments

        self.additionalHeaders = additionalHeaders
    }

    private static func getAlternative(_ attachments: [Attachment]) -> (Attachment?, [Attachment]) {
        var reversed: [Attachment] = attachments.reversed()
        #if swift(>=4.2)
            let index = reversed.firstIndex(where: { $0.isAlternative })
        #else
            let index = reversed.index(where: { $0.isAlternative })
        #endif
        if let index = index {
            return (reversed.remove(at: index), reversed.reversed())
        }
        return (nil, attachments)
    }
    
    public var contentType: String {
        if html != nil {
            let boundary = "Swift-SMTP-\(UUID().uuidString)"
            return "multipart/alternative; boundary=\"\(boundary)\""
        } else {
            return "text/plain; charset=UTF-8"
        }
    }

    private var headersDictionary: [String: String] {
        var dictionary = [String: String]()
        dictionary["MESSAGE-ID"] = id
        dictionary["DATE"] = Date().smtpFormatted
        dictionary["FROM"] = from.mime
        dictionary["TO"] = to.map { $0.mime }.joined(separator: ", ")
        dictionary["SUBJECT"] = subject.mimeEncoded ?? ""
        dictionary["MIME-Version"] = "1.0"
        dictionary["Content-Type"] = contentType

        if !cc.isEmpty {
            dictionary["CC"] = cc.map { $0.mime }.joined(separator: ", ")
        }

        for (key, value) in additionalHeaders {
            let keyUppercased = key.uppercased()
            if  keyUppercased != "CONTENT-TYPE" &&
                keyUppercased != "CONTENT-DISPOSITION" &&
                keyUppercased != "CONTENT-TRANSFER-ENCODING" {
                dictionary[keyUppercased] = value
            }
        }

        return dictionary
    }

    var headersString: String {
        return headersDictionary.map { (key, value) in
            return "\(key): \(value)"
            }.joined(separator: CRLF)
    }

    var hasAttachment: Bool {
        return !attachments.isEmpty || alternative != nil || html != nil
    }
}

extension Mail {
    /// Represents a sender or receiver of an email.
    public struct User {
        /// The user's name that is displayed in an email. Optional.
        public let name: String?

        /// The user's email address.
        public let email: String

        ///  Initializes a `User`.
        ///
        /// - Parameters:
        ///     - name: The user's name that is displayed in an email. Optional.
        ///     - email: The user's email address.
        public init(name: String? = nil, email: String) {
            self.name = name
            self.email = email
        }

        var mime: String {
            if let name = name, let nameEncoded = name.mimeEncoded {
                return "\(nameEncoded) <\(email)>"
            } else {
                return email
            }
        }
    }
}

extension DateFormatter {
    static let smtpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss ZZZ"
        return formatter
    }()
}

extension Date {
    var smtpFormatted: String {
        return DateFormatter.smtpDateFormatter.string(from: self)
    }
}

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

#if os(Linux)
    import Dispatch
#endif

/// (`Mail`, `Error`) callback after each `Mail` is sent. `Mail` is the mail sent and `Error` is the error if it failed.
public typealias Progress = ((Mail, Error?) -> Void)?

/// ([`Mail`], [(`Mail`, `Error`)]) callback after all `Mail`s have been attempted. [`Mail`] is an array of successfully
///  sent `Mail`s. [(`Mail`, `Error`)] is an array of failed `Mail`s and their corresponding `Error`s.
public typealias Completion = (([Mail], [(Mail, Error)]) -> Void)?

class MailSender {
    private var socket: SMTPSocket
    private var mailsToSend: [Mail]
    private var progress: Progress
    private var completion: Completion
    private var sent = [Mail]()
    private var failed = [(Mail, Error)]()
    private var dataSender: DataSender
    private let logger: SMTPLogger

    init(socket: SMTPSocket,
         mailsToSend: [Mail],
         progress: Progress,
         completion: Completion,
         logger: SMTPLogger) {
        self.socket = socket
        self.mailsToSend = mailsToSend
        self.progress = progress
        self.completion = completion
        self.logger = logger
        self.dataSender = DataSender(socket: socket, logger: logger)
    }

    func send() {
        logger.log("Starting to send emails")
        DispatchQueue.global().async {
            self.sendNext()
        }
    }

    private func sendNext() {
        if mailsToSend.isEmpty {
            logger.log("All emails processed")
            completion?(sent, failed)
            progress = nil
            completion = nil
            do {
                try quit()
            } catch {
                logger.logError(error, context: "Quitting SMTP session")
            }
            return
        }
        let mail = mailsToSend.removeFirst()
        do {
            logger.log("Attempting to send email: \(mail.subject)")
            try send(mail)
            if completion != nil {
                sent.append(mail)
            }
            progress?(mail, nil)
            logger.log("Email sent successfully: \(mail.subject)")
        } catch {
            logger.logError(error, context: "Sending mail: \(mail.subject)")
            if completion != nil {
                failed.append((mail, error))
            }
            progress?(mail, error)
        }
        DispatchQueue.global().async {
            self.sendNext()
        }
    }

    private func quit() throws {
        logger.log("Initiating SMTP quit sequence")
        try socket.send(.quit)
        socket.close()
        logger.log("SMTP session closed")
    }

    private func send(_ mail: Mail) throws {
        let recipientEmails = try getRecipientEmails(from: mail)
        try validateEmails(recipientEmails)
        try sendMail(mail.from.email)
        try sendTo(recipientEmails)
        try data()
        try dataSender.send(mail)
        try dataEnd()
    }

    private func createEmailContent(_ mail: Mail) -> String {
        var message = mail.headersString + "\r\n"
        
        if let html = mail.html {
            let boundary = "Swift-SMTP-\(UUID().uuidString)"
            message += "MIME-Version: 1.0\r\n"
            message += "Content-Type: multipart/alternative; boundary=\"\(boundary)\"\r\n\r\n"
            
            // Plain text part
            message += "--\(boundary)\r\n"
            message += "Content-Type: text/plain; charset=UTF-8\r\n\r\n"
            message += "\(mail.text)\r\n\r\n"
            
            // HTML part
            message += "--\(boundary)\r\n"
            message += "Content-Type: text/html; charset=UTF-8\r\n\r\n"
            message += "\(html)\r\n\r\n"
            
            message += "--\(boundary)--\r\n"
        } else {
            message += "Content-Type: text/plain; charset=UTF-8\r\n\r\n"
            message += "\(mail.text)\r\n"
        }
        
        return message
    }

    private func getRecipientEmails(from mail: Mail) throws -> [String] {
        var recipientEmails = mail.to.map { $0.email }
        recipientEmails += mail.cc.map { $0.email }
        recipientEmails += mail.bcc.map { $0.email }

        guard !recipientEmails.isEmpty else {
            logger.logError(SMTPError.noRecipients, context: "Getting recipient emails")
            throw SMTPError.noRecipients
        }

        return recipientEmails
    }

    private func validateEmails(_ emails: [String]) throws {
        for email in emails {
            do {
                if try !email.isValidEmail() {
                    throw SMTPError.invalidEmail(email: email)
                }
            } catch {
                logger.logError(error, context: "Validating email: \(email)")
                throw error
            }
        }
    }

    private func sendMail(_ from: String) throws {
        logger.log("Sending MAIL FROM command: \(from)")
        try socket.send(.mail(from))
    }

    private func sendTo(_ emails: [String]) throws {
        for email in emails {
            logger.log("Sending RCPT TO command: \(email)")
            try socket.send(.rcpt(email))
        }
    }

    private func data() throws {
        logger.log("Sending DATA command")
        try socket.send(.data)
    }

    private func dataEnd() throws {
        logger.log("Sending end of data")
        try socket.send(.dataEnd)
    }

    func login(authMethod: AuthMethod, email: String, password: String) throws {
        switch authMethod {
        case .cramMD5:
            try loginCramMD5(email: email, password: password)
        case .login:
            try loginLogin(email: email, password: password)
        case .plain:
            try loginPlain(email: email, password: password)
        case .xoauth2:
            try loginXOAuth2(email: email, accessToken: password)
        }
    }

    func loginCramMD5(email: String, password: String) throws {
        let challenge = try auth(authMethod: .cramMD5, credentials: nil).message
        logger.logReceived("334 \(challenge)")
        let response = try AuthEncoder.cramMD5(challenge: challenge, user: email, password: password)
        try authPassword(response)
        logger.logSent("(CRAM-MD5 response)")
    }

    func loginLogin(email: String, password: String) throws {
        try auth(authMethod: .login, credentials: nil)
        let credentials = AuthEncoder.login(user: email, password: password)
        try authUser(credentials.encodedUser)
        logger.logSent("(base64-encoded username)")
        try authPassword(credentials.encodedPassword)
        logger.logSent("(base64-encoded password)")
    }

    func loginPlain(email: String, password: String) throws {
        let credentials = AuthEncoder.plain(user: email, password: password)
        try auth(authMethod: .plain, credentials: credentials)
        logger.logSent("(base64-encoded credentials)")
    }

    func loginXOAuth2(email: String, accessToken: String) throws {
        let credentials = AuthEncoder.xoauth2(user: email, accessToken: accessToken)
        try auth(authMethod: .xoauth2, credentials: credentials)
        logger.logSent("(XOAUTH2 token)")
    }

    @discardableResult
    func auth(authMethod: AuthMethod, credentials: String?) throws -> Response {
        let responses = try socket.send(.auth(authMethod, credentials))
        guard let response = responses.first else {
            throw SMTPError.badResponse(command: "AUTH", response: responses.description)
        }
        return response
    }

    func authUser(_ user: String) throws {
        try socket.send(.authUser(user))
    }

    func authPassword(_ password: String) throws {
        try socket.send(.authPassword(password))
    }
}

private extension NSRegularExpression {
    static let emailRegex = try? NSRegularExpression(pattern: "^[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}")
}

private extension String {
    func isValidEmail() throws -> Bool {
        guard let emailRegex = NSRegularExpression.emailRegex else {
            throw SMTPError.createEmailRegexFailed
        }
        let range = NSRange(location: 0, length: count)
        return !emailRegex.matches(in: self, options: [], range: range).isEmpty
    }
}

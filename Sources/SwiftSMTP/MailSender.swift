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
        DispatchQueue.global().async {
            self.sendNext()
        }
    }
}

private extension MailSender {
    func sendNext() {
        if mailsToSend.isEmpty {
            completion?(sent, failed)
            progress = nil
            completion = nil
            try? quit()
            return
        }
        let mail = mailsToSend.removeFirst()
        do {
            try send(mail)
            if completion != nil {
                sent.append(mail)
            }
            progress?(mail, nil)
        } catch {
            if completion != nil {
                failed.append((mail, error))
            }
            progress?(mail, error)
        }
        DispatchQueue.global().async {
            self.sendNext()
        }
    }

    func quit() throws {
        try socket.send(.quit)
        socket.close()
    }

    func send(_ mail: Mail) throws {
        let recipientEmails = try getRecipientEmails(from: mail)
        try validateEmails(recipientEmails)
        try sendMail(mail.from.email)
        try sendTo(recipientEmails)
        try data()
        try dataSender.send(mail)
        try dataEnd()
    }

    func getRecipientEmails(from mail: Mail) throws -> [String] {
        var recipientEmails = mail.to.map { $0.email }
        recipientEmails += mail.cc.map { $0.email }
        recipientEmails += mail.bcc.map { $0.email }

        guard !recipientEmails.isEmpty else {
            throw SMTPError.noRecipients
        }

        return recipientEmails
    }

    func validateEmails(_ emails: [String]) throws {
        for email in emails where try !email.isValidEmail() {
            throw SMTPError.invalidEmail(email: email)
        }
    }

    func sendMail(_ from: String) throws {
        try socket.send(.mail(from))
    }

    func sendTo(_ emails: [String]) throws {
        for email in emails {
            try socket.send(.rcpt(email))
        }
    }

    func data() throws {
        try socket.send(.data)
    }

    func dataEnd() throws {
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

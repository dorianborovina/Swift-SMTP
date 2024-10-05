/**
 * Copyright IBM Corporation 2018
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
import Socket
import LoggerAPI

struct SMTPSocket {
    private let socket: Socket
    let logger: SMTPLogger
    
    init(hostname: String,
         email: String,
         password: String,
         port: Int32,
         tlsMode: SMTP.TLSMode,
         tlsConfiguration: TLSConfiguration?,
         authMethods: [String: AuthMethod],
         domainName: String,
         timeout: UInt,
         logger: SMTPLogger) throws {
        self.logger = logger
        do {
            socket = try Socket.create()
            logger.logConnection(to: hostname)
            if tlsMode == .requireTLS {
                logger.log("Initiating TLS connection")
                if let tlsConfiguration = tlsConfiguration {
                    socket.delegate = try tlsConfiguration.makeSSLService()
                } else {
                    socket.delegate = try TLSConfiguration().makeSSLService()
                }
                logger.log("TLS configuration applied")
            }
            logger.log("Attempting to connect to \(hostname) on port \(port)")
            try socket.connect(to: hostname, port: port, timeout: timeout * 1000)
            logger.log("Connected successfully")
            let responses = try parseResponses(readFromSocket(), command: .connect)
            logger.log("Received initial server response: \(responses.map { $0.response }.joined(separator: ", "))")
            var serverOptions = try getServerOptions(domainName: domainName)
            if tlsMode == .requireSTARTTLS || tlsMode == .normal {
                if try doStarttls(serverOptions: serverOptions, tlsConfiguration: tlsConfiguration) {
                    logger.log("STARTTLS completed successfully")
                    serverOptions = try getServerOptions(domainName: domainName)
                } else if tlsMode == .requireSTARTTLS {
                    throw SMTPError.requiredSTARTTLS
                }
            }
            let authMethod = try getAuthMethod(authMethods: authMethods, serverOptions: serverOptions, hostname: hostname)
            try login(authMethod: authMethod, email: email, password: password)
        } catch {
            logger.logError(error, context: "SMTPSocket initialization")
            throw error
        }
    }

    func write(_ text: String) throws {
        do {
            _ = try socket.write(from: text + CRLF)
            Log.debug(text)
            logger.logSent(text)
        } catch {
            logger.logError(error, context: "Writing to socket")
            throw error
        }
    }

    func write(_ data: Data) throws {
        do {
            _ = try socket.write(from: data)
            Log.debug("(sending data)")
            logger.logSent("(sending data: \(data.count) bytes)")
        } catch {
            logger.logError(error, context: "Writing data to socket")
            throw error
        }
    }

    @discardableResult
    func send(_ command: Command) throws -> [Response] {
        logger.log("Executing command: \(command)")
        do {
            try write(command.text)
            let responses = try parseResponses(readFromSocket(), command: command)
            for response in responses {
                logger.logReceived(response.response)
            }
            logger.log("Command execution completed")
            return responses
        } catch {
            logger.logError(error, context: "Sending command: \(command.text)")
            throw error
        }
    }

    func close() {
        socket.close()
        logger.logDisconnection()
    }

    private func readFromSocket() throws -> String {
        var buf = Data()
        do {
            _ = try socket.read(into: &buf)
            guard let responses = String(data: buf, encoding: .utf8) else {
                throw SMTPError.convertDataUTF8Fail(data: buf)
            }
            Log.debug(responses)
            return responses
        } catch {
            logger.logError(error, context: "Reading from socket")
            throw error
        }
    }

    private func parseResponses(_ responses: String, command: Command) throws -> [Response] {
        let responsesArray = responses.components(separatedBy: CRLF)
        guard !responsesArray.isEmpty else {
            throw SMTPError.badResponse(command: command.text, response: responses)
        }
        return try responsesArray.compactMap { response in
            guard response != "" else {
                return nil
            }
            logger.logReceived(response)
            return Response(
                code: try getResponseCode(response, command: command),
                message: getResponseMessage(response),
                response: response
            )
        }
    }

    private func getResponseCode(_ response: String, command: Command) throws -> ResponseCode {
        guard response.count > 3 else {
            throw SMTPError.badResponse(command: command.text, response: response)
        }
        guard let code = Int(response[..<response.index(response.startIndex, offsetBy: 3)]) else {
            throw SMTPError.badResponse(command: command.text, response: response)
        }
        guard
            response.count > 2,
            command.expectedResponseCodes.map({ $0.rawValue }).contains(code) else {
                throw SMTPError.badResponse(command: command.text, response: response)
        }
        return ResponseCode(code)
    }

    private func getResponseMessage(_ response: String) -> String {
        guard response.count > 3 else {
            return ""
        }
        return String(response[response.index(response.startIndex, offsetBy: 4)...])
    }

    private func getServerOptions(domainName: String) throws -> [Response] {
        logger.log("Retrieving server options")
        do {
            return try send(.ehlo(domainName))
        } catch {
            logger.log("EHLO command failed, attempting HELO")
            return try send(.helo(domainName))
        }
    }

    private func getAuthMethod(authMethods: [String: AuthMethod], serverOptions: [Response], hostname: String) throws -> AuthMethod {
        logger.log("Determining authentication method")
        for option in serverOptions {
            let components = option.message.components(separatedBy: " ")
            if components.first == "AUTH" {
                let _authMethods = components.dropFirst()
                for authMethod in _authMethods {
                    if let matchingAuthMethod = authMethods[authMethod] {
                        logger.log("Selected auth method: \(matchingAuthMethod.rawValue)")
                        return matchingAuthMethod
                    }
                }
            }
        }
        logger.logError(SMTPError.noAuthMethodsOrRequiresTLS(hostname: hostname), context: "Determining auth method")
        throw SMTPError.noAuthMethodsOrRequiresTLS(hostname: hostname)
    }

    private func doStarttls(serverOptions: [Response], tlsConfiguration: TLSConfiguration?) throws -> Bool {
        for option in serverOptions {
            if option.message == "STARTTLS" {
                try starttls(tlsConfiguration: tlsConfiguration)
                return true
            }
        }
        return false
    }

    private func starttls(tlsConfiguration: TLSConfiguration?) throws {
        logger.log("Initiating STARTTLS")
        try send(.starttls)
        logger.log("STARTTLS command sent, upgrading connection")
        if let tlsConfiguration = tlsConfiguration {
            socket.delegate = try tlsConfiguration.makeSSLService()
        } else {
            socket.delegate = try TLSConfiguration().makeSSLService()
        }
        try socket.delegate?.initialize(asServer: false)
        try socket.delegate?.onConnect(socket: socket)
        logger.log("TLS connection established")
    }

    private func login(authMethod: AuthMethod, email: String, password: String) throws {
        logger.log("Attempting login with method: \(authMethod.rawValue)")
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
        logger.log("Login successful")
    }

    private func loginCramMD5(email: String, password: String) throws {
        let challenge = try auth(authMethod: .cramMD5, credentials: nil).message
        logger.logReceived("334 \(challenge)")
        let response = try AuthEncoder.cramMD5(challenge: challenge, user: email, password: password)
        try authPassword(response)
        logger.logSent("(CRAM-MD5 response)")
    }

    private func loginLogin(email: String, password: String) throws {
        try auth(authMethod: .login, credentials: nil)
        let credentials = AuthEncoder.login(user: email, password: password)
        try authUser(credentials.encodedUser)
        logger.logSent("(base64-encoded username)")
        try authPassword(credentials.encodedPassword)
        logger.logSent("(base64-encoded password)")
    }

    private func loginPlain(email: String, password: String) throws {
        let credentials = AuthEncoder.plain(user: email, password: password)
        try auth(authMethod: .plain, credentials: credentials)
        logger.logSent("(base64-encoded credentials)")
    }

    private func loginXOAuth2(email: String, accessToken: String) throws {
        let credentials = AuthEncoder.xoauth2(user: email, accessToken: accessToken)
        try auth(authMethod: .xoauth2, credentials: credentials)
        logger.logSent("(XOAUTH2 token)")
    }

    @discardableResult
    private func auth(authMethod: AuthMethod, credentials: String?) throws -> Response {
        let responses = try send(.auth(authMethod, credentials))
        guard let response = responses.first else {
            throw SMTPError.badResponse(command: "AUTH", response: responses.description)
        }
        return response
    }

    private func authUser(_ user: String) throws {
        try send(.authUser(user))
    }

    private func authPassword(_ password: String) throws {
        try send(.authPassword(password))
    }
}

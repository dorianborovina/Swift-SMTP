//
//  SMTPLogger.swift
//  SwiftSMTP
//
//  Created by Dorian Borovina on 05.10.24.
//

import Foundation

public class SMTPLogger {
    public private(set) var transactionLog: [String] = []
    private var lastLogMessage: String?
    
    public func clearLog() {
        transactionLog.removeAll()
        lastLogMessage = nil
    }
    
    public func logConnection(to hostname: String) {
        log("Connected to \(hostname)")
    }
    
    public func logDisconnection() {
        log("Connection closed")
    }
    
    public func logSent(_ command: String) {
        log("C: \(command)")
    }
    
    public func logReceived(_ response: String) {
        log("S: \(response)")
    }
    
    public func logTLSNegotiation() {
        log("(TLS negotiation details)")
    }
    
    public func logAuthAttempt(method: String) {
        log("Attempting authentication with method: \(method)")
    }
    
    public func logAuthSuccess() {
        log("Authentication successful")
    }
    
    public func logMailFrom(address: String) {
        log("Setting sender: \(address)")
    }
    
    public func logRcptTo(address: String) {
        log("Adding recipient: \(address)")
    }
    
    public func logDataStart() {
        log("Starting to send email data")
    }
    
    public func logDataEnd() {
        log("Finished sending email data")
    }
    
    public func logAttachmentStart(name: String, size: Int) {
        log("Starting to send attachment: \(name) (\(size) bytes)")
    }
    
    public func logAttachmentEnd(name: String) {
        log("Finished sending attachment: \(name)")
    }
    
    public func logTimeout() {
        log("Connection timed out")
    }
    
    public func logConnecting(hostname: String, port: Int32) {
        log("Connecting to \(hostname) on port \(port)")
    }
    
    public func logStartTLS() {
        log("Initiating STARTTLS connection upgrade")
    }
    
    public func logTLSSuccess() {
        log("TLS connection established successfully")
    }
    
    public func logQuit() {
        log("Sending QUIT command")
    }
    
    public func logSessionReset() {
        log("Resetting SMTP session")
    }
    
    public func logRetry(attempt: Int, maxAttempts: Int) {
        log("Retry attempt \(attempt) of \(maxAttempts)")
    }
    
    public func logError(_ error: Error, context: String) {
        let errorMessage = "Error in \(context): \(error.localizedDescription)"
        log(errorMessage)
    }
    
    public func logWarning(_ message: String) {
        log("Warning: \(message)")
    }
    
    public func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logEntry = "[\(timestamp)] \(message)"
        
        // Extract content without timestamp for comparison
        let contentWithoutTimestamp = message
        
        // Check if this message is a duplicate of the last one
        if let lastMessage = lastLogMessage,
           lastMessage == contentWithoutTimestamp {
            // Skip duplicate message
            return
        }
        
        transactionLog.append(logEntry)
        lastLogMessage = contentWithoutTimestamp
    }
    
    // Helper method to get the complete transaction log as a string
    public func getCompleteLog() -> String {
        return transactionLog.joined(separator: "\n")
    }
}

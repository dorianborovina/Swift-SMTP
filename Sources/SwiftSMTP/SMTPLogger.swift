//
//  File.swift
//  SwiftSMTP
//
//  Created by Dorian Borovina on 05.10.24.
//

import Foundation

public class SMTPLogger {
    public private(set) var transactionLog: [String] = []
    
    public func clearLog() {
        transactionLog.removeAll()
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
    
    private func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logEntry = "[\(timestamp)] \(message)"
        transactionLog.append(logEntry)
    }
}

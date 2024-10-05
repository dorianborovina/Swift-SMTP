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
    
    public func logSent(_ command: String) {
        transactionLog.append("C: \(command)")
    }
    
    public func logReceived(_ response: String) {
        transactionLog.append("S: \(response)")
    }
}

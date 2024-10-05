//
//  File.swift
//  SwiftSMTP
//
//  Created by Dorian Borovina on 05.10.24.
//

import Foundation

public class SMTPLogger {
    private(set) var transactionLog: [String] = []
    
    func clearLog() {
        transactionLog.removeAll()
    }
    
    func logSent(_ command: String) {
        transactionLog.append("C: \(command)")
    }
    
    func logReceived(_ response: String) {
        transactionLog.append("S: \(response)")
    }
}

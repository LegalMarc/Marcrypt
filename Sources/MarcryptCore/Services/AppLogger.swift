import Foundation
import os

/// Centralized logger for Marcrypt using OSLog.
/// Respects the "EnableDebugLogging" UserDefault for debug/verbose level logs.
public enum AppLogger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.marclaw.Marcrypt"
    
    // Categories
    public static let general = Logger(subsystem: subsystem, category: "General")
    public static let encryption = Logger(subsystem: subsystem, category: "Encryption")
    public static let pdf = Logger(subsystem: subsystem, category: "PDF")
    public static let docx = Logger(subsystem: subsystem, category: "DOCX")
    public static let secureErase = Logger(subsystem: subsystem, category: "SecureErase")
    public static let ui = Logger(subsystem: subsystem, category: "UI")
    
    /// Log a debug message (only if enabled in settings).
    public static func debug(_ message: String, logger: Logger = general, file: String = #file, function: String = #function, line: Int = #line) {
        LogManager.shared.log(message, level: .debug, category: logger, file: file, line: line)
    }
    
    /// Log an informational message.
    public static func info(_ message: String, logger: Logger = general, file: String = #file, function: String = #function, line: Int = #line) {
         LogManager.shared.log(message, level: .info, category: logger, file: file, line: line)
    }
    
    /// Log a warning.
    public static func warning(_ message: String, logger: Logger = general, file: String = #file, function: String = #function, line: Int = #line) {
         LogManager.shared.log(message, level: .warning, category: logger, file: file, line: line)
    }
    
    /// Log an error.
    public static func error(_ message: String, error: Error? = nil, logger: Logger = general, file: String = #file, function: String = #function, line: Int = #line) {
         LogManager.shared.log(message, level: .error, category: logger, file: file, line: line, error: error)
    }
}

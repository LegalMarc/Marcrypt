import Foundation
import os
import AppKit

/// Dual logging service: Writes to OSLog (System) and a local file (User viewable).
public class LogManager {
    public static let shared = LogManager()

    // File Logger Config
    private let fileManager = FileManager.default
    private var logFileURL: URL?
    private let fileQueue = DispatchQueue(label: "com.marcrypt.fileLogger", qos: .utility)

    // OSLog Categories
    public static let general = Logger(subsystem: "com.marcrypt", category: "General")
    public static let encryption = Logger(subsystem: "com.marcrypt", category: "Encryption")
    public static let pdf = Logger(subsystem: "com.marcrypt", category: "PDF")
    public static let docx = Logger(subsystem: "com.marcrypt", category: "DOCX")
    public static let secureErase = Logger(subsystem: "com.marcrypt", category: "SecureErase")
    public static let ui = Logger(subsystem: "com.marcrypt", category: "UI")

    // Config
    var isDebugEnabled: Bool {
        UserDefaults.standard.bool(forKey: "EnableDebugLogging")
    }

    private init() {
        setupFileLogging()
        log("=== MarcryptApp Log Started (v1.0) ===", level: .info)
    }

    private func setupFileLogging() {
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let logDir = appSupport.appendingPathComponent("Marcrypt")
            try? fileManager.createDirectory(at: logDir, withIntermediateDirectories: true)
            logFileURL = logDir.appendingPathComponent("marcrypt.log")

            // Rotate log if too large (> 5MB)
            if let fileSize = try? fileManager.attributesOfItem(atPath: logFileURL!.path)[.size] as? Int64, fileSize > 5 * 1024 * 1024 {
                 try? fileManager.removeItem(at: logFileURL!)
            }
        }
    }

    // MARK: - Public API

    public func openLogFile() {
        guard let url = logFileURL else { return }
        NSWorkspace.shared.open(url)
    }

    public func clearLogs() {
        fileQueue.sync { [weak self] in
            guard let self, let url = self.logFileURL else { return }
            try? self.fileManager.removeItem(at: url)
        }
    }

    public enum LogLevel: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
    }

    public func log(_ message: String, level: LogLevel = .info, category: Logger = general, file: String = #file, line: Int = #line, error: Error? = nil) {
        // 1. OSLog (Always, based on system rules)
        switch level {
        case .debug:
            if isDebugEnabled { category.debug("\(message)") }
        case .info:
            category.info("\(message)")
        case .warning:
            category.warning("\(message)")
        case .error:
            if let e = error {
                category.error("\(message) | Error: \(e.localizedDescription)")
            } else {
                category.error("\(message)")
            }
        }

        // 2. File Log (If enabled or level >= info)
        // We log everything to file if debug is enabled, otherwise only INFO/WARN/ERROR
        if isDebugEnabled || level != .debug {
            let timestamp = Date().ISO8601Format()
            let fileName = (file as NSString).lastPathComponent
            var logLine = "\(timestamp) [\(level.rawValue)] [\(fileName):\(line)] \(message)"
            if let e = error {
                logLine += " -> ERROR: \(e)" // Use full error description for file
            }
            logLine += "\n"

            fileQueue.async { [weak self] in
                self?.appendToFile(line: logLine)
            }
        }
    }

    private func appendToFile(line: String) {
        guard let url = logFileURL else { return }

        if !fileManager.fileExists(atPath: url.path) {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        } else {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                if let data = line.data(using: .utf8) {
                    handle.write(data)
                }
                try? handle.close()
            }
        }
    }
}

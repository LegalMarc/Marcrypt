import Foundation
import CryptoKit

/// Append-only audit trail for document processing operations.
/// Records structured JSON events for legal defensibility.
public class AuditService {
    public static let shared = AuditService()

    /// Supported operation types
    public enum AuditOperation: String, Codable {
        case encrypt
        case decrypt
        case watermark
        case batesStamp
        case shred
        case metadataStrip
        case split
        case classify
    }

    /// Operation outcome
    public enum AuditOutcome: Codable {
        case success
        case failure(reason: String)

        // Manual Codable for associated value
        enum CodingKeys: String, CodingKey { case type, reason }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .success:
                try container.encode("success", forKey: .type)
            case .failure(let reason):
                try container.encode("failure", forKey: .type)
                try container.encode(reason, forKey: .reason)
            }
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            if type == "success" {
                self = .success
            } else {
                let reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? "Unknown"
                self = .failure(reason: reason)
            }
        }
    }

    /// A single audit event
    public struct AuditEvent: Codable {
        public let timestamp: Date
        public let operation: AuditOperation
        public let inputFile: String
        public let inputHash: String?
        public let outputFile: String?
        public let outputHash: String?
        public let outcome: AuditOutcome
        public let parameters: [String: String]

        public init(
            operation: AuditOperation,
            inputFile: String,
            inputHash: String? = nil,
            outputFile: String? = nil,
            outputHash: String? = nil,
            outcome: AuditOutcome,
            parameters: [String: String] = [:]
        ) {
            self.timestamp = Date()
            self.operation = operation
            self.inputFile = inputFile
            self.inputHash = inputHash
            self.outputFile = outputFile
            self.outputHash = outputHash
            self.outcome = outcome
            self.parameters = parameters
        }
    }

    // MARK: - Storage

    private let auditFileURL: URL
    private let encoder: JSONEncoder
    private let queue = DispatchQueue(label: "com.marcrypt.audit", qos: .utility)
    private var persistentAuditEnabled: Bool {
        UserDefaults.standard.bool(forKey: "PersistentAuditEnabled")
    }

    /// All events from the current session (in-memory cache for report generation).
    /// Access is protected by `queue` — use `getSessionEvents()` for thread-safe reads.
    private var _sessionEvents: [AuditEvent] = []

    /// Thread-safe read access to session events.
    public var sessionEvents: [AuditEvent] {
        return queue.sync { _sessionEvents }
    }

    private init() {
        // Store in Application Support
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let marcryptDir = appSupport.appendingPathComponent("Marcrypt")
        try? FileManager.default.createDirectory(at: marcryptDir, withIntermediateDirectories: true)
        self.auditFileURL = marcryptDir.appendingPathComponent("audit.jsonl")

        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
    }

    // MARK: - Public API

    /// Log an audit event. Thread-safe, append-only.
    public func log(event: AuditEvent) {
        queue.async { [weak self] in
            guard let self = self else { return }

            // Cache in memory (same queue = no race)
            self._sessionEvents.append(event)

            guard self.persistentAuditEnabled else { return }

            // Persist to disk only when the user explicitly enables durable audit history.
            do {
                let data = try self.encoder.encode(event)
                if var line = String(data: data, encoding: .utf8) {
                    line += "\n"
                    if let lineData = line.data(using: .utf8) {
                        if FileManager.default.fileExists(atPath: self.auditFileURL.path) {
                            let handle = try FileHandle(forWritingTo: self.auditFileURL)
                            try handle.seekToEnd()
                            try handle.write(contentsOf: lineData)
                            try handle.close()
                        } else {
                            try lineData.write(to: self.auditFileURL, options: .atomic)
                        }
                    }
                }
            } catch {
                AppLogger.error("Failed to write audit event", error: error, logger: AppLogger.general)
            }
        }
    }

    /// Log a simple success event.
    public func logSuccess(
        operation: AuditOperation,
        inputFile: String,
        inputHash: String? = nil,
        outputFile: String? = nil,
        outputHash: String? = nil,
        parameters: [String: String] = [:]
    ) {
        log(event: AuditEvent(
            operation: operation,
            inputFile: inputFile,
            inputHash: inputHash,
            outputFile: outputFile,
            outputHash: outputHash,
            outcome: .success,
            parameters: parameters
        ))
    }

    /// Log a failure event.
    public func logFailure(
        operation: AuditOperation,
        inputFile: String,
        reason: String,
        parameters: [String: String] = [:]
    ) {
        log(event: AuditEvent(
            operation: operation,
            inputFile: inputFile,
            outcome: .failure(reason: reason),
            parameters: parameters
        ))
    }

    /// Read all events from the audit log file.
    public func readAllEvents() -> [AuditEvent] {
        // Read through the same serial queue used for writes to avoid data races
        return queue.sync {
            guard persistentAuditEnabled else { return [] }
            guard let data = try? String(contentsOf: auditFileURL, encoding: .utf8) else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            return data.split(separator: "\n").compactMap { line in
                guard let lineData = String(line).data(using: .utf8) else { return nil }
                return try? decoder.decode(AuditEvent.self, from: lineData)
            }
        }
    }

    /// Clear the session events cache (e.g., after generating a receipt).
    public func clearSessionEvents() {
        queue.async { [weak self] in
            self?._sessionEvents.removeAll()
        }
    }

    /// Clear persisted and in-memory audit history.
    public func clearAllEvents() {
        queue.sync {
            _sessionEvents.removeAll()
            try? FileManager.default.removeItem(at: auditFileURL)
        }
    }

    /// Get the path to the audit log file.
    public var auditLogPath: URL { auditFileURL }
}

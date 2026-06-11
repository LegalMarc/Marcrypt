import Foundation

/// Clears app-controlled history and transient processing artifacts.
public final class HistoryCleanupService {
    public static let shared = HistoryCleanupService()

    private init() {}
    
    public struct Result {
        public let removedPaths: [URL]
        public let failedPaths: [URL]
        
        public var succeeded: Bool { failedPaths.isEmpty }
    }
    
    @discardableResult
    public func clearHistory() -> Result {
        Self.clearHistorySynchronously()
    }
    
    public func clearHistoryAsync() async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.clearHistorySynchronously())
            }
        }
    }
    
    private static func clearHistorySynchronously() -> Result {
        let fileManager = FileManager.default
        
        LogManager.shared.clearLogs()
        AuditService.shared.clearAllEvents()
        TempFileManager.shared.cleanupAll()
        
        var removed: [URL] = []
        var failed: [URL] = []
        
        for url in cleanupTargets(fileManager: fileManager) {
            guard fileManager.fileExists(atPath: url.path) else { continue }
            do {
                try SecureDeletionService.shared.shredItem(at: url)
                removed.append(url)
            } catch {
                failed.append(url)
            }
        }
        
        return Result(removedPaths: removed, failedPaths: failed)
    }

    private static func cleanupTargets(fileManager: FileManager) -> [URL] {
        var targets: [URL] = []
        
        let temp: URL
        if let override = ProcessInfo.processInfo.environment["MARCRYPT_TEMP_ROOT"], !override.isEmpty {
            temp = URL(fileURLWithPath: override).standardizedFileURL
        } else {
            temp = fileManager.temporaryDirectory
        }
        targets.append(temp.appendingPathComponent("MarcryptTemp"))
        
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let appDir = appSupport.appendingPathComponent("Marcrypt")
            targets.append(appDir.appendingPathComponent("marcrypt.log"))
            targets.append(appDir.appendingPathComponent("audit.jsonl"))
        }
        
        return targets
    }
}

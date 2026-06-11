import Foundation

/// Hardened temporary file manager with namespaced directory and atexit cleanup.
/// Ensures no orphaned temp files survive application crashes.
public class TempFileManager {
    
    /// Singleton — prefer this for coordinated cleanup.
    public static let shared = TempFileManager()
    
    /// Namespaced temp directory (e.g., <system tmp>/MarcryptTemp/)
    public let tempDirectory: URL
    
    /// Track all active temp files for atexit cleanup
    private var activeTempFiles: Set<URL> = []
    private let lock = NSLock()
    
    private init() {
        let baseTemp: URL
        if let override = ProcessInfo.processInfo.environment["MARCRYPT_TEMP_ROOT"], !override.isEmpty {
            baseTemp = URL(fileURLWithPath: override).standardizedFileURL
        } else {
            baseTemp = FileManager.default.temporaryDirectory
        }
        self.tempDirectory = baseTemp.appendingPathComponent("MarcryptTemp")
        
        // Ensure the directory exists
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        
        // Register atexit handler for crash safety
        TempFileManager._shared = self
        TempFileManager.registerAtExit()
    }
    
    // MARK: - Public API
    
    /// Create a uniquely named temp file in the Marcrypt namespace.
    /// The returned URL is tracked for automatic cleanup.
    public func createTempFile(extension ext: String = "tmp") -> URL {
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let url = tempDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
        lock.lock()
        activeTempFiles.insert(url)
        lock.unlock()
        return url
    }
    
    /// Create a temp directory within the Marcrypt namespace.
    public func createTempDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let url = tempDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        lock.lock()
        activeTempFiles.insert(url)
        lock.unlock()
        return url
    }
    
    /// Mark a temp file as no longer needed. Securely erases if possible.
    public func release(url: URL) {
        lock.lock()
        activeTempFiles.remove(url)
        lock.unlock()
        
        try? SecureDeletionService.shared.shredItem(at: url)
    }
    
    /// Release all tracked temp files.
    public func releaseAll() {
        lock.lock()
        let files = activeTempFiles
        activeTempFiles.removeAll()
        lock.unlock()
        
        for url in files {
            SecureDeletionService.secureErase(at: url)
        }
    }
    
    /// Clean up the entire namespaced directory (for startup or shutdown).
    public func cleanupAll() {
        // Shred any known active files
        releaseAll()
        
        // Also clean any orphaned files in the directory
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(at: tempDirectory, includingPropertiesForKeys: nil) else { return }
        
        for url in contents {
            // Safety: don't follow symlinks
            let attrs = try? fileManager.attributesOfItem(atPath: url.path)
            if let type = attrs?[.type] as? FileAttributeType, type == .typeSymbolicLink {
                try? fileManager.removeItem(at: url) // Just unlink
            } else {
                try? SecureDeletionService.shared.shredItem(at: url)
            }
        }
    }
    
    /// Number of currently tracked temp files.
    public var activeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return activeTempFiles.count
    }
    
    // MARK: - atexit handler
    
    /// Global static reference for atexit access
    private static var _shared: TempFileManager?
    
    private static func registerAtExit() {
        atexit {
            TempFileManager._shared?.cleanupAll()
        }
    }
}

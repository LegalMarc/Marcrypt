import Foundation
import CryptoKit

/// Service for computing and verifying SHA-256 file integrity hashes.
/// Used before/after encryption operations to ensure data integrity.
public class IntegrityService {
    public static let shared = IntegrityService()
    
    private init() {}
    
    /// Bufferred hash size (1MB chunks for large files)
    private let bufferSize = 1024 * 1024
    
    /// Compute SHA-256 hash of a file at the given URL.
    /// Returns the hex-encoded hash string.
    public func sha256(of url: URL, progress: OperationProgressHandler? = nil) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        
        var hasher = SHA256()
        let totalBytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        var completedBytes: Int64 = 0
        progress?(OperationProgress(completedUnitCount: 0, totalUnitCount: totalBytes, message: url.lastPathComponent))
        
        while autoreleasepool(invoking: {
            let data = handle.readData(ofLength: bufferSize)
            if data.isEmpty { return false }
            hasher.update(data: data)
            completedBytes += Int64(data.count)
            progress?(OperationProgress(completedUnitCount: completedBytes, totalUnitCount: totalBytes, message: url.lastPathComponent))
            return true
        }) {}

        if Task.isCancelled { throw CancellationError() }
        
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    /// Verify a file's SHA-256 hash matches the expected value.
    public func verify(file: URL, expectedHash: String) throws -> Bool {
        let actual = try sha256(of: file)
        return actual.lowercased() == expectedHash.lowercased()
    }
    
    /// Generate a `.sha256` sidecar file alongside the given file.
    /// Format: `<hash>  <filename>` (BSD/GNU coreutils format)
    public func generateSidecar(for url: URL) throws -> URL {
        let hash = try sha256(of: url)
        let sidecarURL = url.appendingPathExtension("sha256")
        let content = "\(hash)  \(url.lastPathComponent)\n"
        try content.write(to: sidecarURL, atomically: true, encoding: .utf8)
        return sidecarURL
    }
}

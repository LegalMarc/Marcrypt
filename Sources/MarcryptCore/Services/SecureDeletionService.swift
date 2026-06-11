import Foundation

/// Service for best-effort overwrite-before-removal.
/// This cannot guarantee physical erasure on SSDs, APFS, or other copy-on-write storage.
/// Pass 1: Overwrite with zeros (0x00)
/// Pass 2: Overwrite with ones (0xFF)
/// Pass 3: Overwrite with random data
/// Final: Remove file
public class SecureDeletionService {
    public static let shared = SecureDeletionService()

    private init() {}

    /// Overwrites and removes a file at the given URL.
    /// Requirements:
    /// - File MUST be writable.
    /// - URL must be a file, not a directory. Directories are shredded via `shredItem(at:)`, which iterates recursively.
    public func shredFile(at url: URL) throws {
        let fileManager = FileManager.default

        // 1. Basic Validation
        guard fileManager.fileExists(atPath: url.path) else { return }

        // Security: Prevent Symlink Traversal
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        if let type = attributes[.type] as? FileAttributeType, type == .typeSymbolicLink {
            // Just unlink the symlink, do NOT overwrite target
            try fileManager.removeItem(at: url)
            return
        }
        let fileSize = (attributes[.size] as? Int64) ?? 0

        guard fileSize > 0 else {
            // Empty file, just delete it
            try fileManager.removeItem(at: url)
            return
        }

        // 2. Open File Handle for Writing
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        // chunk size for writing (e.g., 1MB)
        let chunkSize = 1024 * 1024

        // 3. DoD Pass 1: All Zeros (0x00)
        try overwrite(handle: handle, size: fileSize, pattern: .byte(0x00), chunkSize: chunkSize)

        // 4. DoD Pass 2: All Ones (0xFF)
        try overwrite(handle: handle, size: fileSize, pattern: .byte(0xFF), chunkSize: chunkSize)

        // 5. DoD Pass 3: Random
        try overwrite(handle: handle, size: fileSize, pattern: .random, chunkSize: chunkSize)

        // 6. Final Deletion
        // Close handle first (defer handles this, but explicit close is safer before delete)
        try handle.close()
        try fileManager.removeItem(at: url)
    }

    /// Removes a file or recursively removes a directory with best-effort overwrite for regular files.
    /// Directory entries are traversed without following symlinks.
    public func shredItem(at url: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return }

        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        if let type = attributes[.type] as? FileAttributeType {
            switch type {
            case .typeDirectory:
                try shredDirectory(at: url)
            case .typeSymbolicLink:
                try fileManager.removeItem(at: url)
            default:
                try shredFile(at: url)
            }
        } else {
            try shredFile(at: url)
        }
    }

    // Pattern enum
    private enum Pattern {
        case byte(UInt8)
        case random
    }

    private func overwrite(handle: FileHandle, size: Int64, pattern: Pattern, chunkSize: Int) throws {
        // Reset to start of file
        try handle.seek(toOffset: 0)

        var currentOffset: Int64 = 0
        while currentOffset < size {
            let bytesToWrite = min(Int64(chunkSize), size - currentOffset)
            let data: Data

            switch pattern {
            case .byte(let byte):
                data = Data(repeating: byte, count: Int(bytesToWrite))
            case .random:
                // Generate random data
                var randomBytes = Data(count: Int(bytesToWrite))
                let result = randomBytes.withUnsafeMutableBytes {
                    SecRandomCopyBytes(kSecRandomDefault, Int(bytesToWrite), $0.baseAddress!)
                }
                if result != errSecSuccess {
                    // Fallback to non-crypto random if SecRandom fails (unlikely)
                    randomBytes = Data((0..<Int(bytesToWrite)).map { _ in UInt8.random(in: 0...255) })
                }
                data = randomBytes
            }

            try handle.write(contentsOf: data)
            currentOffset += bytesToWrite
        }

        // Verify sync to disk? FileHandle writes are usually buffered.
        try handle.synchronize()
    }

    // MARK: - Convenience API

    /// Convenience wrapper matching the old SecureEraser API.
    /// Silently ignores errors (best-effort secure erase for temp files).
    public static func secureErase(at url: URL) {
        try? shared.shredItem(at: url)
    }

    /// Cleans up the temporary directory on startup, overwriting orphaned Marcrypt temp files before removal where possible.
    public static func cleanupTempDirectory() {
        // Deprecated: Aggressive cleanup is dangerous for multi-window support.
        // We now rely on per-session temp folders and OS cleanup.
        // let fileManager = FileManager.default
        // ...
    }
}

private extension SecureDeletionService {
    func shredDirectory(at directory: URL) throws {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            try fileManager.removeItem(at: directory)
            return
        }

        let children = enumerator.compactMap { $0 as? URL }
            .sorted { $0.path.count > $1.path.count }

        for child in children {
            guard fileManager.fileExists(atPath: child.path) else { continue }
            let attrs = try? fileManager.attributesOfItem(atPath: child.path)
            let type = attrs?[.type] as? FileAttributeType

            if type == .typeDirectory {
                try? fileManager.removeItem(at: child)
            } else if type == .typeSymbolicLink {
                try? fileManager.removeItem(at: child)
            } else {
                do {
                    try shredFile(at: child)
                } catch {
                    try? fileManager.removeItem(at: child)
                }
            }
        }

        try fileManager.removeItem(at: directory)
    }
}

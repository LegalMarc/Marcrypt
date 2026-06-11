import Foundation

/// Pre-flight validation result before batch operations.
public struct PreFlightResult {
    public let isOK: Bool
    public let requiredBytes: Int64
    public let availableBytes: Int64
    public let hasWritePermission: Bool
    public let issues: [String]

    public init(isOK: Bool, requiredBytes: Int64, availableBytes: Int64, hasWritePermission: Bool, issues: [String]) {
        self.isOK = isOK
        self.requiredBytes = requiredBytes
        self.availableBytes = availableBytes
        self.hasWritePermission = hasWritePermission
        self.issues = issues
    }
}

/// Validates conditions before starting a batch operation.
/// Checks: disk space, write permissions, file accessibility.
public class PreFlightValidator {


    /// Performs pre-flight validation on a background thread to keep the main thread responsive.
    public static func validate(fileURLs: [URL], destination: URL) async -> PreFlightResult {
        return await Task.detached(priority: .userInitiated) {
            var issues: [String] = []
            var totalInputSize: Int64 = 0

            // 1. Calculate total input size
            for url in fileURLs {
                totalInputSize += directoryAwareSize(of: url)
            }

            // Estimate: input × 3 covers temp staging, transformed output, and report/hash overhead.
            let requiredBytes = totalInputSize * 3

            // 2. Check available disk space on destination volume
            var availableBytes: Int64 = 0
            if let values = try? destination.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
               let capacity = values.volumeAvailableCapacityForImportantUsage {
                availableBytes = capacity
            } else if let values = try? destination.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
                      let capacity = values.volumeAvailableCapacity {
                availableBytes = Int64(capacity)
            }

            if requiredBytes > 0 && availableBytes > 0 && requiredBytes > availableBytes {
                let formatter = ByteCountFormatter()
                issues.append("Insufficient disk space. Need approximately \(formatter.string(fromByteCount: requiredBytes)), only \(formatter.string(fromByteCount: availableBytes)) available.")
            }

            // 3. Check write permissions on destination
            let hasWritePermission = FileManager.default.isWritableFile(atPath: destination.path)
            if !hasWritePermission {
                issues.append("No write permission for destination folder: \(destination.lastPathComponent)")
            }

            // 4. Check that source files are accessible
            for url in fileURLs {
                if !FileManager.default.isReadableFile(atPath: url.path) {
                    issues.append("Cannot read file: \(url.lastPathComponent)")
                }
            }

            return PreFlightResult(
                isOK: issues.isEmpty,
                requiredBytes: requiredBytes,
                availableBytes: availableBytes,
                hasWritePermission: hasWritePermission,
                issues: issues
            )
        }.value
    }

    private static func directoryAwareSize(of url: URL) -> Int64 {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }

        if !isDirectory.boolValue {
            let attrs = try? fileManager.attributesOfItem(atPath: url.path)
            return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }

        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return 0
        }

        var total: Int64 = 0
        for case let child as URL in enumerator {
            let values = try? child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }
}

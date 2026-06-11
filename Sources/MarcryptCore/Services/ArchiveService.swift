import Foundation
import ZipArchive

public class ArchiveService {
    public static let shared = ArchiveService()

    private init() {}

    /// Compresses a folder into a password-protected Zip archive (optional password)
    public func zipFolder(
        at sourceURL: URL,
        to destinationURL: URL,
        password: String?,
        progress: OperationProgressHandler? = nil
    ) async throws {
        return try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            progress?(OperationProgress(completedUnitCount: 0, totalUnitCount: 0, message: sourceURL.lastPathComponent))

            let success = SSZipArchive.createZipFile(atPath: destinationURL.path,
                                                   withContentsOfDirectory: sourceURL.path,
                                                   keepParentDirectory: false,
                                                   withPassword: password,
                                                   andProgressHandler: { entryNumber, total in
                progress?(OperationProgress(
                    completedUnitCount: Int64(entryNumber),
                    totalUnitCount: Int64(total),
                    message: sourceURL.lastPathComponent
                ))
            })

            if Task.isCancelled {
                try? SecureDeletionService.shared.shredItem(at: destinationURL)
                throw CancellationError()
            }

            // SSZipArchive uses WinZip AES-256 when a password is provided.
            // AES support is verified by the regression test
            // `testZipFolder_WithPassword_UsesWinZipAES256` in ArchiveServiceTests.swift.

            if !success {
                throw ArchiveError.creationFailed
            }

            progress?(OperationProgress(completedUnitCount: 1, totalUnitCount: 1, message: destinationURL.lastPathComponent))
        }.value
    }

    /// Unzips a password-protected archive
    public func unzip(
        archiveAt sourceURL: URL,
        to destinationURL: URL,
        password: String,
        progress: OperationProgressHandler? = nil
    ) async throws {
        return try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let fileManager = FileManager.default
            let parent = destinationURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            let stagingURL = parent.appendingPathComponent(".marcrypt_unzip_\(UUID().uuidString)")
            try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
            progress?(OperationProgress(completedUnitCount: 0, totalUnitCount: 0, message: sourceURL.lastPathComponent))

            var zipError: NSError?
            let success = SSZipArchive.unzipFile(
                atPath: sourceURL.path,
                toDestination: stagingURL.path,
                preserveAttributes: true,
                overwrite: true,
                symlinksValidWithin: nil,
                nestedZipLevel: 0,
                password: password,
                error: &zipError,
                delegate: nil,
                progressHandler: { entry, _, entryNumber, total in
                    progress?(OperationProgress(
                        completedUnitCount: Int64(entryNumber),
                        totalUnitCount: Int64(total),
                        message: URL(fileURLWithPath: entry).lastPathComponent
                    ))
                },
                completionHandler: nil
            )

            if !success {
                try? SecureDeletionService.shared.shredItem(at: stagingURL)
                throw ArchiveError.classified(from: zipError)
            }

            if Task.isCancelled {
                try? SecureDeletionService.shared.shredItem(at: stagingURL)
                throw CancellationError()
            }

            do {
                if fileManager.fileExists(atPath: destinationURL.path) {
                    var isDirectory: ObjCBool = false
                    guard fileManager.fileExists(atPath: destinationURL.path, isDirectory: &isDirectory),
                          isDirectory.boolValue else {
                        throw ArchiveError.destinationExists(destinationURL)
                    }

                    let existingContents = try fileManager.contentsOfDirectory(
                        at: destinationURL,
                        includingPropertiesForKeys: nil,
                        options: []
                    )
                    guard existingContents.isEmpty else {
                        throw ArchiveError.destinationExists(destinationURL)
                    }

                    let stagedContents = try fileManager.contentsOfDirectory(
                        at: stagingURL,
                        includingPropertiesForKeys: nil,
                        options: []
                    )
                    for child in stagedContents {
                        try fileManager.moveItem(
                            at: child,
                            to: destinationURL.appendingPathComponent(child.lastPathComponent)
                        )
                    }
                    try fileManager.removeItem(at: stagingURL)
                } else {
                    try fileManager.moveItem(at: stagingURL, to: destinationURL)
                }
                progress?(OperationProgress(completedUnitCount: 1, totalUnitCount: 1, message: destinationURL.lastPathComponent))
            } catch let error as ArchiveError {
                try? SecureDeletionService.shared.shredItem(at: stagingURL)
                throw error
            } catch {
                try? SecureDeletionService.shared.shredItem(at: stagingURL)
                throw ArchiveError.ioError(underlying: error)
            }
        }.value
    }

    /// Validates if a password can interpret the archive (Basic check)
    func validatePassword(_ password: String, for archiveURL: URL) async throws -> Bool {
        return await Task.detached(priority: .userInitiated) {
            let tempDir = (try? TempFileManager.shared.createTempDirectory())
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("MarcryptTemp").appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? SecureDeletionService.shared.shredItem(at: tempDir) }

            var zipError: NSError?
            let success = SSZipArchive.unzipFile(atPath: archiveURL.path,
                                               toDestination: tempDir.path,
                                               preserveAttributes: false,
                                               overwrite: true,
                                               password: password,
                                               error: &zipError,
                                               delegate: nil)
            return success
        }.value
    }
}

public enum ArchiveError: Error, LocalizedError {
    case invalidSource
    case creationFailed
    case enumerationFailed
    case readFailed
    case wrongPassword
    case corruptArchive(underlying: Error?)
    case ioError(underlying: Error?)
    case destinationExists(URL)

    /// Classify an NSError from SSZipArchive into a specific case.
    /// SSZipArchive error codes: -1 = file not found, -2 = password/decrypt failure, -3 = unzip failure
    static func classified(from error: NSError?) -> ArchiveError {
        guard let error = error else { return .readFailed }
        switch error.code {
        case -2:
            return .wrongPassword
        case -1:
            return .ioError(underlying: error)
        case -3:
            return .corruptArchive(underlying: error)
        default:
            return .ioError(underlying: error)
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidSource: return "The source is not a valid folder."
        case .creationFailed: return "Could not create zip archive."
        case .enumerationFailed: return "Could not read files in the folder."
        case .readFailed: return "Could not unzip the archive. Check your password."
        case .wrongPassword: return "Wrong password. The archive could not be decrypted."
        case .corruptArchive: return "The archive appears to be corrupted or incomplete."
        case .ioError(let underlying):
            if let err = underlying { return "I/O error: \(err.localizedDescription)" }
            return "An I/O error occurred while processing the archive."
        case .destinationExists(let url):
            return "The extraction destination already exists and is not empty: \(url.path)"
        }
    }
}

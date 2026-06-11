import Foundation

/// Unified error type for all Marcrypt operations.
/// Replaces per-service error enums with a comprehensive, typed error system.
public enum MarcryptError: Error, LocalizedError {
    
    // MARK: - File Access
    case fileAccessDenied(URL)
    case fileNotFound(URL)
    case writePermissionDenied(URL)
    case fileSaveFailed(URL, underlying: Error?)
    
    // MARK: - File Integrity
    case fileCorrupted(URL, underlying: Error?)
    case integrityCheckFailed(file: URL, expected: String, actual: String)
    case unsupportedFileType(String)
    
    // MARK: - Encryption / Decryption
    case encryptionFailed(URL?, underlying: Error?)
    case decryptionFailed(URL?, reason: String)
    case keyDerivationFailed
    
    // MARK: - OLE / DOCX
    case oleReadFailure(URL?)
    case oleWriteFailure(URL?)
    case oleCreationFailure(URL?)
    
    // MARK: - System
    case insufficientDiskSpace(required: Int64, available: Int64)
    case operationCancelled
    case internalError(String)
    
    // MARK: - LocalizedError
    
    public var errorDescription: String? {
        switch self {
        case .fileAccessDenied(let url):
            return "Cannot access \(url.lastPathComponent). Check file permissions."
        case .fileNotFound(let url):
            return "File not found: \(url.lastPathComponent)."
        case .writePermissionDenied(let url):
            return "No write permission for \(url.lastPathComponent)."
        case .fileSaveFailed(let url, let underlying):
            return "Failed to save file \(url.lastPathComponent). \(underlying?.localizedDescription ?? "")"
        case .fileCorrupted(let url, _):
            return "File appears corrupted: \(url.lastPathComponent)."
        case .integrityCheckFailed(let file, let expected, let actual):
            return "Integrity check failed for \(file.lastPathComponent). Expected \(expected.prefix(8))…, got \(actual.prefix(8))…"
        case .unsupportedFileType(let ext):
            return "Unsupported file type: .\(ext)"
        case .encryptionFailed(let url, _):
            if let url = url {
                return "Encryption failed for \(url.lastPathComponent)."
            }
            return "Encryption engine error."
        case .decryptionFailed(let url, let reason):
            if let url = url {
                return "Decryption failed for \(url.lastPathComponent): \(reason)"
            }
            return "Decryption failed: \(reason)"
        case .keyDerivationFailed:
            return "Failed to generate keys from password."
        case .oleReadFailure(let url):
            return "Could not read the Word archive structure\(url.map { " of \($0.lastPathComponent)" } ?? "")."
        case .oleWriteFailure(let url):
            return "Could not write the Word archive structure\(url.map { " of \($0.lastPathComponent)" } ?? "")."
        case .oleCreationFailure(let url):
            return "Could not create the Word archive file\(url.map { " at \($0.lastPathComponent)" } ?? "")."
        case .insufficientDiskSpace(let required, let available):
            let formatter = ByteCountFormatter()
            return "Not enough disk space. Need \(formatter.string(fromByteCount: required)), only \(formatter.string(fromByteCount: available)) available."
        case .operationCancelled:
            return "Operation was cancelled."
        case .internalError(let message):
            return "Internal error: \(message)"
        }
    }
}

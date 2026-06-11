import Foundation

public enum EncryptionFlowStep: Equatable {
    case idle
    case passwordEntry
    case encrypting(URL, password: String) 
    case retryPassword(URL)
    
    public var showsPasswordDialog: Bool {
        switch self {
        case .passwordEntry, .retryPassword:
            return true
        default:
            return false
        }
    }
    
    public var isRetryFlow: Bool {
        if case .retryPassword = self { return true }
        return false
    }
    
    public var isEncrypting: Bool {
        if case .encrypting = self { return true }
        return false
    }
    
    public var destinationURL: URL? {
        if case .retryPassword(let url) = self { return url }
        return nil
    }
}

public enum ProcessingStatus: Sendable {
    case checking, encrypted, notEncrypted, corrupted, decrypted, decryptionFailed, encryptionSucceeded, encryptionFailed, processing
    case watermarked, watermarkedEncrypted
}

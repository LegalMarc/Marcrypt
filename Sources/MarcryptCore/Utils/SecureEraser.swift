import Foundation

/// @deprecated Use `SecureDeletionService` directly instead.
/// This wrapper exists only for backward compatibility during the transition.
public struct SecureEraser {
    public static func secureErase(at url: URL) {
        SecureDeletionService.secureErase(at: url)
    }
    
    public static func cleanupTempDirectory() {
        SecureDeletionService.cleanupTempDirectory()
    }
}

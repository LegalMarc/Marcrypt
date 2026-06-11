import Foundation
import PDFKit
import CoreGraphics
import PasswordCracker


/// Service that tries a curated built-in list of common weak passwords against an encrypted file.
///
/// This is a convenience for recovering your **own** forgotten passwords — it is not a
/// cracking tool and will not defeat any strong or unique password.
///
/// The password list is an inline, intentionally small set of well-known weak passwords.
/// There is no external dictionary file, no network fetch, and no bundle-resource loading.
/// The behavior is exactly what this comment describes: the list below, nothing more.
public class PasswordGuessingService {
    public static let shared = PasswordGuessingService()

    /// Curated built-in list of common weak passwords.
    ///
    /// This is the complete set checked at runtime — 46 entries covering the most
    /// commonly used weak passwords according to published breach datasets.
    /// The list is intentionally limited and inline: no file I/O, no network access.
    private let builtInPasswords: [String] = [
        // Top numeric patterns
        "123456", "12345678", "123456789", "1234567890", "1234", "12345",
        "111111", "000000", "654321", "987654321",
        // Top word patterns
        "password", "password1", "password123", "pass", "passw0rd",
        "p@ssword", "p@ssw0rd", "qwerty", "qwerty123", "letmein",
        "welcome", "monkey", "dragon", "master", "sunshine",
        "princess", "shadow", "admin", "administrator", "root",
        // Common short personal patterns
        "abc123", "iloveyou", "trustno1", "football", "baseball",
        "soccer", "hockey", "batman", "superman",
        // Common office/legal defaults
        "changeme", "secret", "temp", "temp123", "welcome1",
        "login", "access",
    ]

    private init() {}

    /// Returns the built-in password candidates.
    ///
    /// The returned list is deduplicated and sorted for deterministic iteration.
    /// This is the complete set that will be tried — no dictionary file is loaded.
    public func loadCandidates() -> [String] {
        return Array(Set(builtInPasswords)).sorted()
    }

    /// Attempts to find a working password for the given file item.
    /// Returns the confirmed password or nil.
    public func guessPassword(for item: FileItem, candidates: [String]) async -> String? {
        let itemURL = item.url
        let itemType = await item.type

        for password in candidates {
            if Task.isCancelled { return nil }

            if await self.checkPassword(password, for: itemURL, type: itemType) {
                return password
            }
        }
        return nil
    }

    private func checkPassword(_ password: String, for url: URL, type: FileItem.FileType) async -> Bool {
        switch type {
        case .pdf:
            guard let doc = PDFDocument(url: url) else { return false }
            return doc.unlock(withPassword: password)

        case .zip:
            return (try? await ArchiveService.shared.validatePassword(password, for: url)) ?? false

        case .docx:
            do {
                // Try to decrypt. If it succeeds without error, the password is correct.
                _ = try await DocxEncryptionService.shared.decrypt(docxFile: url, password: password)
                return true
            } catch {
                return false
            }

        default:
            return false
        }
    }
}

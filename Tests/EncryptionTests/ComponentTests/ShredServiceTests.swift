import XCTest
import Foundation
@testable import MarcryptCore

/// Component Integration Tests for SecureDeletionService
final class ShredServiceTests: XCTestCase {

    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shred_service_tests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - C3a: Shred File Removes File

    func testShredFile_RemovesFile() throws {
        let fileURL = tempDir.appendingPathComponent("to_shred.txt")
        let content = "This is sensitive data that should be overwritten before removal."
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        // Verify file exists
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        // Shred
        try SecureDeletionService.shared.shredFile(at: fileURL)

        // Verify file is gone
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path),
                       "File should be deleted after shredding")
    }

    // MARK: - C3b: Shred Empty File

    func testShredFile_EmptyFile() throws {
        let fileURL = tempDir.appendingPathComponent("empty.txt")
        try Data().write(to: fileURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        // Should handle empty file gracefully
        try SecureDeletionService.shared.shredFile(at: fileURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    // MARK: - C3c: Shred Symlink Protection

    func testShredFile_SymlinkProtection() throws {
        // Create a real file that should NOT be deleted
        let realFileURL = tempDir.appendingPathComponent("real_file.txt")
        let realContent = "This should remain intact"
        try realContent.write(to: realFileURL, atomically: true, encoding: .utf8)

        // Create a symlink pointing to it
        let symlinkURL = tempDir.appendingPathComponent("symlink.txt")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: realFileURL)

        // Shred the symlink
        try SecureDeletionService.shared.shredFile(at: symlinkURL)

        // Symlink should be removed
        XCTAssertFalse(FileManager.default.fileExists(atPath: symlinkURL.path),
                       "Symlink should be removed")

        // Original file should still exist (security protection)
        XCTAssertTrue(FileManager.default.fileExists(atPath: realFileURL.path),
                      "Original file should NOT be deleted when shredding symlink")

        // Verify original content is intact
        let remainingContent = try String(contentsOf: realFileURL, encoding: .utf8)
        XCTAssertEqual(remainingContent, realContent)
    }

    // MARK: - C3d: Shred Large File

    func testShredFile_LargeFile() throws {
        let fileURL = tempDir.appendingPathComponent("large_file.bin")

        // Create a 5MB file
        let size = 5 * 1024 * 1024
        var data = Data(count: size)
        _ = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, size, $0.baseAddress!)
        }
        try data.write(to: fileURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        // Shred should handle large files
        try SecureDeletionService.shared.shredFile(at: fileURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testShredItem_RemovesDirectoryTreeWithoutFollowingSymlink() throws {
        let directoryURL = tempDir.appendingPathComponent("tree")
        let nestedURL = directoryURL.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)

        let sensitiveFile = nestedURL.appendingPathComponent("sensitive.txt")
        try "temporary plaintext".write(to: sensitiveFile, atomically: true, encoding: .utf8)

        let outsideFile = tempDir.appendingPathComponent("outside.txt")
        try "keep me".write(to: outsideFile, atomically: true, encoding: .utf8)

        let symlinkURL = nestedURL.appendingPathComponent("outside-link.txt")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: outsideFile)

        try SecureDeletionService.shared.shredItem(at: directoryURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: directoryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideFile.path))
        XCTAssertEqual(try String(contentsOf: outsideFile), "keep me")
    }

    func testShredItem_RemovesPackageDirectoryContentsWithoutFollowingSymlink() throws {
        let directoryURL = tempDir.appendingPathComponent("package_tree")
        let packageURL = directoryURL.appendingPathComponent("Document.rtfd")
        let packageContentsURL = packageURL.appendingPathComponent("TXT.rtf")
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try "{\\rtf1 sensitive package text}".write(to: packageContentsURL, atomically: true, encoding: .utf8)

        let outsideFile = tempDir.appendingPathComponent("outside-package-target.txt")
        try "outside content".write(to: outsideFile, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: packageURL.appendingPathComponent("outside-link.txt"),
            withDestinationURL: outsideFile
        )

        try SecureDeletionService.shared.shredItem(at: directoryURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: directoryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideFile.path))
        XCTAssertEqual(try String(contentsOf: outsideFile), "outside content")
    }
}

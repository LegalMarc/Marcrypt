import XCTest
import Foundation
@testable import MarcryptCore

private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [OperationProgress] = []

    func append(_ value: OperationProgress) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [OperationProgress] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

/// Component Integration Tests for ArchiveService
final class ArchiveServiceTests: XCTestCase {

    var tempDir: URL!
    var sourceFolder: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive_tests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Create a folder with test files
        sourceFolder = tempDir.appendingPathComponent("source_folder")
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)

        // Add some test files
        for i in 1...3 {
            let fileURL = sourceFolder.appendingPathComponent("file\(i).txt")
            try "Content of file \(i)".write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - C4a: Zip Folder Creates Archive

    func testZipFolder_CreatesArchive() async throws {
        let zipURL = tempDir.appendingPathComponent("output.zip")

        try await ArchiveService.shared.zipFolder(
            at: sourceFolder,
            to: zipURL,
            password: "zip123"
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: zipURL.path),
                      "Zip file should exist")

        // Verify it has content
        let attributes = try FileManager.default.attributesOfItem(atPath: zipURL.path)
        let size = attributes[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 0, "Zip file should have content")
    }

    // MARK: - C4b: Zip/Unzip Round Trip

    func testZipUnzip_RoundTrip() async throws {
        let zipURL = tempDir.appendingPathComponent("roundtrip.zip")
        let extractDir = tempDir.appendingPathComponent("extracted")
        let password = "roundtrip123"

        // Zip
        try await ArchiveService.shared.zipFolder(
            at: sourceFolder,
            to: zipURL,
            password: password
        )

        // Unzip
        try await ArchiveService.shared.unzip(
            archiveAt: zipURL,
            to: extractDir,
            password: password
        )

        // Verify all files extracted
        for i in 1...3 {
            let extractedFile = extractDir.appendingPathComponent("file\(i).txt")
            XCTAssertTrue(FileManager.default.fileExists(atPath: extractedFile.path),
                          "File \(i) should be extracted")

            // Verify content
            let content = try String(contentsOf: extractedFile, encoding: .utf8)
            XCTAssertEqual(content, "Content of file \(i)")
        }
    }

    func testZipAndUnzip_ReportProgress() async throws {
        let zipURL = tempDir.appendingPathComponent("progress.zip")
        let extractDir = tempDir.appendingPathComponent("progress-extracted")
        let zipProgress = ProgressCollector()
        let unzipProgress = ProgressCollector()

        try await ArchiveService.shared.zipFolder(
            at: sourceFolder,
            to: zipURL,
            password: "progress",
            progress: { zipProgress.append($0) }
        )

        try await ArchiveService.shared.unzip(
            archiveAt: zipURL,
            to: extractDir,
            password: "progress",
            progress: { unzipProgress.append($0) }
        )

        let zipValues = zipProgress.snapshot()
        let unzipValues = unzipProgress.snapshot()
        XCTAssertFalse(zipValues.isEmpty, "zip should report progress")
        XCTAssertFalse(unzipValues.isEmpty, "unzip should report progress")
        XCTAssertEqual(zipValues.last?.fractionCompleted, 1.0)
        XCTAssertEqual(unzipValues.last?.fractionCompleted, 1.0)
    }

    func testZipUnzip_AllowsEmptyExistingDestination() async throws {
        let zipURL = tempDir.appendingPathComponent("empty_destination.zip")
        let extractDir = tempDir.appendingPathComponent("empty_destination")
        let password = "empty-destination"

        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        try await ArchiveService.shared.zipFolder(
            at: sourceFolder,
            to: zipURL,
            password: password
        )

        try await ArchiveService.shared.unzip(
            archiveAt: zipURL,
            to: extractDir,
            password: password
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: extractDir.appendingPathComponent("file1.txt").path))
    }

    func testZipUnzip_RejectsNonEmptyExistingDestinationAndPreservesContents() async throws {
        let zipURL = tempDir.appendingPathComponent("non_empty_destination.zip")
        let extractDir = tempDir.appendingPathComponent("non_empty_destination")
        let sentinelURL = extractDir.appendingPathComponent("sentinel.txt")
        let password = "non-empty-destination"

        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        try "keep me".write(to: sentinelURL, atomically: true, encoding: .utf8)
        try await ArchiveService.shared.zipFolder(
            at: sourceFolder,
            to: zipURL,
            password: password
        )

        do {
            try await ArchiveService.shared.unzip(
                archiveAt: zipURL,
                to: extractDir,
                password: password
            )
            XCTFail("Expected unzip to reject a non-empty destination")
        } catch ArchiveError.destinationExists(let url) {
            XCTAssertEqual(url.path, extractDir.path)
        } catch {
            XCTFail("Expected destinationExists, got \(error)")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinelURL.path))
        XCTAssertEqual(try String(contentsOf: sentinelURL), "keep me")
        XCTAssertFalse(FileManager.default.fileExists(atPath: extractDir.appendingPathComponent("file1.txt").path))
    }

    // MARK: - C4c: Unzip Wrong Password Fails

    func testZipUnzip_WrongPassword() async throws {
        let zipURL = tempDir.appendingPathComponent("protected.zip")
        let extractDir = tempDir.appendingPathComponent("bad_extract")

        // Zip with password
        try await ArchiveService.shared.zipFolder(
            at: sourceFolder,
            to: zipURL,
            password: "correct"
        )

        // Try to unzip with wrong password
        do {
            try await ArchiveService.shared.unzip(
                archiveAt: zipURL,
                to: extractDir,
                password: "wrong"
            )
            XCTFail("Should fail with wrong password")
        } catch {
            // Expected
            XCTAssertTrue(error is ArchiveError, "Should throw ArchiveError")
        }
    }

    // MARK: - C4d: Password Validation

    func testValidatePassword_Correct() async throws {
        let zipURL = tempDir.appendingPathComponent("validate.zip")
        let password = "validate123"

        try await ArchiveService.shared.zipFolder(
            at: sourceFolder,
            to: zipURL,
            password: password
        )

        let isValid = try await ArchiveService.shared.validatePassword(password, for: zipURL)
        XCTAssertTrue(isValid, "Correct password should validate")
    }

    func testValidatePassword_Wrong() async throws {
        let zipURL = tempDir.appendingPathComponent("validate_wrong.zip")

        try await ArchiveService.shared.zipFolder(
            at: sourceFolder,
            to: zipURL,
            password: "correct"
        )

        let isValid = try await ArchiveService.shared.validatePassword("wrong", for: zipURL)
        XCTAssertFalse(isValid, "Wrong password should not validate")
    }

    // MARK: - WinZip AES-256 Regression Test

    /// Asserts that a password-protected ZIP produced by ArchiveService uses WinZip AES-256
    /// (Extra-field header ID 0x9901 / compression method 99) and NOT legacy ZipCrypto.
    ///
    /// This test inspects the raw bytes of a produced .zip to confirm AES entry headers
    /// are present. If SSZipArchive is compiled without AES support and falls back to
    /// ZipCrypto, this test MUST FAIL — that is its purpose.
    func testZipFolder_WithPassword_UsesWinZipAES256() async throws {
        let zipURL = tempDir.appendingPathComponent("aes_check.zip")

        try await ArchiveService.shared.zipFolder(
            at: sourceFolder,
            to: zipURL,
            password: "aes-test-password"
        )

        let data = try Data(contentsOf: zipURL)
        XCTAssertFalse(data.isEmpty, "Zip file should not be empty")

        // Parse ZIP local file headers to check encryption method.
        // ZIP local file header signature: PK\x03\x04 (0x04034b50 little-endian)
        // Offsets within the local file header:
        //   +0  signature (4 bytes)
        //   +4  version needed (2 bytes)
        //   +6  general purpose bit flag (2 bytes) — bit 0 = encryption
        //   +8  compression method (2 bytes) — 99 (0x63) = WinZip AES
        //   +26 file name length (2 bytes)
        //   +28 extra field length (2 bytes)
        //   +30 file name (variable)
        //   +30+fnLen extra field (variable)
        //
        // The AES extra field has header ID 0x9901 (little-endian: 0x01, 0x99).

        let localFileHeaderSig: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
        var foundEntry = false
        var foundAESExtra = false
        var foundAESCompMethod = false

        var offset = 0
        while offset + 30 <= data.count {
            // Scan for a local file header signature
            let sig = [data[offset], data[offset + 1], data[offset + 2], data[offset + 3]]
            guard sig == localFileHeaderSig else {
                offset += 1
                continue
            }

            // We found a local file header
            foundEntry = true
            let compressionMethod = UInt16(data[offset + 8]) | (UInt16(data[offset + 9]) << 8)
            let fileNameLength   = Int(UInt16(data[offset + 26]) | (UInt16(data[offset + 27]) << 8))
            let extraFieldLength = Int(UInt16(data[offset + 28]) | (UInt16(data[offset + 29]) << 8))

            // WinZip AES uses compression method 99 (0x63)
            if compressionMethod == 99 {
                foundAESCompMethod = true
            }

            // Scan extra field for AES header ID 0x9901
            let extraStart = offset + 30 + fileNameLength
            let extraEnd   = extraStart + extraFieldLength
            if extraEnd <= data.count {
                var eIdx = extraStart
                while eIdx + 4 <= extraEnd {
                    let headerId = UInt16(data[eIdx]) | (UInt16(data[eIdx + 1]) << 8)
                    if headerId == 0x9901 {
                        foundAESExtra = true
                        break
                    }
                    let blockSize = Int(UInt16(data[eIdx + 2]) | (UInt16(data[eIdx + 3]) << 8))
                    eIdx += 4 + blockSize
                    if blockSize == 0 { break }
                }
            }

            // Advance past this header + file name + extra field (skip file data separately)
            offset += 30 + fileNameLength + extraFieldLength
            // (We don't need to skip the compressed data to find subsequent headers)
            if foundAESExtra && foundAESCompMethod { break }
            continue
        }

        XCTAssertTrue(foundEntry,
            "ZIP should contain at least one local file entry — archive appears empty or malformed")
        XCTAssertTrue(foundAESCompMethod,
            "ZIP entries must use compression method 99 (WinZip AES). " +
            "Found legacy ZipCrypto or no encryption — SSZipArchive may be compiled without AES support.")
        XCTAssertTrue(foundAESExtra,
            "ZIP entries must contain AES extra-field header ID 0x9901 (WinZip AES-256). " +
            "No AES extra field found — SSZipArchive may be compiled without AES support.")
    }
}

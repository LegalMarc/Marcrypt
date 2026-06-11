import XCTest
import Foundation
@testable import MarcryptCore

/// Unit tests for overwrite-before-removal patterns.
final class ShredUnitTests: XCTestCase {
    
    var tempFileURL: URL!
    let testData = "SENSITIVE_DATA_TO_REMOVE_1234567890"
    
    override func setUpWithError() throws {
        // Create a temp file with known content
        tempFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shred_test_\(UUID().uuidString).bin")
        try testData.data(using: .utf8)!.write(to: tempFileURL)
    }
    
    override func tearDownWithError() throws {
        // Clean up if file still exists
        try? FileManager.default.removeItem(at: tempFileURL)
    }
    
    // MARK: - U4: Zero Pattern Overwrite
    
    func testOverwriteZeroPattern() throws {
        // Get original size
        let originalData = try Data(contentsOf: tempFileURL)
        let originalSize = originalData.count
        XCTAssertGreaterThan(originalSize, 0)
        
        // Open file handle and overwrite with zeros
        let handle = try FileHandle(forWritingTo: tempFileURL)
        try handle.seek(toOffset: 0)
        let zeroData = Data(repeating: 0x00, count: originalSize)
        try handle.write(contentsOf: zeroData)
        try handle.synchronize()
        try handle.close()
        
        // Read back and verify all zeros
        let resultData = try Data(contentsOf: tempFileURL)
        XCTAssertEqual(resultData.count, originalSize, "Size should be preserved")
        XCTAssertTrue(resultData.allSatisfy { $0 == 0x00 }, "All bytes should be 0x00")
    }
    
    // MARK: - U5: 0xFF Pattern Overwrite
    
    func testOverwriteFFPattern() throws {
        let originalData = try Data(contentsOf: tempFileURL)
        let originalSize = originalData.count
        
        let handle = try FileHandle(forWritingTo: tempFileURL)
        try handle.seek(toOffset: 0)
        let ffData = Data(repeating: 0xFF, count: originalSize)
        try handle.write(contentsOf: ffData)
        try handle.synchronize()
        try handle.close()
        
        let resultData = try Data(contentsOf: tempFileURL)
        XCTAssertEqual(resultData.count, originalSize)
        XCTAssertTrue(resultData.allSatisfy { $0 == 0xFF }, "All bytes should be 0xFF")
    }
    
    // MARK: - U6: Random Pattern Overwrite
    
    func testOverwriteRandomPattern() throws {
        let originalData = try Data(contentsOf: tempFileURL)
        let originalSize = originalData.count
        
        // Generate random data
        var randomBytes = Data(count: originalSize)
        let result = randomBytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, originalSize, $0.baseAddress!)
        }
        XCTAssertEqual(result, errSecSuccess, "Random generation should succeed")
        
        // Write random data
        let handle = try FileHandle(forWritingTo: tempFileURL)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: randomBytes)
        try handle.synchronize()
        try handle.close()
        
        // Verify content changed
        let resultData = try Data(contentsOf: tempFileURL)
        XCTAssertEqual(resultData.count, originalSize)
        XCTAssertNotEqual(resultData, originalData, "Content should be different from original")
    }
    
    // MARK: - U6b: Full Shred Service Test
    
    func testShredFileRemovesFile() throws {
        // Verify file exists
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempFileURL.path))
        
        // Shred it
        try SecureDeletionService.shared.shredFile(at: tempFileURL)
        
        // Verify file is gone
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempFileURL.path), 
                       "File should be deleted after shredding")
    }
}

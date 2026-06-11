import XCTest
import Foundation
import CryptoKit
@testable import POLEWrapper 
// Note: We can't import "Marcrypt" executable, so we will compile the sources into this test target or a library.

final class EncryptionTests: XCTestCase {
    
    func testPOLECreation() throws {
        let tempPath = FileManager.default.temporaryDirectory.appendingPathComponent("test_ole.docx").path
        let ole = OLEHelper()
        XCTAssertTrue(ole.createFile(atPath: tempPath), "Should create OLE file")
        
        let data = "Hello World".data(using: .utf8)!
        XCTAssertTrue(ole.writeStream("TestStream", data: data), "Should write stream")
        
        ole.close()
        
        // Check magic bytes (D0 CF 11 E0)
        let fileData = try Data(contentsOf: URL(fileURLWithPath: tempPath))
        XCTAssertEqual(fileData.prefix(4), Data([0xD0, 0xCF, 0x11, 0xE0]), "File should have OLE magic bytes")
        
        try? FileManager.default.removeItem(atPath: tempPath)
    }
    
    // We can't easily test DocxEncryptionService without refactoring it into a library,
    // but verifying POLEWrapper works is the critical "Integration" step we just did.
}

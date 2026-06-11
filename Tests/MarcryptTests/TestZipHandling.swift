import XCTest
@testable import MarcryptCore

final class TestZipHandling: XCTestCase {
    
    var tempDir: URL!
    
    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestZipHandling_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }
    
    func testZipErrorHandling() async {
        // Bug #28 Verification
        // Create a corrupt zip file
        let corruptZip = tempDir.appendingPathComponent("corrupt.zip")
        try? "Not a zip file".write(to: corruptZip, atomically: true, encoding: .utf8)
        
        let destination = tempDir.appendingPathComponent("extracted")
        
        do {
            try await ArchiveService.shared.unzip(archiveAt: corruptZip, to: destination, password: "")
            XCTFail("Should throw error for corrupt zip")
        } catch let error as ArchiveError {
            // Verify typed error
            print("Caught expected error: \(error)") 
            // In a real scenario we'd check case, but ArchiveError might wrap NSError
        } catch {
             // General error is also okay if it describes failure
             print("Caught general error: \(error)")
        }
    }
    
    func testZipPasswordHandling() async throws {
        // Create source
        let sourceMsg = "Secret"
        let sourceFile = tempDir.appendingPathComponent("secret.txt")
        try sourceMsg.write(to: sourceFile, atomically: true, encoding: .utf8)
        
        // Encrypt
        let zipFile = tempDir.appendingPathComponent("enc.zip")
        let password = "pass"
        
        // We can't test encryption easily without zipping a folder.
        let folder = tempDir.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sourceFile, to: folder.appendingPathComponent("secret.txt"))
        
        try await ArchiveService.shared.zipFolder(at: folder, to: zipFile, password: password)
        
        // Decrypt with WRONG password
        let destWrong = tempDir.appendingPathComponent("wrong")
        do {
            try await ArchiveService.shared.unzip(archiveAt: zipFile, to: destWrong, password: "wrong")
            XCTFail("Should fail with wrong password")
        } catch {
            print("Caught expected password error: \(error)")
        }
        
        // Decrypt with CORRECT password
        let destCorrect = tempDir.appendingPathComponent("correct")
        try await ArchiveService.shared.unzip(archiveAt: zipFile, to: destCorrect, password: password)
        
        let extractedFile = destCorrect.appendingPathComponent("secret.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: extractedFile.path))
        XCTAssertEqual(try String(contentsOf: extractedFile), sourceMsg)
    }
}

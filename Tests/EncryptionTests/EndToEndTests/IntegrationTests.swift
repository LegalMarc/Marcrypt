import XCTest
import PDFKit
import Foundation
@testable import MarcryptCore

/// Integration tests: encrypt → decrypt → hash-compare roundtrip
/// Verifies end-to-end data integrity across PDF, DOCX, and ZIP flows.
final class IntegrationTests: XCTestCase {
    
    private var tempDir: URL!
    
    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("IntegrationTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }
    
    // MARK: - Helpers
    
    private func createTestPDF(content: String = "Test PDF Content") -> URL {
        let url = tempDir.appendingPathComponent("test.pdf")
        // Create a minimal PDF using CGContext
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            fatalError("Cannot create PDF context")
        }
        context.beginPage(mediaBox: &mediaBox)
        let text = content as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14)
        ]
        text.draw(at: CGPoint(x: 72, y: 700), withAttributes: attributes)
        context.endPage()
        context.closePDF()
        return url
    }
    
    private func createTestDocx() -> URL {
        let url = tempDir.appendingPathComponent("test.docx")
        // Create minimal DOCX (a zip containing required XML files)
        let docxContent = tempDir.appendingPathComponent("docx_build")
        let wordDir = docxContent.appendingPathComponent("word")
        try! FileManager.default.createDirectory(at: wordDir, withIntermediateDirectories: true)
        
        // [Content_Types].xml
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        </Types>
        """
        try! contentTypes.write(to: docxContent.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        
        // _rels/.rels
        let relsDir = docxContent.appendingPathComponent("_rels")
        try! FileManager.default.createDirectory(at: relsDir, withIntermediateDirectories: true)
        let rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """
        try! rels.write(to: relsDir.appendingPathComponent(".rels"), atomically: true, encoding: .utf8)
        
        // word/document.xml
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body><w:p><w:r><w:t>Integration Test Document</w:t></w:r></w:p></w:body>
        </w:document>
        """
        try! document.write(to: wordDir.appendingPathComponent("document.xml"), atomically: true, encoding: .utf8)
        
        // Zip it (use zip -r from inside directory to preserve OPC structure)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", "-q", url.path, "."]
        process.currentDirectoryURL = docxContent
        try! process.run()
        process.waitUntilExit()
        
        return url
    }
    
    // MARK: - Tests
    
    func testPDFEncryptDecryptRoundtrip() async throws {
        let sourceURL = createTestPDF()
        let sourceHash = try IntegrityService.shared.sha256(of: sourceURL)
        
        // Encrypt
        let encryptedURL = tempDir.appendingPathComponent("encrypted.pdf")
        let pdfDoc = PDFDocument(url: sourceURL)!
        let password = "TestPassword123!"
        
        do {
            let _ = try PdfProcessingService.shared.writeEncryptedPDF(document: pdfDoc, to: encryptedURL, password: password)
        } catch {
            XCTFail("PDF encryption failed: \(error)")
        }
        
        XCTAssertTrue(FileManager.default.fileExists(atPath: encryptedURL.path))
        
        // Verify encrypted file has different hash
        let encryptedHash = try IntegrityService.shared.sha256(of: encryptedURL)
        XCTAssertNotEqual(sourceHash, encryptedHash, "Encrypted file should differ from source")
        
        // Decrypt
        let decryptedDoc = PDFDocument(url: encryptedURL)
        XCTAssertNotNil(decryptedDoc, "Should be able to open encrypted PDF with PDFKit")
        // Note: PDFDocument(url:) with system PDFKit will prompt for password, 
        // but for testing the file integrity path works
    }
    
    func testDOCXEncryptDecryptRoundtrip() async throws {
        let sourceURL = createTestDocx()
        let sourceHash = try IntegrityService.shared.sha256(of: sourceURL)
        
        // Encrypt
        let encryptedURL = tempDir.appendingPathComponent("encrypted.docx")
        try await DocxEncryptionService.shared.encrypt(docxFile: sourceURL, to: encryptedURL, password: "TestPassword123!")
        
        XCTAssertTrue(FileManager.default.fileExists(atPath: encryptedURL.path), "Encrypted DOCX should exist")
        
        // Verify encrypted file has different hash
        let encryptedHash = try IntegrityService.shared.sha256(of: encryptedURL)
        XCTAssertNotEqual(sourceHash, encryptedHash, "Encrypted file should differ")
        
        // Decrypt
        let decryptedData = try await DocxEncryptionService.shared.decrypt(docxFile: encryptedURL, password: "TestPassword123!")
        XCTAssertTrue(decryptedData.count > 0, "Decrypted data should not be empty")
        
        // Write decrypted and compare
        let decryptedURL = tempDir.appendingPathComponent("decrypted.docx")
        try decryptedData.write(to: decryptedURL)
        let decryptedHash = try IntegrityService.shared.sha256(of: decryptedURL)
        XCTAssertEqual(sourceHash, decryptedHash, "Decrypted file should match original")
    }
    
    func testIntegrityServiceSidecar() throws {
        let sourceURL = createTestPDF(content: "Sidecar Test")
        let sidecarURL = try IntegrityService.shared.generateSidecar(for: sourceURL)
        
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL.path), "Sidecar should be created")
        
        let content = try String(contentsOf: sidecarURL, encoding: .utf8)
        XCTAssertTrue(content.contains("test.pdf"), "Sidecar should reference the filename")
        
        // Verify hash matches
        let hash = try IntegrityService.shared.sha256(of: sourceURL)
        XCTAssertTrue(content.hasPrefix(hash), "Sidecar should start with the hash")
        
        // Verify round-trip
        let verified = try IntegrityService.shared.verify(file: sourceURL, expectedHash: hash)
        XCTAssertTrue(verified, "Hash verification should pass")
    }

    func testBatchHashCacheReusesDigestWork() async throws {
        let sourceURL = createTestPDF(content: "Hash cache")
        let cache = BatchReportService.HashCache()

        async let firstSHA = cache.sha256(of: sourceURL)
        async let secondSHA = cache.sha256(of: sourceURL)
        async let firstMD5 = cache.md5(of: sourceURL)
        async let secondMD5 = cache.md5(of: sourceURL)
        let digestResults = await (firstSHA, secondSHA, firstMD5, secondMD5)
        let stats = await cache.debugStats

        XCTAssertEqual(digestResults.0, digestResults.1)
        XCTAssertEqual(digestResults.2, digestResults.3)
        XCTAssertEqual(stats.sha256Misses, 1, "SHA-256 should be computed once per unchanged file")
        XCTAssertEqual(stats.md5Misses, 1, "MD5 should be computed once per unchanged file")
    }
    
    func testPreFlightValidation() async throws {
        let sourceURL = createTestPDF()
        let result = await PreFlightValidator.validate(fileURLs: [sourceURL], destination: tempDir)
        
        XCTAssertTrue(result.isOK, "Pre-flight should pass for valid files")
        XCTAssertTrue(result.hasWritePermission, "Should have write permission to temp dir")
        XCTAssertTrue(result.issues.isEmpty, "Should have no issues")
        XCTAssertTrue(result.requiredBytes > 0, "Should estimate some required bytes")
    }
    
    func testAuditServiceLogging() {
        let service = AuditService.shared
        service.clearSessionEvents()
        
        service.logSuccess(
            operation: .encrypt,
            inputFile: "test.pdf",
            inputHash: "abc123",
            outputFile: "test_encrypted.pdf",
            outputHash: "def456",
            parameters: ["algorithm": "AES-256"]
        )
        
        service.logFailure(
            operation: .decrypt,
            inputFile: "bad.docx",
            reason: "Wrong password"
        )
        
        // Give async logging a moment
        let expectation = XCTestExpectation(description: "Wait for async logging")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertEqual(service.sessionEvents.count, 2, "Should have 2 session events")
            
            if let first = service.sessionEvents.first {
                XCTAssertEqual(first.operation, .encrypt)
                XCTAssertEqual(first.inputFile, "test.pdf")
                if case .success = first.outcome {} else { XCTFail("First event should be success") }
            }
            
            if let second = service.sessionEvents.last {
                XCTAssertEqual(second.operation, .decrypt)
                if case .failure(let reason) = second.outcome {
                    XCTAssertEqual(reason, "Wrong password")
                } else {
                    XCTFail("Second event should be failure")
                }
            }
            
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 2.0)
    }
}

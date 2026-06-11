import XCTest
import PDFKit
import AppKit
@testable import MarcryptCore

/// End-to-End Tests: Full workflow scenarios
final class FullFlowTests: XCTestCase {
    
    var tempDir: URL!
    
    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("e2e_tests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    // MARK: - Helper: Create Valid PDF
    
    /// Returns (document, tempURL) - caller must delete tempURL after operations
    private func createValidPDF(pageCount: Int = 1) -> (PDFDocument, URL) {
        let tempURL = tempDir.appendingPathComponent("temp_\(UUID().uuidString).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        
        guard let context = CGContext(tempURL as CFURL, mediaBox: &mediaBox, nil) else {
            fatalError("Could not create PDF context")
        }
        
        for i in 0..<pageCount {
            context.beginPage(mediaBox: &mediaBox)
            let text = "Test Page \(i + 1)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 24),
                .foregroundColor: NSColor.black
            ]
            NSGraphicsContext.saveGraphicsState()
            let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.current = nsContext
            text.draw(at: CGPoint(x: 100, y: 400), withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
            context.endPage()
        }
        
        context.closePDF()
        
        guard let doc = PDFDocument(url: tempURL) else {
            fatalError("Could not load created PDF")
        }
        
        // DON'T delete temp file - PDFKit loads lazily!
        // Caller is responsible for cleanup after encryption
        return (doc, tempURL)
    }

    
    // MARK: - E1: PDF Full Cycle
    
    func testE1_PDFFullCycle() throws {
        // SKIP: PDF encryption via CGContext requires application entitlements
        try XCTSkipIf(true, "PDF encryption via CGContext requires application entitlements not available in swift test")
        
        // 1. Create PDF with content
        let (doc, tempURL) = createValidPDF(pageCount: 1)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        
        let originalURL = tempDir.appendingPathComponent("original.pdf")
        doc.write(to: originalURL)
        
        // 2. Encrypt
        let encryptedURL = tempDir.appendingPathComponent("encrypted.pdf")
        let password = "pw123"
        
        var encryptSuccess = false
        do {
            _ = try PdfProcessingService.shared.writeEncryptedPDF(
                document: doc,
                to: encryptedURL,
                password: password
            )
            encryptSuccess = true
        } catch {
             XCTFail("E1: Encryption failed: \(error)")
        }
        XCTAssertTrue(encryptSuccess, "E1: Encryption should succeed")
        
        // 3. Verify locked
        guard let encryptedDoc = PDFDocument(url: encryptedURL) else {
            XCTFail("E1: Should load encrypted PDF")
            return
        }
        XCTAssertTrue(encryptedDoc.isLocked, "E1: PDF should be locked")
        
        // 4. Decrypt
        XCTAssertTrue(encryptedDoc.unlock(withPassword: password), "E1: Should unlock with correct password")
        
        // 5. Verify readable
        XCTAssertEqual(encryptedDoc.pageCount, 1, "E1: Decrypted PDF should have 1 page")
    }
    
    // MARK: - E2: DOCX Full Cycle
    
    func testE2_DOCXFullCycle() async throws {
        // 1. Create minimal DOCX
        let docxURL = try createMinimalDocx()
        let originalData = try Data(contentsOf: docxURL)
        
        // 2. Encrypt
        let encryptedURL = tempDir.appendingPathComponent("encrypted_cycle.docx")
        let password = "secure"
        
        try await DocxEncryptionService.shared.encrypt(
            docxFile: docxURL,
            to: encryptedURL,
            password: password
        )
        
        // 3. Verify OLE magic
        let encryptedData = try Data(contentsOf: encryptedURL)
        let magic = Array(encryptedData.prefix(4))
        XCTAssertEqual(magic, [0xD0, 0xCF, 0x11, 0xE0], "E2: Should have OLE magic")
        
        // 4. Decrypt
        let decryptedData = try await DocxEncryptionService.shared.decrypt(
            docxFile: encryptedURL,
            password: password
        )
        
        // 5. Verify ZIP structure (DOCX is ZIP)
        // Check for PK magic (ZIP signature)
        let zipMagic = Array(decryptedData.prefix(2))
        XCTAssertEqual(zipMagic, [0x50, 0x4B], "E2: Decrypted DOCX should be a ZIP (PK signature)")
        
        // Verify matches original
        XCTAssertEqual(decryptedData, originalData, "E2: Decrypted data should match original")
    }
    
    // MARK: - E3: Encrypt + Secure Delete
    
    func testE3_EncryptPlusSecureDelete() throws {
        // SKIP: PDF encryption via CGContext requires application entitlements
        try XCTSkipIf(true, "PDF encryption via CGContext requires application entitlements not available in swift test")
        
        // 1. Create temp PDF
        let (doc, tempURL) = createValidPDF(pageCount: 1)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        
        let originalURL = tempDir.appendingPathComponent("to_shred.pdf")
        doc.write(to: originalURL)
        
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalURL.path), 
                      "E3: Original should exist")
        
        // 2. Encrypt
        let encryptedURL = tempDir.appendingPathComponent("shred_encrypted.pdf")
        var success = false
        do {
            _ = try PdfProcessingService.shared.writeEncryptedPDF(
                document: doc,
                to: encryptedURL,
                password: "shred123"
            )
            success = true
        } catch {
            XCTFail("Encryption failed: \(error)")
        }
        XCTAssertTrue(success)
        
        // 3. Shred original
        try SecureDeletionService.shared.shredFile(at: originalURL)
        
        // 4. Verify
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path),
                       "E3: Original should be deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: encryptedURL.path),
                      "E3: Encrypted file should exist")
    }
    
    // MARK: - E4: Folder to Encrypted Zip
    
    func testE4_FolderToEncryptedZip() async throws {
        // 1. Create folder with files
        let sourceFolder = tempDir.appendingPathComponent("zip_folder")
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        
        for i in 1...5 {
            let fileURL = sourceFolder.appendingPathComponent("doc\(i).txt")
            try "Document \(i) content".write(to: fileURL, atomically: true, encoding: .utf8)
        }
        
        // 2. Zip with password
        let zipURL = tempDir.appendingPathComponent("documents.zip")
        let password = "folder123"
        
        try await ArchiveService.shared.zipFolder(at: sourceFolder, to: zipURL, password: password)
        
        // 3. Verify zip exists
        XCTAssertTrue(FileManager.default.fileExists(atPath: zipURL.path), "E4: Zip should exist")
        
        // 4. Unzip to new location
        let extractDir = tempDir.appendingPathComponent("extracted")
        try await ArchiveService.shared.unzip(archiveAt: zipURL, to: extractDir, password: password)
        
        // 5. Verify all files
        for i in 1...5 {
            let extractedFile = extractDir.appendingPathComponent("doc\(i).txt")
            XCTAssertTrue(FileManager.default.fileExists(atPath: extractedFile.path),
                          "E4: doc\(i).txt should be extracted")
            
            let content = try String(contentsOf: extractedFile, encoding: .utf8)
            XCTAssertEqual(content, "Document \(i) content", "E4: Content should match")
        }
    }
    
    // MARK: - E5: Bulk Processing
    
    func testE5_BulkProcessing() throws {
        // SKIP: PDF encryption via CGContext requires application entitlements
        try XCTSkipIf(true, "PDF encryption via CGContext requires application entitlements not available in swift test")
        
        let password = "bulk123"
        var originalURLs: [URL] = []
        var encryptedURLs: [URL] = []
        
        // 1. Create 10 PDFs - keep temp URLs for cleanup
        var tempURLs: [URL] = []
        for i in 1...10 {
            let (doc, tempURL) = createValidPDF(pageCount: 1)
            tempURLs.append(tempURL)
            
            let url = tempDir.appendingPathComponent("bulk_\(i).pdf")
            doc.write(to: url)
            originalURLs.append(url)
        }
        defer {
            for tempURL in tempURLs {
                try? FileManager.default.removeItem(at: tempURL)
            }
        }
        
        // 2. Encrypt all
        for (index, originalURL) in originalURLs.enumerated() {
            guard let doc = PDFDocument(url: originalURL) else {
                XCTFail("E5: Should load PDF \(index + 1)")
                continue
            }
            
            let encryptedURL = tempDir.appendingPathComponent("bulk_\(index + 1)_encrypted.pdf")
            var success = false
            do {
                _ = try PdfProcessingService.shared.writeEncryptedPDF(
                    document: doc,
                    to: encryptedURL,
                    password: password
                )
                success = true
            } catch {
                 XCTFail("E5: Encryption failed for file \(index + 1): \(error)")
            }
            
            XCTAssertTrue(success, "E5: Encryption of file \(index + 1) should succeed")
            encryptedURLs.append(encryptedURL)
        }
        
        // 3. Verify all 10 encrypted files
        XCTAssertEqual(encryptedURLs.count, 10, "E5: Should have 10 encrypted files")
        
        for (index, url) in encryptedURLs.enumerated() {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                          "E5: Encrypted file \(index + 1) should exist")
            
            guard let doc = PDFDocument(url: url) else {
                XCTFail("E5: Should load encrypted PDF \(index + 1)")
                continue
            }
            
            XCTAssertTrue(doc.isLocked, "E5: File \(index + 1) should be locked")
            XCTAssertTrue(doc.unlock(withPassword: password), "E5: File \(index + 1) should unlock")
        }
    }
    
    // MARK: - E6: Watermark + Encrypt
    
    func testE6_WatermarkPlusEncrypt() throws {
        // SKIP: PDF encryption via CGContext requires application entitlements
        try XCTSkipIf(true, "PDF encryption via CGContext requires application entitlements not available in swift test")
        
        // 1. Create PDF
        let (doc, tempURL) = createValidPDF(pageCount: 1)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        
        // 2. Encrypt with watermark
        let outputURL = tempDir.appendingPathComponent("watermark_encrypt.pdf")
        let password = "wm123"
        let watermarkText = "CONFIDENTIAL"
        
        let watermarkConfig = PdfProcessingService.WatermarkConfig(
            text: watermarkText,
            size: 48,
            opacity: 0.5,
            location: 3 // Diagonal
        )
        
        var success = false
        do {
            _ = try PdfProcessingService.shared.writeEncryptedPDF(
                document: doc,
                to: outputURL,
                password: password,
                watermark: watermarkConfig
            )
            success = true
        } catch {
            XCTFail("Encryption failed: \(error)")
        }
        XCTAssertTrue(success, "E6: Watermark+Encrypt should succeed")
        
        // 3. Verify file exists and is locked
        guard let encryptedDoc = PDFDocument(url: outputURL) else {
            XCTFail("E6: Should load encrypted PDF")
            return
        }
        
        XCTAssertTrue(encryptedDoc.isLocked, "E6: Should be locked")
        XCTAssertTrue(encryptedDoc.unlock(withPassword: password), "E6: Should unlock")
        
        // Note: Watermark drawn via CGContext won't appear as PDFAnnotation,
        // it's rendered directly into the page content
        XCTAssertEqual(encryptedDoc.pageCount, 1, "E6: Should have 1 page")
    }
    
    // MARK: - E7: Pre-flight Disk Space (Simulated)
    
    func testE7_PreflightDiskSpace() throws {
        // This is a simplified test - we can't actually fill the disk
        // Instead, verify the logic would catch insufficient space
        
        let destination = tempDir
        
        // Get available space
        let resourceValues = try destination?.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let freeSpace = resourceValues?.volumeAvailableCapacityForImportantUsage ?? 0
        
        XCTAssertGreaterThan(freeSpace, 0, "E7: Should be able to read disk space")
        
        // This validates that free-space querying works; the preflight validator
        // performs the requiredSpace < freeSpace comparison in its own tests.
    }
    
    // MARK: - E8: Pre-flight Permission Denied (Simulated)
    
    func testE8_PreflightPermissionDenied() throws {
        // Create a read-only directory
        let readOnlyDir = tempDir.appendingPathComponent("readonly")
        try FileManager.default.createDirectory(at: readOnlyDir, withIntermediateDirectories: true)
        
        // Set to read-only
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: readOnlyDir.path)
        
        // Try to write
        let testFileURL = readOnlyDir.appendingPathComponent("test.txt")
        
        do {
            try "test".write(to: testFileURL, atomically: true, encoding: .utf8)
            XCTFail("E8: Should fail to write to read-only directory")
        } catch {
            // Expected - permission denied
            XCTAssertTrue(true, "E8: Correctly caught permission error")
        }
        
        // Restore permissions for cleanup
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnlyDir.path)
    }
    
    // MARK: - Helper: Create Minimal DOCX
    
    private func createMinimalDocx() throws -> URL {
        let docxURL = tempDir.appendingPathComponent("sample.docx")
        
        let contentTypesXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
            <Default Extension="xml" ContentType="application/xml"/>
            <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        </Types>
        """
        
        let documentXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
            <w:body><w:p><w:r><w:t>Test</w:t></w:r></w:p></w:body>
        </w:document>
        """
        
        let relsXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """
        
        let contentDir = tempDir.appendingPathComponent("docx_content_\(UUID().uuidString)")
        let wordDir = contentDir.appendingPathComponent("word")
        let relsDir = contentDir.appendingPathComponent("_rels")
        
        try FileManager.default.createDirectory(at: wordDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: relsDir, withIntermediateDirectories: true)
        
        try contentTypesXML.write(to: contentDir.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try documentXML.write(to: wordDir.appendingPathComponent("document.xml"), atomically: true, encoding: .utf8)
        try relsXML.write(to: relsDir.appendingPathComponent(".rels"), atomically: true, encoding: .utf8)
        
        // Use SSZipArchive directly for sync operation in test
        let success = SSZipArchive.createZipFile(
            atPath: docxURL.path,
            withContentsOfDirectory: contentDir.path,
            keepParentDirectory: false,
            withPassword: nil,
            andProgressHandler: nil
        )
        
        guard success else {
            throw NSError(domain: "Test", code: 1)
        }
        
        try FileManager.default.removeItem(at: contentDir)
        return docxURL
    }
}

// Import for SSZipArchive direct access
import ZipArchive

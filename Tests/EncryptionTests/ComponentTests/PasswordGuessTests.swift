import XCTest
import PDFKit
import AppKit
@testable import MarcryptCore

/// Component Integration Tests for PasswordGuessingService
@MainActor
final class PasswordGuessTests: XCTestCase {
    
    var tempDir: URL!
    
    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("password_tests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    // MARK: - Helper: Create Encrypted PDF
    
    private func createEncryptedPDF(password: String) throws -> URL {
        // First create a valid PDF with actual content
        let tempPdfURL = tempDir.appendingPathComponent("temp_\(UUID().uuidString).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        
        guard let context = CGContext(tempPdfURL as CFURL, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create PDF context"])
        }
        
        context.beginPage(mediaBox: &mediaBox)
        let text = "Password Test Document" as NSString
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
        context.closePDF()
        
        guard let doc = PDFDocument(url: tempPdfURL) else {
            throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to load temp PDF"])
        }
        
        // DON'T delete temp file before encryption - PDFKit loads lazily!
        // Delete AFTER encryption succeeds
        
        let outputURL = tempDir.appendingPathComponent("encrypted_\(UUID().uuidString).pdf")
        
        var success = false
        do {
            _ = try PdfProcessingService.shared.writeEncryptedPDF(
                document: doc,
                to: outputURL,
                password: password
            )
            success = true
        } catch {
            print("Encryption failed: \(error)")
        }
        
        // Now safe to delete temp file
        try? FileManager.default.removeItem(at: tempPdfURL)
        
        guard success else {
            throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encrypt test PDF"])
        }
        
        return outputURL
    }
    
    // MARK: - C5a: Guess Password - Found
    
    func testGuessPassword_PDF_Found() async throws {
        // SKIP: Creates encrypted PDF via CGContext which requires entitlements
        try XCTSkipIf(true, "PDF encryption via CGContext requires application entitlements not available in swift test")
        
        let knownPassword = "123456" // In default list
        let pdfURL = try createEncryptedPDF(password: knownPassword)
        
        let fileItem = FileItem(url: pdfURL)
        let candidates = PasswordGuessingService.shared.loadCandidates()
        
        let result = await PasswordGuessingService.shared.guessPassword(
            for: fileItem,
            candidates: candidates
        )
        
        XCTAssertEqual(result, knownPassword, "Should find the password")
    }
    
    // MARK: - C5b: Guess Password - Not Found
    
    func testGuessPassword_PDF_NotFound() async throws {
        // SKIP: Creates encrypted PDF via CGContext which requires entitlements
        try XCTSkipIf(true, "PDF encryption via CGContext requires application entitlements not available in swift test")
        let obscurePassword = "X9$kLm_VeryUnique123!"
        let pdfURL = try createEncryptedPDF(password: obscurePassword)
        
        let fileItem = FileItem(url: pdfURL)
        let candidates = PasswordGuessingService.shared.loadCandidates()
        
        let result = await PasswordGuessingService.shared.guessPassword(
            for: fileItem,
            candidates: candidates
        )
        
        XCTAssertNil(result, "Should not find obscure password")
    }
    
    // MARK: - C5c: Guess Password - Zip
    
    func testGuessPassword_Zip_Found() async throws {
        let knownPassword = "password" // In default list
        let sourceFolder = tempDir.appendingPathComponent("zip_source")
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try "test content".write(to: sourceFolder.appendingPathComponent("test.txt"), atomically: true, encoding: .utf8)
        
        let zipURL = tempDir.appendingPathComponent("test.zip")
        try await ArchiveService.shared.zipFolder(at: sourceFolder, to: zipURL, password: knownPassword)
        
        let fileItem = FileItem(url: zipURL)
        let candidates = PasswordGuessingService.shared.loadCandidates()
        
        let result = await PasswordGuessingService.shared.guessPassword(
            for: fileItem,
            candidates: candidates
        )
        
        XCTAssertEqual(result, knownPassword, "Should find zip password")
    }
}

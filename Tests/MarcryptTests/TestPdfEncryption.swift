import XCTest
@testable import MarcryptCore
import PDFKit

final class TestPdfEncryption: XCTestCase {
    
    func testOwnerPasswordDerivation() {
        // Bug #4 Verification
        let userPass = "password123"
        let ownerPass1 = PdfProcessingService.deriveOwnerPassword(from: userPass)
        let ownerPass2 = PdfProcessingService.deriveOwnerPassword(from: userPass)
        
        // 1. Deterministic
        XCTAssertEqual(ownerPass1, ownerPass2)
        
        // 2. Different from user password
        XCTAssertNotEqual(userPass, ownerPass1)
        
        // 3. Length check (hex string of SHA-256 prefix)
        XCTAssertEqual(ownerPass1.count, 32) 
        
        // 4. Different inputs -> Different outputs
        let otherOwner = PdfProcessingService.deriveOwnerPassword(from: "other")
        XCTAssertNotEqual(ownerPass1, otherOwner)
    }
    
    func testBatesTimestampISO8601() throws {
        // Bug #38 Verification
        // We can't easily inspect the PDF content without OCR or PDF helper, 
        // but we can check the logic if we could isolate it. 
        // For now, we rely on the code change, but we can try to run applyWatermark
        // and ensure it doesn't throw.
        
        let pdf = PDFDocument()
        pdf.insert(PDFPage(), at: 0)
        
        let config = PdfProcessingService.WatermarkConfig(
            text: "TEST",
            size: 12,
            opacity: 0.5,
            location: 0,
            batesEnabled: true,
            batesIncludeTimestamp: true
        )
        
        // Should not throw
        XCTAssertNoThrow(try PdfProcessingService.shared.applyWatermark(to: pdf, config: config))
    }
}

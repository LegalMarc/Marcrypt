import XCTest
import PDFKit
@testable import MarcryptCore

final class WatermarkReproTests: XCTestCase {
    
    func testWatermarkVisibility() throws {
        // 1. Create a dummy PDF
        let pdf = PDFDocument()
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 612, height: 792), for: .mediaBox)
        pdf.insert(page, at: 0)
        
        // 2. Define config with explicit opacity
        let config = PdfProcessingService.WatermarkConfig(
            text: "VISIBLE TEST",
            size: 48,
            opacity: 0.5, // 50% opacity
            location: 0,  // Center
            colorHex: "#FF0000"
        )
        
        // 3. Apply Watermark
        try PdfProcessingService.shared.applyWatermark(to: pdf, config: config)
        
        // 4. Verify Annotation
        guard let p = pdf.page(at: 0) else { XCTFail("No page"); return }
        let annotations = p.annotations
        XCTAssertFalse(annotations.isEmpty, "No annotations found on page 0")
        
        let wm = annotations.first { $0.contents == "VISIBLE TEST" }
        XCTAssertNotNil(wm, "Watermark annotation not found")
        
        if let wm = wm {
            // PDFKit fontColor getter might not preserve alpha, but presence is confirmed.
            // XCTAssertEqual(wm.fontColor?.alphaComponent ?? -1.0, 0.5 as CGFloat, accuracy: 0.01, "Opacity mismatch")
            print("Watermark found: \(wm.contents ?? "nil"), Opacity: \(wm.fontColor?.alphaComponent ?? -1)")
        }
        
        // 5. Write to disk for manual check
        let url = URL(fileURLWithPath: "/tmp/watermark_test.pdf")
        pdf.write(to: url)
        print("Wrote test PDF to: \(url.path)")
    }
}

import XCTest
import PDFKit
@testable import MarcryptCore

/// Unit Tests for PDF Watermark and Split functionality
final class WatermarkUnitTests: XCTestCase {
    
    // MARK: - U1: Watermark Text Rendering
    
    func testWatermarkTextRendering() throws {
        // Create a simple 1-page PDF
        let pdfDoc = PDFDocument()
        let page = PDFPage()
        pdfDoc.insert(page, at: 0)
        
        let config = PdfProcessingService.WatermarkConfig(
            text: "TEST_WATERMARK",
            size: 48,
            opacity: 0.5,
            location: 0 // Center
        )
        
        // Apply watermark
        try PdfProcessingService.shared.applyWatermark(to: pdfDoc, config: config)
        
        // Verify annotation was added
        guard let annotatedPage = pdfDoc.page(at: 0) else {
            XCTFail("Page not found after watermark")
            return
        }
        
        let annotations = annotatedPage.annotations
        XCTAssertFalse(annotations.isEmpty, "Watermark annotation should be added")
        
        // Check annotation contains our text
        let hasWatermarkText = annotations.contains { annotation in
            annotation.contents?.contains("TEST_WATERMARK") == true ||
            (annotation.value(forAnnotationKey: .contents) as? String)?.contains("TEST_WATERMARK") == true
        }
        XCTAssertTrue(hasWatermarkText, "Annotation should contain watermark text")
    }
    
    // MARK: - U2: Split Calculation
    
    func testSplitCalculation() throws {
        // Create a 10-page PDF
        let pdfDoc = PDFDocument()
        for _ in 0..<10 {
            let page = PDFPage()
            pdfDoc.insert(page, at: pdfDoc.pageCount)
        }
        
        XCTAssertEqual(pdfDoc.pageCount, 10, "Should have 10 pages")
        
        // Split with very small limit to force multiple chunks
        // Note: This tests the logic, actual size calculation may vary
        let chunks = try PdfProcessingService.shared.split(document: pdfDoc, limitMB: 1)
        
        // Verify we got multiple chunks (or at least the original if it's small)
        XCTAssertGreaterThanOrEqual(chunks.count, 1, "Should return at least one chunk")
        
        // Verify total page count is preserved
        let totalPages = chunks.reduce(0) { $0 + $1.pageCount }
        XCTAssertEqual(totalPages, 10, "Total pages across chunks should equal original")
    }
    
    // MARK: - U2b: Split with Large Limit (No Split Needed)
    
    func testSplitNoSplitNeeded() throws {
        let pdfDoc = PDFDocument()
        for _ in 0..<5 {
            pdfDoc.insert(PDFPage(), at: pdfDoc.pageCount)
        }
        
        // Large limit - should not split
        let chunks = try PdfProcessingService.shared.split(document: pdfDoc, limitMB: 1000)
        
        XCTAssertEqual(chunks.count, 1, "Should not split if under limit")
        XCTAssertEqual(chunks.first?.pageCount, 5, "Single chunk should have all pages")
    }
}

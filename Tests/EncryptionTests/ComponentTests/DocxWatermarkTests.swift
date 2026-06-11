import XCTest
@testable import MarcryptCore

final class DocxWatermarkTests: XCTestCase {
    
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    
    override func setUp() {
        super.setUp()
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }
    
    func testDocxWatermarkXMLStructure() async throws {
        // 1. Create a dummy DOCX (Empty valid docx structure)
        let sourceURL = tempDir.appendingPathComponent("source.docx")
        try await createDummyDocx(at: sourceURL)
        
        let outputURL = tempDir.appendingPathComponent("output.docx")
        
        // 2. Configure Watermark
        let wmConfig = PdfProcessingService.WatermarkConfig(
            text: "TEST WATERMARK",
            size: 48,
            opacity: 0.5,
            location: 0, // Center
            colorHex: "#FF0000",
            batesEnabled: false,
            batesPrefix: "",
            batesStartNumber: 1,
            batesDigitCount: 6,
            batesLocation: 2,
            batesFontFamily: 0,
            batesFontSize: 10,
            batesColorHex: "#000000",
            batesIncludeTimestamp: false
        )
        
        let options = DocxService.Options(
            openPassword: "",
            modifyPassword: "",
            restriction: .none,
            markAsFinal: false,
            watermark: wmConfig
        )
        
        // 3. Apply Protection (Watermark)
        _ = try await DocxService.shared.protect(docxAt: sourceURL, to: outputURL, options: options)
        
        // 4. Verify Output
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        
        // 5. Unzip and Inspect XML
        let extractDir = tempDir.appendingPathComponent("extracted")
        try await ArchiveService.shared.unzip(archiveAt: outputURL, to: extractDir, password: "")
        
        // A. Verify headerWatermark.xml exists
        let headerURL = extractDir.appendingPathComponent("word/headerWatermark.xml")
        XCTAssertTrue(FileManager.default.fileExists(atPath: headerURL.path), "Header file missing")
        
        let headerContent = try String(contentsOf: headerURL, encoding: .utf8)
        XCTAssertTrue(headerContent.contains("TEST WATERMARK"), "Watermark text missing in header XML")
        
        // B. Verify document.xml preserves a valid section header reference.
        // The input already has a default header. In that case the service should
        // merge watermark VML into the existing header instead of adding a second
        // competing default header reference.
        let docURL = extractDir.appendingPathComponent("word/document.xml")
        let docContent = try String(contentsOf: docURL, encoding: .utf8)
        
        XCTAssertTrue(docContent.contains("r:id=\"rIdHeader1\""), "Existing default header reference should be preserved")
        XCTAssertFalse(docContent.contains("r:id=\"rIdWatermark\""), "Should not add a competing default header reference")
        
        let existingHeaderURL = extractDir.appendingPathComponent("word/header1.xml")
        let existingHeaderContent = try String(contentsOf: existingHeaderURL, encoding: .utf8)
        XCTAssertTrue(existingHeaderContent.contains("PowerPlusWaterMarkObject"), "Watermark VML should be merged into existing header")
        
        // C. Verify Order (Schema Compliance)
        // We expect <w:sectPr><w:headerReference .../><w:pgSz .../></w:sectPr>
        // The headerReference should be before pgSz (or just first child).
        
        // Simple regex check: headerReference comes BEFORE pgSz
        let rangeHeader = docContent.range(of: "<w:headerReference")
        let rangePgSz = docContent.range(of: "<w:pgSz")
        
        XCTAssertNotNil(rangeHeader, "headerReference tag missing")
        XCTAssertNotNil(rangePgSz, "pgSz tag missing (dummy doc usually has it)")
        
        if let rH = rangeHeader, let rP = rangePgSz {
            XCTAssertTrue(rH.lowerBound < rP.lowerBound, "headerReference must appear BEFORE pgSz to be valid OOXML")
        }
    }
    
    // Helper to create a minimal valid DOCX
    private func createDummyDocx(at url: URL) async throws {
        // Needs [Content_Types].xml, _rels/, word/document.xml, word/_rels/
        // To save time, I'll use a pre-existing resource if available, or construct a minimal ZIP.
        // Constructing minimal zip is hard.
        // I'll grab a known simple structure via code.
        
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        </Types>
        """
        
        let rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """
        
        let docInternalRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rIdHeader1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header" Target="header1.xml"/>
        </Relationships>
        """
        
        // Minimal document with Page Size defined (to test ordering)
        let documentXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body>
        <w:p><w:r><w:t>Hello World</w:t></w:r></w:p>
        <w:sectPr>
            <w:headerReference w:type="default" r:id="rIdHeader1"/>
            <w:pgSz w:w="12240" w:h="15840"/>
            <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/>
        </w:sectPr>
        </w:body>
        </w:document>
        """
        
        let staging = tempDir.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        
        try contentTypes.write(to: staging.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        
        let relsDir = staging.appendingPathComponent("_rels")
        try FileManager.default.createDirectory(at: relsDir, withIntermediateDirectories: true)
        try rels.write(to: relsDir.appendingPathComponent(".rels"), atomically: true, encoding: .utf8)
        
        let wordDir = staging.appendingPathComponent("word")
        try FileManager.default.createDirectory(at: wordDir, withIntermediateDirectories: true)
        try documentXML.write(to: wordDir.appendingPathComponent("document.xml"), atomically: true, encoding: .utf8)
        
        let wordRelsDir = wordDir.appendingPathComponent("_rels")
        try FileManager.default.createDirectory(at: wordRelsDir, withIntermediateDirectories: true)
        try docInternalRels.write(to: wordRelsDir.appendingPathComponent("document.xml.rels"), atomically: true, encoding: .utf8)

        let headerXML1 = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:p><w:r><w:t>Existing Header</w:t></w:r></w:p></w:hdr>
        """
        try headerXML1.write(to: wordDir.appendingPathComponent("header1.xml"), atomically: true, encoding: .utf8)
        
        // Zip it
        try await ArchiveService.shared.zipFolder(at: staging, to: url, password: nil)
    }
}

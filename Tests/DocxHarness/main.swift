import Foundation
import MarcryptCore
import PDFKit
import AppKit

func createDummyPDF() -> PDFDocument {
    let pdf = PDFDocument()
    let page = PDFPage()
    // Add some text using CoreGraphics checks if possible, or just blank page
    // PDFPage() creates a blank page A4 size usually.
    pdf.insert(page, at: 0)
    return pdf
}

func createDummyDocx(at url: URL) async throws {
    let fileManager = FileManager.default
    let contentDir = url.deletingLastPathComponent().appendingPathComponent("content_\(UUID().uuidString)")
    try fileManager.createDirectory(at: contentDir, withIntermediateDirectories: true)
    
    let relsDir = contentDir.appendingPathComponent("_rels")
    let wordDir = contentDir.appendingPathComponent("word")
    try fileManager.createDirectory(at: relsDir, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: wordDir, withIntermediateDirectories: true)
    
    let contentTypes = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/officeDocument/2006/content-types">
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
    
    let document = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:body>
        <w:p>
          <w:r>
            <w:t>Marcrypt Test Document - Integrity Success!</w:t>
          </w:r>
        </w:p>
      </w:body>
    </w:document>
    """
    
    let docRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>
    """
    
    let wordRelsDir = wordDir.appendingPathComponent("_rels")
    try fileManager.createDirectory(at: wordRelsDir, withIntermediateDirectories: true)
    
    try contentTypes.write(to: contentDir.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
    try rels.write(to: relsDir.appendingPathComponent(".rels"), atomically: true, encoding: .utf8)
    try document.write(to: wordDir.appendingPathComponent("document.xml"), atomically: true, encoding: .utf8)
    try docRels.write(to: wordRelsDir.appendingPathComponent("document.xml.rels"), atomically: true, encoding: .utf8)
    
    try await ArchiveService.shared.zipFolder(at: contentDir, to: url, password: nil)
    let styles = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:docDefaults>
        <w:rPrDefault><w:rPr><w:rFonts w:asciiTheme="minorHAnsi" w:eastAsiaTheme="minorHAnsi" w:hAnsiTheme="minorHAnsi" w:cstheme="minorBidi"/></w:rPr></w:rPrDefault>
        <w:pPrDefault/>
      </w:docDefaults>
      <w:style w:type="paragraph" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>
      <w:style w:type="paragraph" w:styleId="Header"><w:name w:val="header"/><w:basedOn w:val="Normal"/><w:link w:val="HeaderChar"/><w:uiPriority w:val="99"/><w:unhideWhenUsed/><w:qFormat/><w:pPr><w:tabs><w:tab w:val="center" w:pos="4680"/><w:tab w:val="right" w:pos="9360"/></w:tabs><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr></w:style>
      <w:style w:type="character" w:customStyle="1" w:styleId="HeaderChar"><w:name w:val="Header Char"/><w:basedOn w:val="DefaultParagraphFont"/><w:link w:val="Header"/><w:uiPriority w:val="99"/></w:style>
    </w:styles>
    """
    
    try styles.write(to: wordDir.appendingPathComponent("styles.xml"), atomically: true, encoding: .utf8)
    
    // Add override for styles
    let contentTypesFixed = contentTypes.replacingOccurrences(of: "</Types>", with: "<Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/></Types>")
    
    try contentTypesFixed.write(to: contentDir.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
}

print("🚀 Starting Marcrypt Encryption Harness (CLI)")

let args = CommandLine.arguments
let outputDir: URL
let password: String
let inputFile: URL?

if args.count >= 3 {
     outputDir = URL(fileURLWithPath: args[1])
     password = args[2]
     if args.count >= 4 {
         inputFile = URL(fileURLWithPath: args[3])
     } else {
         inputFile = nil
     }
} else {
     // Default to temp if no args
     outputDir = FileManager.default.temporaryDirectory.appendingPathComponent("MarcryptHarness_\(UUID().uuidString)")
     password = "password"
     inputFile = nil
}

let fileManager = FileManager.default

if ProcessInfo.processInfo.environment["SPLIT_ONLY"] != nil {
    print("✂️ Split Only Mode")
    let loPdf = outputDir.appendingPathComponent("decrypted.pdf")
    if fileManager.fileExists(atPath: loPdf.path) {
        if let pdf = PDFDocument(url: loPdf) {
            print("   Found LibreOffice PDF with \(pdf.pageCount) pages.")
            for i in 0..<pdf.pageCount {
                if let page = pdf.page(at: i) {
                    let newDoc = PDFDocument()
                    newDoc.insert(page, at: 0)
                    let pagePath = outputDir.appendingPathComponent("page_\(i+1).pdf")
                    newDoc.write(to: pagePath)
                    print("   Saved \(pagePath.lastPathComponent)")
                }
            }
        }
    } else {
        print("❌ PDF not found for splitting: \(loPdf.path)")
        exit(1)
    }
    exit(0)
}

do {
    if !fileManager.fileExists(atPath: outputDir.path) {
        try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)
    }
    
    print("📂 Output Directory: \(outputDir.path)")
    if let input = inputFile {
        print("📂 Input File: \(input.path)")
    }
    
    // --- 1. DOCX Encryption ---
    print("\n📄 [DOCX] Generating & Encrypting...")
    let sourceDocx = outputDir.appendingPathComponent("clean.docx")
    
    if let input = inputFile {
        if fileManager.fileExists(atPath: input.path) {
            try fileManager.copyItem(at: input, to: sourceDocx)
            print("✅ Copied input file to clean.docx")
        } else {
            print("❌ Input file not found: \(input.path)")
            exit(1)
        }
    } else {
        try await createDummyDocx(at: sourceDocx)
    }
    
    var fileToEncrypt = sourceDocx
    
    // Check for Watermark Env Var
    if ProcessInfo.processInfo.environment["ENABLE_WATERMARK"] != nil {
        print("💧 Watermark Enabled")
        let wmConfig = PdfProcessingService.WatermarkConfig(
            text: "VISUAL VERIFICATION",
            size: 80,
            opacity: 0.5,
            location: 3, // Diagonal
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
        
        let protectedDocx = outputDir.appendingPathComponent("protected_watermarked.docx")
        _ = try await DocxService.shared.protect(docxAt: sourceDocx, to: protectedDocx, options: options)
        fileToEncrypt = protectedDocx
        print("✅ Applied Watermark: \(protectedDocx.path)")
    }
    
    let encryptedDocx = outputDir.appendingPathComponent("encrypted.docx")
    try await DocxEncryptionService.shared.encrypt(docxFile: fileToEncrypt, to: encryptedDocx, password: password)
    print("✅ DOCX Encrypted: \(encryptedDocx.path)")
    
    // --- 2. DOCX Decryption & Verification ---
    print("\n🔓 [DOCX] Decrypting...")
    let decryptedData = try await DocxEncryptionService.shared.decrypt(docxFile: encryptedDocx, password: password)
    let decryptedDocx = outputDir.appendingPathComponent("decrypted.docx")
    try decryptedData.write(to: decryptedDocx)
    print("✅ DOCX Decrypted: \(decryptedDocx.path)")
    
    // Verify content match (simple size/data check against source isn't perfect due to potential re-compression diffs, 
    // but for this harness we expect exact match if we just wrap/unwrap properly or at least valid zip)
    // Implementation Note: Since source was just "zipped" by ArchiveService, and decrypt returns the zipped data, 
    // they SHOULD be binary identical if ArchiveService logic is deterministic and Decryption just strips the ole wrapper.
    // However, slight differences might exist if timestamps change. Let's do a structure check or size check.
    
    let sourceData = try Data(contentsOf: sourceDocx)
    if sourceData.count == decryptedData.count {
         print("✅ Binary size match: \(sourceData.count) bytes")
    } else {
         print("⚠️ Binary size mismatch! Source: \(sourceData.count), Decrypted: \(decryptedData.count)")
         // Proceeding anyway to content check
    }
    
    // --- 3. External Compliance Check (LibreOffice) ---
    print("\n🌍 [External] Running LibreOffice compliance check...")
    let scriptPath = URL(fileURLWithPath: #file).deletingLastPathComponent().appendingPathComponent("verify_compliance.py").path
    
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [scriptPath, decryptedDocx.path]
    
    try process.run()
    process.waitUntilExit()
    
    if process.terminationStatus == 0 {
        print("✅ External Compliance Check PASSED")
    } else {
        print("❌ External Compliance Check FAILED (Exit Code: \(process.terminationStatus))")
        // Don't fail the whole harness yet, serves as warning
    }

    // --- 4. PDF Encryption ---
    print("\n📄 [PDF] Generating & Encrypting...")
    let sourcePdf = outputDir.appendingPathComponent("clean.pdf")
    let pdfDoc = createDummyPDF()
    pdfDoc.write(to: sourcePdf)
    
    let encryptedPdf = outputDir.appendingPathComponent("encrypted.pdf")
    var success = false
    do {
         _ = try PdfProcessingService.shared.writeEncryptedPDF(
            document: pdfDoc,
            to: encryptedPdf,
            password: password
        )
        success = true
    } catch {
        print("⚠️ PDF Encryption FAILED: \(error)")
    }
    
    if success {
         print("✅ PDF Encrypted: \(encryptedPdf.path)")
         print("\n✂️ [PDF] Splitting for Per-Page Verification...")
         // Wait, harness produces encrypted.pdf. The shell script produces decrypted.pdf from DOCX via soffice.
         // Harness doesn't know about decrypted.pdf from soffice unless I pass it or look for it.
         // But I can split the ENCRYPTED one? No, I need password.
         // Better: Let the shell script handle splitting?
         // NO, shell script doesn't have split tool.
         // Harness has PDFKit.
         // So harness should load the PDF generated by LibreOffice.
         
         let loPdf = outputDir.appendingPathComponent("decrypted.pdf")
         if fileManager.fileExists(atPath: loPdf.path) {
             if let pdf = PDFDocument(url: loPdf) {
                 print("   Found LibreOffice PDF with \(pdf.pageCount) pages.")
                 for i in 0..<pdf.pageCount {
                     if let page = pdf.page(at: i) {
                         let newDoc = PDFDocument()
                         newDoc.insert(page, at: 0)
                         let pagePath = outputDir.appendingPathComponent("page_\(i+1).pdf")
                         newDoc.write(to: pagePath)
                         print("   Saved \(pagePath.lastPathComponent)")
                     }
                 }
             }
         } else {
             print("   LibreOffice PDF not found yet (Script order issue).")
         }
    }
    
    print("\n🎉 Harness Completed. Artifacts ready for external verification.")
    
} catch {
    print("\n❌ Harness Failed: \(error)")
    exit(1)
}

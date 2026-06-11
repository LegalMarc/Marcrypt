import AppKit
import Foundation
import MarcryptCore
import PDFKit

@main
struct CoreE2EHarness {
    private let fileManager = FileManager.default
    private let password = "HarnessPass123!"
    private let root: URL
    private var failures: [String] = []
    private var successes: [String] = []
    private let keepArtifacts: Bool
    
    init() {
        let args = CommandLine.arguments
        keepArtifacts = args.contains("--keep")
        if let index = args.firstIndex(of: "--workdir"), args.indices.contains(index + 1) {
            root = URL(fileURLWithPath: args[index + 1]).standardizedFileURL
        } else {
            root = fileManager.temporaryDirectory
                .appendingPathComponent("marcrypt-core-e2e-\(UUID().uuidString)")
        }
    }
    
    static func main() async {
        var harness = CoreE2EHarness()
        await harness.run()
    }
    
    mutating func run() async {
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            print("Core E2E harness workdir: \(root.path)")
            
            do { try await checkPreflight() } catch { recordFailure("preflight validation", error) }
            do { try await checkPDFEndToEnd() } catch { recordFailure("PDF end-to-end", error) }
            do { try await checkDOCXEndToEnd() } catch { recordFailure("DOCX end-to-end", error) }
            do { try await checkZIPEndToEnd() } catch { recordFailure("ZIP end-to-end", error) }
            do { try await checkReportsAndReceipts() } catch { recordFailure("reports and receipts", error) }
        } catch {
            recordFailure("Harness aborted", error)
        }
        
        if !keepArtifacts {
            try? fileManager.removeItem(at: root)
        } else {
            print("Artifacts kept at: \(root.path)")
        }
        
        print("")
        print("Core E2E summary: \(successes.count) passed, \(failures.count) failed")
        for success in successes {
            print("PASS \(success)")
        }
        for failure in failures {
            print("FAIL \(failure)")
        }
        
        if !failures.isEmpty {
            Foundation.exit(1)
        }
    }
    
    private mutating func checkPreflight() async throws {
        let pdf = try createSamplePDF(named: "preflight.pdf", pageCount: 1)
        let result = await PreFlightValidator.validate(fileURLs: [pdf], destination: root)
        
        try require(result.isOK, "preflight should pass for generated sample files")
        try require(result.requiredBytes > 0, "preflight should estimate required bytes")
        try require(result.hasWritePermission, "preflight should verify destination write permission")
        recordSuccess("preflight validation")
    }
    
    private mutating func checkPDFEndToEnd() async throws {
        let source = try createSamplePDF(named: "source.pdf", pageCount: 3)
        let sourceHash = try IntegrityService.shared.sha256(of: source)
        
        let stripped = root.appendingPathComponent("source.stripped.pdf")
        try MetadataStripService.shared.stripPDFMetadata(at: source, to: stripped)
        try require(PDFDocument(url: stripped)?.pageCount == 3, "stripped PDF should preserve page count")
        
        let watermark = PdfProcessingService.WatermarkConfig(
            text: "CONFIDENTIAL",
            size: 40,
            opacity: 0.45,
            location: 3,
            colorHex: "#AA0000",
            batesEnabled: true,
            batesPrefix: "MARC-",
            batesStartNumber: 42,
            batesDigitCount: 5,
            batesLocation: 2,
            batesFontFamily: 2,
            batesFontSize: 10,
            batesColorHex: "#111111"
        )
        
        guard let strippedDoc = PDFDocument(url: stripped) else {
            throw HarnessError.assertion("stripped PDF should be readable")
        }
        let watermarked = root.appendingPathComponent("source.watermarked.pdf")
        let nextBates = try PdfProcessingService.shared.writeWatermarkedPDF(
            document: strippedDoc,
            to: watermarked,
            watermark: watermark,
            startBates: 42
        )
        try require(nextBates == 45, "PDF Bates numbering should advance by page count")
        try require(PDFDocument(url: watermarked)?.pageCount == 3, "watermarked PDF should preserve page count")
        
        guard let watermarkedDoc = PDFDocument(url: watermarked) else {
            throw HarnessError.assertion("watermarked PDF should be readable")
        }
        let encrypted = root.appendingPathComponent("source.encrypted.pdf")
        _ = try PdfProcessingService.shared.writeEncryptedPDF(
            document: watermarkedDoc,
            to: encrypted,
            password: password
        )
        try require(fileManager.fileExists(atPath: encrypted.path), "encrypted PDF should exist")
        try require(try IntegrityService.shared.sha256(of: encrypted) != sourceHash, "encrypted PDF hash should differ from source")
        
        guard let encryptedDoc = PDFDocument(url: encrypted) else {
            throw HarnessError.assertion("encrypted PDF should open as a PDF document")
        }
        try require(encryptedDoc.isLocked, "encrypted PDF should initially be locked")
        try require(!encryptedDoc.unlock(withPassword: "wrong-password"), "encrypted PDF should reject wrong password")
        try require(encryptedDoc.unlock(withPassword: password), "encrypted PDF should unlock with correct password")
        try require(encryptedDoc.pageCount == 3, "unlocked PDF should preserve page count")
        
        let sidecar = try IntegrityService.shared.generateSidecar(for: encrypted)
        try require(fileManager.fileExists(atPath: sidecar.path), "PDF sidecar hash should be generated")
        recordSuccess("PDF strip, watermark, Bates, encrypt, unlock, hash sidecar")
    }
    
    private mutating func checkDOCXEndToEnd() async throws {
        let source = try await createSampleDOCX(named: "source.docx")
        let sourceHash = try IntegrityService.shared.sha256(of: source)
        
        let stripped = root.appendingPathComponent("source.stripped.docx")
        try await MetadataStripService.shared.stripDocxMetadata(at: source, to: stripped)
        let strippedMetadata = try await MetadataStripService.shared.inspectMetadata(at: stripped)
        try require(strippedMetadata["dc:creator"] == nil, "DOCX creator metadata should be stripped")
        try require(strippedMetadata["Company"] == nil, "DOCX company metadata should be stripped")
        
        let watermark = PdfProcessingService.WatermarkConfig(
            text: "PRIVILEGED",
            size: 36,
            opacity: 0.35,
            location: 0,
            colorHex: "#006699",
            batesEnabled: true,
            batesPrefix: "DOC-",
            batesStartNumber: 7,
            batesDigitCount: 4,
            batesLocation: 2,
            batesFontFamily: 2,
            batesFontSize: 10,
            batesColorHex: "#000000"
        )
        let protected = root.appendingPathComponent("source.protected.docx")
        _ = try await DocxService.shared.protect(
            docxAt: stripped,
            to: protected,
            options: DocxService.Options(
                openPassword: "",
                modifyPassword: "modify-\(password)",
                restriction: .readOnly,
                markAsFinal: true,
                watermark: watermark
            ),
            startBates: 7
        )
        
        let inspected = try await unzipDOCX(protected, into: "protected-docx")
        let documentXML = try read(inspected.appendingPathComponent("word/document.xml"))
        let relsXML = try read(inspected.appendingPathComponent("word/_rels/document.xml.rels"))
        let headerXML = try read(inspected.appendingPathComponent("word/headerWatermark.xml"))
        let settingsXML = try read(inspected.appendingPathComponent("word/settings.xml"))
        
        try require(documentXML.contains("<w:headerReference"), "protected DOCX should link a watermark header")
        try require(relsXML.contains("headerWatermark.xml"), "protected DOCX relationships should include watermark header")
        try require(headerXML.contains("PRIVILEGED"), "protected DOCX header should contain watermark text")
        try require(headerXML.contains("DOC-"), "protected DOCX header should contain Bates prefix")
        try require(settingsXML.contains("w:documentProtection"), "protected DOCX should include editing restriction")
        
        let encrypted = root.appendingPathComponent("source.encrypted.docx")
        try await DocxEncryptionService.shared.encrypt(docxFile: protected, to: encrypted, password: password)
        let encryptedData = try Data(contentsOf: encrypted)
        try require(Array(encryptedData.prefix(4)) == [0xD0, 0xCF, 0x11, 0xE0], "encrypted DOCX should use OLE compound file magic")
        try require(try IntegrityService.shared.sha256(of: encrypted) != sourceHash, "encrypted DOCX hash should differ from source")
        
        do {
            _ = try await DocxEncryptionService.shared.decrypt(docxFile: encrypted, password: "wrong-password")
            throw HarnessError.assertion("encrypted DOCX should reject wrong password")
        } catch HarnessError.assertion {
            throw HarnessError.assertion("encrypted DOCX should reject wrong password")
        } catch {
            // Expected wrong-password failure.
        }
        
        let decrypted = try await DocxEncryptionService.shared.decrypt(docxFile: encrypted, password: password)
        let protectedData = try Data(contentsOf: protected)
        try require(decrypted == protectedData, "decrypted DOCX should match protected input bytes")
        recordSuccess("DOCX metadata strip, watermark, Bates, protect, encrypt, decrypt")
    }
    
    private mutating func checkZIPEndToEnd() async throws {
        let folder = root.appendingPathComponent("zip-source")
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try "alpha\n".write(to: folder.appendingPathComponent("alpha.txt"), atomically: true, encoding: .utf8)
        try "beta\n".write(to: folder.appendingPathComponent("beta.txt"), atomically: true, encoding: .utf8)
        let nested = folder.appendingPathComponent("nested")
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        try "gamma\n".write(to: nested.appendingPathComponent("gamma.txt"), atomically: true, encoding: .utf8)
        
        let archive = root.appendingPathComponent("sample.zip")
        try await ArchiveService.shared.zipFolder(at: folder, to: archive, password: password)
        try require(fileManager.fileExists(atPath: archive.path), "encrypted ZIP should exist")
        
        do {
            try await ArchiveService.shared.unzip(archiveAt: archive, to: root.appendingPathComponent("wrong-zip"), password: "wrong-password")
            throw HarnessError.assertion("encrypted ZIP should reject wrong password")
        } catch HarnessError.assertion {
            throw HarnessError.assertion("encrypted ZIP should reject wrong password")
        } catch {
            // Expected wrong-password failure.
        }
        
        let extracted = root.appendingPathComponent("zip-extracted")
        try await ArchiveService.shared.unzip(archiveAt: archive, to: extracted, password: password)
        try require(try directoriesMatch(folder, extracted), "extracted ZIP contents should match source folder")
        
        let item = await FileItem(url: archive)
        let guessed = await PasswordGuessingService.shared.guessPassword(
            for: item,
            candidates: ["wrong-password", password, "123456"]
        )
        try require(guessed == password, "password guesser should find ZIP password from candidates")
        recordSuccess("ZIP encrypt, wrong-password reject, decrypt, content compare, password guess")
    }
    
    private mutating func checkReportsAndReceipts() async throws {
        let file = try createSamplePDF(named: "report-source.pdf", pageCount: 1)
        let report = BatchReportService.FileReport(
            fileID: UUID().uuidString,
            fileName: file.lastPathComponent,
            sourceURL: file,
            outputURL: root.appendingPathComponent("report-output.pdf"),
            operation: "Core E2E",
            success: true,
            startTime: Date(),
            endTime: Date(),
            fileSizeBefore: BatchReportService.fileSize(of: file),
            fileSizeAfter: BatchReportService.fileSize(of: file),
            md5Before: await BatchReportService.md5(of: file),
            md5After: await BatchReportService.md5(of: file),
            details: ["Harness": "true"]
        )
        
        guard let reportURL = BatchReportService.shared.generateReport(
            title: "Core E2E Harness",
            batchOperation: "Validation",
            files: [report],
            outputDirectory: root
        ) else {
            throw HarnessError.assertion("batch report should be generated")
        }
        try require(try read(reportURL).contains("Core E2E Harness"), "batch report should include title")
        recordSuccess("batch report generation")
    }
    
    private func createSamplePDF(named name: String, pageCount: Int) throws -> URL {
        let url = root.appendingPathComponent(name)
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let metadata: [CFString: Any] = [
            kCGPDFContextTitle: "Harness PDF",
            kCGPDFContextAuthor: "Marcrypt Harness",
            kCGPDFContextSubject: "End-to-end validation"
        ]
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, metadata as CFDictionary) else {
            throw HarnessError.assertion("could not create sample PDF")
        }
        
        for page in 1...pageCount {
            context.beginPage(mediaBox: &mediaBox)
            let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsContext
            let text = "Marcrypt harness PDF page \(page)" as NSString
            text.draw(
                at: CGPoint(x: 72, y: 680),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 24),
                    .foregroundColor: NSColor.black
                ]
            )
            NSGraphicsContext.restoreGraphicsState()
            context.endPage()
        }
        context.closePDF()
        return url
    }
    
    private func createSampleDOCX(named name: String) async throws -> URL {
        let docxRoot = root.appendingPathComponent("docx-source-\(UUID().uuidString)")
        let word = docxRoot.appendingPathComponent("word")
        let wordRels = word.appendingPathComponent("_rels")
        let packageRels = docxRoot.appendingPathComponent("_rels")
        let props = docxRoot.appendingPathComponent("docProps")
        try fileManager.createDirectory(at: wordRels, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: packageRels, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: props, withIntermediateDirectories: true)
        
        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
          <Override PartName="/word/settings.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/>
          <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
          <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
        </Types>
        """.write(to: docxRoot.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        
        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
          <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
          <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
        </Relationships>
        """.write(to: packageRels.appendingPathComponent(".rels"), atomically: true, encoding: .utf8)
        
        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        </Relationships>
        """.write(to: wordRels.appendingPathComponent("document.xml.rels"), atomically: true, encoding: .utf8)
        
        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
                    xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <w:body>
            <w:p><w:r><w:t>Marcrypt harness DOCX body</w:t></w:r></w:p>
            <w:sectPr>
              <w:pgSz w:w="12240" w:h="15840"/>
              <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/>
            </w:sectPr>
          </w:body>
        </w:document>
        """.write(to: word.appendingPathComponent("document.xml"), atomically: true, encoding: .utf8)
        
        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:settings xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"/>
        """.write(to: word.appendingPathComponent("settings.xml"), atomically: true, encoding: .utf8)
        
        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
                           xmlns:dc="http://purl.org/dc/elements/1.1/">
          <dc:title>Harness DOCX</dc:title>
          <dc:creator>Marcrypt Harness</dc:creator>
          <cp:lastModifiedBy>Marcrypt Harness</cp:lastModifiedBy>
          <cp:revision>3</cp:revision>
        </cp:coreProperties>
        """.write(to: props.appendingPathComponent("core.xml"), atomically: true, encoding: .utf8)
        
        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"
                    xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">
          <Application>Marcrypt Harness</Application>
          <Company>MarcLaw</Company>
          <Manager>Harness</Manager>
          <Pages>1</Pages>
        </Properties>
        """.write(to: props.appendingPathComponent("app.xml"), atomically: true, encoding: .utf8)
        
        let output = root.appendingPathComponent(name)
        try await ArchiveService.shared.zipFolder(at: docxRoot, to: output, password: nil)
        return output
    }
    
    private func unzipDOCX(_ source: URL, into name: String) async throws -> URL {
        let destination = root.appendingPathComponent(name)
        try await ArchiveService.shared.unzip(archiveAt: source, to: destination, password: "")
        return destination
    }
    
    private func directoriesMatch(_ lhs: URL, _ rhs: URL) throws -> Bool {
        let lhsFiles = try relativeFiles(under: lhs)
        let rhsFiles = try relativeFiles(under: rhs)
        guard lhsFiles == rhsFiles else { return false }
        for file in lhsFiles {
            let lhsData = try Data(contentsOf: lhs.appendingPathComponent(file))
            let rhsData = try Data(contentsOf: rhs.appendingPathComponent(file))
            if lhsData != rhsData { return false }
        }
        return true
    }
    
    private func relativeFiles(under root: URL) throws -> [String] {
        let normalizedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        
        var files: [String] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                let normalizedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
                if normalizedPath.hasPrefix(normalizedRoot + "/") {
                    files.append(String(normalizedPath.dropFirst(normalizedRoot.count + 1)))
                } else {
                    files.append(url.lastPathComponent)
                }
            }
        }
        return files.sorted()
    }
    
    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }
    
    private mutating func require(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw HarnessError.assertion(message)
        }
    }
    
    private mutating func recordSuccess(_ message: String) {
        successes.append(message)
    }
    
    private mutating func recordFailure(_ message: String, _ error: Error) {
        failures.append("\(message): \(error)")
    }
}

private enum HarnessError: Error, CustomStringConvertible {
    case assertion(String)
    
    var description: String {
        switch self {
        case .assertion(let message):
            return message
        }
    }
}

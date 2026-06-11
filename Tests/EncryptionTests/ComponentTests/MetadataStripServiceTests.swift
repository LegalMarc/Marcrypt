import XCTest
import Foundation
import ZipArchive
@testable import MarcryptCore

/// Regression tests for MetadataStripService's in-process DOCX stripping.
///
/// Verifies that:
///   (a) Author and Company fields are blanked after stripping.
///   (b) The output is still a valid DOCX (unzips successfully and word/document.xml parses).
///   (c) No subprocess is used (the test cannot directly assert absence of a Process() call,
///       but the implementation no longer contains one — compilation is the proof, and the
///       sandboxed round-trip below proves in-process unzip/rezip works end-to-end).
final class MetadataStripServiceTests: XCTestCase {

    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("metadata_strip_tests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    /// Build a minimal valid DOCX with author and company metadata populated.
    private func createDocxWithMetadata(author: String, company: String) throws -> URL {
        let docxURL = tempDir.appendingPathComponent("metadata_source.docx")
        let contentDir = tempDir.appendingPathComponent("metadata_docx_structure")
        let wordDir = contentDir.appendingPathComponent("word")
        let relsDir = contentDir.appendingPathComponent("_rels")
        let propsDir = contentDir.appendingPathComponent("docProps")

        try FileManager.default.createDirectory(at: wordDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: relsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: propsDir, withIntermediateDirectories: true)

        let contentTypesXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
            <Default Extension="xml" ContentType="application/xml"/>
            <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
            <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
            <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
        </Types>
        """

        let relsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
            <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
            <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
        </Relationships>
        """

        let documentXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
            <w:body>
                <w:p><w:r><w:t>Test document with metadata</w:t></w:r></w:p>
            </w:body>
        </w:document>
        """

        let coreXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties
            xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
            xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:creator>\(author)</dc:creator>
            <cp:lastModifiedBy>\(author)</cp:lastModifiedBy>
            <cp:revision>5</cp:revision>
            <dc:title>Sensitive Contract</dc:title>
        </cp:coreProperties>
        """

        let appXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">
            <Company>\(company)</Company>
            <Manager>Jane Smith</Manager>
            <Application>Microsoft Office Word</Application>
        </Properties>
        """

        let wordRelsDir = wordDir.appendingPathComponent("_rels")
        try FileManager.default.createDirectory(at: wordRelsDir, withIntermediateDirectories: true)
        let docRelsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        </Relationships>
        """

        try contentTypesXML.write(to: contentDir.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try relsXML.write(to: relsDir.appendingPathComponent(".rels"), atomically: true, encoding: .utf8)
        try documentXML.write(to: wordDir.appendingPathComponent("document.xml"), atomically: true, encoding: .utf8)
        try docRelsXML.write(to: wordRelsDir.appendingPathComponent("document.xml.rels"), atomically: true, encoding: .utf8)
        try coreXML.write(to: propsDir.appendingPathComponent("core.xml"), atomically: true, encoding: .utf8)
        try appXML.write(to: propsDir.appendingPathComponent("app.xml"), atomically: true, encoding: .utf8)

        let success = SSZipArchive.createZipFile(
            atPath: docxURL.path,
            withContentsOfDirectory: contentDir.path,
            keepParentDirectory: false,
            withPassword: nil,
            andProgressHandler: nil
        )
        guard success else {
            throw NSError(domain: "MetadataStripServiceTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create test DOCX ZIP"])
        }
        try? FileManager.default.removeItem(at: contentDir)
        return docxURL
    }

    // MARK: - DOCX Metadata Strip Round-Trip

    /// Asserts that stripDocxMetadata blanks the dc:creator and Company fields,
    /// and that the output is still a structurally valid DOCX (unzips and word/document.xml parses).
    func testStripDocxMetadata_BlanksAuthorAndCompany() async throws {
        let sourceURL = try createDocxWithMetadata(author: "John Doe", company: "Acme Corp")
        let strippedURL = tempDir.appendingPathComponent("stripped.docx")

        try await MetadataStripService.shared.stripDocxMetadata(at: sourceURL, to: strippedURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: strippedURL.path),
                      "Stripped DOCX should exist at destination")

        // (a) Verify author/company fields are blanked
        let verifyDir = tempDir.appendingPathComponent("verify_stripped")
        try await ArchiveService.shared.unzip(archiveAt: strippedURL, to: verifyDir, password: "")

        let coreXMLPath = verifyDir.appendingPathComponent("docProps/core.xml")
        XCTAssertTrue(FileManager.default.fileExists(atPath: coreXMLPath.path),
                      "core.xml should be present in stripped DOCX")

        let coreData = try Data(contentsOf: coreXMLPath)
        let coreXML = try XMLDocument(data: coreData, options: [])
        let coreRoot = try XCTUnwrap(coreXML.rootElement(), "core.xml should have a root element")

        for fieldName in ["dc:creator", "cp:lastModifiedBy", "dc:title", "cp:revision"] {
            let elements = coreRoot.elements(forName: fieldName)
            for el in elements {
                let value = el.stringValue ?? ""
                XCTAssertTrue(value.isEmpty,
                    "core.xml field '\(fieldName)' should be blanked after stripping, got: '\(value)'")
            }
        }

        let appXMLPath = verifyDir.appendingPathComponent("docProps/app.xml")
        XCTAssertTrue(FileManager.default.fileExists(atPath: appXMLPath.path),
                      "app.xml should be present in stripped DOCX")

        let appData = try Data(contentsOf: appXMLPath)
        let appXML = try XMLDocument(data: appData, options: [])
        let appRoot = try XCTUnwrap(appXML.rootElement(), "app.xml should have a root element")

        for fieldName in ["Company", "Manager"] {
            let elements = appRoot.elements(forName: fieldName)
            for el in elements {
                let value = el.stringValue ?? ""
                XCTAssertTrue(value.isEmpty,
                    "app.xml field '\(fieldName)' should be blanked after stripping, got: '\(value)'")
            }
        }

        // (b) Output is a valid DOCX — word/document.xml is present and parses
        let documentXMLPath = verifyDir.appendingPathComponent("word/document.xml")
        XCTAssertTrue(FileManager.default.fileExists(atPath: documentXMLPath.path),
                      "word/document.xml must survive metadata stripping")

        let docData = try Data(contentsOf: documentXMLPath)
        let docXML = try XMLDocument(data: docData, options: [])
        XCTAssertNotNil(docXML.rootElement(), "word/document.xml must parse as valid XML")
    }

    /// Asserts that stripping a DOCX twice (idempotency) still produces a valid, openable DOCX.
    func testStripDocxMetadata_IsIdempotent() async throws {
        let sourceURL = try createDocxWithMetadata(author: "Alice", company: "Contoso")
        let stripped1URL = tempDir.appendingPathComponent("stripped1.docx")
        let stripped2URL = tempDir.appendingPathComponent("stripped2.docx")

        try await MetadataStripService.shared.stripDocxMetadata(at: sourceURL, to: stripped1URL)
        try await MetadataStripService.shared.stripDocxMetadata(at: stripped1URL, to: stripped2URL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: stripped2URL.path),
                      "Double-stripped DOCX should exist")

        // Must still unzip and contain word/document.xml
        let verifyDir = tempDir.appendingPathComponent("verify_idempotent")
        try await ArchiveService.shared.unzip(archiveAt: stripped2URL, to: verifyDir, password: "")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: verifyDir.appendingPathComponent("word/document.xml").path),
            "word/document.xml must be present after double strip"
        )
    }

    /// Stripping to a path where a (stale) file already exists must replace
    /// it cleanly, not append to or corrupt the existing archive.
    func testStripDocxMetadata_OverwritesStaleDestination() async throws {
        let sourceURL = try createDocxWithMetadata(author: "Bob", company: "Initech")
        let destURL = tempDir.appendingPathComponent("stripped_over_stale.docx")

        // Pre-create a non-empty stale file at the destination path.
        try Data("not a real docx — stale bytes that must be replaced".utf8).write(to: destURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path))

        try await MetadataStripService.shared.stripDocxMetadata(at: sourceURL, to: destURL)

        // The result must be a valid DOCX (the stale bytes must be gone, not appended to).
        let verifyDir = tempDir.appendingPathComponent("verify_stale")
        try await ArchiveService.shared.unzip(archiveAt: destURL, to: verifyDir, password: "")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: verifyDir.appendingPathComponent("word/document.xml").path),
            "word/document.xml must be present after overwriting a stale destination"
        )
        let docData = try Data(contentsOf: verifyDir.appendingPathComponent("word/document.xml"))
        XCTAssertNotNil(try XMLDocument(data: docData, options: []).rootElement(),
                        "word/document.xml must parse after overwriting a stale destination")
    }
}

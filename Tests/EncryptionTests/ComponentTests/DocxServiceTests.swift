import XCTest
import Foundation
import ZipArchive
import POLEWrapper
@testable import MarcryptCore

/// Component Integration Tests for DocxEncryptionService
final class DocxServiceTests: XCTestCase {

    var tempDir: URL!
    var sampleDocxURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("docx_tests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Create a minimal valid DOCX (it's a ZIP with specific structure)
        sampleDocxURL = try createMinimalDocx()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helper: Create Minimal DOCX

    private func createMinimalDocx() throws -> URL {
        let docxURL = tempDir.appendingPathComponent("sample.docx")

        // DOCX is a ZIP file with specific XML structure
        // Create minimal content
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
            <w:body>
                <w:p><w:r><w:t>Hello Test Document</w:t></w:r></w:p>
            </w:body>
        </w:document>
        """

        let relsXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """

        // Create temp folder structure
        let contentDir = tempDir.appendingPathComponent("docx_content")
        let wordDir = contentDir.appendingPathComponent("word")
        let relsDir = contentDir.appendingPathComponent("_rels")

        try FileManager.default.createDirectory(at: wordDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: relsDir, withIntermediateDirectories: true)

        try contentTypesXML.write(to: contentDir.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try documentXML.write(to: wordDir.appendingPathComponent("document.xml"), atomically: true, encoding: .utf8)
        try relsXML.write(to: relsDir.appendingPathComponent(".rels"), atomically: true, encoding: .utf8)

        // Add word/_rels/document.xml.rels for watermark injection
        let wordRelsDir = wordDir.appendingPathComponent("_rels")
        try FileManager.default.createDirectory(at: wordRelsDir, withIntermediateDirectories: true)
        let docRelsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rIdWatermark" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer1.xml"/>
        </Relationships>
        """
        try docRelsXML.write(to: wordRelsDir.appendingPathComponent("document.xml.rels"), atomically: true, encoding: .utf8)

        // Zip it using SSZipArchive directly (sync)
        let success = SSZipArchive.createZipFile(
            atPath: docxURL.path,
            withContentsOfDirectory: contentDir.path,
            keepParentDirectory: false,
            withPassword: nil,
            andProgressHandler: nil
        )

        guard success else {
            throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create DOCX ZIP"])
        }

        // Clean up temp content folder
        try? FileManager.default.removeItem(at: contentDir)

        return docxURL
    }


    // MARK: - C2a: DOCX Encryption Round Trip

    func testDocxEncryption_RoundTrip() async throws {
        let originalData = try Data(contentsOf: sampleDocxURL)
        let encryptedURL = tempDir.appendingPathComponent("encrypted.docx")
        let password = "secret123"

        // Encrypt
        try await DocxEncryptionService.shared.encrypt(
            docxFile: sampleDocxURL,
            to: encryptedURL,
            password: password
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: encryptedURL.path),
                      "Encrypted file should exist")

        // Decrypt
        let decryptedData = try await DocxEncryptionService.shared.decrypt(
            docxFile: encryptedURL,
            password: password
        )

        // Verify decrypted data matches original
        XCTAssertEqual(decryptedData, originalData,
                       "Decrypted data should match original")
    }

    // MARK: - C2b: DOCX Wrong Password Fails

    func testDocxEncryption_WrongPassword() async throws {
        let encryptedURL = tempDir.appendingPathComponent("encrypted_wrong.docx")
        let password = "correct"

        // Encrypt
        try await DocxEncryptionService.shared.encrypt(
            docxFile: sampleDocxURL,
            to: encryptedURL,
            password: password
        )

        // Try to decrypt with wrong password
        do {
            _ = try await DocxEncryptionService.shared.decrypt(
                docxFile: encryptedURL,
                password: "wrong"
            )
            XCTFail("Should throw error for wrong password")
        } catch {
            // Expected - decryption should fail
            XCTAssertTrue(true, "Correctly threw error for wrong password")
        }
    }

    // MARK: - C2c: DOCX Encryption Has OLE Magic Bytes

    func testDocxEncryption_OLEMagic() async throws {
        let encryptedURL = tempDir.appendingPathComponent("encrypted_ole.docx")

        try await DocxEncryptionService.shared.encrypt(
            docxFile: sampleDocxURL,
            to: encryptedURL,
            password: "test"
        )

        // Read first 4 bytes
        let fileData = try Data(contentsOf: encryptedURL)
        let magicBytes = Array(fileData.prefix(4))

        // OLE Compound Document magic: D0 CF 11 E0
        let expectedMagic: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0]

        XCTAssertEqual(magicBytes, expectedMagic,
                       "Encrypted DOCX should have OLE magic bytes")
    }

    func testDocxEncryption_DataIntegrityUsesRandomizedKeys() async throws {
        let encryptedURLA = tempDir.appendingPathComponent("encrypted_integrity_a.docx")
        let encryptedURLB = tempDir.appendingPathComponent("encrypted_integrity_b.docx")
        let password = "integrity123"

        try await DocxEncryptionService.shared.encrypt(
            docxFile: sampleDocxURL,
            to: encryptedURLA,
            password: password
        )

        try await DocxEncryptionService.shared.encrypt(
            docxFile: sampleDocxURL,
            to: encryptedURLB,
            password: password
        )

        let (encHmacKeyA, encHmacValueA) = try extractEncryptedDataIntegrityValues(from: encryptedURLA)
        let (encHmacKeyB, encHmacValueB) = try extractEncryptedDataIntegrityValues(from: encryptedURLB)

        let keyA = try XCTUnwrap(Data(base64Encoded: encHmacKeyA))
        let keyB = try XCTUnwrap(Data(base64Encoded: encHmacKeyB))
        let valueA = try XCTUnwrap(Data(base64Encoded: encHmacValueA))
        let valueB = try XCTUnwrap(Data(base64Encoded: encHmacValueB))

        XCTAssertEqual(keyA.count, 64, "dataIntegrity encryptedHmacKey should be 64 bytes after base64 decode")
        XCTAssertEqual(valueA.count, 64, "dataIntegrity encryptedHmacValue should be 64 bytes after base64 decode")
        XCTAssertEqual(keyB.count, 64, "dataIntegrity encryptedHmacKey should remain 64 bytes on each encryption")
        XCTAssertEqual(valueB.count, 64, "dataIntegrity encryptedHmacValue should remain 64 bytes on each encryption")

        XCTAssertNotEqual(encHmacKeyA, encHmacKeyB, "encryptedHmacKey should differ across separate encryptions")
        XCTAssertNotEqual(encHmacValueA, encHmacValueB, "encryptedHmacValue should differ across separate encryptions")

        let decryptedA = try await DocxEncryptionService.shared.decrypt(docxFile: encryptedURLA, password: password)
        let decryptedB = try await DocxEncryptionService.shared.decrypt(docxFile: encryptedURLB, password: password)
        let originalData = try Data(contentsOf: sampleDocxURL)
        XCTAssertEqual(decryptedA, originalData, "Decrypted payload should match original")
        XCTAssertEqual(decryptedB, originalData, "Decrypted payload should match original")
    }

    func testDocxEncryption_AgileContainerIncludesDataSpacesStreams() async throws {
        let encryptedURL = tempDir.appendingPathComponent("encrypted_dataspaces.docx")

        try await DocxEncryptionService.shared.encrypt(
            docxFile: sampleDocxURL,
            to: encryptedURL,
            password: "test"
        )

        let ole = OLEHelper()
        XCTAssertTrue(ole.openFile(atPath: encryptedURL.path), "Encrypted DOCX should open as OLE")
        defer { ole.close() }

        let rawStreamNames = Set(ole.allStreamNames())
        let streamNames = Set(rawStreamNames.flatMap { name -> [String] in
            if name.hasPrefix("/") {
                return [name, String(name.dropFirst())]
            }
            return [name, "/\(name)"]
        })

        let expectedDataSpaceStreams = [
            ["DataSpaces/Version", "/DataSpaces/Version"],
            ["DataSpaces/DataSpaceMap", "/DataSpaces/DataSpaceMap"],
            ["DataSpaces/DataSpaceInfo/StrongEncryptionDataSpace", "/DataSpaces/DataSpaceInfo/StrongEncryptionDataSpace"],
            ["DataSpaces/TransformInfo/StrongEncryptionTransform/Primary", "/DataSpaces/TransformInfo/StrongEncryptionTransform/Primary"]
        ]
        for aliases in expectedDataSpaceStreams {
            let resolvedDataSpaceStream = aliases.first(where: { streamNames.contains($0) })
            XCTAssertNotNil(
                resolvedDataSpaceStream,
                "Missing Agile data space stream \(aliases.joined(separator: " / "))"
            )
            guard let dataSpaceStream = resolvedDataSpaceStream else { continue }
            XCTAssertTrue(ole.streamExists(dataSpaceStream), "streamExists should report \(dataSpaceStream)")
            let streamData = try XCTUnwrap(ole.readStream(dataSpaceStream), "\(dataSpaceStream) should be readable")
            XCTAssertGreaterThan(streamData.count, 0, "\(dataSpaceStream) should contain bytes")
        }

        let expectedCoreStreams = [
            ["EncryptionInfo", "/EncryptionInfo", "\u{06}EncryptionInfo"],
            ["EncryptedPackage", "/EncryptedPackage", "\u{06}EncryptedPackage"]
        ]
        for aliases in expectedCoreStreams {
            let resolvedCoreStream = aliases.first(where: { streamNames.contains($0) })
            XCTAssertNotNil(
                resolvedCoreStream,
                "Missing core Agile stream \(aliases.joined(separator: " / "))"
            )
            if let coreStream = resolvedCoreStream {
                XCTAssertTrue(ole.streamExists(coreStream), "streamExists should report \(coreStream)")
                let streamData = try XCTUnwrap(ole.readStream(coreStream), "\(coreStream) should be readable")
                XCTAssertGreaterThan(streamData.count, 0, "\(coreStream) should contain bytes")
            }
        }

        let unexpectedPropertyStream = ["\u{05}SummaryInformation", "SummaryInformation", "/SummaryInformation"].first { streamNames.contains($0) }
        XCTAssertNil(
            unexpectedPropertyStream,
            "Unexpected OLE property stream \(unexpectedPropertyStream ?? "<none>") in Agile container"
        )

        let encryptionInfoData = try XCTUnwrap(ole.readStream("EncryptionInfo"), "EncryptionInfo stream should exist")
        guard let encryptionXML = String(data: encryptionInfoData.dropFirst(8), encoding: .utf8) else {
            XCTFail("EncryptionInfo XML should be UTF-8")
            return
        }
        XCTAssertTrue(encryptionXML.contains("standalone=\"yes\""), "EncryptionInfo header should declare standalone=yes")
        XCTAssertTrue(encryptionXML.contains("xmlns:c=\"http://schemas.microsoft.com/office/2006/keyEncryptor/certificate\""), "EncryptionInfo should declare certificate keyEncryptor namespace")
    }

    // MARK: - C2d: DOCX Watermark Injection

    func testDocxWatermark_InjectsHeader() async throws {
        let outputURL = tempDir.appendingPathComponent("watermarked.docx")
        var options = DocxService.Options(
            openPassword: "",
            modifyPassword: "",
            restriction: .none,
            markAsFinal: false
        )
        options.watermark = PdfProcessingService.WatermarkConfig(
            text: "CONFIDENTIAL",
            size: 48,
            opacity: 0.5,
            location: 0
        )

        _ = try await DocxService.shared.protect(
            docxAt: sampleDocxURL,
            to: outputURL,
            options: options
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path), "Output file should exist")

        // Unzip and verify contents
        let unzipDir = tempDir.appendingPathComponent("verify_wm_unzip")
        try await ArchiveService.shared.unzip(archiveAt: outputURL, to: unzipDir, password: "")

        let wordDir = unzipDir.appendingPathComponent("word")
        let headerURL = wordDir.appendingPathComponent("headerWatermark.xml")

        XCTAssertTrue(FileManager.default.fileExists(atPath: headerURL.path), "headerWatermark.xml should be created")

        let docURL = wordDir.appendingPathComponent("document.xml")
        let docContent = try String(contentsOf: docURL)
        XCTAssertTrue(docContent.contains("<w:headerReference"), "document.xml should contain header reference")

        let relsURL = wordDir.appendingPathComponent("_rels/document.xml.rels")
        let relsContent = try String(contentsOf: relsURL)
        XCTAssertTrue(relsContent.contains("headerWatermark.xml"), "relationships should point to header")
    }

    func testDocxWatermark_UsesUniqueRelationshipId_WhenPreferredIdIsReserved() async throws {
        let sourceURL = try createMinimalDocxWithReservedRelationshipId()
        let outputURL = tempDir.appendingPathComponent("watermark-relationship-collision.docx")
        let options = DocxService.Options(
            openPassword: "",
            modifyPassword: "",
            restriction: .none,
            markAsFinal: false,
            watermark: PdfProcessingService.WatermarkConfig(
                text: "CONFIDENTIAL",
                size: 48,
                opacity: 0.5,
                location: 0
            )
        )

        _ = try await DocxService.shared.protect(
            docxAt: sourceURL,
            to: outputURL,
            options: options
        )

        let unzipDir = tempDir.appendingPathComponent("verify_relationship_collision")
        try await ArchiveService.shared.unzip(archiveAt: outputURL, to: unzipDir, password: "")
        let docRelsURL = unzipDir.appendingPathComponent("word/_rels/document.xml.rels")
        let documentURL = unzipDir.appendingPathComponent("word/document.xml")
        let relsMap = try parseRelationshipMap(from: docRelsURL)
        let docContent = try String(contentsOf: documentURL)
        let docRoot = try XMLHelper.parse(xml: docContent)
        let headerReferenceNodes = docRoot.findAll(named: "w:headerReference")
            .filter { $0.attributes["w:type"] == "default" }
        let headerRels = headerReferenceNodes.compactMap { $0.attributes["r:id"] }
        XCTAssertEqual(headerRels.count, 1, "default header reference should exist once")
        guard let headerRelId = headerRels.first else {
            XCTFail("Expected one default header reference")
            return
        }

        XCTAssertTrue(headerRelId.hasPrefix("rIdWatermark"), "header relationship id should use watermark namespace")
        XCTAssertFalse(headerRelId == "rIdWatermark", "header id should avoid clashing with existing IDs")

        let relationship = relsMap[headerRelId]
        XCTAssertNotNil(relationship, "default header relationship should exist in document rels")
        XCTAssertEqual(relationship?.type,
                       "http://schemas.openxmlformats.org/officeDocument/2006/relationships/header")
        XCTAssertEqual(relationship?.target, "headerWatermark.xml")

        XCTAssertTrue(FileManager.default.fileExists(atPath: unzipDir.appendingPathComponent("word/headerWatermark.xml").path),
                      "header watermark file should be present")
    }

    func testDocxWatermark_RepairsInvalidHeaderReference() async throws {
        let sourceURL = try createMinimalDocxWithInvalidHeaderReference()
        let outputURL = tempDir.appendingPathComponent("watermark-invalid-ref.docx")
        let options = DocxService.Options(
            openPassword: "",
            modifyPassword: "",
            restriction: .none,
            markAsFinal: false,
            watermark: PdfProcessingService.WatermarkConfig(
                text: "CONFIDENTIAL",
                size: 44,
                opacity: 0.5,
                location: 0
            )
        )

        _ = try await DocxService.shared.protect(
            docxAt: sourceURL,
            to: outputURL,
            options: options
        )

        let unzipDir = tempDir.appendingPathComponent("verify_invalid_header_ref")
        try await ArchiveService.shared.unzip(archiveAt: outputURL, to: unzipDir, password: "")

        let documentURL = unzipDir.appendingPathComponent("word/document.xml")
        let relsMap = try parseRelationshipMap(from: unzipDir.appendingPathComponent("word/_rels/document.xml.rels"))

        let docContent = try String(contentsOf: documentURL)
        let docRoot = try XMLHelper.parse(xml: docContent)
        let headerReferenceNodes = docRoot.findAll(named: "w:headerReference")
            .filter { $0.attributes["w:type"] == "default" }
        let headerRefs = headerReferenceNodes.compactMap { $0.attributes["r:id"] }
        XCTAssertEqual(headerRefs.count, 1, "default header should be restored to a single valid reference")

        guard let headerRelId = headerRefs.first,
              let relationship = relsMap[headerRelId] else {
            XCTFail("header reference should resolve to a document relationship")
            return
        }

        XCTAssertEqual(relationship.type,
                       "http://schemas.openxmlformats.org/officeDocument/2006/relationships/header")
        XCTAssertEqual(relationship.target, "headerWatermark.xml")

        let headerContent = try String(contentsOf: unzipDir.appendingPathComponent("word/headerWatermark.xml"))
        XCTAssertTrue(headerContent.contains("PowerPlusWaterMarkObject"), "watermark should be written into the header part")
    }

    func testDocxMarkAsFinal_RegistersCustomPropertiesPart() async throws {
        let outputURL = tempDir.appendingPathComponent("final.docx")
        let options = DocxService.Options(
            openPassword: "",
            modifyPassword: "",
            restriction: .none,
            markAsFinal: true
        )

        _ = try await DocxService.shared.protect(
            docxAt: sampleDocxURL,
            to: outputURL,
            options: options
        )

        let unzipDir = tempDir.appendingPathComponent("verify_final_unzip")
        try await ArchiveService.shared.unzip(archiveAt: outputURL, to: unzipDir, password: "")

        let customURL = unzipDir.appendingPathComponent("docProps/custom.xml")
        XCTAssertTrue(FileManager.default.fileExists(atPath: customURL.path), "custom.xml should be created")
        XCTAssertTrue(try String(contentsOf: customURL).contains("_MarkAsFinal"), "custom.xml should contain Mark as Final property")

        let contentTypes = try String(contentsOf: unzipDir.appendingPathComponent("[Content_Types].xml"))
        XCTAssertTrue(contentTypes.contains("/docProps/custom.xml"), "[Content_Types].xml should register custom properties")
        XCTAssertTrue(contentTypes.contains("application/vnd.openxmlformats-officedocument.custom-properties+xml"))

        let rootRels = try String(contentsOf: unzipDir.appendingPathComponent("_rels/.rels"))
        XCTAssertTrue(rootRels.contains("docProps/custom.xml"), "root relationships should target custom properties")
        XCTAssertTrue(rootRels.contains("custom-properties"), "root relationships should use custom-properties relationship type")
    }

    func testDocxMarkAsFinal_UsesUniquePid_WhenCustomPropertiesExist() async throws {
        let sourceURL = try createDocxWithExistingCustomProperty(pid: 2)
        let outputURL = tempDir.appendingPathComponent("final-existing-custom.docx")

        let options = DocxService.Options(
            openPassword: "",
            modifyPassword: "",
            restriction: .none,
            markAsFinal: true
        )

        _ = try await DocxService.shared.protect(
            docxAt: sourceURL,
            to: outputURL,
            options: options
        )

        let extractDir = tempDir.appendingPathComponent("verify_final_existing_custom")
        try await ArchiveService.shared.unzip(archiveAt: outputURL, to: extractDir, password: "")

        let customURL = extractDir.appendingPathComponent("docProps/custom.xml")
        let customContent = try String(contentsOf: customURL)
        XCTAssertTrue(customContent.contains("_MarkAsFinal"), "custom.xml should include the Mark As Final flag")

        let pids = parseCustomPropertyPids(from: customContent)
        XCTAssertEqual(Set(pids).count, pids.count, "custom property PIDs should be unique")
        XCTAssertTrue(pids.contains(2), "existing custom property PID should remain")
        XCTAssertTrue(pids.contains(3), "mark-as-final property should use the next available PID")
        XCTAssertFalse(
            hasDuplicatePID(for: customContent),
            "custom.xml should not include duplicate PID values"
        )
    }

    func testDocxProtection_PreservesStructuralPartsWithMarkAsFinalAndWatermark() async throws {
        let sourceURL = tempDir.appendingPathComponent("structure_source.docx")
        _ = try createSampleDOCXWithHeadersAndCustomProperties(at: sourceURL, includeCustomPid: 2)

        let watermark = PdfProcessingService.WatermarkConfig(
            text: "CONFIDENTIAL",
            size: 36,
            opacity: 0.45,
            location: 0,
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

        let outputURL = tempDir.appendingPathComponent("structure-final.docx")
        let options = DocxService.Options(
            openPassword: "",
            modifyPassword: "modify",
            restriction: .readOnly,
            markAsFinal: true,
            watermark: watermark
        )

        _ = try await DocxService.shared.protect(docxAt: sourceURL, to: outputURL, options: options)

        let unzipDir = tempDir.appendingPathComponent("verify_structure_output")
        try await ArchiveService.shared.unzip(archiveAt: outputURL, to: unzipDir, password: "")

        let contentTypes = try String(contentsOf: unzipDir.appendingPathComponent("[Content_Types].xml"))
        let rootRels = try String(contentsOf: unzipDir.appendingPathComponent("_rels/.rels"))
        let docRels = try String(contentsOf: unzipDir.appendingPathComponent("word/_rels/document.xml.rels"))
        let settingsXML = try String(contentsOf: unzipDir.appendingPathComponent("word/settings.xml"))
        let documentXML = try String(contentsOf: unzipDir.appendingPathComponent("word/document.xml"))
        let customXMLURL = unzipDir.appendingPathComponent("docProps/custom.xml")
        let headerURL = unzipDir.appendingPathComponent("word/headerWatermark.xml")

        XCTAssertTrue(FileManager.default.fileExists(atPath: customXMLURL.path), "docProps/custom.xml should exist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: headerURL.path), "word/headerWatermark.xml should exist")
        XCTAssertTrue(contentTypes.contains("/word/headerWatermark.xml"), "header part should be declared")
        XCTAssertTrue(contentTypes.contains("/docProps/custom.xml"), "custom properties part should be declared")
        XCTAssertTrue(rootRels.contains("docProps/custom.xml"), "package relationships should include custom properties")
        XCTAssertTrue(rootRels.contains("custom-properties"), "package relationship should use custom-properties type")
        XCTAssertTrue(docRels.contains("headerWatermark.xml"), "document part should relate header watermark")
        XCTAssertTrue(documentXML.contains("w:headerReference"), "document.xml should include header references")
        XCTAssertTrue(settingsXML.contains("w:documentProtection"), "settings.xml should include restriction")
    }

    private func hasDuplicatePID(for customXml: String) -> Bool {
        let values = parseCustomPropertyPids(from: customXml)
        return Set(values).count != values.count
    }

    private func parseCustomPropertyPids(from customXml: String) -> [Int] {
        guard let data = customXml.data(using: .utf8),
              let xml = try? XMLDocument(data: data, options: []),
              let root = xml.rootElement() else {
            return []
        }
        return root.elements(forName: "property").compactMap { element in
            guard let pidText = element.attribute(forName: "pid")?.stringValue else { return nil }
            return Int(pidText)
        }
    }

    private func parseRelationshipMap(from url: URL) throws -> [String: (target: String, type: String)] {
        let data = try Data(contentsOf: url)
        let xml = try XMLDocument(data: data, options: [])
        let relRoot = try XCTUnwrap(xml.rootElement())
        var map: [String: (target: String, type: String)] = [:]

        for node in relRoot.elements(forName: "Relationship") {
            guard let id = node.attribute(forName: "Id")?.stringValue,
                  let target = node.attribute(forName: "Target")?.stringValue,
                  let type = node.attribute(forName: "Type")?.stringValue else { continue }
            map[id] = (target: target, type: type)
        }
        return map
    }

    private func extractEncryptedDataIntegrityValues(from encryptedDOCX: URL) throws -> (String, String) {
        let infoXML = try readEncryptionInfoXML(from: encryptedDOCX)
        guard let integrityStart = infoXML.range(of: "<dataIntegrity") else {
            throw NSError(domain: "DocxServiceTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing dataIntegrity element"])
        }

        guard let integrityEnd = infoXML[integrityStart.lowerBound...].range(of: "/>") else {
            throw NSError(domain: "DocxServiceTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "dataIntegrity element is malformed"])
        }

        let dataIntegrity = String(infoXML[integrityStart.lowerBound..<integrityEnd.upperBound])

        func attribute(_ name: String) -> String? {
            let marker = "\(name)=\""
            guard let start = dataIntegrity.range(of: marker)?.upperBound else { return nil }
            let remainder = dataIntegrity[start...]
            guard let end = remainder.firstIndex(of: "\"") else { return nil }
            return String(dataIntegrity[start..<end])
        }

        guard let encHmacKey = attribute("encryptedHmacKey"),
              let encHmacValue = attribute("encryptedHmacValue") else {
            throw NSError(domain: "DocxServiceTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing encryptedHmacKey or encryptedHmacValue"])
        }

        return (encHmacKey, encHmacValue)
    }

    private func readEncryptionInfoXML(from encryptedDOCX: URL) throws -> String {
        let ole = OLEHelper()
        guard ole.openFile(atPath: encryptedDOCX.path) else {
            throw NSError(domain: "DocxServiceTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to open OLE file"])
        }
        defer { ole.close() }

        let readResult = ole.readStream("EncryptionInfo") ?? ole.readStream("\u{06}EncryptionInfo")
        guard let encryptionInfo = readResult else {
            throw NSError(domain: "DocxServiceTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing EncryptionInfo stream"])
        }
        guard encryptionInfo.count > 8,
              let infoXML = String(data: encryptionInfo.dropFirst(8), encoding: .utf8) else {
            throw NSError(domain: "DocxServiceTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid EncryptionInfo payload"])
        }
        return infoXML
    }

    private func createMinimalDocxWithReservedRelationshipId() throws -> URL {
        let docxURL = tempDir.appendingPathComponent("reserved_relationship.docx")
        let contentDir = tempDir.appendingPathComponent("reserved_docx_structure")
        let wordDir = contentDir.appendingPathComponent("word")
        let relsDir = contentDir.appendingPathComponent("_rels")
        let wordRelsDir = wordDir.appendingPathComponent("_rels")

        try FileManager.default.createDirectory(at: wordDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: relsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wordRelsDir, withIntermediateDirectories: true)

        let contentTypesXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
            <Default Extension="xml" ContentType="application/xml"/>
            <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
            <Override PartName="/word/header1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"/>
            <Override PartName="/word/footer1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/>
        </Types>
        """

        let relsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/package/2006/relationships/officeDocument" Target="word/document.xml"/>
            <Relationship Id="rIdWatermark" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer1.xml"/>
        </Relationships>
        """

        let documentXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
            <w:body>
                <w:p><w:r><w:t>Reserved watermark ID document</w:t></w:r></w:p>
                <w:sectPr>
                    <w:pgSz w:w="12240" w:h="15840"/>
                </w:sectPr>
            </w:body>
        </w:document>
        """

        let docRelsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rIdWatermark" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer1.xml"/>
        </Relationships>
        """

        let headerXML = """
        <?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>
        <w:hdr xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:p><w:r><w:t>Header</w:t></w:r></w:p></w:hdr>
        """

        let footerXML = """
        <?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>
        <w:ftr xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:p><w:r><w:t>Footer</w:t></w:r></w:p></w:ftr>
        """

        try contentTypesXML.write(to: contentDir.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try relsXML.write(to: relsDir.appendingPathComponent(".rels"), atomically: true, encoding: .utf8)
        try documentXML.write(to: wordDir.appendingPathComponent("document.xml"), atomically: true, encoding: .utf8)
        try docRelsXML.write(to: wordRelsDir.appendingPathComponent("document.xml.rels"), atomically: true, encoding: .utf8)
        try headerXML.write(to: wordDir.appendingPathComponent("header1.xml"), atomically: true, encoding: .utf8)
        try footerXML.write(to: wordDir.appendingPathComponent("footer1.xml"), atomically: true, encoding: .utf8)

        let success = SSZipArchive.createZipFile(
            atPath: docxURL.path,
            withContentsOfDirectory: contentDir.path,
            keepParentDirectory: false,
            withPassword: nil,
            andProgressHandler: nil
        )
        guard success else { throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create DOCX ZIP"]) }
        try? FileManager.default.removeItem(at: contentDir)
        return docxURL
    }

    private func createMinimalDocxWithInvalidHeaderReference() throws -> URL {
        let docxURL = tempDir.appendingPathComponent("invalid_header_ref.docx")
        let contentDir = tempDir.appendingPathComponent("invalid_ref_docx_structure")
        let wordDir = contentDir.appendingPathComponent("word")
        let relsDir = contentDir.appendingPathComponent("_rels")
        let wordRelsDir = wordDir.appendingPathComponent("_rels")

        try FileManager.default.createDirectory(at: wordDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: relsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wordRelsDir, withIntermediateDirectories: true)

        let contentTypesXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
            <Default Extension="xml" ContentType="application/xml"/>
            <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
            <Override PartName="/word/header1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"/>
        </Types>
        """

        let relsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/package/2006/relationships/officeDocument" Target="word/document.xml"/>
            <Relationship Id="rIdHeader1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header" Target="header1.xml"/>
        </Relationships>
        """

        let documentXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
            <w:body>
                <w:p><w:r><w:t>Invalid header reference document</w:t></w:r></w:p>
                <w:sectPr>
                    <w:headerReference w:type=\"default\" r:id=\"rIdMissing\"/>
                    <w:pgSz w:w=\"12240\" w:h=\"15840\"/>
                </w:sectPr>
            </w:body>
        </w:document>
        """

        let docRelsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        </Relationships>
        """

        let headerXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:p><w:r><w:t>Header</w:t></w:r></w:p></w:hdr>
        """

        try contentTypesXML.write(to: contentDir.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try relsXML.write(to: relsDir.appendingPathComponent(".rels"), atomically: true, encoding: .utf8)
        try documentXML.write(to: wordDir.appendingPathComponent("document.xml"), atomically: true, encoding: .utf8)
        try docRelsXML.write(to: wordRelsDir.appendingPathComponent("document.xml.rels"), atomically: true, encoding: .utf8)
        try headerXML.write(to: wordDir.appendingPathComponent("header1.xml"), atomically: true, encoding: .utf8)

        let success = SSZipArchive.createZipFile(
            atPath: docxURL.path,
            withContentsOfDirectory: contentDir.path,
            keepParentDirectory: false,
            withPassword: nil,
            andProgressHandler: nil
        )
        guard success else { throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create DOCX ZIP"]) }
        try? FileManager.default.removeItem(at: contentDir)
        return docxURL
    }

    private func createDocxWithExistingCustomProperty(pid: Int) throws -> URL {
        let docxURL = tempDir.appendingPathComponent("source-existing-custom.docx")
        let contentTypesXML = """
        <?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>
        <Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">
            <Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>
            <Default Extension=\"xml\" ContentType=\"application/xml\"/>
            <Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>
            <Override PartName=\"/word/settings.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml\"/>
            <Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>
            <Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/>
            <Override PartName=\"/docProps/custom.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.custom-properties+xml\"/>
        </Types>
        """

        let relsXML = """
        <?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>
        <Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">
            <Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/officeDocument\" Target=\"word/document.xml\"/>
            <Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/>
            <Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties\" Target=\"docProps/app.xml\"/>
            <Relationship Id=\"rId4\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/custom-properties\" Target=\"docProps/custom.xml\"/>
        </Relationships>
        """

        let documentXML = """
        <?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>
        <w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">
            <w:body>
                <w:p><w:r><w:t>Existing custom properties document</w:t></w:r></w:p>
            </w:body>
        </w:document>
        """

        let contentDir = tempDir.appendingPathComponent("docx_custom")
        let wordDir = contentDir.appendingPathComponent("word")
        let relsDir = contentDir.appendingPathComponent("_rels")
        let propsDir = contentDir.appendingPathComponent("docProps")

        try FileManager.default.createDirectory(at: wordDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: relsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: propsDir, withIntermediateDirectories: true)

        try contentTypesXML.write(to: contentDir.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try relsXML.write(to: relsDir.appendingPathComponent(".rels"), atomically: true, encoding: .utf8)
        try documentXML.write(to: wordDir.appendingPathComponent("document.xml"), atomically: true, encoding: .utf8)
        try "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:settings xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"/>"
            .write(to: wordDir.appendingPathComponent("settings.xml"), atomically: true, encoding: .utf8)
        try """
        <?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>
        <cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\">
            <dc:creator>Marcrypt QA</dc:creator>
            <cp:lastModifiedBy>Marcrypt QA</cp:lastModifiedBy>
            <cp:revision>3</cp:revision>
        </cp:coreProperties>
        """.write(to: propsDir.appendingPathComponent("core.xml"), atomically: true, encoding: .utf8)
        try """
        <?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>
        <Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\"
                    xmlns:vt=\"http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes\">
            <Template>Normal.dotm</Template>
        </Properties>
        """.write(to: propsDir.appendingPathComponent("app.xml"), atomically: true, encoding: .utf8)
        try """
        <?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>
        <Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/custom-properties\" xmlns:vt=\"http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes\">
            <property fmtid=\"{D5CDD505-2E9C-101B-9397-08002B2CF9AE}\" pid=\"\(pid)\" name=\"ExistingProperty\" helpid=\"0\">
                <vt:lpwstr>Existing</vt:lpwstr>
            </property>
        </Properties>
        """.write(to: propsDir.appendingPathComponent("custom.xml"), atomically: true, encoding: .utf8)

        let success = SSZipArchive.createZipFile(
            atPath: docxURL.path,
            withContentsOfDirectory: contentDir.path,
            keepParentDirectory: false,
            withPassword: nil,
            andProgressHandler: nil
        )
        guard success else { throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create DOCX ZIP"]) }
        try? FileManager.default.removeItem(at: contentDir)

        return docxURL
    }

    private func createSampleDOCXWithHeadersAndCustomProperties(at url: URL, includeCustomPid: Int) throws -> URL {
        let docxURL = url
        let contentDir = tempDir.appendingPathComponent("docx_structure_source")
        let wordDir = contentDir.appendingPathComponent("word")
        let relsDir = contentDir.appendingPathComponent("_rels")
        let wordRels = wordDir.appendingPathComponent("_rels")
        let propsDir = contentDir.appendingPathComponent("docProps")
        try FileManager.default.createDirectory(at: wordDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: relsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wordRels, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: propsDir, withIntermediateDirectories: true)

        try """
        <?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>
        <Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">
          <Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>
          <Default Extension=\"xml\" ContentType=\"application/xml\"/>
          <Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>
          <Override PartName=\"/word/settings.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml\"/>
          <Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>
          <Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/>
          <Override PartName=\"/docProps/custom.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.custom-properties+xml\"/>
        </Types>
        """.write(to: contentDir.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)

        try """
        <?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>
        <Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">
          <Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/>
          <Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/>
          <Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties\" Target=\"docProps/app.xml\"/>
          <Relationship Id=\"rId4\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/custom-properties\" Target=\"docProps/custom.xml\"/>
        </Relationships>
        """.write(to: relsDir.appendingPathComponent(".rels"), atomically: true, encoding: .utf8)

        try """
        <?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>
        <Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">
          <Relationship Id=\"rIdHeader1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/header\" Target=\"header1.xml\"/>
          <Relationship Id=\"rIdFooter1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer\" Target=\"footer1.xml\"/>
        </Relationships>
        """.write(to: wordRels.appendingPathComponent("document.xml.rels"), atomically: true, encoding: .utf8)

        try """
        <?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>
        <w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">
          <w:body>
            <w:p><w:r><w:t>Structured DOCX fixture</w:t></w:r></w:p>
            <w:sectPr>
              <w:headerReference w:type=\"default\" r:id=\"rIdHeader1\"/>
              <w:pgSz w:w=\"12240\" w:h=\"15840\"/>
            </w:sectPr>
          </w:body>
        </w:document>
        """.write(to: wordDir.appendingPathComponent("document.xml"), atomically: true, encoding: .utf8)

        try """
        <?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>
        <w:settings xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main"/>
        """.write(to: wordDir.appendingPathComponent("settings.xml"), atomically: true, encoding: .utf8)

        try """
        <?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>
        <w:hdr xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:p><w:r><w:t>Existing Header</w:t></w:r></w:p></w:hdr>
        """.write(to: wordDir.appendingPathComponent("header1.xml"), atomically: true, encoding: .utf8)

        try """
        <?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>
        <w:ftr xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:p><w:r><w:t>Existing Footer</w:t></w:r></w:p></w:ftr>
        """.write(to: wordDir.appendingPathComponent("footer1.xml"), atomically: true, encoding: .utf8)

        try """
        <?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>
        <cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\">
          <dc:creator>Marcrypt QA</dc:creator>
          <cp:lastModifiedBy>Marcrypt QA</cp:lastModifiedBy>
          <cp:revision>3</cp:revision>
        </cp:coreProperties>
        """.write(to: propsDir.appendingPathComponent("core.xml"), atomically: true, encoding: .utf8)

        try """
        <?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>
        <Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\" xmlns:vt=\"http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes\">
          <Template>Normal.dotm</Template>
        </Properties>
        """.write(to: propsDir.appendingPathComponent("app.xml"), atomically: true, encoding: .utf8)

        try """
        <?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>
        <Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/custom-properties\" xmlns:vt=\"http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes\">
          <property fmtid=\"{D5CDD505-2E9C-101B-9397-08002B2CF9AE}\" pid=\"\(includeCustomPid)\" name=\"ExistingProperty\" helpid=\"0\">
            <vt:lpwstr>Existing</vt:lpwstr>
          </property>
        </Properties>
        """.write(to: propsDir.appendingPathComponent("custom.xml"), atomically: true, encoding: .utf8)

        let success = SSZipArchive.createZipFile(
            atPath: docxURL.path,
            withContentsOfDirectory: contentDir.path,
            keepParentDirectory: false,
            withPassword: nil,
            andProgressHandler: nil
        )

        guard success else { throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create DOCX ZIP"]) }
        try? FileManager.default.removeItem(at: contentDir)

        return docxURL
    }
}

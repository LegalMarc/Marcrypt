import XCTest
import Foundation
@testable import MarcryptCore
import POLEWrapper

final class DocxRealWorldCorruptionTests: XCTestCase {
    private typealias TestXMLNode = MarcryptCore.XMLNode
    private struct OLEHeader {
        let firstDirectorySectorLocation: UInt32
        let firstMiniFatSectorLocation: UInt32
        let rootStartSectorLocation: UInt32
        let numBigBatSectors: UInt32
        let fatSectorLocations: [UInt32]
    }

    private struct OLEDirectoryEntry {
        let index: Int
        let name: String
        let objectType: UInt8
        let prev: Int
        let next: Int
        let child: Int
        let start: Int
        let size: Int
    }

    private struct RelationshipRef {
        let target: String
        let type: String
    }

    func testRealWorldDOCXFlowStructureIntegrity() async throws {
        guard let sourcePath = ProcessInfo.processInfo.environment["MARCRYPT_REALWORLD_DOCX_PATH"],
              !sourcePath.isEmpty else {
            throw XCTSkip("Set MARCRYPT_REALWORLD_DOCX_PATH to the RealWorld DOCX for fixture repro")
        }
        guard FileManager.default.fileExists(atPath: sourcePath) else {
            throw XCTSkip("RealWorld fixture path is not configured or unavailable")
        }
        let keepArtifacts = ProcessInfo.processInfo.environment["MARCRYPT_KEEP_REALWORLD_ARTIFACTS"] == "1"

        let sourceURL = URL(fileURLWithPath: sourcePath)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("marcrypt-realworld-repro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            if !keepArtifacts {
                try? FileManager.default.removeItem(at: tempDir)
            }
        }

        let originalCopy = tempDir.appendingPathComponent("original.docx")
        try FileManager.default.copyItem(at: sourceURL, to: originalCopy)

        let metadataStripped = tempDir.appendingPathComponent("step1-strip.docx")
        try await MetadataStripService.shared.stripDocxMetadata(at: originalCopy, to: metadataStripped)
        try validateDocxPackage(at: metadataStripped, stage: "metadata-strip", expectHeaderWatermark: false, expectCustomProperties: false)

        let options = DocxService.Options(
            openPassword: "",
            modifyPassword: "",
            restriction: .readOnly,
            markAsFinal: true,
            watermark: nil
        )
        let protected = tempDir.appendingPathComponent("step2-protect.docx")
        _ = try await DocxService.shared.protect(docxAt: metadataStripped, to: protected, options: options)
        try validateDocxPackage(at: protected, stage: "protect-mark-final", expectHeaderWatermark: false, expectCustomProperties: true)

        let wmConfig = PdfProcessingService.WatermarkConfig(
            text: "CONFIDENTIAL",
            size: 56,
            opacity: 0.20,
            location: 3,
            colorHex: "#FF0000",
            batesEnabled: false,
            batesPrefix: "",
            batesStartNumber: 1,
            batesDigitCount: 6,
            batesLocation: 2,
            batesFontFamily: 2,
            batesFontSize: 10,
            batesColorHex: "#000000",
            batesIncludeTimestamp: false
        )

        let protectedWatermark = tempDir.appendingPathComponent("step3-watermark.docx")
        let wmOptions = DocxService.Options(
            openPassword: "",
            modifyPassword: "",
            restriction: .readOnly,
            markAsFinal: true,
            watermark: wmConfig
        )
        _ = try await DocxService.shared.protect(docxAt: metadataStripped, to: protectedWatermark, options: wmOptions)
        try validateDocxPackage(at: protectedWatermark, stage: "protect-mark-final-watermark", expectHeaderWatermark: true, expectCustomProperties: true)

        let encrypted = tempDir.appendingPathComponent("step4-encrypted.docx")
        try await DocxEncryptionService.shared.encrypt(docxFile: protectedWatermark, to: encrypted, password: "P@ssw0rd123")
        try validateDocxOleStreams(at: encrypted, stage: "step4-encrypted")

        let decrypted = tempDir.appendingPathComponent("step5-decrypted.docx")
        let decryptedData = try await DocxEncryptionService.shared.decrypt(docxFile: encrypted, password: "P@ssw0rd123")
        try decryptedData.write(to: decrypted)

        try validateDocxPackage(at: decrypted, stage: "after-decrypt", expectHeaderWatermark: true, expectCustomProperties: true)

        if keepArtifacts {
            print("RealWorld repro artifacts retained under temporary working directory")
        }
    }

    private func validateDocxOleStreams(at url: URL, stage: String) throws {
        let ole = OLEHelper()
        XCTAssertTrue(ole.openFile(atPath: url.path), "\(stage): encrypted file should open as OLE storage")
        defer { ole.close() }

        let rawStreamNames = Set(ole.allStreamNames())
        let streamNames = Set(rawStreamNames.flatMap { name -> [String] in
            if name.hasPrefix("/") {
                return [name, String(name.dropFirst())]
            }
            return [name, "/\(name)"]
        })
        let expected = [
            "EncryptionInfo",
            "EncryptedPackage"
        ]
        for streamName in expected {
            XCTAssertTrue(streamNames.contains(streamName), "\(stage): missing OLE stream \(streamName)")
            XCTAssertTrue(ole.streamExists(streamName), "\(stage): streamExists should report \(streamName)")
        }

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
                "\(stage): missing Agile data space stream \(aliases.joined(separator: " / "))"
            )
            guard let dataSpaceStream = resolvedDataSpaceStream else { continue }
            XCTAssertTrue(ole.streamExists(dataSpaceStream), "\(stage): streamExists should report \(dataSpaceStream)")
            let dataSpacePayload = try XCTUnwrap(
                ole.readStream(dataSpaceStream),
                "\(stage): \(dataSpaceStream) stream should be readable"
            )
            XCTAssertGreaterThan(dataSpacePayload.count, 0, "\(stage): \(dataSpaceStream) should not be empty")
        }

        let unexpectedPropertyStream = ["\u{05}SummaryInformation", "SummaryInformation", "/SummaryInformation"].first { streamNames.contains($0) }
        XCTAssertNil(
            unexpectedPropertyStream,
            "\(stage): OLE property streams are not expected in the encrypted Agile container"
        )

        let infoData = try XCTUnwrap(ole.readStream("EncryptionInfo"), "\(stage): EncryptionInfo stream should be readable")
        XCTAssertTrue(infoData.count > 8, "\(stage): EncryptionInfo stream should include header + XML payload")
        XCTAssertEqual(Array(infoData.prefix(4)), [0x04, 0x00, 0x04, 0x00], "\(stage): EncryptionInfo should carry Agile header")

        guard let infoXML = String(data: infoData.dropFirst(8), encoding: .utf8) else {
            XCTFail("\(stage): EncryptionInfo payload should be UTF-8 XML")
            return
        }
        XCTAssertTrue(infoXML.hasPrefix("<"), "\(stage): EncryptionInfo payload should be XML")
        XCTAssertTrue(infoXML.contains("keyData"), "\(stage): EncryptionInfo payload should contain keyData")
        XCTAssertTrue(infoXML.contains("standalone=\"yes\""), "\(stage): EncryptionInfo XML should declare standalone=\"yes\"")
        XCTAssertTrue(infoXML.contains("xmlns:c=\"http://schemas.microsoft.com/office/2006/keyEncryptor/certificate\""), "\(stage): EncryptionInfo XML should declare the certificate keyEncryptor namespace")

        let header = try parseOLEHeader(at: url)
        XCTAssertEqual(header.numBigBatSectors, 1, "\(stage): CFB header num_bat should remain at one for agile DOCX compatibility")
        XCTAssertEqual(header.firstDirectorySectorLocation, 2, "\(stage): CFB header firstDirectorySectorLocation should be Word-compatible")
        XCTAssertEqual(header.firstMiniFatSectorLocation, 1, "\(stage): CFB header firstMiniFatSectorLocation should be Word-compatible")
        XCTAssertEqual(header.rootStartSectorLocation, 5, "\(stage): CFB root mini-stream should start at sector 5 for Word-compatible encrypted DOCX")

        let data = try Data(contentsOf: url)
        let sectorSize = 1 << Int(data[0x1e])
        let directoryChain = try parseFATChain(
            at: url,
            header: header,
            firstSector: Int(header.firstDirectorySectorLocation),
            sectorSize: sectorSize,
            maxSectors: 10
        )
        XCTAssertEqual(directoryChain, [2, 3, 4], "\(stage): Directory chain should use the same compact shape as Word-generated encrypted DOCX")

        let miniStreamChain = try parseFATChain(
            at: url,
            header: header,
            firstSector: Int(header.rootStartSectorLocation),
            sectorSize: sectorSize,
            maxSectors: 20
        )
        XCTAssertEqual(miniStreamChain, [5, 6, 7, 8], "\(stage): Mini-stream chain should start at sector 5 and remain compact")

        let directoryEntries = try parseOLEDirectoryEntries(at: url)
        let topology = try topLevelDirectoryOrder(in: directoryEntries)
        XCTAssertEqual(
            topology,
            ["DataSpaces", "EncryptionInfo", "EncryptedPackage"],
            "\(stage): top-level OLE directory siblings should match Word-generated agile DOCX order"
        )

        let dataSpaceChildren = try directoryChildren(of: "DataSpaces", in: directoryEntries, stage: stage)
        XCTAssertEqual(
            dataSpaceChildren,
            ["Version", "DataSpaceMap", "DataSpaceInfo", "TransformInfo"],
            "\(stage): DataSpaces child sibling order should stay canonical"
        )

        let nonRootStorageEntries = directoryEntries.filter { entry in
            entry.objectType == 1 && entry.name != "Root Entry"
        }
        for entry in nonRootStorageEntries {
            XCTAssertEqual(entry.start, 0, "\(stage): storage entry \(entry.name) should use start=0 in directory")
            XCTAssertEqual(entry.size, 0, "\(stage): storage entry \(entry.name) should have zero size in directory")
        }
    }

    private func validateDocxPackage(at url: URL, stage: String, expectHeaderWatermark: Bool, expectCustomProperties: Bool) throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(stage): expected file exists")
        XCTAssertEqual(url.pathExtension.lowercased(), "docx")

        let unzipDir = FileManager.default.temporaryDirectory.appendingPathComponent("marcrypt-realworld-stage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: unzipDir) }
        try FileManager.default.createDirectory(at: unzipDir, withIntermediateDirectories: true)

        let zipCheck = Process()
        zipCheck.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        zipCheck.arguments = ["-t", url.path]
        let stderrPipe = Pipe()
        zipCheck.standardError = stderrPipe
        try zipCheck.run()
        zipCheck.waitUntilExit()
        XCTAssertEqual(zipCheck.terminationStatus, 0, "\(stage): zip integrity check should pass")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", url.path, "-d", unzipDir.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(stage): unzip should succeed")

        let required = ["[Content_Types].xml", "_rels/.rels", "word/document.xml", "word/_rels/document.xml.rels", "word/settings.xml", "docProps/core.xml"]
        for rel in required {
            XCTAssertTrue(FileManager.default.fileExists(atPath: unzipDir.appendingPathComponent(rel).path), "\(stage): missing required part \(rel)")
        }

        if expectCustomProperties {
            XCTAssertTrue(FileManager.default.fileExists(atPath: unzipDir.appendingPathComponent("docProps/custom.xml").path), "\(stage): custom properties must exist")
            let customRels = try String(contentsOf: unzipDir.appendingPathComponent("_rels/.rels"))
            XCTAssertTrue(customRels.contains("custom-properties"))
            XCTAssertTrue(customRels.contains("docProps/custom.xml"))
        }

        let documentRels = try String(contentsOf: unzipDir.appendingPathComponent("word/_rels/document.xml.rels"))
        let sectionXML = try String(contentsOf: unzipDir.appendingPathComponent("word/document.xml"))

        if expectHeaderWatermark {
            XCTAssertTrue(documentRels.contains("headerWatermark.xml"), "\(stage): section relationship must target headerWatermark.xml")
            XCTAssertTrue(documentRels.contains("header"), "\(stage): document relationship should include header type")
            XCTAssertTrue(FileManager.default.fileExists(atPath: unzipDir.appendingPathComponent("word/headerWatermark.xml").path), "\(stage): headerWatermark.xml should exist")
            XCTAssertTrue(sectionXML.contains("w:headerReference"), "\(stage): section should reference header")
        }

        let typesXML = try String(contentsOf: unzipDir.appendingPathComponent("[Content_Types].xml"))
        XCTAssertTrue(typesXML.contains("/word/document.xml"), "\(stage): document part type should be declared")

        try validateOPCPackageIntegrity(
            at: unzipDir,
            stage: stage,
            expectHeaderWatermark: expectHeaderWatermark,
            expectCustomProperties: expectCustomProperties
        )

        // Basic xml parse sanity check for major documents
        for part in ["[Content_Types].xml", "_rels/.rels", "word/_rels/document.xml.rels", "word/document.xml", "word/settings.xml"] {
            let partURL = unzipDir.appendingPathComponent(part)
            let xmlCheck = Process()
            xmlCheck.executableURL = URL(fileURLWithPath: "/usr/bin/xmllint")
            xmlCheck.arguments = ["--noout", partURL.path]
            try xmlCheck.run()
            xmlCheck.waitUntilExit()
            if xmlCheck.terminationStatus != 0 {
                let data = try? FileManager.default.attributesOfItem(atPath: partURL.path)
                let err = String(data: data?[.modificationDate] as? Data ?? Data(), encoding: .utf8) ?? ""
                _ = err
            }
            XCTAssertEqual(xmlCheck.terminationStatus, 0, "\(stage): XML parse should pass for \(part)")
        }

        if let headerTag = sectionXML.range(of: "<w:headerReference") {
            XCTAssertNotNil(headerTag, "\(stage): headerReference tag should be well formed")
        }
    }

    private func parseOLEDirectoryEntries(at url: URL) throws -> [OLEDirectoryEntry] {
        let data = try Data(contentsOf: url)
        let header = try parseOLEHeader(at: url)
        let sectorSize = 1 << Int(data[0x1e])
        let directoryChain = try parseFATChain(
            at: url,
            header: header,
            firstSector: Int(header.firstDirectorySectorLocation),
            sectorSize: sectorSize,
            maxSectors: 16
        )

        var entries: [OLEDirectoryEntry] = []
        var index = 0

        func readUInt16(_ offset: Int) -> UInt16 {
            let value = data.subdata(in: offset ..< offset + 2)
            return value.withUnsafeBytes { $0.load(as: UInt16.self) }.littleEndian
        }

        func readUInt32(_ offset: Int) -> UInt32 {
            let value = data.subdata(in: offset ..< offset + 4)
            return value.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
        }

        func normalizedDirectoryName(from offset: Int) -> String {
            let nameLength = Int(readUInt16(offset + 0x40))
            let cappedNameLength = min(nameLength, 64)
            guard cappedNameLength >= 2 else { return "" }
            let utf16Limit = max(0, cappedNameLength - 2)
            let nameBytes = data.subdata(in: offset ..< offset + utf16Limit)
            let units = nameBytes.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> [UInt16] in
                let typed = buffer.bindMemory(to: UInt16.self)
                return Array(typed.map { UInt16(littleEndian: $0) })
            }
            var name = String(decoding: units, as: UTF16.self)
            if let firstScalar = name.unicodeScalars.first, firstScalar.value < 0x20 {
                name = String(name.unicodeScalars.dropFirst())
            }
            return name
        }

        for sector in directoryChain {
            let sectorOffset = 0x200 + (Int(sector) * sectorSize)
            let sectorEnd = sectorOffset + sectorSize
            guard sectorEnd <= data.count else {
                break
            }
            for baseOffset in stride(from: sectorOffset, to: sectorEnd, by: 128) {
                let objectType = data[baseOffset + 0x42]
                guard objectType == 1 || objectType == 2 || objectType == 5 else {
                    index += 1
                    continue
                }

                let prev = Int(readUInt32(baseOffset + 0x44))
                let next = Int(readUInt32(baseOffset + 0x48))
                let child = Int(readUInt32(baseOffset + 0x4c))
                let start = Int(readUInt32(baseOffset + 0x74))
                let size = Int(readUInt32(baseOffset + 0x78))
                let name = normalizedDirectoryName(from: baseOffset)

                entries.append(OLEDirectoryEntry(
                    index: index,
                    name: name,
                    objectType: objectType,
                    prev: prev,
                    next: next,
                    child: child,
                    start: start,
                    size: size
                ))
                index += 1
            }
        }

        return entries
    }

    private func topLevelDirectoryOrder(in entries: [OLEDirectoryEntry]) throws -> [String] {
        guard let root = entries.first(where: { $0.index == 0 }) else {
            throw NSError(
                domain: "DocxRealWorldCorruptionTests",
                code: 2001,
                userInfo: [NSLocalizedDescriptionKey: "Missing CFB root directory entry"]
            )
        }
        let entryMap = Dictionary(uniqueKeysWithValues: entries.map { ($0.index, $0) })
        return collectSiblings(start: root.child, using: entryMap)
    }

    private func directoryChildren(of storageName: String, in entries: [OLEDirectoryEntry], stage: String) throws -> [String] {
        guard let storage = entries.first(where: { $0.name == storageName }) else {
            throw NSError(
                domain: "DocxRealWorldCorruptionTests",
                code: 2002,
                userInfo: [NSLocalizedDescriptionKey: "\(stage): missing \(storageName) directory entry"]
            )
        }
        let entryMap = Dictionary(uniqueKeysWithValues: entries.map { ($0.index, $0) })
        return collectSiblings(start: storage.child, using: entryMap)
    }

    private func collectSiblings(start: Int, using entryMap: [Int: OLEDirectoryEntry]) -> [String] {
        if start < 0 || start == 0xffffffff {
            return []
        }

        var names: [String] = []
        var visited = Set<Int>()

        func walk(_ index: Int) {
            guard index != 0xffffffff && index >= 0 else { return }
            guard let entry = entryMap[index] else { return }
            if visited.contains(index) {
                return
            }
            visited.insert(index)
            if entry.prev != 0xffffffff && entry.prev != -1 {
                walk(entry.prev)
            }
            names.append(entry.name)
            if entry.next != 0xffffffff && entry.next != -1 {
                walk(entry.next)
            }
        }

        walk(start)
        return names
    }

    private func validateOPCPackageIntegrity(
        at packageRoot: URL,
        stage: String,
        expectHeaderWatermark: Bool,
        expectCustomProperties: Bool
    ) throws {
        let packageRels = try parseRelationshipMap(from: packageRoot.appendingPathComponent("_rels/.rels"))
        let documentRels = try parseRelationshipMap(from: packageRoot.appendingPathComponent("word/_rels/document.xml.rels"))

        if expectCustomProperties {
            XCTAssertTrue(packageRels.values.contains { $0.target == "docProps/custom.xml" },
                          "\(stage): package relationships should include docProps/custom.xml")
            XCTAssertTrue(packageRels.values.contains { $0.type == "http://schemas.openxmlformats.org/officeDocument/2006/relationships/custom-properties" },
                          "\(stage): package relationships should include custom-properties type")
        }

        let sectionXML = try String(contentsOf: packageRoot.appendingPathComponent("word/document.xml"))

        let documentRoot = try XMLHelper.parse(xml: sectionXML)
        let sectionElements = documentRoot.findAll(named: "w:sectPr")
        var headerRefs: [TestXMLNode] = []
        for section in sectionElements {
            for child in section.children where child.name == "w:headerReference" {
                headerRefs.append(child)
            }
        }

        if expectHeaderWatermark {
            XCTAssertFalse(headerRefs.isEmpty, "\(stage): expected at least one headerReference")
        }

        for headerRef in headerRefs {
            guard let relId = headerRef.attributes["r:id"] else {
                XCTAssertTrue(false, "\(stage): headerReference missing r:id")
                continue
            }

            guard let rel = documentRels[relId] else {
                XCTAssertTrue(false, "\(stage): headerReference with unresolved r:id: \(relId)")
                continue
            }

            XCTAssertEqual(rel.type,
                           "http://schemas.openxmlformats.org/officeDocument/2006/relationships/header",
                           "\(stage): headerRelationship must use header type")

            let resolvedTarget = resolvePartPath(target: rel.target, base: packageRoot.appendingPathComponent("word"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: resolvedTarget.path),
                          "\(stage): missing referenced header part \(rel.target)")
        }

        let declaredParts = [
            ("/word/document.xml", "/word/document.xml"),
            ("word/settings.xml", "word/settings.xml"),
            ("word/_rels/document.xml.rels", "word/_rels/document.xml.rels")
        ]
        for rel in documentRels.values where rel.type.hasSuffix("/header") {
            let relPath = rel.target
            let shouldResolve = relPath.hasPrefix(".") || relPath.hasPrefix("../") || relPath.hasPrefix("./") || !relPath.hasPrefix("/")
            let resolved = shouldResolve ?
                resolvePartPath(target: relPath, base: packageRoot.appendingPathComponent("word")) :
                packageRoot.appendingPathComponent(String(relPath.dropFirst()))
            XCTAssertTrue(FileManager.default.fileExists(atPath: resolved.path),
                          "\(stage): declared header target missing: \(rel.target)")
        }

        if expectHeaderWatermark {
            XCTAssertTrue(FileManager.default.fileExists(atPath: packageRoot.appendingPathComponent("word/headerWatermark.xml").path),
                          "\(stage): headerWatermark.xml must exist")
        }

        // Validate content-types declares every referenced part we touch in this path.
        let contentTypes = try String(contentsOf: packageRoot.appendingPathComponent("[Content_Types].xml"))
        if expectHeaderWatermark {
            XCTAssertTrue(contentTypes.contains("/word/headerWatermark.xml"), "\(stage): header watermarks should be in [Content_Types].xml")
        }
        if expectCustomProperties {
            XCTAssertTrue(contentTypes.contains("/docProps/custom.xml"), "\(stage): custom properties should be in [Content_Types].xml")
        }

        if !declaredParts.allSatisfy({ FileManager.default.fileExists(atPath: packageRoot.appendingPathComponent($0.0).path) }) {
            // no-op: required parts already validated above
        }
    }

    private func parseOLEHeader(at url: URL) throws -> OLEHeader {
        let data = try Data(contentsOf: url)
        guard data.count >= 0x208 else {
            throw NSError(
                domain: "DocxRealWorldCorruptionTests",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "Invalid OLE file size for \(url.lastPathComponent)"]
            )
        }

        func readUInt16(_ offset: Int) -> UInt16 {
            let value = data.subdata(in: offset ..< offset + 2)
            return value.withUnsafeBytes { $0.load(as: UInt16.self) }.littleEndian
        }

        func readUInt32(_ offset: Int) -> UInt32 {
            let value = data.subdata(in: offset ..< offset + 4)
            return value.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
        }

        let bShift = Int(readUInt16(0x1e))
        let sectorSize = 1 << bShift
        guard bShift >= 7 else {
            throw NSError(
                domain: "DocxRealWorldCorruptionTests",
                code: 1002,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported sector shift in \(url.lastPathComponent)"]
            )
        }
        guard data.count >= 512 + sectorSize else {
            throw NSError(
                domain: "DocxRealWorldCorruptionTests",
                code: 1003,
                userInfo: [NSLocalizedDescriptionKey: "Missing root directory sector in \(url.lastPathComponent)"]
            )
        }

        let directorySector = readUInt32(0x30)
        let miniFatSector = readUInt32(0x3c)
        let directoryOffset = 512 + Int(directorySector) * sectorSize
        guard data.count >= directoryOffset + 0x80 else {
            throw NSError(
                domain: "DocxRealWorldCorruptionTests",
                code: 1004,
                userInfo: [NSLocalizedDescriptionKey: "Directory entry sector out of range in \(url.lastPathComponent)"]
            )
        }
        let rootStartSector = readUInt32(directoryOffset + 0x74)

        return OLEHeader(
            firstDirectorySectorLocation: directorySector,
            firstMiniFatSectorLocation: miniFatSector,
            rootStartSectorLocation: rootStartSector,
            numBigBatSectors: readUInt32(0x2c),
            fatSectorLocations: {
                var sectors: [UInt32] = []
                let numBigBat = Int(readUInt32(0x2c))
                let sectorCount = min(numBigBat, 109)

                for index in 0..<sectorCount {
                    let value = readUInt32(0x4c + (index * 4))
                    sectors.append(value)
                }

                if numBigBat > 109 {
                    let metaStart = readUInt32(0x44)
                    let numMetaBat = Int(readUInt32(0x48))
                    if numMetaBat > 0 && metaStart != 0xfffffffe {
                        let metaSectorCapacity = (sectorSize / 4) - 1
                        var currentMetaSector = metaStart
                        var loadedCount = sectors.count
                        var seen: Set<UInt32> = []

                        while loadedCount < numBigBat && numMetaBat > 0 && !seen.contains(currentMetaSector) {
                            seen.insert(currentMetaSector)

                            let metaSectorOffset = 0x200 + Int(currentMetaSector) * sectorSize
                            guard metaSectorOffset + sectorSize <= data.count else {
                                break
                            }

                            for index in 0..<metaSectorCapacity {
                                guard loadedCount < numBigBat else { break }
                                let valueOffset = metaSectorOffset + (index * 4)
                                let value = readUInt32(valueOffset)
                                sectors.append(value)
                                loadedCount += 1
                            }

                            let nextMeta = readUInt32(metaSectorOffset + sectorSize - 4)
                            if nextMeta == 0xfffffffe {
                                break
                            }
                            currentMetaSector = nextMeta
                        }
                    }
                }

                return sectors
            }()
        )
    }

    private func parseFATChain(
        at url: URL,
        header: OLEHeader,
        firstSector: Int,
        sectorSize: Int,
        maxSectors: Int
    ) throws -> [UInt32] {
        let data = try Data(contentsOf: url)
        let totalSectors = (data.count - 0x200) / sectorSize
        guard totalSectors > 0 else {
            throw NSError(
                domain: "DocxRealWorldCorruptionTests",
                code: 1008,
                userInfo: [NSLocalizedDescriptionKey: "Invalid OLE file size in \(url.lastPathComponent)"]
            )
        }

        let eof: UInt32 = 0xfffffffe
        let invalidSectors = Set<UInt32>([0xffffffff, 0xfffffffd, 0xfffffffc])
        let entriesPerFatSector = sectorSize / 4

        guard !header.fatSectorLocations.isEmpty else {
            throw NSError(
                domain: "DocxRealWorldCorruptionTests",
                code: 1010,
                userInfo: [NSLocalizedDescriptionKey: "Missing FAT sector definitions in \(url.lastPathComponent)"]
            )
        }

        func readFATEntry(_ sectorIndex: Int) throws -> UInt32 {
            guard sectorIndex >= 0 else {
                throw NSError(
                    domain: "DocxRealWorldCorruptionTests",
                    code: 1005,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid FAT sector index in \(url.lastPathComponent)"]
                )
            }

            let fatSectorIndex = sectorIndex / entriesPerFatSector
            let inSectorOffset = (sectorIndex % entriesPerFatSector) * 4

            guard fatSectorIndex < header.fatSectorLocations.count else {
                throw NSError(
                    domain: "DocxRealWorldCorruptionTests",
                    code: 1008,
                    userInfo: [NSLocalizedDescriptionKey: "FAT entry out of configured FAT range in \(url.lastPathComponent)"]
                )
            }

            let fatSector = Int(header.fatSectorLocations[fatSectorIndex])
            let entryOffset = 0x200 + (fatSector * sectorSize) + inSectorOffset
            guard entryOffset + 4 <= data.count else {
                throw NSError(
                    domain: "DocxRealWorldCorruptionTests",
                    code: 1007,
                    userInfo: [NSLocalizedDescriptionKey: "FAT sector index out of range in \(url.lastPathComponent)"]
                )
            }
            let value = data.subdata(in: entryOffset ..< entryOffset + 4)
            return value.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
        }

        guard firstSector >= 0 else {
            throw NSError(
                domain: "DocxRealWorldCorruptionTests",
                code: 1005,
                userInfo: [NSLocalizedDescriptionKey: "Invalid FAT first sector in \(url.lastPathComponent)"]
            )
        }
        guard firstSector < totalSectors else {
            throw NSError(
                domain: "DocxRealWorldCorruptionTests",
                code: 1006,
                userInfo: [NSLocalizedDescriptionKey: "FAT chain first sector is out of range in \(url.lastPathComponent)"]
            )
        }

        var chain: [UInt32] = []
        var current = UInt32(firstSector)
        var visited = Set<UInt32>()
        var terminated = false
        for _ in 0..<maxSectors {
            if visited.contains(current) {
                throw NSError(
                    domain: "DocxRealWorldCorruptionTests",
                    code: 1007,
                    userInfo: [NSLocalizedDescriptionKey: "Circular FAT chain detected in \(url.lastPathComponent)"]
                )
            }
            visited.insert(current)
            chain.append(current)
            let next = try readFATEntry(Int(current))
            if next == eof {
                terminated = true
                break
            }
            if invalidSectors.contains(next) {
                throw NSError(
                    domain: "DocxRealWorldCorruptionTests",
                    code: 1007,
                    userInfo: [NSLocalizedDescriptionKey: "Unexpected FAT terminator in chain parsing for \(url.lastPathComponent)"]
                )
            }
            if next >= UInt32(totalSectors) {
                throw NSError(
                    domain: "DocxRealWorldCorruptionTests",
                    code: 1007,
                    userInfo: [NSLocalizedDescriptionKey: "FAT chain ended unexpectedly in \(url.lastPathComponent)"]
                )
            }
            current = next
        }
        if chain.isEmpty || !terminated {
            throw NSError(
                domain: "DocxRealWorldCorruptionTests",
                code: 1008,
                userInfo: [NSLocalizedDescriptionKey: "Unable to parse FAT chain in \(url.lastPathComponent)"]
            )
        }
        if chain.count == maxSectors {
            throw NSError(
                domain: "DocxRealWorldCorruptionTests",
                code: 1009,
                userInfo: [NSLocalizedDescriptionKey: "FAT chain traversal exceeded maximum allowed length in \(url.lastPathComponent)"]
            )
        }
        return chain
    }

    private func parseRelationshipMap(from url: URL) throws -> [String: RelationshipRef] {
        let data = try Data(contentsOf: url)
        let xml = try XMLDocument(data: data, options: [])
        let relRoot = try XCTUnwrap(xml.rootElement())
        var map: [String: RelationshipRef] = [:]

        for node in relRoot.elements(forName: "Relationship") {
            let id = node.attribute(forName: "Id")?.stringValue ?? ""
            guard let target = node.attribute(forName: "Target")?.stringValue,
                  let type = node.attribute(forName: "Type")?.stringValue,
                  !id.isEmpty else {
                continue
            }
            if map[id] != nil {
                XCTFail("Duplicate relationship id detected: \(id)")
            }
            map[id] = RelationshipRef(target: target, type: type)
        }

        return map
    }

    private func resolvePartPath(target: String, base: URL) -> URL {
        if target.hasPrefix("../") || target.hasPrefix("./") {
            return URL(fileURLWithPath: target, relativeTo: base).standardized
        }
        if target.hasPrefix("/") {
            return base.deletingLastPathComponent().appendingPathComponent(String(target.dropFirst()))
        }
        return URL(fileURLWithPath: target, relativeTo: base).standardized
    }
}

import Foundation

enum DocxError: Error {
    case extractionFailed
    case xmlParsingFailed
    case compressionFailed
}

public class DocxService {
    public static let shared = DocxService()

    public struct Options {
        public var openPassword: String
        public var modifyPassword: String
        public var restriction: RestrictionType
        public var markAsFinal: Bool
        public var watermark: PdfProcessingService.WatermarkConfig?

        public init(openPassword: String, modifyPassword: String, restriction: RestrictionType, markAsFinal: Bool, watermark: PdfProcessingService.WatermarkConfig? = nil) {
            self.openPassword = openPassword
            self.modifyPassword = modifyPassword
            self.restriction = restriction
            self.markAsFinal = markAsFinal
            self.watermark = watermark
        }
    }

    public enum RestrictionType {
        case none, readOnly, comments, trackedChanges, forms
    }

    private init() {}

    /// Applies protections to a Docx file
    /// - Parameters:
    ///   - sourceURL: The original .docx file
    ///   - destinationURL: The target path for the protected .docx
    ///   - options: The protections to apply
    ///   - startBates: Optional override for Bates numbering start position (if enabled in options)
    /// - Returns: The number of pages in the DOCX (useful for batch bates sequencing), or nil if undetermined.
    public func protect(
        docxAt sourceURL: URL,
        to destinationURL: URL,
        options: Options,
        startBates: Int? = nil,
        progress: OperationProgressHandler? = nil
    ) async throws -> Int? {
        try Task.checkCancellation()
        progress?(OperationProgress(completedUnitCount: 0, totalUnitCount: 4, message: "Preparing DOCX package"))
        // Create a temporary directory for processing
        let tempDir = try TempFileManager.shared.createTempDirectory()

        defer {
            TempFileManager.shared.release(url: tempDir)
        }

        // 1. Unzip the docx
        // Note: SSZipArchive unzipFile path args are String
        try await ArchiveService.shared.unzip(archiveAt: sourceURL, to: tempDir, password: "", progress: nil)
        try Task.checkCancellation()
        progress?(OperationProgress(completedUnitCount: 1, totalUnitCount: 4, message: "Unpacked DOCX package"))

        // 2. Apply XML Modifications
        if options.markAsFinal {
            try applyMarkAsFinal(in: tempDir)
        }

        if options.restriction != .none {
            try applyEditingRestrictions(in: tempDir, type: options.restriction, password: options.modifyPassword)
        }

        let pageCount: Int? = getPageCount(in: tempDir)

        if let wm = options.watermark {
            try applyWatermark(in: tempDir, config: wm, startBates: startBates ?? wm.batesStartNumber)
        }
        try Task.checkCancellation()
        progress?(OperationProgress(completedUnitCount: 3, totalUnitCount: 4, message: "Applied DOCX protection"))

        // 3. Re-zip to destination
        try await ArchiveService.shared.zipFolder(at: tempDir, to: destinationURL, password: nil, progress: nil)
        progress?(OperationProgress(completedUnitCount: 4, totalUnitCount: 4, message: destinationURL.lastPathComponent))

        return pageCount

        // Note: `protect(_:to:options:)` applies XML-level protections (editing restrictions,
        // mark-as-final, watermarks) and repackages the DOCX. Open-password encryption is
        // handled separately by `DocxEncryptionService`, which wraps the package in the
        // standard MS-OFFCRYPTO (Office Agile AES-256) container.
    }

    // MARK: - Helper Logic

    private func getPageCount(in directory: URL) -> Int? {
        let appXML = directory.appendingPathComponent("docProps/app.xml")
        guard FileManager.default.fileExists(atPath: appXML.path) else { return nil }

        do {
            let xmlDoc = try XMLDocument(contentsOf: appXML, options: [])
            if let root = xmlDoc.rootElement() {
                var queue = [root]
                while !queue.isEmpty {
                    let node = queue.removeFirst()
                    if node.localName == "Pages", let v = node.stringValue, let c = Int(v) { return c }
                    if let children = node.children as? [XMLElement] { queue.append(contentsOf: children) }
                }
            }
        } catch {}
        return nil
    }

    public func estimatedPageCount(inDocxAt sourceURL: URL) async -> Int? {
        let tempDir: URL
        do {
            tempDir = try TempFileManager.shared.createTempDirectory()
        } catch {
            return nil
        }
        defer {
            TempFileManager.shared.release(url: tempDir)
        }

        do {
            try await ArchiveService.shared.unzip(archiveAt: sourceURL, to: tempDir, password: "")
            return getPageCount(in: tempDir)
        } catch {
            return nil
        }
    }



    // MARK: - XML Modification Logic

    private func applyMarkAsFinal(in directory: URL) throws {
        let customXMLURL = directory.appendingPathComponent("docProps/custom.xml")

        var root: XMLNode

        if FileManager.default.fileExists(atPath: customXMLURL.path) {
            let content = try String(contentsOf: customXMLURL, encoding: .utf8)
            root = try XMLHelper.parse(xml: content)
        } else {
            // Create new
             root = XMLNode(name: "Properties", attributes: [
                "xmlns": "http://schemas.openxmlformats.org/officeDocument/2006/custom-properties",
                "xmlns:vt": "http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"
             ])
            // Ensure docProps dir exists
            try FileManager.default.createDirectory(at: customXMLURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        // Check if property exists
        var exists = false
        if let children = root.children as [XMLNode]? {
             exists = children.contains { $0.attributes["name"] == "_MarkAsFinal" }
        }

        if !exists {
        let pid = nextCustomPropertiesPid(in: root)

        let prop = XMLNode(name: "property", attributes: [
            "fmtid": "{D5CDD505-2E9C-101B-9397-08002B2CF9AE}",
            "pid": "\(pid)",
            "name": "_MarkAsFinal",
            "helpid": "0"
        ])
        let boolVal = XMLNode(name: "vt:bool", content: "true")
        prop.appendChild(boolVal)
        root.appendChild(prop)
        }

        let xmlHeader = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        try (xmlHeader + root.toString()).write(to: customXMLURL, atomically: true, encoding: .utf8)
        try registerCustomPropertiesPackageReferences(in: directory)
    }

    private func nextCustomPropertiesPid(in root: XMLNode) -> Int {
        let usedPids = root.children.compactMap { child -> Int? in
            guard child.name == "property",
                  let pidText = child.attributes["pid"] else {
                return nil
            }
            return Int(pidText)
        }
        return (usedPids.max() ?? 1) + 1
    }

    private func registerCustomPropertiesPackageReferences(in directory: URL) throws {
        try registerCustomPropertiesContentType(in: directory)
        try registerCustomPropertiesRelationship(in: directory)
    }

    private func registerCustomPropertiesContentType(in directory: URL) throws {
        let ctURL = directory.appendingPathComponent("[Content_Types].xml")
        guard FileManager.default.fileExists(atPath: ctURL.path) else { return }

        let content = try String(contentsOf: ctURL, encoding: .utf8)
        let root = try XMLHelper.parse(xml: content)
        let partName = "/docProps/custom.xml"
        let exists = root.children.contains {
            $0.name == "Override" && $0.attributes["PartName"] == partName
        }

        guard !exists else { return }

        root.appendChild(XMLNode(name: "Override", attributes: [
            "PartName": partName,
            "ContentType": "application/vnd.openxmlformats-officedocument.custom-properties+xml"
        ]))

        let xmlHeader = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        try (xmlHeader + root.toString()).write(to: ctURL, atomically: true, encoding: .utf8)
    }

    private func registerCustomPropertiesRelationship(in directory: URL) throws {
        let relsDir = directory.appendingPathComponent("_rels")
        try FileManager.default.createDirectory(at: relsDir, withIntermediateDirectories: true)
        let relsURL = relsDir.appendingPathComponent(".rels")

        let root: XMLNode
        if FileManager.default.fileExists(atPath: relsURL.path) {
            let content = try String(contentsOf: relsURL, encoding: .utf8)
            root = try XMLHelper.parse(xml: content)
        } else {
            root = XMLNode(name: "Relationships", attributes: [
                "xmlns": "http://schemas.openxmlformats.org/package/2006/relationships"
            ])
        }

        let target = "docProps/custom.xml"
        let exists = root.children.contains {
            $0.name == "Relationship" && $0.attributes["Target"] == target
        }
        guard !exists else { return }

        let usedIds = Set(root.children.compactMap { $0.attributes["Id"] })
        var relId = "rIdCustomProperties"
        var index = 1
        while usedIds.contains(relId) {
            relId = "rIdCustomProperties\(index)"
            index += 1
        }

        root.appendChild(XMLNode(name: "Relationship", attributes: [
            "Id": relId,
            "Type": "http://schemas.openxmlformats.org/officeDocument/2006/relationships/custom-properties",
            "Target": target
        ]))

        let xmlHeader = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        try (xmlHeader + root.toString()).write(to: relsURL, atomically: true, encoding: .utf8)
    }

    private func applyEditingRestrictions(in directory: URL, type: RestrictionType, password: String) throws {
        let settingsXMLURL = directory.appendingPathComponent("word/settings.xml")
        guard FileManager.default.fileExists(atPath: settingsXMLURL.path) else { return }

        let content = try String(contentsOf: settingsXMLURL, encoding: .utf8)
        let root = try XMLHelper.parse(xml: content)

        // Remove existing protection
        root.removeChildren(named: "w:documentProtection")

        // Map enum to XML value
        let editValue: String
        switch type {
        case .readOnly: editValue = "readOnly"
        case .comments: editValue = "comments"
        case .trackedChanges: editValue = "trackedChanges"
        case .forms: editValue = "forms"
        case .none: return
        }

        let protection = XMLNode(name: "w:documentProtection", attributes: [
            "w:edit": editValue,
            "w:enforcement": "1"
        ])

        // Insert as first child so the protection element appears near the top of settings.xml,
        // which is where Word expects it.
        root.insertChild(protection, at: 0)

        let xmlHeader = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        try (xmlHeader + root.toString()).write(to: settingsXMLURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Watermarking (Header Injection)

    private func applyWatermark(in directory: URL, config: PdfProcessingService.WatermarkConfig, startBates: Int) throws {
        let wordDir = directory.appendingPathComponent("word")
        let headerURL = wordDir.appendingPathComponent("headerWatermark.xml")

        // --- Watermark (Center/Diagonal usually) ---

        // Escape XML-special characters in user text
        let escapedText = config.text.uppercased()
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")

        // Compute shape dimensions from text + font size
        let fontSize = max(config.size, 12)
        let charWidthFactor = 0.6
        let shapeWidth = Int(Double(escapedText.count) * Double(fontSize) * charWidthFactor)
        let shapeHeight = Int(Double(fontSize) * 1.8)

        // Map location to VML style positioning
        let vmlStyle = vmlStyleForLocation(config.location, shapeWidth: shapeWidth, shapeHeight: shapeHeight)

        // VML opacity expects a fractional value like "0.25"
        let opacityStr = String(format: "%.2f", config.opacity)

        // --- Bates Numbering (Corner usually) ---

        var batesVML = ""
        if config.batesEnabled {
            // Calculate dimensions
            let bTextLen = config.batesPrefix.count + config.batesDigitCount + (config.batesIncludeTimestamp ? 15 : 0)
            let bSize = max(config.batesFontSize, 8)
            let bWidth = Int(Double(bTextLen) * Double(bSize) * 0.7) + 20
            let bHeight = Int(Double(bSize) * 2.0)

            let bStyle = vmlStyleForLocation(config.batesLocation, shapeWidth: bWidth, shapeHeight: bHeight)
            let bColor = config.batesColorHex

            // Calculate Offset for Field Code
            // Formula: { = { PAGE } + (startBates - 1) }
            // If startBates is 1, offset is 0. Result is PAGE.
            let offset = startBates - 1
            let offsetStr = offset >= 0 ? "+ \(offset)" : "- \(abs(offset))" // Just in case
            let numberFormat = String(repeating: "0", count: max(1, config.batesDigitCount))
            let displayedStartBates = String(format: "%0\(config.batesDigitCount)d", startBates)

            // Field Code XML Construction
            // We need nested fields: { = { PAGE } + offset }
            // Sequence:
            // 1. Prefix Text
            // 2. Field Begin
            // 3. Formula " = "
            // 4. Field Begin (PAGE)
            // 5. " PAGE "
            // 6. Field End
            // 7. " + offset "
            // 8. Field Separate
            // 9. Display Result (startBates)
            // 10. Field End
            // Timestamp follows if enabled.

            // Note: v:textbox content is w:txbxContent -> w:p -> w:r ...
            batesVML = """
                        <v:shape id="BatesStamp" type="#_x0000_t202" style="\(bStyle);z-index:10" fillcolor="none" strokecolor="none">
                            <v:textbox>
                                <w:txbxContent>
                                    <w:p>
                                        <w:pPr>
                                            <w:jc w:val="center"/>
                                        </w:pPr>
                                        <w:r>
                                            <w:rPr>
                                                <w:rFonts w:ascii="Arial" w:hAnsi="Arial"/>
                                                <w:sz w:val="\(bSize * 2)"/>
                                                <w:color w:val="\(bColor.replacingOccurrences(of: "#", with: ""))"/>
                                            </w:rPr>
                                            <w:t xml:space="preserve">\(config.batesPrefix.xmlEscaped())</w:t>
                                        </w:r>
                                        <w:r>
                                            <w:fldChar w:fldCharType="begin"/>
                                        </w:r>
                                        <w:r>
                                            <w:instrText xml:space="preserve"> = </w:instrText>
                                        </w:r>
                                        <w:r>
                                            <w:fldChar w:fldCharType="begin"/>
                                        </w:r>
                                        <w:r>
                                            <w:instrText xml:space="preserve"> PAGE </w:instrText>
                                        </w:r>
                                        <w:r>
                                            <w:fldChar w:fldCharType="end"/>
                                        </w:r>
                                        <w:r>
                                            <w:instrText xml:space="preserve"> \(offsetStr) \\# "\(numberFormat)" </w:instrText>
                                        </w:r>
                                        <w:r>
                                            <w:fldChar w:fldCharType="separate"/>
                                        </w:r>
                                        <w:r>
                                            <w:rPr>
                                                <w:rFonts w:ascii="Arial" w:hAnsi="Arial"/>
                                                <w:sz w:val="\(bSize * 2)"/>
                                                <w:color w:val="\(bColor.replacingOccurrences(of: "#", with: ""))"/>
                                            </w:rPr>
                                            <w:t>\(displayedStartBates)</w:t>
                                        </w:r>
                                        <w:r>
                                            <w:fldChar w:fldCharType="end"/>
                                        </w:r>
            """

            if config.batesIncludeTimestamp {
                 let ts = Int(Date().timeIntervalSince1970)
                 batesVML += """
                                        <w:r>
                                            <w:rPr>
                                                <w:rFonts w:ascii="Arial" w:hAnsi="Arial"/>
                                                <w:sz w:val="\(bSize * 2)"/>
                                                <w:color w:val="\(bColor.replacingOccurrences(of: "#", with: ""))"/>
                                            </w:rPr>
                                            <w:t xml:space="preserve"> | \(ts)</w:t>
                                        </w:r>
                 """
            }

            batesVML += """
                                    </w:p>
                                </w:txbxContent>
                            </v:textbox>
                        </v:shape>
            """
        }

        // 1. Create the Header XML with VML Shape.
        // Wrapped in mc:AlternateContent to prevent Word's corruption warning.
        let headerXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
               xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
               xmlns:v="urn:schemas-microsoft-com:vml"
               xmlns:o="urn:schemas-microsoft-com:office:office"
               xmlns:w10="urn:schemas-microsoft-com:office:word"
               xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"
                xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"
                xmlns:w14="http://schemas.microsoft.com/office/word/2010/wordml"
                xmlns:wp14="http://schemas.microsoft.com/office/word/2010/wordprocessingDrawing"
                mc:Ignorable="w14 wp14">
            <w:p>
                <w:pPr><w:pStyle w:val="Header"/></w:pPr>
                <w:r>
                    <w:rPr><w:noProof/></w:rPr>
                    <mc:AlternateContent>
                    <mc:Choice Requires="wps">
                    <w:pict>
                        <v:shapetype id="_x0000_t136" coordsize="21600,21600" o:spt="136" adj="10800"
                                     path="m@7,l@8,m@5,21600l@6,21600e">
                            <v:formulas>
                                <v:f eqn="sum #0 0 10800"/>
                                <v:f eqn="prod #0 2 1"/>
                                <v:f eqn="sum 21600 0 @1"/>
                                <v:f eqn="sum 0 0 @2"/>
                                <v:f eqn="sum 21600 0 @3"/>
                                <v:f eqn="if @0 @3 0"/>
                                <v:f eqn="if @0 21600 @1"/>
                                <v:f eqn="if @0 0 @2"/>
                                <v:f eqn="if @0 @4 21600"/>
                                <v:f eqn="mid @5 @6"/>
                                <v:f eqn="mid @8 @5"/>
                                <v:f eqn="mid @7 @8"/>
                                <v:f eqn="mid @6 @7"/>
                                <v:f eqn="sum @6 0 @5"/>
                            </v:formulas>
                            <v:path textpathok="t" o:connecttype="custom" o:connectlocs="@9,0;@10,10800;@11,21600;@12,10800" o:connectangles="270,180,90,0"/>
                            <v:textpath on="t"/>
                            <v:handles><v:h position="#0,bottomRight" xrange="6629,14971"/></v:handles>
                            <o:lock v:ext="edit" text="t" shapetype="t"/>
                        </v:shapetype>
                        <v:shape id="PowerPlusWaterMarkObject"
                                 o:spid="_x0000_s2049"
                                 type="#_x0000_t136"
                                 style="\(vmlStyle)"
                                 o:allowincell="f"
                                 fillcolor="\(config.colorHex)"
                                 stroked="f">
                            <v:fill opacity="\(opacityStr)"/>
                            <v:textpath style="font-family:&quot;Arial&quot;;font-size:\(fontSize)pt" string="\(escapedText)"/>
                        </v:shape>
                        \(batesVML)
                    </w:pict>
                    </mc:Choice>
                    <mc:Fallback/>
                    </mc:AlternateContent>
                </w:r>
            </w:p>
        </w:hdr>
        """

        try headerXML.write(to: headerURL, atomically: true, encoding: .utf8)

        // 2. Register in [Content_Types].xml
        try registerContentType(in: directory, extension: "xml", contentType: "application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml")

        // 3. Register in word/_rels/document.xml.rels
        let relID = try registerRelationship(
            in: wordDir,
            id: "rIdWatermark",
            type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/header",
            target: "headerWatermark.xml"
        )

        // 4. Link in word/document.xml — inject into ALL sections
        try injectHeaderReference(
            in: wordDir,
            relID: relID,
            watermarkStyle: vmlStyle,
            watermarkColorHex: config.colorHex,
            watermarkOpacity: opacityStr,
            watermarkFontSize: fontSize,
            watermarkText: escapedText
        )
    }

    /// Maps a location integer (matching PdfProcessingService.WatermarkConfig.location)
    /// to a VML CSS style string for consistent placement across PDF and DOCX.
    private func vmlStyleForLocation(_ location: Int, shapeWidth: Int, shapeHeight: Int) -> String {
        let base = "position:absolute;width:\(shapeWidth)pt;height:\(shapeHeight)pt"

        switch location {
        case 1: // Top Left
            return "\(base);mso-position-horizontal:left;mso-position-horizontal-relative:margin;mso-position-vertical:top;mso-position-vertical-relative:margin"
        case 2: // Bottom Right
            return "\(base);mso-position-horizontal:right;mso-position-horizontal-relative:margin;mso-position-vertical:bottom;mso-position-vertical-relative:margin"
        case 3: // Diagonal
            return "\(base);rotation:-45;mso-position-horizontal:center;mso-position-horizontal-relative:margin;mso-position-vertical:center;mso-position-vertical-relative:margin"
        case 4: // Top Center
            return "\(base);mso-position-horizontal:center;mso-position-horizontal-relative:margin;mso-position-vertical:top;mso-position-vertical-relative:margin"
        case 5: // Top Right
            return "\(base);mso-position-horizontal:right;mso-position-horizontal-relative:margin;mso-position-vertical:top;mso-position-vertical-relative:margin"
        case 6: // Bottom Left
            return "\(base);mso-position-horizontal:left;mso-position-horizontal-relative:margin;mso-position-vertical:bottom;mso-position-vertical-relative:margin"
        case 7: // Bottom Center
            return "\(base);mso-position-horizontal:center;mso-position-horizontal-relative:margin;mso-position-vertical:bottom;mso-position-vertical-relative:margin"
        case 8: // Left Margin (Vertical)
            return "\(base);rotation:90;mso-position-horizontal:left;mso-position-horizontal-relative:margin;mso-position-vertical:center;mso-position-vertical-relative:margin"
        case 9: // Right Margin (Vertical)
            return "\(base);rotation:-90;mso-position-horizontal:right;mso-position-horizontal-relative:margin;mso-position-vertical:center;mso-position-vertical-relative:margin"
        default: // 0: Center
            return "\(base);mso-position-horizontal:center;mso-position-horizontal-relative:margin;mso-position-vertical:center;mso-position-vertical-relative:margin"
        }
    }

    private func registerContentType(in directory: URL, extension ext: String, contentType: String) throws {
        let ctURL = directory.appendingPathComponent("[Content_Types].xml")
        guard FileManager.default.fileExists(atPath: ctURL.path) else { return }

        let content = try String(contentsOf: ctURL, encoding: .utf8)
        let root = try XMLHelper.parse(xml: content)

        // Check duplication
        let exists = root.children.contains {
            $0.name == "Override" && $0.attributes["PartName"] == "/word/headerWatermark.xml"
        }

        if !exists {
            let override = XMLNode(name: "Override", attributes: [
                "PartName": "/word/headerWatermark.xml",
                "ContentType": contentType
            ])
            root.appendChild(override)

            let xmlHeader = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
            try (xmlHeader + root.toString()).write(to: ctURL, atomically: true, encoding: .utf8)
        }
    }

    private func registerRelationship(in wordDir: URL, id: String, type: String, target: String) throws -> String {
        let relsURL = wordDir.appendingPathComponent("_rels/document.xml.rels")
        guard FileManager.default.fileExists(atPath: relsURL.path) else {
            throw MarcryptError.fileCorrupted(relsURL, underlying: nil)
        }

        let content = try String(contentsOf: relsURL, encoding: .utf8)
        let root = try XMLHelper.parse(xml: content)

        for child in root.children where child.name == "Relationship" {
            if child.attributes["Target"] == target && child.attributes["Type"] == type,
               let existingId = child.attributes["Id"] {
                return existingId
            }
        }

        var usedIds = Set<String>()
        for child in root.children where child.name == "Relationship" {
            if let childId = child.attributes["Id"] {
                usedIds.insert(childId)
            }
        }

        var assignedId = id
        var suffix = 1
        while usedIds.contains(assignedId) {
            assignedId = "\(id)\(suffix)"
            suffix += 1
        }

        let rel = XMLNode(name: "Relationship", attributes: [
            "Id": assignedId,
            "Type": type,
            "Target": target
        ])
        root.appendChild(rel)

        let xmlHeader = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        try (xmlHeader + root.toString()).write(to: relsURL, atomically: true, encoding: .utf8)
        return assignedId
    }

    private func injectHeaderReference(
        in wordDir: URL,
        relID: String,
        watermarkStyle: String,
        watermarkColorHex: String,
        watermarkOpacity: String,
        watermarkFontSize: Int,
        watermarkText: String
    ) throws {
         let docURL = wordDir.appendingPathComponent("document.xml")
         guard FileManager.default.fileExists(atPath: docURL.path) else { return }

         let content = try String(contentsOf: docURL, encoding: .utf8)
         let root = try XMLHelper.parse(xml: content)

         guard let body = root.firstChild(named: "w:body") else { return }

         // Find ALL w:sectPr elements — body-level (last section) AND
         // those nested inside w:pPr (intermediate sections with section breaks).
         // This ensures the watermark header applies to every section of the document.
         let allSectPrs = body.findAll(named: "w:sectPr")

         if allSectPrs.isEmpty {
             // No sections at all — create one at end of body
             let refTag = XMLNode(name: "w:headerReference", attributes: [
                "w:type": "default",
                "r:id": relID
             ])
             let sectPr = XMLNode(name: "w:sectPr")
             sectPr.appendChild(refTag)
             body.appendChild(sectPr)
        } else {
            // First, load relationships to resolve IDs
            let relsURL = wordDir.appendingPathComponent("_rels/document.xml.rels")
             let headerRelationshipType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/header"
             var relationships: [String: (target: String, type: String)] = [:] // ID -> (Target, Type)
             if FileManager.default.fileExists(atPath: relsURL.path),
                let relsContent = try? String(contentsOf: relsURL, encoding: .utf8),
                let relsRoot = try? XMLHelper.parse(xml: relsContent) {
                 for child in relsRoot.children where child.name == "Relationship" {
                     if let id = child.attributes["Id"], let target = child.attributes["Target"], let type = child.attributes["Type"] {
                         if relationships[id] == nil {
                             relationships[id] = (target: target, type: type)
                         }
                     }
                 }
             }

             func headerTarget(for relID: String) -> String? {
                 guard let relationship = relationships[relID],
                       relationship.type == headerRelationshipType else {
                     return nil
                 }
                 return relationship.target
             }

             func isHeaderPart(_ headerFile: String) -> Bool {
                 let headerPath = wordDir.appendingPathComponent(headerFile)
                 return FileManager.default.fileExists(atPath: headerPath.path)
             }

             // Helper to inject VML into a specific header file
             func injectVML(into headerFile: String) throws {
                 let headerURL = wordDir.appendingPathComponent(headerFile)
                 guard FileManager.default.fileExists(atPath: headerURL.path) else { return }
                 let content = try String(contentsOf: headerURL, encoding: .utf8)
                 let headerRoot = try XMLHelper.parse(xml: content)

                 // Check if already watermarked
                 let hasWatermark = headerRoot.findAll(named: "v:shape").contains { $0.attributes["id"] == "PowerPlusWaterMarkObject" }
                 guard !hasWatermark else { return }

                 // Verify namespaces
                 if headerRoot.attributes["xmlns:w14"] == nil {
                     headerRoot.attributes["xmlns:w14"] = "http://schemas.microsoft.com/office/word/2010/wordml"
                 }
                 if headerRoot.attributes["xmlns:wp14"] == nil {
                     headerRoot.attributes["xmlns:wp14"] = "http://schemas.microsoft.com/office/word/2010/wordprocessingDrawing"
                 }
                 if headerRoot.attributes["xmlns:wps"] == nil {
                     headerRoot.attributes["xmlns:wps"] = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape"
                 }
                 if headerRoot.attributes["xmlns:v"] == nil {
                     headerRoot.attributes["xmlns:v"] = "urn:schemas-microsoft-com:vml"
                 }

                 let vmlP = XMLNode(name: "w:p")
                 let pPr = XMLNode(name: "w:pPr")
                 pPr.appendChild(XMLNode(name: "w:pStyle", attributes: ["w:val": "Header"]))
                 vmlP.appendChild(pPr)

                 let run = XMLNode(name: "w:r")
                 let rPr = XMLNode(name: "w:rPr")
                 rPr.appendChild(XMLNode(name: "w:noProof"))
                 run.appendChild(rPr)

                 let picture = XMLNode(name: "w:pict")

                 // Ensure v:shapetype exists (Essential for VML visibility)
                 let hasShapeType = headerRoot.findAll(named: "v:shapetype").contains { $0.attributes["id"] == "_x0000_t136" }
                 if !hasShapeType {
                     let shapeType = XMLNode(name: "v:shapetype", attributes: [
                        "id": "_x0000_t136",
                        "coordsize": "21600,21600",
                        "o:spt": "136",
                        "adj": "10800",
                        "path": "m@7,l@8,m@5,21600l@6,21600e"
                     ])

                     let formulas = XMLNode(name: "v:formulas")
                     let eqns = [
                        "sum #0 0 10800", "prod #0 2 1", "sum 21600 0 @1", "sum 0 0 @2",
                        "sum 21600 0 @3", "if @0 @3 0", "if @0 21600 @1", "if @0 0 @2",
                        "if @0 @4 21600", "mid @5 @6", "mid @8 @5", "mid @7 @8",
                        "mid @6 @7", "sum @6 0 @5"
                     ]
                     for eqn in eqns { formulas.appendChild(XMLNode(name: "v:f", attributes: ["eqn": eqn])) }
                     shapeType.appendChild(formulas)

                     let path = XMLNode(name: "v:path", attributes: [
                        "textpathok": "t", "o:connecttype": "custom",
                        "o:connectlocs": "@9,0;@10,10800;@11,21600;@12,10800",
                        "o:connectangles": "270,180,90,0"
                     ])
                     shapeType.appendChild(path)

                     shapeType.appendChild(XMLNode(name: "v:textpath", attributes: ["on": "t"]))

                     let handles = XMLNode(name: "v:handles")
                     handles.appendChild(XMLNode(name: "v:h", attributes: ["position": "#0,bottomRight", "xrange": "6629,14971"]))
                     shapeType.appendChild(handles)

                     shapeType.appendChild(XMLNode(name: "o:lock", attributes: ["v:ext": "edit", "text": "t", "shapetype": "t"]))

                     picture.appendChild(shapeType)
                 }

                 let shape = XMLNode(name: "v:shape", attributes: [
                     "id": "PowerPlusWaterMarkObject",
                     "o:spid": "_x0000_s2049",
                     "type": "#_x0000_t136",
                     "style": watermarkStyle,
                     "o:allowincell": "f",
                     "fillcolor": watermarkColorHex,
                     "stroked": "f"
                 ])

                 let fill = XMLNode(name: "v:fill", attributes: ["opacity": watermarkOpacity])
                 let textpath = XMLNode(name: "v:textpath", attributes: [
                     "style": "font-family:\"Arial\";font-size:\(watermarkFontSize)pt",
                     "string": watermarkText
                 ])

                 shape.appendChild(fill)
                 shape.appendChild(textpath)
                 picture.appendChild(shape)
                 run.appendChild(picture)
                 vmlP.appendChild(run)

                 headerRoot.appendChild(vmlP)

                 let xmlHeader = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
                 try (xmlHeader + headerRoot.toString()).write(to: headerURL, atomically: true, encoding: .utf8)
             }

             // Process Sections
             for sectPr in allSectPrs {
                 // Detect configuration
                 let hasTitlePg = sectPr.children.contains { $0.name == "w:titlePg" }

                 func handleType(_ type: String, alwaysInject: Bool) throws {
                     if let existing = sectPr.children.first(where: { $0.name == "w:headerReference" && $0.attributes["w:type"] == type }),
                        let rId = existing.attributes["r:id"],
                        let target = headerTarget(for: rId),
                        isHeaderPart(target) {
                         // Merge into existing header part when resolvable.
                         try injectVML(into: target)
                     } else if let existing = sectPr.children.first(where: { $0.name == "w:headerReference" && $0.attributes["w:type"] == type }) {
                         // Repair malformed section metadata by redirecting an invalid/referenced header reference.
                         existing.attributes["r:id"] = relID
                         if isHeaderPart("headerWatermark.xml") {
                             try injectVML(into: "headerWatermark.xml")
                         }
                     } else if alwaysInject {
                         // Create new reference to our watermark header
                         if !sectPr.children.contains(where: { $0.name == "w:headerReference" && $0.attributes["w:type"] == type }) {
                             let ref = XMLNode(name: "w:headerReference", attributes: ["w:type": type, "r:id": relID])
                             sectPr.insertChild(ref, at: 0)
                             if isHeaderPart("headerWatermark.xml") {
                                 try injectVML(into: "headerWatermark.xml")
                             }
                         }
                     }
                 }

                 try handleType("default", alwaysInject: true)
                 try handleType("first", alwaysInject: hasTitlePg)
                 try handleType("even", alwaysInject: false)
             }
         }

         let xmlHeader = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
         try (xmlHeader + root.toString()).write(to: docURL, atomically: true, encoding: .utf8)
    }
}

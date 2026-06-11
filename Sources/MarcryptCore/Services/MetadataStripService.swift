import Foundation
import CoreGraphics

/// Service for stripping sensitive metadata from documents before encryption.
/// - PDF: Title, Author, Creator, Producer, Subject, Keywords
/// - DOCX: core.xml (author, last modified by, revision, etc.) and app.xml (company, manager, etc.)
///
/// All file operations use the in-process ZipArchive/SSZipArchive library (via ArchiveService)
/// so that the service works correctly in a sandboxed, hardened-runtime App Store build.
/// No external process spawning is used.
public class MetadataStripService {
    public static let shared = MetadataStripService()

    private init() {}

    // MARK: - Public API

    /// Strip metadata from a PDF file using CGPDFDocument.
    /// Creates a new PDF at destination without metadata dictionary entries.
    public func stripPDFMetadata(at url: URL, to destination: URL) throws {
        guard let pdfDocument = CGPDFDocument(url as CFURL) else {
            throw MarcryptError.fileCorrupted(url, underlying: nil)
        }

        let pageCount = pdfDocument.numberOfPages
        guard pageCount > 0 else {
            throw MarcryptError.fileCorrupted(url, underlying: nil)
        }

        // Create new PDF without metadata — pass empty auxiliary dictionary to omit info dict
        var mediaBox = CGRect.zero
        let auxDict: [CFString: Any] = [:] // No metadata
        guard let context = CGContext(destination as CFURL, mediaBox: &mediaBox, auxDict as CFDictionary) else {
            throw MarcryptError.encryptionFailed(destination, underlying: nil)
        }

        for pageIndex in 1...pageCount {
            guard let page = pdfDocument.page(at: pageIndex) else { continue }
            var pageRect = page.getBoxRect(.mediaBox)
            context.beginPage(mediaBox: &pageRect)
            context.drawPDFPage(page)
            context.endPage()
        }

        context.closePDF()

        AppLogger.debug("Stripped PDF metadata: \(url.lastPathComponent)", logger: AppLogger.pdf)
    }

    /// Strip metadata from a DOCX file.
    /// Unzips in-process via ArchiveService, removes/blanks sensitive fields in
    /// docProps/core.xml and docProps/app.xml, then re-zips in-process via ArchiveService.
    public func stripDocxMetadata(at url: URL, to destination: URL) async throws {
        let fileManager = FileManager.default

        // Create temp working directory
        let tempDir = try TempFileManager.shared.createTempDirectory()
        defer { TempFileManager.shared.release(url: tempDir) }

        // Unzip DOCX using the in-process library (no external process)
        let unzipDir = tempDir.appendingPathComponent("content")
        try fileManager.createDirectory(at: unzipDir, withIntermediateDirectories: true)

        do {
            try await ArchiveService.shared.unzip(archiveAt: url, to: unzipDir, password: "")
        } catch {
            throw MarcryptError.fileCorrupted(url, underlying: error)
        }

        // Strip core.xml metadata
        let coreXMLPath = unzipDir.appendingPathComponent("docProps/core.xml")
        if fileManager.fileExists(atPath: coreXMLPath.path) {
            try stripCoreXML(at: coreXMLPath)
        }

        // Strip app.xml metadata
        let appXMLPath = unzipDir.appendingPathComponent("docProps/app.xml")
        if fileManager.fileExists(atPath: appXMLPath.path) {
            try stripAppXML(at: appXMLPath)
        }

        // Re-zip to destination using the in-process library (no external process).
        // Remove any stale destination first so zipFolder does not append to an existing archive.
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        do {
            try await ArchiveService.shared.zipFolder(at: unzipDir, to: destination, password: nil)
        } catch {
            throw MarcryptError.encryptionFailed(destination, underlying: error)
        }

        AppLogger.debug("Stripped DOCX metadata: \(url.lastPathComponent)", logger: AppLogger.docx)
    }

    /// Inspect what metadata a file contains (for preview/audit purposes).
    public func inspectMetadata(at url: URL) async throws -> [String: String] {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            return inspectPDFMetadata(at: url)
        case "docx":
            return try await inspectDocxMetadata(at: url)
        default:
            return [:]
        }
    }

    // MARK: - Private Helpers

    private func inspectPDFMetadata(at url: URL) -> [String: String] {
        guard let pdf = CGPDFDocument(url as CFURL),
              let info = pdf.info else { return [:] }

        var result: [String: String] = [:]
        let keys = ["Title", "Author", "Subject", "Creator", "Producer", "Keywords"]

        for key in keys {
            var value: CGPDFStringRef?
            if CGPDFDictionaryGetString(info, key, &value), let pdfStr = value,
               let cfString = CGPDFStringCopyTextString(pdfStr) {
                result[key] = cfString as String
            }
        }

        return result
    }

    /// Inspect DOCX metadata by unzipping in-process and reading docProps XML.
    /// Throws on unzip failure rather than silently returning an empty dictionary.
    private func inspectDocxMetadata(at url: URL) async throws -> [String: String] {
        let tempDir = try TempFileManager.shared.createTempDirectory()
        defer { TempFileManager.shared.release(url: tempDir) }

        do {
            try await ArchiveService.shared.unzip(archiveAt: url, to: tempDir, password: "")
        } catch {
            throw MarcryptError.fileCorrupted(url, underlying: error)
        }

        var result: [String: String] = [:]

        let coreXMLPath = tempDir.appendingPathComponent("docProps/core.xml")
        if let data = try? Data(contentsOf: coreXMLPath),
           let xml = try? XMLDocument(data: data, options: []),
           let root = xml.rootElement() {
            let fields = ["dc:creator", "cp:lastModifiedBy", "cp:revision", "dc:title", "dc:subject", "dc:description"]
            for field in fields {
                if let el = root.elements(forName: field).first, let text = el.stringValue, !text.isEmpty {
                    result[field] = text
                }
            }
        }

        let appXMLPath = tempDir.appendingPathComponent("docProps/app.xml")
        if let data = try? Data(contentsOf: appXMLPath),
           let xml = try? XMLDocument(data: data, options: []),
           let root = xml.rootElement() {
            let fields = ["Company", "Manager", "Application"]
            for field in fields {
                if let el = root.elements(forName: field).first, let text = el.stringValue, !text.isEmpty {
                    result[field] = text
                }
            }
        }

        return result
    }

    private func stripCoreXML(at url: URL) throws {
        guard let data = try? Data(contentsOf: url),
              let xml = try? XMLDocument(data: data, options: []),
              let root = xml.rootElement() else { return }

        // Fields to blank/remove
        let sensitiveFields = ["dc:creator", "cp:lastModifiedBy", "cp:revision",
                               "dc:title", "dc:subject", "dc:description", "cp:keywords"]

        for fieldName in sensitiveFields {
            for element in root.elements(forName: fieldName) {
                element.stringValue = ""
            }
        }

        let output = xml.xmlData(options: [.nodePrettyPrint])
        try output.write(to: url)
    }

    private func stripAppXML(at url: URL) throws {
        guard let data = try? Data(contentsOf: url),
              let xml = try? XMLDocument(data: data, options: []),
              let root = xml.rootElement() else { return }

        let sensitiveFields = ["Company", "Manager"]

        for fieldName in sensitiveFields {
            for element in root.elements(forName: fieldName) {
                element.stringValue = ""
            }
        }

        let output = xml.xmlData(options: [.nodePrettyPrint])
        try output.write(to: url)
    }
}

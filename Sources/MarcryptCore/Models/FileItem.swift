import Foundation
import PDFKit
import SwiftUI

@MainActor
public final class FileItem: Identifiable, ObservableObject {
    public enum FileType {
        case pdf
        case zip
        case folder
        case docx
        case unknown
    }
    
    public let id   = UUID()
    public let url  : URL
    public let type : FileType
    
    @Published public var status: ProcessingStatus = .checking
    @Published public var errorMessage: String?     = nil
    @Published public var fileSizeString: String    = ""
    @Published public var decryptedDocument: PDFDocument?     = nil
    @Published public var temporaryDecryptedURL: URL?         = nil
    @Published public var outputURL: URL?                     = nil // Path to result file
    @Published public var reportURL: URL?                     = nil // Path to batch report HTML
    public var managedSourceRoot: URL? = nil
    public var securityScopedBookmarkData: Data? = nil
    
    // Task handle for cancellation
    public var statusCheckTask: Task<Void, Never>? = nil
    
    public init(url: URL, securityScopedBookmarkData: Data? = nil, managedSourceRoot: URL? = nil) {
        self.url = url
        self.securityScopedBookmarkData = securityScopedBookmarkData
        self.managedSourceRoot = managedSourceRoot
        
        // Determine type from the filesystem when possible. Some file-provider
        // and CLI-created folder URLs do not include a trailing slash.
        let isDirectory = (try? Self.withSecurityScopedAccess(url: url, bookmarkData: securityScopedBookmarkData) { accessibleURL in
            try accessibleURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory ?? false
        }) ?? false
        if isDirectory {
            self.type = .folder
        } else {
            switch url.pathExtension.lowercased() {
            case "pdf": self.type = .pdf
            case "zip": self.type = .zip
            case "docx": self.type = .docx
            default: self.type = .unknown
            }
        }
    }

    public func updateFileSize() {
        do {
            let resources = try Self.withSecurityScopedAccess(url: url, bookmarkData: securityScopedBookmarkData) { accessibleURL in
                try accessibleURL.resourceValues(forKeys: [.fileSizeKey])
            }
            if let fileSize = resources.fileSize {
                let formatter = ByteCountFormatter()
                formatter.countStyle = .file
                formatter.allowedUnits = [.useAll] 
                self.fileSizeString = formatter.string(fromByteCount: Int64(fileSize))
            }
        } catch {
            self.fileSizeString = ""
        }
    }

    public nonisolated static func makeSecurityScopedBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public nonisolated static func resolvedSecurityScopedURL(from bookmarkData: Data) throws -> URL {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        if isStale {
            throw CocoaError(.fileReadUnknown)
        }
        return url
    }

    public nonisolated static func withSecurityScopedAccess<T>(
        url: URL,
        bookmarkData: Data?,
        _ body: (URL) throws -> T
    ) throws -> T {
        let accessibleURL: URL
        if let bookmarkData {
            accessibleURL = try resolvedSecurityScopedURL(from: bookmarkData)
        } else {
            accessibleURL = url
        }

        let didStartAccess = accessibleURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                accessibleURL.stopAccessingSecurityScopedResource()
            }
        }
        return try body(accessibleURL)
    }

    public nonisolated static func withSecurityScopedAccess<T>(
        url: URL,
        bookmarkData: Data?,
        _ body: (URL) async throws -> T
    ) async throws -> T {
        let accessibleURL: URL
        if let bookmarkData {
            accessibleURL = try resolvedSecurityScopedURL(from: bookmarkData)
        } else {
            accessibleURL = url
        }

        let didStartAccess = accessibleURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                accessibleURL.stopAccessingSecurityScopedResource()
            }
        }
        return try await body(accessibleURL)
    }
}

public struct AlertInfo: Identifiable {
    public let id = UUID()
    public let title: String
    public let message: String
    
    public init(title: String, message: String) {
        self.title = title
        self.message = message
    }
}

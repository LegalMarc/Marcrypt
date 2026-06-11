import PDFKit
import SwiftUI
import CoreGraphics
import AppKit
import CryptoKit

public class PdfProcessingService {
    public static let shared = PdfProcessingService()
    
    private init() {}
    
    // MARK: - Watermarking
    
    public struct WatermarkConfig {
        public let text: String
        public let size: Int
        public let opacity: Double
        public let location: Int // 0: Center, 1: TL, 2: BR, 3: Diagonal, 4: TC, 5: TR, 6: BL, 7: BC, 8: Left, 9: Right
        public let colorHex: String // e.g. "#FF0000"
        
        // Bates Numbering
        public var batesEnabled: Bool = false
        public var batesPrefix: String = ""
        public var batesStartNumber: Int = 1
        public var batesDigitCount: Int = 6
        public var batesLocation: Int = 2        // Same position codes as watermark; default Bottom Right
        public var batesFontFamily: Int = 2      // 0=sans, 1=serif, 2=mono
        public var batesFontSize: Int = 10
        public var batesColorHex: String = "#000000"
        public var batesIncludeTimestamp: Bool = false
        
        public init(text: String, size: Int, opacity: Double, location: Int,
                    colorHex: String = "#FF0000",
                    batesEnabled: Bool = false, batesPrefix: String = "",
                    batesStartNumber: Int = 1, batesDigitCount: Int = 6,
                    batesLocation: Int = 2, batesFontFamily: Int = 2,
                    batesFontSize: Int = 10, batesColorHex: String = "#000000",
                    batesIncludeTimestamp: Bool = false) {
            self.text = text
            self.size = size
            self.opacity = opacity
            self.location = location
            self.colorHex = colorHex
            self.batesEnabled = batesEnabled
            self.batesPrefix = batesPrefix
            self.batesStartNumber = batesStartNumber
            self.batesDigitCount = batesDigitCount
            self.batesLocation = batesLocation
            self.batesFontFamily = batesFontFamily
            self.batesFontSize = batesFontSize
            self.batesColorHex = batesColorHex
            self.batesIncludeTimestamp = batesIncludeTimestamp
        }
    }
    
    /// Parse a hex color string like "#FF0000" into an NSColor.
    public static func nsColor(from hex: String) -> NSColor {
        var hexStr = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hexStr.hasPrefix("#") { hexStr.removeFirst() }
        guard hexStr.count == 6, let val = UInt64(hexStr, radix: 16) else { return .red }
        return NSColor(
            red: CGFloat((val >> 16) & 0xFF) / 255.0,
            green: CGFloat((val >> 8) & 0xFF) / 255.0,
            blue: CGFloat(val & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
    
    /// Applies watermark (and optional Bates numbering) to a PDFDocument.
    /// Returns the next Bates number (for batch continuity across documents).
    @discardableResult
    public func applyWatermark(
        to document: PDFDocument,
        config: WatermarkConfig,
        progress: OperationProgressHandler? = nil
    ) throws -> Int {
        let pages = (0..<document.pageCount).compactMap({ document.page(at: $0) })
        guard !pages.isEmpty else { return config.batesStartNumber }
        
        var currentBatesNumber = config.batesStartNumber
        progress?(OperationProgress(completedUnitCount: 0, totalUnitCount: Int64(pages.count), message: "Applying watermark"))
        
        for (index, page) in pages.enumerated() {
            // Cancellation Check
            try Task.checkCancellation()
            
            let bounds = page.bounds(for: .mediaBox)
            let text = config.text
            
            let watermarkColor = Self.nsColor(from: config.colorHex)
            
            let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
            annotation.contents = text
            annotation.font = NSFont.systemFont(ofSize: CGFloat(config.size), weight: .bold)
            annotation.color = NSColor.clear // Transparent background
            annotation.fontColor = watermarkColor.withAlphaComponent(config.opacity)
            annotation.alignment = .center
            annotation.shouldPrint = true
            annotation.isReadOnly = true
            
            // Rough size estimation for positioning
            let width = CGFloat(config.text.count * config.size / 2)
            let height = CGFloat(config.size) * 1.5
            
            var rect: NSRect
            
            // Adjust location based on page rotation to ensure visual correctness
            let rotation = page.rotation
            let effectiveLocation = Self.adjustLocation(config.location, for: rotation)
            
            switch effectiveLocation {
            case 1: // Top Left
                rect = NSRect(x: 20, y: bounds.height - height - 20, width: width, height: height)
            case 2: // Bottom Right
                rect = NSRect(x: bounds.width - width - 20, y: 20, width: width, height: height)
            default: // Center / Diagonal
                rect = NSRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
            }
            
            annotation.bounds = rect
            page.addAnnotation(annotation)
            
            // Bates Number Stamp
            if config.batesEnabled {
                var batesStr = "\(config.batesPrefix)\(String(format: "%0\(config.batesDigitCount)d", currentBatesNumber))"
                if config.batesIncludeTimestamp {
                    let isoFormatter = ISO8601DateFormatter()
                    isoFormatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
                    batesStr += " | \(isoFormatter.string(from: Date()))"
                }
                
                let batesFont = Self.batesFont(family: config.batesFontFamily, size: CGFloat(config.batesFontSize))
                let batesColor = Self.nsColor(from: config.batesColorHex)
                
                let batesAnnotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
                batesAnnotation.contents = batesStr
                batesAnnotation.font = batesFont
                batesAnnotation.color = NSColor.clear
                batesAnnotation.fontColor = batesColor.withAlphaComponent(0.85)
                batesAnnotation.shouldPrint = true
                batesAnnotation.isReadOnly = true
                
                let charWidth = CGFloat(config.batesFontSize) * 0.6
                let batesWidth = CGFloat(batesStr.count) * charWidth + 10
                let batesHeight = CGFloat(config.batesFontSize) * 1.6
                var batesRect = Self.rectForLocation(config.batesLocation, textWidth: batesWidth, textHeight: batesHeight, pageBounds: bounds)
                
                // If the Bates stamp and watermark overlap, shift the Bates stamp
                // above the watermark. If that would push it off the page, move it below instead.
                if batesRect.intersects(rect) {
                   batesRect.origin.y += rect.height + 10
                   if batesRect.maxY > bounds.height {
                       batesRect.origin.y = rect.minY - batesHeight - 10
                   }
                }
                
                batesAnnotation.bounds = batesRect
                batesAnnotation.alignment = .center
                page.addAnnotation(batesAnnotation)
                
                currentBatesNumber += 1
            }
            
            AppLogger.debug("Applied watermark to page \(index + 1)", logger: AppLogger.pdf)
            progress?(OperationProgress(
                completedUnitCount: Int64(index + 1),
                totalUnitCount: Int64(pages.count),
                message: "Applied watermark to page \(index + 1)"
            ))
        }
        
        return currentBatesNumber
    }
    
    // MARK: - Splitting
    
    public func split(
        document: PDFDocument,
        limitMB: Int,
        progress: OperationProgressHandler? = nil
    ) throws -> [PDFDocument] {
        try Task.checkCancellation()
        guard limitMB > 0, document.pageCount > 0 else { return [document] }
        progress?(OperationProgress(completedUnitCount: 0, totalUnitCount: Int64(document.pageCount), message: "Splitting PDF"))
        
        let splitLimitBytes = Int64(limitMB * 1024 * 1024)
        
        // Memory Optimization: Try to get size from disk first
        var totalSize: Int64 = 0
        if let url = document.documentURL, let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            totalSize = attrs[.size] as? Int64 ?? 0
        } 
        
        // If size could not be read from disk (e.g. document was not loaded from a URL),
        // fall back to a per-page heuristic (~150 KB/page). Over-splitting is safer than
        // attempting to serialise the entire document just to measure it.
        if totalSize == 0 {
             totalSize = Int64(document.pageCount * 150 * 1024)
        }
        
        guard totalSize > splitLimitBytes else {
            return [document]
        }
        
        let avgPageSize = max(1024, totalSize / Int64(max(1, document.pageCount))) // Ensure non-zero
        let pagesPerChunk = max(1, Int(splitLimitBytes / avgPageSize))
        
        var chunks: [PDFDocument] = []
        var currentChunk = PDFDocument()
        var currentPageCount = 0
        
        for i in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: i) else { continue }
            currentChunk.insert(page, at: currentChunk.pageCount)
            currentPageCount += 1
            progress?(OperationProgress(
                completedUnitCount: Int64(i + 1),
                totalUnitCount: Int64(document.pageCount),
                message: "Prepared split page \(i + 1)"
            ))
            
            if currentPageCount >= pagesPerChunk {
                chunks.append(currentChunk)
                currentChunk = PDFDocument()
                currentPageCount = 0
            }
        }
        
        if currentChunk.pageCount > 0 {
            chunks.append(currentChunk)
        }
        
        return chunks
    }

    // MARK: - Encryption
    
    public func writeEncryptedPDF(
        document: PDFDocument,
        to url: URL,
        password: String,
        watermark: WatermarkConfig? = nil,
        startBates: Int = 1,
        progress: OperationProgressHandler? = nil
    ) throws -> Int? {
        try Task.checkCancellation()
        var nextBates: Int? = nil
        
        // 1. Apply Watermark if needed (As Annotation, since we can't context-draw in CLI reliably)
        if var wm = watermark {
            wm.batesStartNumber = startBates
            nextBates = try applyWatermark(to: document, config: wm, progress: progress)
        }

        // 2. Write with Encryption Options
        progress?(OperationProgress(completedUnitCount: 0, totalUnitCount: 1, message: "Writing encrypted PDF"))
        // The owner (permissions) password must differ from the user (open) password.
        // If they are equal, opening the PDF grants full owner privileges, defeating
        // the permissions model. A deterministic derivation keeps the owner password
        // stable across re-encryptions of the same document.
        let ownerPassword = Self.deriveOwnerPassword(from: password)
        let options: [PDFDocumentWriteOption: Any] = [
            .userPasswordOption: password,
            .ownerPasswordOption: ownerPassword,
        ]
        
        if document.write(to: url, withOptions: options) {
            if Task.isCancelled {
                try? SecureDeletionService.shared.shredItem(at: url)
                throw CancellationError()
            }
            AppLogger.debug("Wrote PDFKit encrypted PDF to: \(url.lastPathComponent)", logger: AppLogger.pdf)
            progress?(OperationProgress(completedUnitCount: 1, totalUnitCount: 1, message: url.lastPathComponent))
            return nextBates
        } else {
            // Check for common reasons if write fails
            if !FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path) {
                throw MarcryptError.writePermissionDenied(url)
            }
            // Could strictly check disk space here too, but simple error is better than bool
            throw MarcryptError.encryptionFailed(url, underlying: nil)
        }
    }
    
    // MARK: - Watermark Only (No Encryption)
    
    public func writeWatermarkedPDF(
        document: PDFDocument,
        to url: URL,
        watermark: WatermarkConfig,
        startBates: Int,
        progress: OperationProgressHandler? = nil
    ) throws -> Int? {
        try Task.checkCancellation()
        guard let consumer = CGDataConsumer(url: url as CFURL) else { return nil }
        
        // No Encryption Keys
        var auxInfo: [CFString: Any] = [:]
        
        // Copy original attributes
        if let attributes = document.documentAttributes {
            for (key, value) in attributes {
                if let strKey = key as? String {
                    auxInfo[strKey as CFString] = value
                }
            }
        }
        
        guard let context = CGContext(consumer: consumer, mediaBox: nil, auxInfo as CFDictionary) else {
            AppLogger.error("Failed to create PDF context for watermarking", logger: AppLogger.pdf)
            return nil
        }
        
        var currentBates = startBates
        progress?(OperationProgress(completedUnitCount: 0, totalUnitCount: Int64(document.pageCount), message: "Writing watermarked PDF"))
        
        for i in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: i) else { continue }
            var mediaBox = page.bounds(for: .mediaBox)
            let rotation = page.rotation
            
            // Handle Rotation
            if rotation == 90 || rotation == 270 {
                let temp = mediaBox.width
                mediaBox.size.width = mediaBox.height
                mediaBox.size.height = temp
                mediaBox.origin = .zero
            }
            
            context.beginPage(mediaBox: &mediaBox)
            context.saveGState()
            
            // Draw page
            page.draw(with: .mediaBox, to: context)
            
            context.restoreGState()
            
            // Draw Watermark
            // NSString.draw requires NSGraphicsContext.current to be set.
            // On background threads (Task.detached) it's nil, so we must set it explicitly.
            let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.current = nsContext
            drawWatermark(in: context, pageBounds: mediaBox, config: watermark, currentBates: currentBates)
            NSGraphicsContext.current = nil
            
            if watermark.batesEnabled { currentBates += 1 }
            
            context.endPage()
            progress?(OperationProgress(
                completedUnitCount: Int64(i + 1),
                totalUnitCount: Int64(document.pageCount),
                message: "Wrote PDF page \(i + 1)"
            ))
        }
        
        context.closePDF()
        AppLogger.debug("Wrote Watermarked PDF to: \(url.lastPathComponent)", logger: AppLogger.pdf)
        return currentBates
    }
    
    private func drawWatermark(in context: CGContext, pageBounds: CGRect, config: WatermarkConfig, currentBates: Int) {
        context.saveGState()
        
        let text = config.text as NSString
        let watermarkColor = Self.nsColor(from: config.colorHex)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: CGFloat(config.size), weight: .bold),
            .foregroundColor: watermarkColor.withAlphaComponent(config.opacity)
        ]
        let textSize = text.size(withAttributes: attributes)
        
        // Calculate position
        var x: CGFloat = 0
        var y: CGFloat = 0
        let margin: CGFloat = 20
        let w = pageBounds.width
        let h = pageBounds.height
        var rotation: CGFloat = 0
        
        // 0: Center, 1: TL, 2: BR, 3: Diag
        // 4: TC, 5: TR, 6: BL, 7: BC, 8: Left, 9: Right
        
        switch config.location {
        case 1: // Top Left
            x = margin
            y = h - margin - textSize.height
        case 2: // Bottom Right
            x = w - margin - textSize.width
            y = margin
        case 3: // Diagonal
            x = (w - textSize.width) / 2
            y = (h - textSize.height) / 2
            rotation = 45 * .pi / 180
        case 4: // Top Center
            x = (w - textSize.width) / 2
            y = h - margin - textSize.height
        case 5: // Top Right
            x = w - margin - textSize.width
            y = h - margin - textSize.height
        case 6: // Bottom Left
            x = margin
            y = margin
        case 7: // Bottom Center
            x = (w - textSize.width) / 2
            y = margin
        case 8: // Left Margin (Vertical)
            // Rotate 90 degrees around center of text
            // Anchor at x=margin, y=center
            x = margin
            y = (h - textSize.width) / 2 // Using width because relevant dimension after rotation
            rotation = 90 * .pi / 180
        case 9: // Right Margin (Vertical)
            x = w - margin - textSize.height // height becomes width
            y = (h - textSize.width) / 2
            rotation = -90 * .pi / 180
        default: // 0: Center
            x = (w - textSize.width) / 2
            y = (h - textSize.height) / 2
        }
        
        // Draw
        if rotation != 0 {
            // Move to center of text position
            // For simple rotation, translate to target center, rotate, translate back
            // Or simpler: translate to pivot, rotate, draw at origin.
            
            // Standard center rotation logic:
            // 1. Move origin to center of page (or text center?)
            // Diagonal is usually page center.
            
            if config.location == 3 { // Diagonal - Page Center
                 context.translateBy(x: w/2, y: h/2)
                 context.rotate(by: rotation)
                 text.draw(at: CGPoint(x: -textSize.width/2, y: -textSize.height/2), withAttributes: attributes)
            } else if config.location == 8 { // Left Margin
                context.translateBy(x: margin + textSize.height/2, y: h/2) // Pivot
                context.rotate(by: rotation)
                text.draw(at: CGPoint(x: -textSize.width/2, y: -textSize.height/2), withAttributes: attributes)
            } else if config.location == 9 { // Right Margin
                context.translateBy(x: w - margin - textSize.height/2, y: h/2) // Pivot
                context.rotate(by: rotation)
                text.draw(at: CGPoint(x: -textSize.width/2, y: -textSize.height/2), withAttributes: attributes)
            }
        } else {
            text.draw(at: CGPoint(x: x, y: y), withAttributes: attributes)
        }
        
        // Draw Bates Stamp
        if config.batesEnabled {
            var batesStr = "\(config.batesPrefix)\(String(format: "%0\(config.batesDigitCount)d", currentBates))"
            if config.batesIncludeTimestamp {
                batesStr += " | \(Int(Date().timeIntervalSince1970))"
            }
            
            let batesFont = Self.batesFont(family: config.batesFontFamily, size: CGFloat(config.batesFontSize))
            let batesColor = Self.nsColor(from: config.batesColorHex).withAlphaComponent(0.85)
            
            let batesAttrs: [NSAttributedString.Key: Any] = [
                .font: batesFont,
                .foregroundColor: batesColor
            ]
            let batesText = batesStr as NSString
            
            // Calculate position using helper but need to convert NSRect to CGPoint for drawing
            // Helper returns NSRect
            let charWidth = CGFloat(config.batesFontSize) * 0.6
            let batesWidth = CGFloat(batesStr.count) * charWidth + 10
            let batesHeight = CGFloat(config.batesFontSize) * 1.6
            
            // Helper rect is based on PDF coordinates (Lower-Left origin) but NSString drawing context might be flipped?
            // "flipped: false" in nsContext suggests standard PDF coordinates.
            // But NSString.draw uses current context.
            
            let rect = Self.rectForLocation(config.batesLocation, textWidth: batesWidth, textHeight: batesHeight, pageBounds: pageBounds)
            
            // Draw centered in rect
            // rect.x, rect.y is bottom-left of rect?
            // Yes, standard PDF rect.
            
            // To center text in rect:
            let textSize = batesText.size(withAttributes: batesAttrs)
            let drawX = rect.origin.x + (rect.width - textSize.width) / 2
            let drawY = rect.origin.y + (rect.height - textSize.height) / 2
            
            batesText.draw(at: CGPoint(x: drawX, y: drawY), withAttributes: batesAttrs)
        }
        
        context.restoreGState()
    }
    
    /// Returns an NSFont for the given Bates font family (0=sans, 1=serif, 2=mono).
    static func batesFont(family: Int, size: CGFloat) -> NSFont {
        switch family {
        case 0: // Sans Serif
            return NSFont.systemFont(ofSize: size, weight: .medium)
        case 1: // Serif
            return NSFont(name: "Times New Roman", size: size) ?? NSFont.systemFont(ofSize: size, weight: .medium)
        default: // 2: Monospace
            return NSFont.monospacedSystemFont(ofSize: size, weight: .medium)
        }
    }
    
    /// Returns an NSRect for placing text at the given location code within page bounds.
    static func rectForLocation(_ location: Int, textWidth: CGFloat, textHeight: CGFloat, pageBounds: CGRect) -> NSRect {
        let margin: CGFloat = 15
        let w = pageBounds.width
        let h = pageBounds.height
        
        switch location {
        case 1: // Top Left
            return NSRect(x: margin, y: h - margin - textHeight, width: textWidth, height: textHeight)
        case 2: // Bottom Right
            return NSRect(x: w - margin - textWidth, y: margin, width: textWidth, height: textHeight)
        case 3: // Diagonal (center)
            return NSRect(x: (w - textWidth) / 2, y: (h - textHeight) / 2, width: textWidth, height: textHeight)
        case 4: // Top Center
            return NSRect(x: (w - textWidth) / 2, y: h - margin - textHeight, width: textWidth, height: textHeight)
        case 5: // Top Right
            return NSRect(x: w - margin - textWidth, y: h - margin - textHeight, width: textWidth, height: textHeight)
        case 6: // Bottom Left
            return NSRect(x: margin, y: margin, width: textWidth, height: textHeight)
        case 7: // Bottom Center
            return NSRect(x: (w - textWidth) / 2, y: margin, width: textWidth, height: textHeight)
        case 8: // Left
            return NSRect(x: margin, y: (h - textHeight) / 2, width: textWidth, height: textHeight)
        case 9: // Right
            return NSRect(x: w - margin - textWidth, y: (h - textHeight) / 2, width: textWidth, height: textHeight)
        default: // 0: Center
            return NSRect(x: (w - textWidth) / 2, y: (h - textHeight) / 2, width: textWidth, height: textHeight)
        }
    }
    
    /// Adjusts the location code based on page rotation (e.g., if page is rotated 90 deg, "Top Left" becomes "Bottom Left" physically).
    static func adjustLocation(_ location: Int, for rotation: Int) -> Int {
        // Normalize rotation to 0, 90, 180, 270
        let rot = (rotation % 360 + 360) % 360
        
        guard rot != 0 else { return location }
        
        // 1: TL, 2: BR, 3: Diag, 4: TC, 5: TR, 6: BL, 7: BC, 8: Left, 9: Right
        // 0: Center (invariant)
        
        switch rot {
        case 90:
            switch location {
            case 1: return 6 // TL -> BL
            case 2: return 5 // BR -> TR
            case 4: return 8 // TC -> Left
            case 5: return 1 // TR -> TL
            case 6: return 2 // BL -> BR
            case 7: return 9 // BC -> Right
            case 8: return 7 // Left -> BC
            case 9: return 4 // Right -> TC
            default: return location
            }
        case 180:
            switch location {
            case 1: return 2 // TL -> BR
            case 2: return 1 // BR -> TL
            case 4: return 7 // TC -> BC
            case 5: return 6 // TR -> BL
            case 6: return 5 // BL -> TR
            case 7: return 4 // BC -> TC
            case 8: return 9 // Left -> Right
            case 9: return 8 // Right -> Left
            default: return location
            }
        case 270:
            switch location {
            case 1: return 5 // TL -> TR
            case 2: return 6 // BR -> BL
            case 4: return 9 // TC -> Right
            case 5: return 2 // TR -> BR
            case 6: return 1 // BL -> TL
            case 7: return 8 // BC -> Left
            case 8: return 4 // Left -> TC
            case 9: return 7 // Right -> BC
            default: return location
            }
        default:
            return location
        }
    }
    
    /// Derives an Owner password that is distinct from the User password.
    /// Uses SHA-256(password + fixed salt) to ensure the owner password is deterministic
    /// but always different from the user password.
    static func deriveOwnerPassword(from userPassword: String) -> String {
        let salt = "com.marcrypt.owner-key-derivation-v1"
        let input = Data((userPassword + salt).utf8)
        let hash = SHA256.hash(data: input)
        // Return the first 32 hex characters as the owner password
        return hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

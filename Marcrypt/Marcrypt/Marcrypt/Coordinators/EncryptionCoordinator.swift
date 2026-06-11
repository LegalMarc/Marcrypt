import Foundation
import MarcryptCore
import PDFKit

/// Extracted coordinator for encryption operations.
/// Moves business logic out of FileViewModel for testability and separation of concerns.
@MainActor
class EncryptionCoordinator {
    
    struct EncryptionConfig {
        let password: String
        let destination: URL
        let policy: FileViewModel.CollisionPolicy
        let shouldShred: Bool
        let watermarkConfig: PdfProcessingService.WatermarkConfig?
        let splitEnabled: Bool
        let splitLimitMB: Int
    }
    
    // MARK: - PDF Encryption
    
    /// Encrypt a single PDF file. Returns the output URL on success.
    func encryptPDF(item: FileItem, config: EncryptionConfig) async throws -> URL {
        let tempURL = TempFileManager.shared.createTempFile(extension: "pdf")
        
        guard let pdfDoc = PDFDocument(url: item.url) else {
            throw MarcryptError.fileCorrupted(item.url, underlying: nil)
        }
        
        // Apply watermark if configured
        if let wmConfig = config.watermarkConfig {
            try PdfProcessingService.shared.applyWatermark(to: pdfDoc, config: wmConfig)
        }
        
        // Handle splitting
        if config.splitEnabled {
            let chunks = try PdfProcessingService.shared.split(document: pdfDoc, limitMB: config.splitLimitMB)
            
            if chunks.count > 1 {
                var createdParts: [URL] = []
                
                do {
                    // Write each chunk as encrypted PDF
                    for (i, chunk) in chunks.enumerated() {
                        let partName = "\(item.url.deletingPathExtension().lastPathComponent)_part\(i + 1).pdf"
                        let partURL = config.destination.appendingPathComponent(partName)
                        
                        _ = try PdfProcessingService.shared.writeEncryptedPDF(document: chunk, to: partURL, password: config.password)
                        createdParts.append(partURL)
                    }
                    // Return directory as we created multiple files
                    return config.destination
                } catch {
                    // Cleanup partial outputs on failure
                    for url in createdParts {
                        try? FileManager.default.removeItem(at: url)
                    }
                    throw MarcryptError.encryptionFailed(item.url, underlying: error)
                }
            }
        }
        
        // Single file encryption
        do {
            _ = try PdfProcessingService.shared.writeEncryptedPDF(document: pdfDoc, to: tempURL, password: config.password)
        } catch {
            TempFileManager.shared.release(url: tempURL)
             throw MarcryptError.encryptionFailed(item.url, underlying: error)
        }
        
        // Move to destination
        let outputURL = config.destination.appendingPathComponent(item.url.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: outputURL)
            }
            // Release memory tracking for temp file since it's now moved
            TempFileManager.shared.release(url: tempURL)
        } catch {
             TempFileManager.shared.release(url: tempURL)
             throw MarcryptError.fileSaveFailed(outputURL, underlying: error)
        }
        
        return outputURL
    }
    
    // MARK: - DOCX Encryption
    
    /// Encrypt a single DOCX file. Returns the output URL on success.
    func encryptDOCX(item: FileItem, config: EncryptionConfig) async throws -> URL {
        let outName = item.url.lastPathComponent
        let outputURL = config.destination.appendingPathComponent(outName)
        
        try await DocxEncryptionService.shared.encrypt(docxFile: item.url, to: outputURL, password: config.password)
        
        return outputURL
    }
    
    // MARK: - ZIP Encryption
    
    /// Encrypt a single file/folder by creating a password-protected ZIP. Returns the output URL.
    func encryptAsZIP(item: FileItem, config: EncryptionConfig) async throws -> URL {
        let outName = item.url.deletingPathExtension().lastPathComponent + ".zip"
        let outputURL = config.destination.appendingPathComponent(outName)
        
        try await ArchiveService.shared.zipFolder(at: item.url, to: outputURL, password: config.password)
        
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw MarcryptError.encryptionFailed(item.url, underlying: nil)
        }
        
        return outputURL
    }
    
    // MARK: - Post-processing
    
    /// Optionally shred the original file after successful encryption.
    func shredOriginalIfNeeded(item: FileItem, config: EncryptionConfig) throws {
        guard config.shouldShred else { return }
        try SecureDeletionService.shared.shredItem(at: item.url)
    }
    
    /// Log the encryption operation to the audit trail.
    func logAudit(item: FileItem, outputURL: URL, inputHash: String?, outputHash: String?) {
        AuditService.shared.logSuccess(
            operation: .encrypt,
            inputFile: item.url.lastPathComponent,
            inputHash: inputHash,
            outputFile: outputURL.lastPathComponent,
            outputHash: outputHash,
            parameters: ["type": item.type == .pdf ? "PDF" : item.type == .docx ? "DOCX" : "ZIP"]
        )
    }
}

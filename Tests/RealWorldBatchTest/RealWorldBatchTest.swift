import Foundation
import MarcryptCore
import PDFKit
import SwiftUI

// MARCRYPT_SAMPLE_FILES_PATH must point to a directory containing at least one
// .pdf, one .docx, and one subdirectory. Set the variable to opt in to this
// harness; it is intentionally skipped on a clean clone where local fixtures are
// absent. Example:
//   MARCRYPT_SAMPLE_FILES_PATH=/path/to/ignore-resources/sample-files-marcrypt \
//   .build/debug/RealWorldBatchTest
@main
struct RealWorldBatchTest {
    static func main() async {
        print("╔═══════════════════════════════════════════════════════════╗")
        print("║    REAL WORLD SAMPLE VERIFICATION (ROUND-TRIP)            ║")
        print("╠═══════════════════════════════════════════════════════════╣")
        print("║    Source: MARCRYPT_SAMPLE_FILES_PATH env var             ║")
        print("╚═══════════════════════════════════════════════════════════╝")

        // Paths — driven by env var so the harness is clean-clone-safe.
        guard let sourcePath = ProcessInfo.processInfo.environment["MARCRYPT_SAMPLE_FILES_PATH"],
              !sourcePath.isEmpty else {
            print()
            print("⚠️  SKIPPED: Set MARCRYPT_SAMPLE_FILES_PATH to run this harness.")
            print("   Example: MARCRYPT_SAMPLE_FILES_PATH=/path/to/sample-files-marcrypt .build/debug/RealWorldBatchTest")
            exit(0)
        }
        guard FileManager.default.fileExists(atPath: sourcePath) else {
            print()
            print("⚠️  SKIPPED: MARCRYPT_SAMPLE_FILES_PATH directory not found: \(sourcePath)")
            exit(0)
        }
        let outputDirName = "verification-output"
        let sourceUrl = URL(fileURLWithPath: sourcePath)
        let outputUrl = sourceUrl.appendingPathComponent(outputDirName)
        let password = "doggy-style"

        let fileManager = FileManager.default

        do {
            // Clean/Create output directory
            if fileManager.fileExists(atPath: outputUrl.path) {
                try fileManager.removeItem(at: outputUrl)
            }
            try fileManager.createDirectory(at: outputUrl, withIntermediateDirectories: true)
            print("📁 Output directory ready: \(outputUrl.path)")
            print()
            
            // Get root contents
            let items = try fileManager.contentsOfDirectory(at: sourceUrl, includingPropertiesForKeys: [.isDirectoryKey])
            
            var processedTypes: Set<String> = []
            let requiredTypes = ["pdf", "folder", "docx"]
            
            for item in items {
                if processedTypes.count == requiredTypes.count { break } // Done if we found one of each
                
                // Skip output dir itself and system files
                if item.lastPathComponent == outputDirName { continue }
                if item.lastPathComponent.hasPrefix(".") { continue }
                
                let filename = item.lastPathComponent
                var isDirectory: ObjCBool = false
                fileManager.fileExists(atPath: item.path, isDirectory: &isDirectory)
                
                // --- FOLDER / ZIP ---
                if isDirectory.boolValue {
                    if processedTypes.contains("folder") { continue }
                    
                    print("📦 [FOLDER] Found sample: \(filename)")
                    let destZip = outputUrl.appendingPathComponent("\(filename).zip")
                    let decryptedDir = outputUrl.appendingPathComponent("\(filename)_decrypted")
                    
                    print("   🔒 Encrypting...")
                    try await ArchiveService.shared.zipFolder(at: item, to: destZip, password: password)
                    print("   ✅ Encrypted to: \(destZip.lastPathComponent)")
                    
                    print("   🔓 Decrypting...")
                    try await ArchiveService.shared.unzip(archiveAt: destZip, to: decryptedDir, password: password)
                    print("   ✅ Decrypted to: \(decryptedDir.lastPathComponent)")
                    
                    // Simple verification: Only check if it exists & has content
                    let contentCount = (try? fileManager.contentsOfDirectory(at: decryptedDir, includingPropertiesForKeys: nil).count) ?? 0
                    if contentCount > 0 {
                        print("   ✅ Verification: Decrypted folder has \(contentCount) items.")
                    } else {
                        print("   ❌ Verification: Decrypted folder is empty!")
                    }
                    print("   -----------------------------------------------------------")
                    processedTypes.insert("folder")
                    
                } else {
                    let ext = item.pathExtension.lowercased()
                    
                    // --- PDF ---
                    if ext == "pdf" {
                        if processedTypes.contains("pdf") { continue }
                        
                        print("📄 [PDF] Found sample: \(filename)")
                        let pdfDoc = PDFDocument(url: item)
                        
                        if let doc = pdfDoc {
                            let destPdf = outputUrl.appendingPathComponent("encrypted_\(filename)")
                            
                            print("   🔒 Encrypting...")
                            do {
                                let _ = try PdfProcessingService.shared.writeEncryptedPDF(
                                    document: doc,
                                    to: destPdf,
                                    password: password
                                )
                                print("   ✅ Encrypted to: \(destPdf.lastPathComponent)")
                                
                                print("   🔓 Decrypting (Unlock Check)...")
                                if let encDoc = PDFDocument(url: destPdf) {
                                    if encDoc.isLocked {
                                        if encDoc.unlock(withPassword: password) {
                                            print("   ✅ Verification: PDF unlocked successfully. Page count: \(encDoc.pageCount)")
                                        } else {
                                             print("   ❌ Verification: Failed to unlock with correct password.")
                                        }
                                    } else {
                                        print("   ⚠️ Verification: PDF was not locked!")
                                    }
                                } else {
                                    print("   ❌ Verification: Could not load encrypted PDF.")
                                }
                            } catch {
                                print("   ❌ Encryption failed via PDFKit: \(error.localizedDescription)")
                            }
                        } else {
                            print("   ⚠️ Skipped (Invalid PDF load)")
                        }
                        print("   -----------------------------------------------------------")
                        processedTypes.insert("pdf")
                        
                    // --- DOCX ---
                    } else if ext == "docx" {
                        if processedTypes.contains("docx") { continue }
                        
                        print("📝 [DOCX] Found sample: \(filename)")
                        let destDocx = outputUrl.appendingPathComponent("encrypted_\(filename)")
                        let decryptedDocx = outputUrl.appendingPathComponent("decrypted_\(filename)")
                        
                        print("   🔒 Encrypting...")
                        try await DocxEncryptionService.shared.encrypt(docxFile: item, to: destDocx, password: password)
                        print("   ✅ Encrypted to: \(destDocx.lastPathComponent)")
                        
                        print("   🔓 Decrypting...")
                        let decryptedData = try await DocxEncryptionService.shared.decrypt(docxFile: destDocx, password: password)
                        try decryptedData.write(to: decryptedDocx)
                        print("   ✅ Decrypted to: \(decryptedDocx.lastPathComponent)")
                        
                        // Size verification
                        let originalSize = (try? fileManager.attributesOfItem(atPath: item.path)[.size] as? Int64) ?? 0
                        let decryptedSize = Int64(decryptedData.count)
                        
                        // Docx rounds trip via Zip so sizes might vary slightly due to compression/meta
                        // but let's just log them.
                        print("   ℹ️ Size Check: Orig: \(ByteCountFormatter.string(fromByteCount: originalSize, countStyle: .file)) vs Decrypted: \(ByteCountFormatter.string(fromByteCount: decryptedSize, countStyle: .file))")
                        
                        // Check for key file inside
                        let magic = decryptedData.prefix(4)
                        if magic.elementsEqual([0x50, 0x4B, 0x03, 0x04]) {
                             print("   ✅ Verification: Valid ZIP header found.")
                        } else {
                             print("   ❌ Verification: Invalid header (Not ZIP/DOCX)!")
                        }
                        
                        print("   -----------------------------------------------------------")
                        processedTypes.insert("docx")
                    }
                }
            }
            
            print()
            if processedTypes.count == requiredTypes.count {
                print("✅ All requested types (PDF, Folder, DOCX) were processed.")
            } else {
                print("⚠️ Some types were not found in source directory. Processed: \(processedTypes)")
            }
            print("📂 Results at: \(outputUrl.path)")
            
        } catch {
            print("❌ Critical Error: \(error)")
            exit(1)
        }
    }
}

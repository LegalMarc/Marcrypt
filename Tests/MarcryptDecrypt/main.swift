import Foundation
import MarcryptCore

let args = ProcessInfo.processInfo.arguments

guard args.count >= 4 else {
    print("Usage: MarcryptDecrypt <input_file> <output_file> <password>")
    exit(1)
}

let intputPath = args[1]
let outputPath = args[2]
let password = args[3]

let inputUrl = URL(fileURLWithPath: intputPath)
let outputUrl = URL(fileURLWithPath: outputPath)

print("🔓 Decrypting: \(inputUrl.lastPathComponent)")
print("🔑 Password: \(String(repeating: "*", count: password.count))")

let ext = inputUrl.pathExtension.lowercased()

do {
    if ext == "docx" {
        let decryptedData = try await DocxEncryptionService.shared.decrypt(docxFile: inputUrl, password: password)
        try decryptedData.write(to: outputUrl)
        print("✅ Success! Decrypted DOCX payload written to: \(outputPath)")
        
        // Check ZIP signature
        let magic = decryptedData.prefix(4)
        if magic.elementsEqual([0x50, 0x4B, 0x03, 0x04]) {
             print("   INTEGRITY: Valid ZIP Signature (PK) detected.")
        } else {
             print("   WARNING: Decrypted data does not start with PK header! (Magic: \(magic.map { String(format: "%02hhx", $0) }.joined()))")
        }
        
    } else if ext == "zip" {
        // Zip decryption unpacks
        try await ArchiveService.shared.unzip(archiveAt: inputUrl, to: outputUrl, password: password)
        print("✅ Success! ZIP extracted to: \(outputPath)")
    } else {
        print("❌ Unsupported file extension: .\(ext)")
        exit(1)
    }
} catch {
    print("❌ Decryption Failed: \(error)")
    exit(1)
}

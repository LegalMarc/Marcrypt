import Foundation
import CryptoKit
import POLEWrapper

public class DocxEncryptionService {
    public static let shared = DocxEncryptionService()
    public static let maxSupportedDocumentBytes: Int64 = 256 * 1024 * 1024

    // Header for Agile EncryptionInfo (Version 4.4, Flags 0x40)
    private let encryptionInfoHeader: [UInt8] = [0x04, 0x00, 0x04, 0x00, 0x40, 0x00, 0x00, 0x00]

    private let dataSpacesVersionStreamName = "\u{06}DataSpaces/Version"
    private let dataSpaceMapStreamName = "\u{06}DataSpaces/DataSpaceMap"
    private let dataSpacesDataSpaceInfoStreamName = "\u{06}DataSpaces/DataSpaceInfo/StrongEncryptionDataSpace"
    private let dataSpacesPrimaryTransformStreamName = "\u{06}DataSpaces/TransformInfo/StrongEncryptionTransform/\u{06}Primary"

    // MS-OFFCRYPTO / Agile interoperability streams copied from Word- and msoffcrypto-compatible defaults.
    private let dataSpacesVersion: [UInt8] = [
        0x3C, 0x00, 0x00, 0x00, 0x4D, 0x00, 0x69, 0x00, 0x63, 0x00, 0x72, 0x00, 0x6F, 0x00, 0x73, 0x00,
        0x6F, 0x00, 0x66, 0x00, 0x74, 0x00, 0x2E, 0x00, 0x43, 0x00, 0x6F, 0x00, 0x6E, 0x00, 0x74, 0x00,
        0x61, 0x00, 0x69, 0x00, 0x6E, 0x00, 0x65, 0x00, 0x72, 0x00, 0x2E, 0x00, 0x44, 0x00, 0x61, 0x00,
        0x74, 0x00, 0x61, 0x00, 0x53, 0x00, 0x70, 0x00, 0x61, 0x00, 0x63, 0x00, 0x65, 0x00, 0x73, 0x00,
        0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00
    ]
    private let dataSpaceMap: [UInt8] = [
        0x08, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x68, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00, 0x45, 0x00, 0x6E, 0x00, 0x63, 0x00, 0x72, 0x00,
        0x79, 0x00, 0x70, 0x00, 0x74, 0x00, 0x65, 0x00, 0x64, 0x00, 0x50, 0x00, 0x61, 0x00, 0x63, 0x00,
        0x6B, 0x00, 0x61, 0x00, 0x67, 0x00, 0x65, 0x00, 0x32, 0x00, 0x00, 0x00, 0x53, 0x00, 0x74, 0x00,
        0x72, 0x00, 0x6F, 0x00, 0x6E, 0x00, 0x67, 0x00, 0x45, 0x00, 0x6E, 0x00, 0x63, 0x00, 0x72, 0x00,
        0x79, 0x00, 0x70, 0x00, 0x74, 0x00, 0x69, 0x00, 0x6F, 0x00, 0x6E, 0x00, 0x44, 0x00, 0x61, 0x00,
        0x74, 0x00, 0x61, 0x00, 0x53, 0x00, 0x70, 0x00, 0x61, 0x00, 0x63, 0x00, 0x65, 0x00, 0x00, 0x00
    ]
    private let dataSpacesDataSpaceInfo: [UInt8] = [
        0x08, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x32, 0x00, 0x00, 0x00, 0x53, 0x00, 0x74, 0x00,
        0x72, 0x00, 0x6F, 0x00, 0x6E, 0x00, 0x67, 0x00, 0x45, 0x00, 0x6E, 0x00, 0x63, 0x00, 0x72, 0x00,
        0x79, 0x00, 0x70, 0x00, 0x74, 0x00, 0x69, 0x00, 0x6F, 0x00, 0x6E, 0x00, 0x54, 0x00, 0x72, 0x00,
        0x61, 0x00, 0x6E, 0x00, 0x73, 0x00, 0x66, 0x00, 0x6F, 0x00, 0x72, 0x00, 0x6D, 0x00, 0x00, 0x00
    ]
    private let dataSpacesPrimaryTransform: [UInt8] = [
        0x58, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x4C, 0x00, 0x00, 0x00, 0x7B, 0x00, 0x46, 0x00,
        0x46, 0x00, 0x39, 0x00, 0x41, 0x00, 0x33, 0x00, 0x46, 0x00, 0x30, 0x00, 0x33, 0x00, 0x2D, 0x00,
        0x35, 0x00, 0x36, 0x00, 0x45, 0x00, 0x46, 0x00, 0x2D, 0x00, 0x34, 0x00, 0x36, 0x00, 0x31, 0x00,
        0x33, 0x00, 0x2D, 0x00, 0x42, 0x00, 0x44, 0x00, 0x44, 0x00, 0x35, 0x00, 0x2D, 0x00, 0x35, 0x00,
        0x41, 0x00, 0x34, 0x00, 0x31, 0x00, 0x43, 0x00, 0x31, 0x00, 0x44, 0x00, 0x30, 0x00, 0x37, 0x00,
        0x32, 0x00, 0x34, 0x00, 0x36, 0x00, 0x7D, 0x00, 0x4E, 0x00, 0x00, 0x00, 0x4D, 0x00, 0x69, 0x00,
        0x63, 0x00, 0x72, 0x00, 0x6F, 0x00, 0x73, 0x00, 0x6F, 0x00, 0x66, 0x00, 0x74, 0x00, 0x2E, 0x00,
        0x43, 0x00, 0x6F, 0x00, 0x6E, 0x00, 0x74, 0x00, 0x61, 0x00, 0x69, 0x00, 0x6E, 0x00, 0x65, 0x00,
        0x72, 0x00, 0x2E, 0x00, 0x45, 0x00, 0x6E, 0x00, 0x63, 0x00, 0x72, 0x00, 0x79, 0x00, 0x70, 0x00,
        0x74, 0x00, 0x69, 0x00, 0x6F, 0x00, 0x6E, 0x00, 0x54, 0x00, 0x72, 0x00, 0x61, 0x00, 0x6E, 0x00,
        0x73, 0x00, 0x66, 0x00, 0x6F, 0x00, 0x72, 0x00, 0x6D, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00
    ]

    private init() {}

    // MARK: - Encryption

    public func encrypt(
        docxFile: URL,
        to destinationURL: URL,
        password: String,
        progress: OperationProgressHandler? = nil
    ) async throws {
        AppLogger.debug("Starting encryption for: \(docxFile.lastPathComponent)", logger: AppLogger.docx)

        try await Task.detached(priority: .userInitiated) {
            do {
                try Task.checkCancellation()
                progress?(OperationProgress(completedUnitCount: 0, totalUnitCount: 7, message: "Reading DOCX package"))
                try Self.validateInMemorySize(url: docxFile)
                let packageData = try Data(contentsOf: docxFile)
                try Task.checkCancellation()

                // 1. Generate Random Session Key (Intermediate Key) and Content Salt
                let sessionKey = try self.generateRandomBytes(size: 32)
                let contentSalt = try self.generateRandomBytes(size: 16)
                progress?(OperationProgress(completedUnitCount: 1, totalUnitCount: 7, message: "Generated DOCX session key"))

                // 2. Encrypt Package using Agile block-based encryption
                guard let encryptedPackage = AgileEncryptionUtils.encryptAgileContent(data: packageData, key: sessionKey, salt: contentSalt) else {
                    throw EncryptionError.encryptionFailed
                }
                try Task.checkCancellation()
                progress?(OperationProgress(completedUnitCount: 2, totalUnitCount: 7, message: "Encrypted DOCX package"))

                // 3. Prepare Password KEK Salt and derive intermediate hash
                let KEK_Salt = try self.generateRandomBytes(size: 16)

                // Derive intermediate hash (steps 1-2 of MS-OFFCRYPTO 2.3.4.11)
                guard let intermediateHash = AgileEncryptionUtils.deriveIteratedHash(
                    password: password,
                    salt: KEK_Salt
                ) else {
                    throw EncryptionError.keyDerivationFailed
                }
                try Task.checkCancellation()
                progress?(OperationProgress(completedUnitCount: 3, totalUnitCount: 7, message: "Derived DOCX password key"))

                // Derive THREE separate keys using different block constants
                let keyForVerifierInput = AgileEncryptionUtils.finalizeKey(
                    intermediateHash: intermediateHash,
                    blockKey: Data(AgileEncryptionUtils.blockKeyEncryptedVerifierHashInput)
                )
                let keyForVerifierHash = AgileEncryptionUtils.finalizeKey(
                    intermediateHash: intermediateHash,
                    blockKey: Data(AgileEncryptionUtils.blockKeyEncryptedVerifierHashValue)
                )
                let keyForSessionKey = AgileEncryptionUtils.finalizeKey(
                    intermediateHash: intermediateHash,
                    blockKey: Data(AgileEncryptionUtils.blockKeyEncryptedKeyValue)
                )

                // 4. Wrap Session Key with keyForSessionKey
                // IV is the salt value directly (per msoffcrypto-tool reference)
                guard let encryptedSessionKey = AgileEncryptionUtils.encryptNoPadding(data: sessionKey, key: keyForSessionKey, iv: KEK_Salt) else {
                    throw EncryptionError.encryptionFailed
                }

                // 5. Generate Verifiers
                let verifier = try self.generateRandomBytes(size: 16)
                let verifierHash = Data(SHA512.hash(data: verifier))

                // Encrypt with respective keys, IV is salt value
                guard let encVerifier = AgileEncryptionUtils.encryptNoPadding(data: verifier, key: keyForVerifierInput, iv: KEK_Salt),
                      let encVerifierHash = AgileEncryptionUtils.encryptNoPadding(data: verifierHash, key: keyForVerifierHash, iv: KEK_Salt) else {
                    throw EncryptionError.encryptionFailed
                }

                // 6. Generate Data Integrity HMAC
                // Use random HMAC key per MS-OFFCRYPTO, then encrypt with content-derived IVs (2.3.4.14).
                // The derived/session key is only used to wrap the HMAC key material, not as the HMAC key itself.
                let hmacKey = try self.generateRandomBytes(size: 64)
                let hmacValue = AgileEncryptionUtils.hmac(data: encryptedPackage, key: hmacKey)

                // Derive Distinct IVs
                // IV1 = Hash(contentSalt + BlockKey1)
                let ivHmacKeyHash = SHA512.hash(data: contentSalt + Data(AgileEncryptionUtils.blockKeyDataIntegrity1))
                let ivHmacKey = Data(ivHmacKeyHash).prefix(16)

                // IV2 = Hash(contentSalt + BlockKey2)
                let ivHmacValueHash = SHA512.hash(data: contentSalt + Data(AgileEncryptionUtils.blockKeyDataIntegrity2))
                let ivHmacValue = Data(ivHmacValueHash).prefix(16)

                // Encrypt using correct separate IVs
                guard let encHmacKey = AgileEncryptionUtils.encryptNoPadding(data: hmacKey, key: sessionKey, iv: ivHmacKey),
                      let encHmacValue = AgileEncryptionUtils.encryptNoPadding(data: hmacValue, key: sessionKey, iv: ivHmacValue) else {
                    throw EncryptionError.encryptionFailed
                }
                try Task.checkCancellation()
                progress?(OperationProgress(completedUnitCount: 4, totalUnitCount: 7, message: "Prepared DOCX integrity metadata"))

                // 7. Generate EncryptionInfo XML
                let encryptionInfoData = try self.generateAgileXML(
                    contentSalt: contentSalt,
                    passwordSalt: KEK_Salt,
                    encVerifier: encVerifier,
                    encVerifierHash: encVerifierHash,
                    encSessionKey: encryptedSessionKey,
                    // Integrity salt removed, we use contentSalt implicitly
                    encHmacKey: encHmacKey,
                    encHmacValue: encHmacValue
                )
                progress?(OperationProgress(completedUnitCount: 5, totalUnitCount: 7, message: "Generated DOCX encryption metadata"))

                // 8. Write to Secure Temporary Location first
                // Use system temp to ensure cleaner failure state (no orphaned .tmp files in user's folder)
                let tempDir = try TempFileManager.shared.createTempDirectory()
                let tempURL = tempDir.appendingPathComponent(destinationURL.lastPathComponent)

                // Ensure cleanup
                defer {
                    TempFileManager.shared.release(url: tempDir)
                }

                // Write OLE File to temp location
                let ole = OLEHelper()
                if !ole.createFile(atPath: tempURL.path) {
                    throw EncryptionError.oleCreationFailure
                }

                var writeSuccess = false

                // Write streams in Word-compatible order so the CFB top-level directory tree matches
                // known-good encrypted DOCX layouts (used by Word and msoffcrypto-tool).
                let orderedStreams: [(String, Data)] = [
                    (self.dataSpacesVersionStreamName, Data(self.dataSpacesVersion)),
                    (self.dataSpaceMapStreamName, Data(self.dataSpaceMap)),
                    (self.dataSpacesDataSpaceInfoStreamName, Data(self.dataSpacesDataSpaceInfo)),
                    (self.dataSpacesPrimaryTransformStreamName, Data(self.dataSpacesPrimaryTransform)),
                    ("EncryptionInfo", encryptionInfoData),
                    ("EncryptedPackage", encryptedPackage)
                ]

                writeSuccess = true
                for (streamName, payload) in orderedStreams {
                    if !ole.writeStream(streamName, data: payload) {
                        writeSuccess = false
                        break
                    }
                }

                ole.close()

                if writeSuccess {
                    try Task.checkCancellation()
                    // Atomic Replace: crash-safe file placement
                    if FileManager.default.fileExists(atPath: destinationURL.path) {
                        _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: tempURL)
                    } else {
                        try FileManager.default.moveItem(at: tempURL, to: destinationURL)
                    }
                    AppLogger.debug("Success: Agile Encrypted Docx saved", logger: AppLogger.docx)
                    progress?(OperationProgress(completedUnitCount: 7, totalUnitCount: 7, message: destinationURL.lastPathComponent))
                } else {
                    throw EncryptionError.oleWriteFailure
                }

            } catch {
                AppLogger.error("Encryption failed", error: error, logger: AppLogger.docx)
                throw error
            }
        }.value
    }

    // MARK: - Decryption

    public func decrypt(
        docxFile: URL,
        password: String,
        progress: OperationProgressHandler? = nil
    ) async throws -> Data {
        AppLogger.debug("Attempting to decrypt: \(docxFile.lastPathComponent)", logger: AppLogger.docx)

        return try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            progress?(OperationProgress(completedUnitCount: 0, totalUnitCount: 5, message: "Opening encrypted DOCX"))
            try Self.validateInMemorySize(url: docxFile)
            let ole = OLEHelper()
            guard ole.openFile(atPath: docxFile.path) else {
                throw EncryptionError.oleReadFailure
            }
            defer { ole.close() }

            // 1. Read EncryptionInfo (Try with prefix first, then fallback)
            var infoData = ole.readStream("\u{06}EncryptionInfo")
            if infoData == nil {
                infoData = ole.readStream("EncryptionInfo")
            }

            guard let data = infoData, data.count > 8 else {
                throw EncryptionError.oleReadFailure
            }

            let xmlData = data.subdata(in: 8..<data.count)
            guard String(data: xmlData, encoding: .utf8) != nil else {
                throw EncryptionError.corruptedFile
            }

            // Robust Parsing - include verifier fields for password validation
            var contentSalt: Data?
            var pwdSalt: Data?
            var encSK: Data?
            var encVerifierInput: Data?
            var encVerifierHash: Data?
            var encHmacKey: Data?
            var encHmacValue: Data?

            do {
                let xmlDoc = try XMLDocument(data: xmlData, options: [])
                if let root = xmlDoc.rootElement() {
                    if let keyData = root.elements(forName: "keyData").first,
                       let val = keyData.attribute(forName: "saltValue")?.stringValue {
                        contentSalt = Data(base64Encoded: val)
                    }

                    if let integrity = root.elements(forName: "dataIntegrity").first {
                        if let val = integrity.attribute(forName: "encryptedHmacKey")?.stringValue { encHmacKey = Data(base64Encoded: val) }
                        if let val = integrity.attribute(forName: "encryptedHmacValue")?.stringValue { encHmacValue = Data(base64Encoded: val) }
                    }

                    func findEncryptedKey(in el: XMLElement) -> XMLElement? {
                        if el.localName == "encryptedKey" { return el }
                        for child in (el.children ?? []) {
                            if let childEl = child as? XMLElement, let found = findEncryptedKey(in: childEl) { return found }
                        }
                        return nil
                    }

                    if let encKeyEl = findEncryptedKey(in: root) {
                        if let val = encKeyEl.attribute(forName: "saltValue")?.stringValue { pwdSalt = Data(base64Encoded: val) }
                        if let val = encKeyEl.attribute(forName: "encryptedKeyValue")?.stringValue { encSK = Data(base64Encoded: val) }
                        if let val = encKeyEl.attribute(forName: "encryptedVerifierHashInput")?.stringValue { encVerifierInput = Data(base64Encoded: val) }
                        if let val = encKeyEl.attribute(forName: "encryptedVerifierHashValue")?.stringValue { encVerifierHash = Data(base64Encoded: val) }
                    }
                }
            } catch {
                AppLogger.warning("XML parsing failed, using regex fallback", logger: AppLogger.docx)
            }

            guard let pSalt = pwdSalt, let cSalt = contentSalt, let eSK = encSK else {
                throw EncryptionError.corruptedFile
            }
            guard let encryptedHmacKey = encHmacKey, let encryptedHmacValue = encHmacValue else {
                AppLogger.warning("DOCX missing dataIntegrity HMAC fields", logger: AppLogger.docx)
                throw EncryptionError.corruptedFile
            }
            try Task.checkCancellation()
            progress?(OperationProgress(completedUnitCount: 1, totalUnitCount: 5, message: "Read DOCX encryption metadata"))

            // 2. Derive intermediate hash and keys (MS-OFFCRYPTO 2.3.4.11)
            guard let intermediateHash = AgileEncryptionUtils.deriveIteratedHash(
                password: password,
                salt: pSalt
            ) else {
                throw EncryptionError.keyDerivationFailed
            }
            try Task.checkCancellation()
            progress?(OperationProgress(completedUnitCount: 2, totalUnitCount: 5, message: "Derived DOCX password key"))

            // 3. VALIDATE PASSWORD using verifier hash (MS-OFFCRYPTO 2.3.4.13)
            // This is critical to reject wrong passwords early
            if let eVI = encVerifierInput, let eVH = encVerifierHash {
                let keyForVerifierInput = AgileEncryptionUtils.finalizeKey(
                    intermediateHash: intermediateHash,
                    blockKey: Data(AgileEncryptionUtils.blockKeyEncryptedVerifierHashInput)
                )
                let keyForVerifierHash = AgileEncryptionUtils.finalizeKey(
                    intermediateHash: intermediateHash,
                    blockKey: Data(AgileEncryptionUtils.blockKeyEncryptedVerifierHashValue)
                )

                // Decrypt the verifier input and hash value (IV is salt)
                guard let decryptedVerifier = AgileEncryptionUtils.decryptNoPadding(data: eVI, key: keyForVerifierInput, iv: pSalt),
                      let decryptedHash = AgileEncryptionUtils.decryptNoPadding(data: eVH, key: keyForVerifierHash, iv: pSalt) else {
                    AppLogger.debug("Verifier decryption failed - wrong password", logger: AppLogger.docx)
                    throw EncryptionError.decryptionFailed
                }

                // Compute hash of decrypted verifier
                let computedHash = Data(SHA512.hash(data: decryptedVerifier))

                // Compare first 64 bytes (SHA-512 = 64 bytes)
                let expectedHash = decryptedHash.prefix(64)
                let actualHash = computedHash.prefix(64)

                if expectedHash != actualHash {
                    AppLogger.debug("Verifier hash mismatch - wrong password", logger: AppLogger.docx)
                    throw EncryptionError.decryptionFailed
                }

                AppLogger.debug("Password verification successful", logger: AppLogger.docx)
            }
            try Task.checkCancellation()
            progress?(OperationProgress(completedUnitCount: 3, totalUnitCount: 5, message: "Verified DOCX password"))

            // 4. Unwrap Session Key
            let keyForSessionKey = AgileEncryptionUtils.finalizeKey(
                intermediateHash: intermediateHash,
                blockKey: Data(AgileEncryptionUtils.blockKeyEncryptedKeyValue)
            )

            // IV is the salt value directly
            guard let sessionKey = AgileEncryptionUtils.decryptNoPadding(data: eSK, key: keyForSessionKey, iv: pSalt) else {
                throw EncryptionError.decryptionFailed
            }

            // 5. Decrypt Content
            guard let encryptedPackage = ole.readStream("EncryptedPackage") else {
                throw EncryptionError.oleReadFailure
            }

            try self.verifyDataIntegrity(
                encryptedPackage: encryptedPackage,
                sessionKey: sessionKey,
                contentSalt: cSalt,
                encryptedHmacKey: encryptedHmacKey,
                encryptedHmacValue: encryptedHmacValue
            )
            try Task.checkCancellation()
            progress?(OperationProgress(completedUnitCount: 4, totalUnitCount: 5, message: "Verified DOCX integrity"))

            guard let decryptedData = AgileEncryptionUtils.decryptAgileContent(data: encryptedPackage, key: sessionKey, salt: cSalt) else {
                throw EncryptionError.decryptionFailed
            }
            try Task.checkCancellation()
            progress?(OperationProgress(completedUnitCount: 5, totalUnitCount: 5, message: docxFile.lastPathComponent))

            return decryptedData
        }.value
    }

    private func verifyDataIntegrity(
        encryptedPackage: Data,
        sessionKey: Data,
        contentSalt: Data,
        encryptedHmacKey: Data,
        encryptedHmacValue: Data
    ) throws {
        let ivHmacKeyHash = SHA512.hash(data: contentSalt + Data(AgileEncryptionUtils.blockKeyDataIntegrity1))
        let ivHmacKey = Data(ivHmacKeyHash).prefix(16)
        let ivHmacValueHash = SHA512.hash(data: contentSalt + Data(AgileEncryptionUtils.blockKeyDataIntegrity2))
        let ivHmacValue = Data(ivHmacValueHash).prefix(16)

        guard let hmacKey = AgileEncryptionUtils.decryptNoPadding(data: encryptedHmacKey, key: sessionKey, iv: ivHmacKey),
              let expectedHmac = AgileEncryptionUtils.decryptNoPadding(data: encryptedHmacValue, key: sessionKey, iv: ivHmacValue) else {
            throw EncryptionError.decryptionFailed
        }

        let actualHmac = AgileEncryptionUtils.hmac(data: encryptedPackage, key: hmacKey)
        guard Self.constantTimeEqual(actualHmac, expectedHmac) else {
            AppLogger.warning("DOCX data integrity HMAC mismatch", logger: AppLogger.docx)
            throw EncryptionError.decryptionFailed
        }
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            diff |= left ^ right
        }
        return diff == 0
    }

    // MARK: - Helper Methods

    private func generateRandomBytes(size: Int = 16) throws -> Data {
        var bytes = Data(count: size)
        let result = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, size, $0.baseAddress!)
        }
        guard result == errSecSuccess else {
            AppLogger.error("RNG Failed with code: \(result)", logger: AppLogger.docx)
            throw MarcryptError.internalError("Secure random number generation failed (code: \(result))")
        }
        return bytes
    }

    private static func validateInMemorySize(url: URL) throws {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= maxSupportedDocumentBytes else {
            throw MarcryptError.internalError("DOCX is too large for the public beta encryption path. Maximum supported size is 256 MB until streaming DOCX encryption is available.")
        }
    }

    private func generateAgileXML(contentSalt: Data, passwordSalt: Data, encVerifier: Data, encVerifierHash: Data, encSessionKey: Data, encHmacKey: Data, encHmacValue: Data) throws -> Data {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <encryption xmlns="http://schemas.microsoft.com/office/2006/encryption" xmlns:p="http://schemas.microsoft.com/office/2006/keyEncryptor/password" xmlns:c="http://schemas.microsoft.com/office/2006/keyEncryptor/certificate">
          <keyData saltSize="16" blockSize="16" keyBits="256" hashSize="64" cipherAlgorithm="AES" cipherChaining="ChainingModeCBC" hashAlgorithm="SHA512" saltValue="\(contentSalt.base64EncodedString())"/>
          <dataIntegrity encryptedHmacKey="\(encHmacKey.base64EncodedString())" encryptedHmacValue="\(encHmacValue.base64EncodedString())"/>
          <keyEncryptors>
            <keyEncryptor uri="http://schemas.microsoft.com/office/2006/keyEncryptor/password">
              <p:encryptedKey spinCount="100000" saltSize="16" blockSize="16" keyBits="256" hashSize="64" cipherAlgorithm="AES" cipherChaining="ChainingModeCBC" hashAlgorithm="SHA512" saltValue="\(passwordSalt.base64EncodedString())" encryptedVerifierHashInput="\(encVerifier.base64EncodedString())" encryptedVerifierHashValue="\(encVerifierHash.base64EncodedString())" encryptedKeyValue="\(encSessionKey.base64EncodedString())"/>
            </keyEncryptor>
          </keyEncryptors>
        </encryption>
        """

        var data = Data(encryptionInfoHeader)
        if let xmlData = xml.data(using: .utf8) {
            data.append(xmlData)
        }
        return data
    }

    /// Detect whether a DOCX file is encrypted using MS-OFFCRYPTO / Agile.
    /// Encrypted DOCX files are OLE compound documents with encryption streams.
    public static func isDocxEncrypted(at url: URL) -> Bool {
        let ole = OLEHelper()
        guard ole.openFile(atPath: url.path) else { return false }
        defer { ole.close() }
        return ole.streamExists("EncryptionInfo") ||
               ole.streamExists("EncryptedPackage") ||
               ole.streamExists("\u{06}EncryptionInfo")
    }

}

public enum EncryptionError: Error, LocalizedError {
    case keyDerivationFailed
    case encryptionFailed
    case decryptionFailed
    case oleCreationFailure
    case oleWriteFailure
    case oleReadFailure
    case corruptedFile

    public var errorDescription: String? {
        switch self {
        case .keyDerivationFailed: return "Failed to generate keys from password."
        case .encryptionFailed: return "Encryption engine error."
        case .decryptionFailed: return "Wrong password or file not encrypted with Marcrypt."
        case .oleReadFailure: return "Could not read the Word archive structure."
        case .corruptedFile: return "The file structure appears to be corrupted."
        default: return "A technical error occurred during processing."
        }
    }
}

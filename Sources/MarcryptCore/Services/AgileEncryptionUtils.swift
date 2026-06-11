import Foundation
import CryptoKit
import CommonCrypto

/// Utilities for ECMA-376 Agile Encryption (MS-OFFCRYPTO 2.3.4)
public enum AgileEncryptionUtils {
    
    struct Keys {
        let key: Data
        let iv: Data
        let hmacKey: Data
    }
    
    // Constants from MS-OFFCRYPTO 2.3.4.11 / 2.3.4.12
    public static let blockKeyConstant: [UInt8] = [0x14, 0x6e, 0x0b, 0x77, 0x47, 0xad, 0x12, 0x31]
    static let blockIvConstant: [UInt8]  = [0x36, 0xf0, 0x49, 0x1b, 0x4a, 0x22, 0x00, 0xf6]
    static let blockVerifierConstant: [UInt8] = [0x2c, 0x0e, 0x43, 0x39, 0x53, 0x50, 0x2a, 0x32]
    
    // MS-OFFCRYPTO Block Key Constants for p:encryptedKey element (2.3.4.13)
    // These must match the msoffcrypto-tool Python reference implementation
    public static let blockKeyEncryptedKeyValue: [UInt8] = [0x14, 0x6E, 0x0B, 0xE7, 0xAB, 0xAC, 0xD0, 0xD6]
    public static let blockKeyEncryptedVerifierHashInput: [UInt8] = [0xFE, 0xA7, 0xD2, 0x76, 0x3B, 0x4B, 0x9E, 0x79]
    public static let blockKeyEncryptedVerifierHashValue: [UInt8] = [0xD7, 0xAA, 0x0F, 0x6D, 0x30, 0x61, 0x34, 0x4E]
    
    // Data Integrity block keys (for HMAC)
    public static let blockKeyDataIntegrity1: [UInt8] = [0x5F, 0xB2, 0xAD, 0x01, 0x0C, 0xB9, 0xE1, 0xF6]
    public static let blockKeyDataIntegrity2: [UInt8] = [0xA0, 0x67, 0x7F, 0x02, 0xB2, 0x2C, 0x84, 0x33]
    
    /// Derives the intermediate (Session) Key or other block keys from a master key.
    /// MS-OFFCRYPTO 2.3.4.11
    public static func deriveBlockKey(masterKey: Data, blockConstant: Data, keyBits: Int) -> Data {
        let hash = SHA512.hash(data: masterKey + blockConstant)
        let fullDigest = Data(hash)
        return fullDigest.prefix(keyBits / 8)
    }

    /// Derives an IV for an XML element using the specialized Verifier/Integrity constant.
    /// MS-OFFCRYPTO 2.3.4.12
    public static func deriveAgileIV(salt: Data, keyBits: Int = 128) -> Data {
        let hash = SHA512.hash(data: salt + Data(blockVerifierConstant))
        return Data(hash).prefix(keyBits / 8)
    }
    
    /// Derives the Password Key (KEK) using MS-OFFCRYPTO 2.3.4.11 iterative SHA-512.
    /// This is NOT PBKDF2. The algorithm is:
    /// 1. H0 = SHA-512(salt + password_utf16le)
    /// 2. For i = 0 to spinCount-1: H(i+1) = SHA-512(i_bytes_le + H(i))
    /// 3. H_final = SHA-512(H_spinCount + blockKey)
    /// 4. derivedKey = first keyBits/8 bytes of H_final
    public static func derivePasswordKey(password: String, salt: Data, spinCount: Int = 100_000, keyBits: Int = 256, blockKey: Data) -> Data? {
        guard let intermediateHash = deriveIteratedHash(password: password, salt: salt, spinCount: spinCount) else {
            return nil
        }
        return finalizeKey(intermediateHash: intermediateHash, blockKey: blockKey, keyBits: keyBits)
    }
    
    /// Derives the intermediate hash from password (steps 1-2 of MS-OFFCRYPTO 2.3.4.11).
    /// This intermediate hash can be reused to derive multiple keys with different block constants.
    public static func deriveIteratedHash(password: String, salt: Data, spinCount: Int = 100_000) -> Data? {
        guard let passwordData = password.data(using: .utf16LittleEndian) else { return nil }
        
        // Step 1: H0 = SHA-512(salt + password)
        var hash = Data(SHA512.hash(data: salt + passwordData))
        
        // Step 2: Iterate spinCount times
        for i in 0..<spinCount {
            var iBytes = UInt32(i).littleEndian
            let iteratorData = Data(bytes: &iBytes, count: 4)
            hash = Data(SHA512.hash(data: iteratorData + hash))
        }
        
        return hash
    }
    
    /// Finalizes key derivation with a block key constant (step 3-4 of MS-OFFCRYPTO 2.3.4.11).
    public static func finalizeKey(intermediateHash: Data, blockKey: Data, keyBits: Int = 256) -> Data {
        let finalHash = Data(SHA512.hash(data: intermediateHash + blockKey))
        return finalHash.prefix(keyBits / 8)
    }

    /// Full key derivation for a password-based encryptor.
    static func deriveKeys(password: String, salt: Data, keyBits: Int = 256) -> Keys? {
        guard let passwordData = password.data(using: .utf16LittleEndian) else { return nil }
        let iterCount = 100_000
        let masterKey = pbkdf2(password: passwordData, salt: salt, iterations: iterCount, keyLength: 64)
        
        let finalKey = deriveBlockKey(masterKey: masterKey, blockConstant: Data(blockKeyConstant), keyBits: keyBits)
        let finalIV  = deriveBlockKey(masterKey: masterKey, blockConstant: Data(blockIvConstant), keyBits: 128)
        let finalHmac = deriveBlockKey(masterKey: masterKey, blockConstant: Data(blockKeyDataIntegrity1), keyBits: 512)
        
        return Keys(key: finalKey, iv: finalIV, hmacKey: finalHmac)
    }
    
    // Wrapper for CC_KeyDerivationPBKDF
    static func pbkdf2(password: Data, salt: Data, iterations: Int, keyLength: Int) -> Data {
        var derivedKey = Data(count: keyLength)
        let result = derivedKey.withUnsafeMutableBytes { derivedKeyBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress, password.count,
                        saltBytes.baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
                        UInt32(iterations),
                        derivedKeyBytes.baseAddress, keyLength
                    )
                }
            }
        }
        return result == kCCSuccess ? derivedKey : Data()
    }
    
    // MARK: - Agile Content Encryption (Block-Based)
    
    /// Encrypts content using Agile block-based encryption (4096-byte blocks).
    /// MS-OFFCRYPTO 2.3.4.15
    public static func encryptAgileContent(data: Data, key: Data, salt: Data) -> Data? {
        let blockSize = 4096
        var result = Data()
        
        // 8-byte plaintext length prefix (little-endian)
        var length = UInt64(data.count).littleEndian
        result.append(Data(bytes: &length, count: 8))
        
        var offset = 0
        var blockIndex: UInt32 = 0
        
        while offset < data.count {
            let chunkEnd = min(offset + blockSize, data.count)
            var chunk = data.subdata(in: offset..<chunkEnd)
            
            // Agile Padding: MS-OFFCRYPTO 2.3.4.15
            // "The last segment MUST be padded ... to the next integral multiple of the KeyData.blockSize."
            // For AES-CBC, we pad to 16 bytes.
            // UNLIKE PKCS7, the value of padding bytes is not specified (since length prefix handles size).
            // We use 0x00 for strict alignment.
            
            let isLastBlock = (offset + blockSize >= data.count)
            if isLastBlock {
                let remainder = chunk.count % 16
                if remainder != 0 {
                    let paddingCount = 16 - remainder
                    chunk.append(Data(repeating: 0x00, count: paddingCount))
                }
            }
            
            // Derive per-block IV: H(salt + blockIndex)
            var blockBytes = blockIndex.littleEndian
            let blockData = Data(bytes: &blockBytes, count: 4)
            let ivHash = SHA512.hash(data: salt + blockData)
            let iv = Data(ivHash).prefix(16)
            
            guard let encrypted = encryptNoPadding(data: chunk, key: key, iv: iv) else {
                return nil
            }
            
            result.append(encrypted)
            offset += blockSize
            blockIndex += 1
        }
        
        return result
    }
    
    /// Decrypts Agile content encrypted with block-based encryption.
    public static func decryptAgileContent(data: Data, key: Data, salt: Data) -> Data? {
        guard data.count > 8 else { return nil }
        
        let lengthData = data.subdata(in: 0..<8)
        let originalLength = Int(lengthData.withUnsafeBytes { $0.load(as: UInt64.self).littleEndian })
        
        let ciphertext = data.subdata(in: 8..<data.count)
        let blockSize = 4096
        var result = Data()
        
        var offset = 0
        var blockIndex: UInt32 = 0
        
        while offset < ciphertext.count {
            let chunkEnd = min(offset + blockSize, ciphertext.count)
            let chunk = ciphertext.subdata(in: offset..<chunkEnd)
            
            var blockBytes = blockIndex.littleEndian
            let blockData = Data(bytes: &blockBytes, count: 4)
            let ivHash = SHA512.hash(data: salt + blockData)
            let iv = Data(ivHash).prefix(16)
            
            guard let decrypted = decryptNoPadding(data: chunk, key: key, iv: iv) else {
                return nil
            }
            
            result.append(decrypted)
            offset += blockSize
            blockIndex += 1
        }
        
        // Truncate to original length (removes any 0x00 or random padding bytes)
        if originalLength <= result.count {
            return result.prefix(originalLength)
        } else {
            return nil // Error: metadata length > actual decrypted data
        }
    }
    
    // MARK: - Low-Level Crypto Wrappers
    
    public static func encrypt(data: Data, key: Data, iv: Data) -> Data? {
        let bufferSize = data.count + kCCBlockSizeAES128
        var buffer = Data(count: bufferSize)
        var numBytesEncrypted: size_t = 0
        
        let result = buffer.withUnsafeMutableBytes { bufferBytes in
            data.withUnsafeBytes { dataBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            dataBytes.baseAddress, data.count,
                            bufferBytes.baseAddress, bufferSize,
                            &numBytesEncrypted
                        )
                    }
                }
            }
        }
        
        return result == kCCSuccess ? buffer.prefix(Int(numBytesEncrypted)) : nil
    }
    
    public static func decrypt(data: Data, key: Data, iv: Data) -> Data? {
        let bufferSize = data.count + kCCBlockSizeAES128
        var buffer = Data(count: bufferSize)
        var numBytesDecrypted: size_t = 0
        
        let result = buffer.withUnsafeMutableBytes { bufferBytes in
            data.withUnsafeBytes { dataBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            dataBytes.baseAddress, data.count,
                            bufferBytes.baseAddress, bufferSize,
                            &numBytesDecrypted
                        )
                    }
                }
            }
        }
        
        return result == kCCSuccess ? buffer.prefix(Int(numBytesDecrypted)) : nil
    }

    public static func encryptNoPadding(data: Data, key: Data, iv: Data) -> Data? {
        var buffer = Data(count: data.count)
        var numBytesEncrypted: size_t = 0
        let result = buffer.withUnsafeMutableBytes { bufferBytes in
            data.withUnsafeBytes { dataBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(0),
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            dataBytes.baseAddress, data.count,
                            bufferBytes.baseAddress, data.count,
                            &numBytesEncrypted
                        )
                    }
                }
            }
        }
        return result == kCCSuccess ? buffer.prefix(Int(numBytesEncrypted)) : nil
    }
    
    public static func decryptNoPadding(data: Data, key: Data, iv: Data) -> Data? {
        var buffer = Data(count: data.count)
        var numBytesDecrypted: size_t = 0
        let result = buffer.withUnsafeMutableBytes { bufferBytes in
            data.withUnsafeBytes { dataBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(0),
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            dataBytes.baseAddress, data.count,
                            bufferBytes.baseAddress, data.count,
                            &numBytesDecrypted
                        )
                    }
                }
            }
        }
        return result == kCCSuccess ? buffer.prefix(Int(numBytesDecrypted)) : nil
    }
    
    public static func hmac(data: Data, key: Data) -> Data {
        let key = SymmetricKey(data: key)
        let authenticationCode = HMAC<SHA512>.authenticationCode(for: data, using: key)
        return Data(authenticationCode)
    }
}

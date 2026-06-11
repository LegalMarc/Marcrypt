#include "PasswordCracker.hpp"
#include <CommonCrypto/CommonCrypto.h>
#include <thread>
#include <mutex>
#include <vector>
#include <algorithm>
#include <iostream>
#include <cstring>

PasswordCracker::PasswordCracker() : shouldStop(false) {}

PasswordCracker::~PasswordCracker() {
    cancel();
}

void PasswordCracker::cancel() {
    shouldStop = true;
}

// --------------------------------------------------------------------------------
// Helper Functions
// --------------------------------------------------------------------------------

static const unsigned char PDF_PADDING[] = {
    0x28, 0xBF, 0x4E, 0x5E, 0x4E, 0x75, 0x8A, 0x41,
    0x64, 0x00, 0x4E, 0x56, 0xFF, 0xFA, 0x01, 0x08,
    0x2E, 0x2E, 0x00, 0xB6, 0xD0, 0x68, 0x3E, 0x80,
    0x2F, 0x0C, 0xA9, 0xFE, 0x64, 0x53, 0x69, 0x7A
};

// PDF revisions 2-4 require MD5 as part of the ISO 32000 legacy password algorithm.
// Keep the deprecated primitive isolated here so new cryptographic code does not reuse it.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static void pdfLegacyMD5Init(CC_MD5_CTX* ctx) {
    CC_MD5_Init(ctx);
}

static void pdfLegacyMD5Update(CC_MD5_CTX* ctx, const void* data, CC_LONG length) {
    CC_MD5_Update(ctx, data, length);
}

static void pdfLegacyMD5Final(uint8_t* digest, CC_MD5_CTX* ctx) {
    CC_MD5_Final(digest, ctx);
}

static void pdfLegacyMD5(const void* data, CC_LONG length, uint8_t* digest) {
    CC_MD5(data, length, digest);
}
#pragma clang diagnostic pop

static std::vector<uint8_t> computeMD5(const std::vector<uint8_t>& data) {
    std::vector<uint8_t> digest(CC_MD5_DIGEST_LENGTH);
    pdfLegacyMD5(data.data(), (CC_LONG)data.size(), digest.data());
    return digest;
}

// RC4 Encryption/Decryption
static void rc4(const std::vector<uint8_t>& key, const uint8_t* inData, size_t len, uint8_t* outData) {
    size_t keyLen = key.size();
    if (keyLen == 0) return;
    
    CCCryptorStatus status;
    size_t moved = 0;
    
    // RC4 is a stream cipher, encrypt/decrypt are the same operation
    status = CCCrypt(kCCEncrypt, kCCAlgorithmRC4, 0,
                     key.data(), keyLen,
                     NULL,
                     inData, len,
                     outData, len,
                     &moved);
}

// Algorithm 3.2: Compute Encryption Key
static std::vector<uint8_t> computeFileKey(const std::string& password, const PdfCryptoMetadata& meta) {
    // 1. Pad Password
    std::vector<uint8_t> buf;
    buf.reserve(32);
    if (password.length() >= 32) {
        buf.assign(password.begin(), password.begin() + 32);
    } else {
        buf.assign(password.begin(), password.end());
        buf.insert(buf.end(), PDF_PADDING, PDF_PADDING + (32 - password.length()));
    }
    
    // 2. MD5 state setup
    CC_MD5_CTX ctx;
    pdfLegacyMD5Init(&ctx);
    
    // Pass Password
    pdfLegacyMD5Update(&ctx, buf.data(), (CC_LONG)buf.size());
    
    // Pass O
    pdfLegacyMD5Update(&ctx, meta.O.data(), (CC_LONG)meta.O.size());
    
    // Pass P (little-endian)
    uint32_t p = (uint32_t)meta.permissions;
    // P is usually signed 32-bit int, treating as unsigned bytes.
    // Ensure Little Endian
    uint8_t pBytes[4];
    pBytes[0] = p & 0xFF;
    pBytes[1] = (p >> 8) & 0xFF;
    pBytes[2] = (p >> 16) & 0xFF;
    pBytes[3] = (p >> 24) & 0xFF;
    pdfLegacyMD5Update(&ctx, pBytes, 4);
    
    // Pass ID (first element usually)
    pdfLegacyMD5Update(&ctx, meta.ID.data(), (CC_LONG)meta.ID.size());
    
    // (Rev 4) EncryptMetadata check
    if (meta.revision >= 4 && !meta.encryptMetadata) {
        uint8_t ones[] = {0xFF, 0xFF, 0xFF, 0xFF};
        pdfLegacyMD5Update(&ctx, ones, 4);
    }
    
    uint8_t digest[CC_MD5_DIGEST_LENGTH];
    pdfLegacyMD5Final(digest, &ctx);
    
    // (Rev 3+) Loop 50 times
    if (meta.revision >= 3) {
        for (int i = 0; i < 50; ++i) {
            pdfLegacyMD5Init(&ctx);
            pdfLegacyMD5Update(&ctx, digest, CC_MD5_DIGEST_LENGTH);
            // Technically specification says takes 16 bytes of output. Digest is 16 bytes.
            pdfLegacyMD5Final(digest, &ctx);
        }
    }
    
    // Final Key: First N/8 bytes
    size_t keyBytes = meta.keyLength / 8;
    if (keyBytes > 16) keyBytes = 16; // MD5 is 16 bytes max
    
    return std::vector<uint8_t>(digest, digest + keyBytes);
}


// --------------------------------------------------------------------------------
// Thread Routines
// --------------------------------------------------------------------------------

bool PasswordCracker::crackPdf(const std::vector<std::string>& dictionary, const PdfCryptoMetadata& metadata, std::string& outPassword) {
    shouldStop = false;
    unsigned int numThreads = std::thread::hardware_concurrency();
    if (numThreads == 0) numThreads = 4;
    // Don't spawn more threads than passwords
    if (dictionary.size() < numThreads) numThreads = (unsigned int)dictionary.size();
    if (numThreads == 0) numThreads = 1;

    std::mutex resultMutex;
    std::atomic<bool> found(false);
    std::string foundPwd;
    
    size_t total = dictionary.size();
    size_t chunkSize = (total + numThreads - 1) / numThreads;
    
    std::vector<std::thread> threads;
    
    // Pre-calculate expensive items if possible? (No, depends on password)
    
    for (unsigned int t = 0; t < numThreads; ++t) {
        threads.emplace_back([&, t]() {
            size_t start = t * chunkSize;
            size_t end = std::min(start + chunkSize, total);
            
            for (size_t i = start; i < end; ++i) {
                if (shouldStop || found) return;
                
                if (checkPdfPassword(dictionary[i], metadata)) {
                    std::lock_guard<std::mutex> lock(resultMutex);
                    if (!found) { // Double check
                        found = true;
                        foundPwd = dictionary[i];
                        shouldStop = true;
                    }
                }
            }
        });
    }
    
    for (auto& t : threads) {
        if (t.joinable()) t.join();
    }
    
    if (found) {
        outPassword = foundPwd;
        return true;
    }
    return false;
}

// This module implements PDF password recovery only; ZIP and DOCX are handled elsewhere.
bool PasswordCracker::crackZip(const std::vector<std::string>& dictionary, const ZipCryptoMetadata& metadata, std::string& outPassword) {
    return false; 
}

bool PasswordCracker::crackDocx(const std::vector<std::string>& dictionary, const DocxCryptoMetadata& metadata, std::string& outPassword) {
    return false;
}


// --------------------------------------------------------------------------------
// Verification Logic
// --------------------------------------------------------------------------------

bool PasswordCracker::checkPdfPassword(const std::string& password, const PdfCryptoMetadata& meta) {
    if (meta.revision == 5 || meta.revision == 6) {
        // AES-256 revisions are handled by the higher-level services, not this path.
        return false; 
    }
    
    // Algorithm 3.2: Generate File Encryption Key
    std::vector<uint8_t> key = computeFileKey(password, meta);
    
    // Algorithm 3.4/3.5: Authenticate User Password
    if (meta.revision == 2) {
        // Rev 2: RC4(key, padding) should equal U
        std::vector<uint8_t> result(32);
        rc4(key, PDF_PADDING, 32, result.data());
        
        // Compare with meta.U (first 32 bytes)
        if (meta.U.size() < 32) return false;
        
        return std::memcmp(result.data(), meta.U.data(), 32) == 0;
    } 
    else if (meta.revision >= 3) {
        // Rev 3+:
        // 1. MD5(padding + ID)
        CC_MD5_CTX ctx;
        pdfLegacyMD5Init(&ctx);
        pdfLegacyMD5Update(&ctx, PDF_PADDING, 32);
        pdfLegacyMD5Update(&ctx, meta.ID.data(), (CC_LONG)meta.ID.size());
        uint8_t hash[16];
        pdfLegacyMD5Final(hash, &ctx);
        
        // 2. RC4(key, hash)
        // Note: For Rev 3 loops, we mutate key or hash?
        // Alg 3.5 Step 4:
        // RC4(key, hash) -> output. (16 bytes)
        // Then loop 19 times.
        
        std::vector<uint8_t> tempKey = key; // Copy key
        std::vector<uint8_t> output(16);
        std::vector<uint8_t> input(hash, hash+16);
        
        rc4(tempKey, input.data(), 16, output.data());
        
        // Loop 1..19
        for (int i = 1; i <= 19; ++i) {
            // New key is XOR of original key
            std::vector<uint8_t> roundKey = key;
            for (size_t j = 0; j < roundKey.size(); ++j) {
                roundKey[j] ^= i;
            }
            std::vector<uint8_t> roundInput = output;
            rc4(roundKey, roundInput.data(), 16, output.data());
        }
        
        // Compare first 16 bytes of U with output
        if (meta.U.size() < 16) return false;
        
        return std::memcmp(output.data(), meta.U.data(), 16) == 0;
    }
    
    return false;
}

bool PasswordCracker::checkZipPassword(const std::string& password, const ZipCryptoMetadata& metadata) {
    return false;
}

bool PasswordCracker::checkDocxPassword(const std::string& password, const DocxCryptoMetadata& metadata) {
    return false;
}

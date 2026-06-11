#pragma once

#include <vector>
#include <string>
#include <cstdint>
#include <atomic>

struct PdfCryptoMetadata {
    int revision;       // Standard Security Handler Revision (2, 3, 4, 5, 6)
    int keyLength;      // Key length in bits (e.g. 128, 256)
    int permissions;    // P value
    bool encryptMetadata;
    
    std::vector<uint8_t> O; // Owner Key / Hash (32 or 48 bytes)
    std::vector<uint8_t> U; // User Key / Hash (32 or 48 bytes)
    std::vector<uint8_t> ID; // File ID (usually 16 or 32 bytes)
    
    // For R5/R6 (AES-256) specifically
    std::vector<uint8_t> UE; // User Encrypt Key (32 bytes)
    std::vector<uint8_t> OE; // Owner Encrypt Key (32 bytes)
    std::vector<uint8_t> Perms; // Perms (16 bytes)
};

struct ZipCryptoMetadata {
    // Basic Zip AES metadata
    int keyLength; // 128, 192, 256
    std::vector<uint8_t> salt;
    std::vector<uint8_t> validationVerifier; // 2 bytes
};

struct DocxCryptoMetadata {
    // ECMA-376 Standard Encryption
    int keyLength;
    std::vector<uint8_t> salt;
    std::vector<uint8_t> encryptedVerifier;
    std::vector<uint8_t> encryptedVerifierHash;
    std::string algorithm; // SHA1, SHA256, etc.
};

class PasswordCracker {
public:
    PasswordCracker();
    ~PasswordCracker();

    // Crack PDF Password
    bool crackPdf(const std::vector<std::string>& dictionary, const PdfCryptoMetadata& metadata, std::string& outPassword);
    
    // Crack Zip Password (WinZip AES)
    bool crackZip(const std::vector<std::string>& dictionary, const ZipCryptoMetadata& metadata, std::string& outPassword);
    
    // Crack Docx Password (Standard Encryption)
    bool crackDocx(const std::vector<std::string>& dictionary, const DocxCryptoMetadata& metadata, std::string& outPassword);

    // Cancel current operation
    void cancel();

private:
    std::atomic<bool> shouldStop;

    bool checkPdfPassword(const std::string& password, const PdfCryptoMetadata& metadata);
    bool checkZipPassword(const std::string& password, const ZipCryptoMetadata& metadata);
    bool checkDocxPassword(const std::string& password, const DocxCryptoMetadata& metadata);
};

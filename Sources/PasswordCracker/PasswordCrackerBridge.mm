#import "PasswordCracker.h"

#include "PasswordCracker.hpp"

#import <CoreGraphics/CoreGraphics.h>

@implementation MCTZipCryptoMetadata
@end

@implementation MCTDocxCryptoMetadata
@end


@implementation PasswordCrackerBridge {
    PasswordCracker *_cracker;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _cracker = new PasswordCracker();
    }
    return self;
}

- (void)dealloc {
    delete _cracker;
}

static NSData * getDataFromDict(CGPDFDictionaryRef dict, const char *key) {
    CGPDFStringRef str;
    if (CGPDFDictionaryGetString(dict, key, &str)) {
        const unsigned char *ptr = CGPDFStringGetBytePtr(str);
        size_t len = CGPDFStringGetLength(str);
        return [NSData dataWithBytes:ptr length:len];
    }
    return nil;
}

- (nullable NSString *)crackPdfWithPasswords:(NSArray<NSString *> *)passwords fileURL:(NSURL *)url {
    if (!url) return nil;
    
    CGPDFDocumentRef doc = CGPDFDocumentCreateWithURL((__bridge CFURLRef)url);
    if (!doc) return nil;
    
    CGPDFDictionaryRef catalog = CGPDFDocumentGetCatalog(doc);
    if (!catalog) {
        CGPDFDocumentRelease(doc);
        return nil;
    }
    
    CGPDFDictionaryRef encryptDict = NULL;
    if (!CGPDFDictionaryGetDictionary(catalog, "Encrypt", &encryptDict)) {
        // Encrypt entry not found or not a dictionary -> Not encrypted
         CGPDFDocumentRelease(doc);
         return nil;
    }
    
    // Prepare C++ Metadata
    PdfCryptoMetadata cppMetadata;
    
    // Parse Dictionary
    CGPDFInteger val;
    if (CGPDFDictionaryGetInteger(encryptDict, "R", &val)) cppMetadata.revision = (int)val;
    if (CGPDFDictionaryGetInteger(encryptDict, "P", &val)) cppMetadata.permissions = (int)val;
    if (CGPDFDictionaryGetInteger(encryptDict, "Length", &val)) cppMetadata.keyLength = (int)val;
    
    CGPDFBoolean boolVal;
    if (CGPDFDictionaryGetBoolean(encryptDict, "EncryptMetadata", &boolVal)) {
        cppMetadata.encryptMetadata = (boolVal != 0);
    } else {
        cppMetadata.encryptMetadata = true;
    }
    
    // O and U
    auto dataToVec = [](NSData *data) -> std::vector<uint8_t> {
        if (!data || data.length == 0) return {};
        const uint8_t *bytes = (const uint8_t *)data.bytes;
        return std::vector<uint8_t>(bytes, bytes + data.length);
    };
    
    cppMetadata.O = dataToVec(getDataFromDict(encryptDict, "O"));
    cppMetadata.U = dataToVec(getDataFromDict(encryptDict, "U"));
    
    // File ID
    CGPDFArrayRef idArray = CGPDFDocumentGetID(doc);
    if (idArray && CGPDFArrayGetCount(idArray) > 0) {
        CGPDFStringRef str;
        if (CGPDFArrayGetString(idArray, 0, &str)) {
            const unsigned char *ptr = CGPDFStringGetBytePtr(str);
            size_t len = CGPDFStringGetLength(str);
            cppMetadata.ID = std::vector<uint8_t>(ptr, ptr + len);
        }
    }
    
    if (cppMetadata.revision >= 5) {
        cppMetadata.UE = dataToVec(getDataFromDict(encryptDict, "UE"));
        cppMetadata.OE = dataToVec(getDataFromDict(encryptDict, "OE"));
        cppMetadata.Perms = dataToVec(getDataFromDict(encryptDict, "Perms"));
    }
    
    CGPDFDocumentRelease(doc);
    
    // Convert passwords
    std::vector<std::string> cppPasswords;
    cppPasswords.reserve(passwords.count);
    for (NSString *pwd in passwords) {
        if (pwd) {
            cppPasswords.push_back([pwd UTF8String]);
        }
    }
    
    std::string result;
    bool found = _cracker->crackPdf(cppPasswords, cppMetadata, result);
    
    if (found) {
        return [NSString stringWithUTF8String:result.c_str()];
    }
    
    return nil;
}

- (nullable NSString *)crackZipWithPasswords:(NSArray<NSString *> *)passwords metadata:(MCTZipCryptoMetadata *)metadata {
    // Convert passwords
    std::vector<std::string> cppPasswords;
    cppPasswords.reserve(passwords.count);
    for (NSString *pwd in passwords) {
        if (pwd) cppPasswords.push_back([pwd UTF8String]);
    }
    
    ZipCryptoMetadata cppMetadata;
    cppMetadata.keyLength = (int)metadata.keyLength;
    
    auto dataToVec = [](NSData *data) -> std::vector<uint8_t> {
        if (!data || data.length == 0) return {};
        const uint8_t *bytes = (const uint8_t *)data.bytes;
        return std::vector<uint8_t>(bytes, bytes + data.length);
    };
    
    cppMetadata.salt = dataToVec(metadata.salt);
    cppMetadata.validationVerifier = dataToVec(metadata.validationVerifier);
    
    std::string result;
    bool found = _cracker->crackZip(cppPasswords, cppMetadata, result);
    
    if (found) {
        return [NSString stringWithUTF8String:result.c_str()];
    }
    return nil;
}

- (nullable NSString *)crackDocxWithPasswords:(NSArray<NSString *> *)passwords metadata:(MCTDocxCryptoMetadata *)metadata {
    // Convert passwords
    std::vector<std::string> cppPasswords;
    cppPasswords.reserve(passwords.count);
    for (NSString *pwd in passwords) {
        if (pwd) cppPasswords.push_back([pwd UTF8String]);
    }
    
    DocxCryptoMetadata cppMetadata;
    cppMetadata.keyLength = (int)metadata.keyLength;
    
    auto dataToVec = [](NSData *data) -> std::vector<uint8_t> {
        if (!data || data.length == 0) return {};
        const uint8_t *bytes = (const uint8_t *)data.bytes;
        return std::vector<uint8_t>(bytes, bytes + data.length);
    };
    
    cppMetadata.salt = dataToVec(metadata.salt);
    cppMetadata.encryptedVerifier = dataToVec(metadata.encryptedVerifier);
    cppMetadata.encryptedVerifierHash = dataToVec(metadata.encryptedVerifierHash);
    if (metadata.algorithm) {
        cppMetadata.algorithm = [metadata.algorithm UTF8String];
    }
    
    std::string result;
    bool found = _cracker->crackDocx(cppPasswords, cppMetadata, result);
    
    if (found) {
        return [NSString stringWithUTF8String:result.c_str()];
    }
    return nil;
}


- (void)cancel {
    _cracker->cancel();
}

@end

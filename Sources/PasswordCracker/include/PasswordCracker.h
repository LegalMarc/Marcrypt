#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN


@interface MCTZipCryptoMetadata : NSObject
@property (nonatomic, assign) NSInteger keyLength;
@property (nonatomic, strong) NSData *salt;
@property (nonatomic, strong) NSData *validationVerifier;
@end

@interface MCTDocxCryptoMetadata : NSObject
@property (nonatomic, assign) NSInteger keyLength;
@property (nonatomic, strong) NSData *salt;
@property (nonatomic, strong) NSData *encryptedVerifier;
@property (nonatomic, strong) NSData *encryptedVerifierHash;
@property (nonatomic, strong) NSString *algorithm;
@end

@interface PasswordCrackerBridge : NSObject

// Returns the found password or nil if not found.
// Call this from a background queue in Swift, as it will block until done.
- (nullable NSString *)crackPdfWithPasswords:(NSArray<NSString *> *)passwords 
                                     fileURL:(NSURL *)url;

- (nullable NSString *)crackZipWithPasswords:(NSArray<NSString *> *)passwords 
                                    metadata:(MCTZipCryptoMetadata *)metadata;

- (nullable NSString *)crackDocxWithPasswords:(NSArray<NSString *> *)passwords 
                                     metadata:(MCTDocxCryptoMetadata *)metadata;

- (void)cancel;

@end

NS_ASSUME_NONNULL_END

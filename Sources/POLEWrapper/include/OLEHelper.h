#import <Foundation/Foundation.h>

@interface OLEHelper : NSObject

/// Create a new OLE file at the specified path.
/// Returns YES on success.
- (BOOL)createFileAtPath:(NSString *)path;

/// Write data to a stream with the given name.
/// The file must be open.
- (BOOL)writeStream:(NSString *)streamName data:(NSData *)data;

/// Open an existing OLE file at the specified path for reading.
- (BOOL)openFileAtPath:(NSString *)path;

/// Read data from a stream with the given name.
/// The file must be open.
- (NSData *)readStream:(NSString *)streamName;

/// Check if a named stream exists in the OLE file without reading its data.
/// The file must be open.
- (BOOL)streamExists:(NSString *)streamName;

/// Returns all stream names in the storage.
/// The file must be open.
- (NSArray<NSString *> *)allStreamNames;

/// Close the OLE file.
- (void)close;

@end

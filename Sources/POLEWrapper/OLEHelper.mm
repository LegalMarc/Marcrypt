#import "OLEHelper.h"
#include "pole.h"
#include <fstream>

@implementation OLEHelper {
    POLE::Storage *_storage;
}

- (BOOL)createFileAtPath:(NSString *)path {
    try {
        [self close]; // Ensure any previous file is closed
        
        // Create new storage instance
        _storage = new POLE::Storage([path UTF8String]);
        
        // Open with write access (true) and create mode (true)
        if (!_storage->open(true, true)) {
            delete _storage;
            _storage = NULL;
            return NO;
        }
        
        return YES;
    } catch (...) {
        if (_storage) {
            delete _storage;
            _storage = NULL;
        }
        return NO;
    }
}
- (BOOL)openFileAtPath:(NSString *)path {
    try {
        [self close];
        _storage = new POLE::Storage([path UTF8String]);
        // Open for reading (false = write mode off, false = create off)
        if (!_storage->open(false, false)) {
            delete _storage;
            _storage = NULL;
            return NO;
        }
        return YES;
    } catch (...) {
        if (_storage) {
            delete _storage;
            _storage = NULL;
        }
        return NO;
    }
}

- (NSData *)readStream:(NSString *)streamName {
    if (!_storage) return nil;
    
    try {
        std::string name = [streamName UTF8String];
        
        // Open stream: storage, name, create=false
        POLE::Stream stream(_storage, name, false);
        if (stream.fail()) return nil;
        
        uint64_t size = stream.size();
        if (size == 0) return [NSData data];
        
        NSMutableData *data = [NSMutableData dataWithLength:size];
        unsigned char *bytes = (unsigned char *)[data mutableBytes];
        uint64_t read = stream.read(bytes, size);
        
        if (read != size) return nil;
        return data;
    } catch (...) {
        return nil;
    }
}

- (BOOL)writeStream:(NSString *)streamName data:(NSData *)data {
    if (!_storage) return NO;
    
    try {
        std::string name = [streamName UTF8String];
        
        // Create stream: storage, name, create=true, size=data.length
        POLE::Stream stream(_storage, name, true, [data length]);
        
        if (stream.fail()) return NO;
        
        // Write data
        unsigned char *bytes = (unsigned char *)[data bytes];
        uint64_t written = stream.write(bytes, [data length]);
        
        stream.flush();
        // Stream destructor automatically handles closing the stream handle
        
        return written == [data length];
    } catch (...) {
        return NO;
    }
}

- (BOOL)streamExists:(NSString *)streamName {
    if (!_storage) return NO;
    
    try {
        std::string name = [streamName UTF8String];
        POLE::Stream stream(_storage, name, false);
        return !stream.fail();
    } catch (...) {
        return NO;
    }
}

- (NSArray<NSString *> *)allStreamNames {
    if (!_storage) return @[];

    try {
        std::list<std::string> names = _storage->GetAllStreams("/");
        if (names.empty()) {
            names = _storage->GetAllStreams("");
        }
        NSMutableArray<NSString *> *result = [NSMutableArray arrayWithCapacity:static_cast<NSUInteger>(names.size())];
        for (const auto& name : names) {
            [result addObject:[NSString stringWithUTF8String:name.c_str()]];
        }
        return result;
    } catch (...) {
        return @[];
    }
}

- (void)close {
    try {
        if (_storage) {
            _storage->flush(); // Ensure header and BAT are written
            _storage->close();
            delete _storage;
            _storage = NULL;
        }
    } catch (...) {
        // Best effort cleanup, just nullify
        _storage = NULL;
    }
}

- (void)dealloc {
    [self close];
}

@end

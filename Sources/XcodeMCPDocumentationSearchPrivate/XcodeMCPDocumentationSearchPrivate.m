#import "XcodeMCPDocumentationSearchPrivate.h"

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <stdint.h>

@interface MADTextInput : NSObject
- (instancetype)initWithText:(NSString *)text;
@end

@interface MADTextEmbeddingRequest : NSObject
@property(nonatomic) unsigned long long version;
@property(nonatomic) BOOL extendedContextLength;
@property(nonatomic) BOOL allowTruncation;
@property(readonly, nonatomic) NSArray *embeddingResults;
@end

@interface MADService : NSObject
+ (instancetype)service;
- (int)performRequests:(NSArray *)requests
            textInputs:(NSArray *)textInputs
     completionHandler:(void (^)(void))handler;
@end

@interface VSKConfig : NSObject
- (instancetype)initWithBaseDirectory:(NSURL *)url
                             readOnly:(BOOL)readOnly
              perConnectionPeakMemory:(NSNumber *)memory
                                error:(NSError **)error;
@end

@interface VSKClient : NSObject
- (instancetype)initWithConfig:(VSKConfig *)config error:(NSError **)error;
- (NSArray *)searchByVector:(NSData *)vector
           attributeFilters:(NSArray *)filters
                      limit:(int)limit
             includePayload:(BOOL)includePayload
             numberOfProbes:(NSNumber *)numberOfProbes
                  batchSize:(NSNumber *)batchSize
       numConcurrentReaders:(NSNumber *)numConcurrentReaders
                      error:(NSError **)error;
@end

static NSString *XCDocStringFromCString(const char *value) {
    if (value == NULL) {
        return nil;
    }
    return [NSString stringWithUTF8String:value];
}

static char *XCDocCopyCString(NSString *value) {
    if (value == nil) {
        return NULL;
    }
    const char *utf8 = [value UTF8String];
    if (utf8 == NULL) {
        return NULL;
    }
    return strdup(utf8);
}

static char *XCDocCopyError(NSString *message) {
    return XCDocCopyCString(message ?: @"unknown private documentation search error");
}

static BOOL XCDocLoadFramework(NSString *path, char **errorMessage) {
    if (dlopen(path.fileSystemRepresentation, RTLD_NOW) != NULL) {
        return YES;
    }
    if (errorMessage != NULL) {
        *errorMessage = XCDocCopyError([NSString stringWithFormat:@"dlopen failed for %@: %s", path, dlerror()]);
    }
    return NO;
}

static BOOL XCDocLoadRequiredFrameworks(char **errorMessage) {
    static dispatch_once_t onceToken;
    static BOOL loaded;
    static char *loadErrorMessage;
    dispatch_once(&onceToken, ^{
        char *error = NULL;
        loaded = XCDocLoadFramework(@"/System/Library/PrivateFrameworks/MediaAnalysisServices.framework/MediaAnalysisServices", &error)
            && XCDocLoadFramework(@"/System/Library/PrivateFrameworks/MediaAnalysis.framework/MediaAnalysis", &error)
            && XCDocLoadFramework(@"/System/Library/PrivateFrameworks/VectorSearch.framework/VectorSearch", &error);
        if (!loaded) {
            loadErrorMessage = error;
        } else if (error != NULL) {
            free(error);
        }
    });
    if (!loaded && errorMessage != NULL) {
        *errorMessage = XCDocCopyError(
            loadErrorMessage != NULL
                ? [NSString stringWithUTF8String:loadErrorMessage]
                : @"failed to load private documentation search frameworks"
        );
    }
    return loaded;
}

static VSKClient *XCDocCachedVectorSearchClient(NSString *databasePath, char **errorMessage) {
    static dispatch_once_t onceToken;
    static NSMutableDictionary<NSString *, VSKClient *> *clientsByPath;
    static NSLock *lock;
    dispatch_once(&onceToken, ^{
        clientsByPath = [NSMutableDictionary dictionary];
        lock = [NSLock new];
    });

    [lock lock];
    VSKClient *cachedClient = clientsByPath[databasePath];
    [lock unlock];
    if (cachedClient != nil) {
        return cachedClient;
    }

    NSError *error = nil;
    VSKConfig *config = [[NSClassFromString(@"VSKConfig") alloc]
        initWithBaseDirectory:[NSURL fileURLWithPath:databasePath isDirectory:YES]
                     readOnly:YES
      perConnectionPeakMemory:nil
                        error:&error];
    if (config == nil) {
        if (errorMessage != NULL) {
            *errorMessage = XCDocCopyError([NSString stringWithFormat:@"VectorSearch config failed: %@", error]);
        }
        return nil;
    }
    VSKClient *client = [[NSClassFromString(@"VSKClient") alloc] initWithConfig:config error:&error];
    if (client == nil) {
        if (errorMessage != NULL) {
            *errorMessage = XCDocCopyError([NSString stringWithFormat:@"VectorSearch client failed: %@", error]);
        }
        return nil;
    }

    [lock lock];
    VSKClient *existingClient = clientsByPath[databasePath];
    if (existingClient == nil) {
        clientsByPath[databasePath] = client;
        existingClient = client;
    }
    [lock unlock];
    return existingClient;
}

static unsigned long long XCDocEmbeddingVersionFromClass(NSString *className) {
    Class cls = NSClassFromString(className);
    if (cls == Nil || ![cls respondsToSelector:@selector(embeddingVersion)]) {
        return 0;
    }
    unsigned long long (*send)(id, SEL) = (unsigned long long (*)(id, SEL))objc_msgSend;
    return send(cls, @selector(embeddingVersion));
}

static unsigned long long XCDocEmbeddingVersionForModel(NSString *modelName) {
    NSString *normalized = modelName.lowercaseString;
    if ([normalized isEqualToString:@"md7v2"]) {
        unsigned long long version = XCDocEmbeddingVersionFromClass(@"MADTextEmbeddingThresholdMD7v2");
        return version != 0 ? version : 9;
    }
    if ([normalized isEqualToString:@"md6"]) {
        unsigned long long version = XCDocEmbeddingVersionFromClass(@"MADTextEmbeddingThresholdMD6");
        return version != 0 ? version : 7;
    }
    if ([normalized isEqualToString:@"md5"]) {
        unsigned long long version = XCDocEmbeddingVersionFromClass(@"MADTextEmbeddingThresholdMD5");
        return version != 0 ? version : 5;
    }
    if ([normalized isEqualToString:@"md4"]) {
        unsigned long long version = XCDocEmbeddingVersionFromClass(@"MADTextEmbeddingThresholdMD4");
        return version != 0 ? version : 4;
    }
    if ([normalized isEqualToString:@"md3"]) {
        unsigned long long version = XCDocEmbeddingVersionFromClass(@"MADTextEmbeddingThresholdMD3");
        return version != 0 ? version : 3;
    }
    Class analyzer = NSClassFromString(@"VCPMediaAnalyzer");
    if (analyzer != Nil && [analyzer respondsToSelector:@selector(getUnifiedEmbeddingVersion)]) {
        unsigned long long (*send)(id, SEL) = (unsigned long long (*)(id, SEL))objc_msgSend;
        return send(analyzer, @selector(getUnifiedEmbeddingVersion));
    }
    return 0;
}

static float XCDocFloat32FromFloat16(uint16_t half) {
    uint16_t halfExponent = half & 0x7C00u;
    uint16_t halfSignificand = half & 0x03FFu;
    uint32_t floatSign = ((uint32_t)half & 0x8000u) << 16;
    uint32_t bits;
    if (halfExponent == 0) {
        if (halfSignificand == 0) {
            bits = floatSign;
        } else {
            int shift = __builtin_clz(halfSignificand) - 21;
            halfSignificand <<= shift;
            uint32_t exponent = (uint32_t)(127 - 15 - shift + 1);
            uint32_t significand = ((uint32_t)halfSignificand & 0x03FFu) << 13;
            bits = floatSign | (exponent << 23) | significand;
        }
    } else if (halfExponent == 0x7C00u) {
        bits = floatSign | 0x7F800000u | ((uint32_t)halfSignificand << 13);
    } else {
        uint32_t exponent = (uint32_t)(halfExponent >> 10) + (127 - 15);
        uint32_t significand = (uint32_t)halfSignificand << 13;
        bits = floatSign | (exponent << 23) | significand;
    }
    float value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

static NSData *XCDocFloat32DataFromEmbeddingData(NSData *data, char **errorMessage) {
    if (data.length == 512 * sizeof(float)) {
        return data;
    }
    if (data.length != 512 * sizeof(uint16_t)) {
        if (errorMessage != NULL) {
            *errorMessage = XCDocCopyError([NSString stringWithFormat:@"unexpected embedding byte count: %lu", (unsigned long)data.length]);
        }
        return nil;
    }
    NSMutableData *floatData = [NSMutableData dataWithLength:512 * sizeof(float)];
    const uint16_t *source = data.bytes;
    float *destination = floatData.mutableBytes;
    for (NSUInteger index = 0; index < 512; index += 1) {
        destination[index] = XCDocFloat32FromFloat16(source[index]);
    }
    return floatData;
}

static NSData *XCDocCopyQueryEmbedding(
    NSString *query,
    NSString *modelName,
    double timeoutSeconds,
    char **errorMessage
) {
    Class requestClass = NSClassFromString(@"MADTextEmbeddingRequest");
    Class inputClass = NSClassFromString(@"MADTextInput");
    Class serviceClass = NSClassFromString(@"MADService");
    if (requestClass == Nil || inputClass == Nil || serviceClass == Nil) {
        if (errorMessage != NULL) {
            *errorMessage = XCDocCopyError(@"MediaAnalysisServices embedding classes are unavailable");
        }
        return nil;
    }

    unsigned long long version = XCDocEmbeddingVersionForModel(modelName);
    if (version == 0) {
        if (errorMessage != NULL) {
            *errorMessage = XCDocCopyError([NSString stringWithFormat:@"unsupported embedding model: %@", modelName ?: @""]);
        }
        return nil;
    }

    MADTextEmbeddingRequest *request = [requestClass new];
    request.version = version;
    request.extendedContextLength = YES;
    request.allowTruncation = YES;
    MADTextInput *input = [[inputClass alloc] initWithText:query];
    MADService *service = [serviceClass service];
    if (service == nil || input == nil) {
        if (errorMessage != NULL) {
            *errorMessage = XCDocCopyError(@"failed to initialize MediaAnalysisServices embedding request");
        }
        return nil;
    }

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [service performRequests:@[request] textInputs:@[input] completionHandler:^{
        dispatch_semaphore_signal(semaphore);
    }];

    int64_t timeoutNanoseconds = timeoutSeconds > 0
        ? (int64_t)(timeoutSeconds * (double)NSEC_PER_SEC)
        : 30LL * NSEC_PER_SEC;
    intptr_t waitResult = dispatch_semaphore_wait(
        semaphore,
        dispatch_time(DISPATCH_TIME_NOW, timeoutNanoseconds)
    );
    if (waitResult != 0) {
        if (errorMessage != NULL) {
            *errorMessage = XCDocCopyError(@"embedding request timed out");
        }
        return nil;
    }

    id requestError = nil;
    @try {
        requestError = [request valueForKey:@"error"];
    } @catch (__unused NSException *exception) {}
    if (requestError != nil && requestError != (id)[NSNull null]) {
        if (errorMessage != NULL) {
            *errorMessage = XCDocCopyError([NSString stringWithFormat:@"embedding request failed: %@", requestError]);
        }
        return nil;
    }

    id result = request.embeddingResults.firstObject;
    NSData *embeddingData = nil;
    if ([result respondsToSelector:@selector(embeddingData)]) {
        embeddingData = [result valueForKey:@"embeddingData"];
    }
    if (embeddingData == nil) {
        if (errorMessage != NULL) {
            *errorMessage = XCDocCopyError(@"embedding request produced no embedding");
        }
        return nil;
    }
    return XCDocFloat32DataFromEmbeddingData(embeddingData, errorMessage);
}

int XCDocSemanticSearchRuntimeAvailable(void) {
    @autoreleasepool {
        if (!XCDocLoadRequiredFrameworks(NULL)) {
            return 0;
        }
        return NSClassFromString(@"MADTextEmbeddingRequest") != Nil
            && NSClassFromString(@"MADTextInput") != Nil
            && NSClassFromString(@"MADService") != Nil
            && NSClassFromString(@"VSKConfig") != Nil
            && NSClassFromString(@"VSKClient") != Nil;
    }
}

char *XCDocSemanticSearchCopyResultJSON(
    const char *databaseDirectoryPath,
    const char *embeddingModelName,
    const char *query,
    int limit,
    double timeoutSeconds,
    char **errorMessage
) {
    @autoreleasepool {
        if (errorMessage != NULL) {
            *errorMessage = NULL;
        }
        NSString *databasePath = XCDocStringFromCString(databaseDirectoryPath);
        NSString *queryString = XCDocStringFromCString(query);
        NSString *modelName = XCDocStringFromCString(embeddingModelName) ?: @"md7v2";
        if (databasePath.length == 0 || queryString.length == 0 || limit <= 0) {
            if (errorMessage != NULL) {
                *errorMessage = XCDocCopyError(@"invalid semantic search arguments");
            }
            return NULL;
        }
        if (!XCDocLoadRequiredFrameworks(errorMessage)) {
            return NULL;
        }

        NSData *embedding = XCDocCopyQueryEmbedding(
            queryString,
            modelName,
            timeoutSeconds,
            errorMessage
        );
        if (embedding == nil) {
            return NULL;
        }

        NSError *error = nil;
        VSKClient *client = XCDocCachedVectorSearchClient(databasePath, errorMessage);
        if (client == nil) {
            return NULL;
        }

        NSArray *results = nil;
        @synchronized (client) {
            results = [client searchByVector:embedding
                            attributeFilters:@[]
                                       limit:limit
                              includePayload:NO
                              numberOfProbes:nil
                                   batchSize:nil
                        numConcurrentReaders:nil
                                       error:&error];
        }
        if (results == nil) {
            if (errorMessage != NULL) {
                *errorMessage = XCDocCopyError([NSString stringWithFormat:@"VectorSearch query failed: %@", error]);
            }
            return NULL;
        }

        NSMutableArray *objects = [NSMutableArray arrayWithCapacity:results.count];
        for (id result in results) {
            NSString *identifier = [result valueForKey:@"stringIdentifier"];
            NSNumber *score = [result valueForKey:@"value"];
            if (identifier.length == 0 || score == nil) {
                continue;
            }
            [objects addObject:@{
                @"asset_id": identifier,
                @"score": score,
            }];
        }
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:objects options:0 error:&error];
        if (jsonData == nil) {
            if (errorMessage != NULL) {
                *errorMessage = XCDocCopyError([NSString stringWithFormat:@"semantic search JSON encoding failed: %@", error]);
            }
            return NULL;
        }
        NSString *json = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        return XCDocCopyCString(json);
    }
}

void XCDocSemanticSearchFree(void *pointer) {
    free(pointer);
}

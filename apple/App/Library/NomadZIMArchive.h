#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Objective-C boundary around libzim. Every operation serializes archive access and catches C++ exceptions.
@interface NomadZIMArchive : NSObject {
@private
    void *_archive;
}
@property(nonatomic, readonly, copy) NSString *title;
@property(nonatomic, readonly) BOOL hasFullTextIndex;
@property(nonatomic, readonly) uint64_t articleCount;
- (nullable instancetype)initWithURL:(NSURL *)url error:(NSError **)error;
- (nullable NSString *)mainPathWithError:(NSError **)error NS_SWIFT_NAME(mainPath());
- (nullable NSDictionary<NSString *, id> *)metadataForPath:(NSString *)path error:(NSError **)error NS_SWIFT_NAME(metadata(path:));
- (nullable NSData *)readPath:(NSString *)path offset:(uint64_t)offset length:(uint64_t)length error:(NSError **)error NS_SWIFT_NAME(read(path:offset:length:));
- (nullable NSArray<NSDictionary<NSString *, id> *> *)search:(NSString *)query fullText:(BOOL)fullText limit:(NSInteger)limit error:(NSError **)error NS_SWIFT_NAME(search(_:fullText:limit:));
@end

NS_ASSUME_NONNULL_END

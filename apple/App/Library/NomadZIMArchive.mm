#import "NomadZIMArchive.h"
#include <zim/archive.h>
#include <zim/entry.h>
#include <zim/item.h>
#include <zim/search.h>
#include <zim/suggestion.h>
#include <algorithm>
#include <stdexcept>

static NSString *NomadString(const std::string &value) {
    return [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding] ?: @"";
}

static void NomadZIMError(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"org.projectnomad.zim" code:1
        userInfo:@{NSLocalizedDescriptionKey: message ?: @"Unable to read this archive."}];
}

@implementation NomadZIMArchive

- (nullable instancetype)initWithURL:(NSURL *)url error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    try {
        if (!url.isFileURL) throw std::runtime_error("Only local ZIM files can be opened.");
        auto archive = std::make_unique<zim::Archive>(url.fileSystemRepresentation);
        _articleCount = archive->getArticleCount();
        _hasFullTextIndex = archive->hasFulltextIndex();
        try { _title = NomadString(archive->getMetadata("Title")); }
        catch (...) { _title = url.lastPathComponent; }
        _archive = archive.release();
        return self;
    } catch (const std::exception &exception) {
        NomadZIMError(error, NomadString(exception.what()));
    } catch (...) { NomadZIMError(error, @"The ZIM archive could not be opened."); }
    return nil;
}

- (void)dealloc { delete static_cast<zim::Archive *>(_archive); }

- (NSString *)mainPathWithError:(NSError **)error {
    @synchronized(self) {
        try {
            auto entry = static_cast<zim::Archive *>(_archive)->getMainEntry();
            return NomadString(entry.getItem(true).getPath());
        } catch (const std::exception &exception) { NomadZIMError(error, NomadString(exception.what())); }
        catch (...) { NomadZIMError(error, @"This archive has no readable main page."); }
        return nil;
    }
}

- (NSDictionary<NSString *, id> *)metadataForPath:(NSString *)path error:(NSError **)error {
    @synchronized(self) {
        try {
            auto item = static_cast<zim::Archive *>(_archive)->getEntryByPath(path.UTF8String).getItem(true);
            return @{@"path": NomadString(item.getPath()), @"title": NomadString(item.getTitle()),
                     @"mime": NomadString(item.getMimetype()), @"size": @(item.getSize())};
        } catch (const std::exception &exception) { NomadZIMError(error, NomadString(exception.what())); }
        catch (...) { NomadZIMError(error, @"This archive entry could not be read."); }
        return nil;
    }
}

- (NSData *)readPath:(NSString *)path offset:(uint64_t)offset length:(uint64_t)length error:(NSError **)error {
    @synchronized(self) {
        try {
            auto item = static_cast<zim::Archive *>(_archive)->getEntryByPath(path.UTF8String).getItem(true);
            const auto size = item.getSize();
            if (offset > size) throw std::runtime_error("The requested range is outside this archive entry.");
            const auto count = std::min<uint64_t>(std::min<uint64_t>(length, size - offset), 512 * 1024);
            if (count == 0) return [NSData data];
            auto bytes = item.getData(offset, count);
            return [NSData dataWithBytes:bytes.data() length:bytes.size()];
        } catch (const std::exception &exception) { NomadZIMError(error, NomadString(exception.what())); }
        catch (...) { NomadZIMError(error, @"The requested archive content could not be read."); }
        return nil;
    }
}

- (NSArray<NSDictionary<NSString *, id> *> *)search:(NSString *)query fullText:(BOOL)fullText limit:(NSInteger)limit error:(NSError **)error {
    @synchronized(self) {
        try {
            auto &archive = *static_cast<zim::Archive *>(_archive);
            const int maximum = (int)std::clamp<NSInteger>(limit, 1, 100);
            NSMutableArray *results = [NSMutableArray array];
            if (query.length == 0) {
                for (const auto &entry : archive.iterByTitle()) {
                    [results addObject:@{@"path": NomadString(entry.getPath()), @"title": NomadString(entry.getTitle()), @"snippet": @""}];
                    if (results.count >= maximum) break;
                }
            } else if (fullText && archive.hasFulltextIndex()) {
                zim::Searcher searcher(archive);
                auto search = searcher.search(zim::Query(query.UTF8String));
                const auto matches = search.getResults(0, maximum);
                for (auto it = matches.begin(); it != matches.end(); ++it) {
                    [results addObject:@{@"path": NomadString(it.getPath()), @"title": NomadString(it.getTitle()),
                                         @"snippet": NomadString(it.getSnippet()), @"score": @(it.getScore())}];
                }
            } else {
                zim::SuggestionSearcher searcher(archive);
                auto search = searcher.suggest(query.UTF8String);
                const auto matches = search.getResults(0, maximum);
                for (auto it = matches.begin(); it != matches.end(); ++it) {
                    [results addObject:@{@"path": NomadString(it->getPath()), @"title": NomadString(it->getTitle()), @"snippet": @""}];
                }
            }
            return results;
        } catch (const std::exception &exception) { NomadZIMError(error, NomadString(exception.what())); }
        catch (...) { NomadZIMError(error, @"The archive search failed. Try title search or a shorter query."); }
        return nil;
    }
}
@end

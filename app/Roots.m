//
//  Roots.m
//  iSH
//
//  Created by Theodore Dubois on 6/7/20.
//

#import <FileProvider/FileProvider.h>
#import "Roots.h"
#import "AppGroup.h"
#import "NSObject+SaneKVO.h"
#include "tools/fakefs.h"
#ifdef LINUXRUNNER
#import <CommonCrypto/CommonDigest.h>
#import "LinuxRunner/FileTransfer.h"
#import "LinuxRunner/BootLog.h"
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
static BOOL validRunnerRoot(NSString *name) {
    return lr_valid_leaf(name.UTF8String) &&
        strlen(name.UTF8String) == [name lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
}
#endif

static NSURL *RootsDir(void) {
    static NSURL *rootsDir;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        rootsDir = [ContainerURL() URLByAppendingPathComponent:@"roots"];
        NSFileManager *manager = [NSFileManager defaultManager];
        [manager createDirectoryAtURL:rootsDir
          withIntermediateDirectories:YES
                           attributes:@{}
                                error:nil];
    });
    return rootsDir;
}

static NSString *kDefaultRoot = @"Default Root";

@interface Roots ()
@property NSMutableOrderedSet<NSString *> *roots;
@property BOOL updatingDomains;
@property BOOL domainsNeedUpdate;
@property BOOL wantsVersionFile;
#ifdef LINUXRUNNER
@property NSError *initializationError;
#endif
@end

@implementation Roots

- (instancetype)init {
    if (self = [super init]) {
        NSError *error = nil;
        NSArray<NSString *> *rootNames = [NSFileManager.defaultManager contentsOfDirectoryAtPath:RootsDir().path error:&error];
#ifdef LINUXRUNNER
        if (error) { self.initializationError = error; self.roots = [NSMutableOrderedSet new]; LRBootEvent("root directory unavailable"); return self; }
#else
        NSAssert(error == nil, @"couldn't list roots: %@", error);
#endif
        self.roots = [[NSMutableOrderedSet alloc] initWithArray:rootNames ?: @[]];
#ifndef LINUXRUNNER
        if (!self.roots.count) {
            // import default root
            NSError *error;
            if (![self importRootFromArchive:[NSBundle.mainBundle URLForResource:@"root" withExtension:@"tar.gz"]
                                        name:@"default"
                                       error:&error
                            progressReporter:nil]) {
                NSAssert(NO, @"failed to import default root, error %@", error);
            }
            _wantsVersionFile = YES;
        }
#endif
        [self observe:@[@"roots"] options:0 owner:self usingBlock:^(typeof(self) self) {
            if (self.defaultRoot == nil && self.roots.count)
                self.defaultRoot = self.roots[0];
            [self syncFileProviderDomains];
        }];
        [self syncFileProviderDomains];

        if ((!self.defaultRoot || ![self.roots containsObject:self.defaultRoot]) && self.roots.count)
            self.defaultRoot = self.roots.firstObject;
        else if (!self.roots.count)
            self.defaultRoot = nil;
    }
    return self;
}

- (NSString *)defaultRoot {
    return [NSUserDefaults.standardUserDefaults stringForKey:kDefaultRoot];
}
- (void)setDefaultRoot:(NSString *)defaultRoot {
    [NSUserDefaults.standardUserDefaults setObject:defaultRoot forKey:kDefaultRoot];
}

- (NSURL *)rootUrl:(NSString *)name {
    return [RootsDir() URLByAppendingPathComponent:name];
}

- (void)syncFileProviderDomains {
#ifdef LINUXRUNNER
    if (CurrentAppGroups().count == 0) {
        return;
    }
#endif
    if (self.updatingDomains) {
        self.domainsNeedUpdate = YES;
        return;
    }
    self.updatingDomains = YES;
    self.domainsNeedUpdate = NO;

    [NSFileProviderManager getDomainsWithCompletionHandler:^(NSArray<NSFileProviderDomain *> *domains, NSError *error) {
        void (^onError)(NSError *error) = ^(NSError *error) {
            if (error != nil)
                NSLog(@"error adjusting domains: %@", error);
        };
        onError(error);
        NSOrderedSet<NSString *> *snapshot = [self.roots copy];
        NSMutableOrderedSet<NSString *> *missingRoots = [snapshot mutableCopy];
        for (NSFileProviderDomain *domain in domains) {
            if ([missingRoots containsObject:domain.identifier]) {
                [missingRoots removeObject:domain.identifier];
            } else {
                NSURL *storage = NSFileProviderManager.defaultManager.documentStorageURL;
                if (storage != nil) {
                    [NSFileManager.defaultManager removeItemAtURL:
                     [storage URLByAppendingPathComponent:domain.pathRelativeToDocumentStorage]
                                                            error:nil];
                }
                [NSFileProviderManager removeDomain:domain completionHandler:onError];
            }
        }
        for (NSString *rootId in missingRoots) {
            NSString *displayName = (snapshot.count == 1) ? @"Debian Minimal" : rootId;
            [NSFileProviderManager addDomain:[[NSFileProviderDomain alloc] initWithIdentifier:rootId
                                                                                  displayName:displayName
                                                                pathRelativeToDocumentStorage:rootId]
                           completionHandler:onError];
        }
        self.updatingDomains = NO;
        if (self.domainsNeedUpdate)
            [self syncFileProviderDomains];
    }];
}

#ifdef LINUXRUNNER
- (void)removeAllFileProviderDomains {
    if (CurrentAppGroups().count == 0)
        return;
    [NSFileProviderManager removeAllDomainsWithCompletionHandler:^(NSError *error) {
        if (error != nil)
            NSLog(@"error removing file provider domains: %@", error);
    }];
}

- (BOOL)forceDestroyAllRoots:(NSError **)error {
    __block NSArray<NSString *> *allRoots = nil;
    void (^snapshotRoots)(void) = ^{
        allRoots = self.roots.array.copy;
    };
    if (NSThread.isMainThread) snapshotRoots(); else dispatch_sync(dispatch_get_main_queue(), snapshotRoots);
    NSError *firstError = nil;
    for (NSString *name in allRoots) {
        NSError *rmError = nil;
        if (![NSFileManager.defaultManager removeItemAtURL:[self rootUrl:name] error:&rmError] &&
            rmError.code != NSFileNoSuchFileError && firstError == nil) {
            firstError = rmError;
        }
    }
    void (^clear)(void) = ^{
        self.defaultRoot = nil;
        [[self mutableOrderedSetValueForKey:@"roots"] removeAllObjects];
    };
    if (NSThread.isMainThread) clear(); else dispatch_sync(dispatch_get_main_queue(), clear);
    [self removeAllFileProviderDomains];
    if (firstError && error) *error = firstError;
    return firstError == nil;
}
#endif

- (BOOL)accessInstanceVariablesDirectly {
    return YES;
}

void root_progress_callback(void *cookie, double progress, const char *message, bool *should_cancel) {
    id <ProgressReporter> reporter = (__bridge id<ProgressReporter>) cookie;
    [reporter updateProgress:progress message:[NSString stringWithUTF8String:message]];
    if ([reporter shouldCancel])
        *should_cancel = true;
}

#ifdef LINUXRUNNER
static void root_import_progress_callback(void *cookie, double progress, const char *message, bool *should_cancel) {
    root_progress_callback(cookie, .2 + .8 * progress, message, should_cancel);
}
#endif

- (BOOL)importRootFromArchive:(NSURL *)archive name:(NSString *)name error:(NSError **)error progressReporter:(id<ProgressReporter> _Nullable)progress {
#ifdef LINUXRUNNER
    if (error) *error = [NSError errorWithDomain:@"dev.linuxrunner.rootfs" code:ENOTSUP
        userInfo:@{NSLocalizedDescriptionKey:@"Install Debian minimal using the built-in verified Debian installer."}];
    return NO;
}
- (BOOL)importVerifiedRootFromArchive:(NSURL *)archive name:(NSString *)name sha256:(NSString *)expected metadata:(NSDictionary *)metadata error:(NSError **)error progressReporter:(id<ProgressReporter> _Nullable)progress {
#endif
#ifdef LINUXRUNNER
    __block BOOL duplicate = NO;
    void (^checkDup)(void) = ^{ duplicate = [self.roots containsObject:name]; };
    if (NSThread.isMainThread) checkDup(); else dispatch_sync(dispatch_get_main_queue(), checkDup);
    if (!validRunnerRoot(name) || duplicate) {
        if (error) *error = [NSError errorWithDomain:@"dev.linuxrunner.rootfs" code:EINVAL
            userInfo:@{NSLocalizedDescriptionKey:@"Invalid or duplicate environment root identifier."}];
        return NO;
    }
    // The managed Debian installer or snapshot manager supplies its archive hash
    // before importing. Verify a private copy, then import those exact bytes.
    unsigned long long maximumBytes = 4ULL * 1024 * 1024 * 1024;
    NSDictionary *attributes = archive ? [archive resourceValuesForKeys:
        @[NSURLIsRegularFileKey, NSURLIsSymbolicLinkKey, NSURLFileSizeKey] error:error] : nil;
    if (![attributes[NSURLIsRegularFileKey] boolValue] ||
        [attributes[NSURLIsSymbolicLinkKey] boolValue] ||
        [attributes[NSURLFileSizeKey] unsignedLongLongValue] > maximumBytes) {
        if (error) *error = [NSError errorWithDomain:@"dev.linuxrunner.rootfs" code:EINVAL
            userInfo:@{NSLocalizedDescriptionKey:@"Select a regular rootfs archive up to 4 GiB."}];
        return NO;
    }
    NSURL *verifiedArchive = [NSFileManager.defaultManager.temporaryDirectory
        URLByAppendingPathComponent:[NSString stringWithFormat:@"rootfs-%@.tar.gz", NSUUID.UUID.UUIDString]];
    int input = open(archive.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    struct stat sourceStat;
    if (input >= 0 && (fstat(input, &sourceStat) < 0 || !S_ISREG(sourceStat.st_mode) || sourceStat.st_size <= 0 || (unsigned long long)sourceStat.st_size > maximumBytes)) {
        close(input); input = -1; errno = EINVAL;
    }
    int output = input < 0 ? -1 : open(verifiedArchive.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    int ioError = input < 0 || output < 0 ? errno : 0;
    BOOL cancelled = NO;
    CC_SHA256_CTX hash; CC_SHA256_Init(&hash);
    uint8_t buffer[65536]; ssize_t count = 0; unsigned long long copied = 0;
    while (!ioError) {
        if (progress && [progress shouldCancel]) { cancelled = YES; break; }
        count = read(input, buffer, sizeof buffer);
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) { ioError = errno; break; }
        if (!count) break;
        copied += count;
        if (copied > maximumBytes) { ioError = EFBIG; break; }
        ssize_t written = 0;
        while (written < count) {
            ssize_t n = write(output, buffer + written, count - written);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) { ioError = n < 0 ? errno : EIO; break; }
            written += n;
        }
        if (ioError) break;
        CC_SHA256_Update(&hash, buffer, (CC_LONG)count);
        unsigned long long expectedBytes = (unsigned long long)sourceStat.st_size;
        [progress updateProgress:expectedBytes ? .2 * (double)copied / expectedBytes : 0 message:@"Copying and verifying the selected filesystem"];
    }
    if (input >= 0) close(input);
    if (output >= 0 && close(output) < 0 && !ioError) ioError = errno;
    uint8_t digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(digest, &hash);
    NSMutableString *actual = [NSMutableString new];
    for (NSUInteger i = 0; i < sizeof(digest); i++) [actual appendFormat:@"%02x", digest[i]];
    if (ioError || cancelled || expected.length != 64 || ![actual isEqual:expected]) {
        [NSFileManager.defaultManager removeItemAtURL:verifiedArchive error:nil];
        if (error) *error = cancelled ? [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil] :
            [NSError errorWithDomain:@"dev.linuxrunner.rootfs" code:ioError ?: EINVAL
            userInfo:@{NSLocalizedDescriptionKey:ioError ? [NSString stringWithFormat:@"The filesystem could not be copied: %s", strerror(ioError)] : @"Rootfs integrity verification failed. The archive differs from its installation manifest."}];
        return NO;
    }
#endif
    NSAssert(![self.roots containsObject:name], @"root already exists: %@", name);
    struct fakefsify_error fs_err;
    NSURL *destination = [self rootUrl:name];
    NSURL *tempDestination = [NSFileManager.defaultManager.temporaryDirectory
                              URLByAppendingPathComponent:[NSProcessInfo.processInfo globallyUniqueString]];
    if (tempDestination == nil) {
#ifdef LINUXRUNNER
        [NSFileManager.defaultManager removeItemAtURL:verifiedArchive error:nil];
#endif
        return NO;
    }
#ifdef LINUXRUNNER
    NSURL *importArchive = verifiedArchive;
#else
    NSURL *importArchive = archive;
#endif
    BOOL imported = fakefs_import_prefix(importArchive.fileSystemRepresentation,
                       tempDestination.fileSystemRepresentation, NULL,
                       &fs_err, (struct progress) {(__bridge void *) progress,
#ifdef LINUXRUNNER
                           root_import_progress_callback
#else
                           root_progress_callback
#endif
                       });
#ifdef LINUXRUNNER
    [NSFileManager.defaultManager removeItemAtURL:verifiedArchive error:nil];
#endif
    if (!imported) {
        NSString *domain = NSPOSIXErrorDomain;
        if (fs_err.type == ERR_SQLITE)
            domain = @"SQLite";
        if (error) *error = [NSError errorWithDomain:domain
                                     code:fs_err.code
                                 userInfo:@{NSLocalizedDescriptionKey:
                                                [NSString stringWithFormat:@"%s, line %d", fs_err.message, fs_err.line]}];
        if (error && fs_err.type == ERR_CANCELLED)
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil];
        free(fs_err.message);
        [NSFileManager.defaultManager removeItemAtURL:tempDestination error:nil];
        return NO;
    }
#ifdef LINUXRUNNER
    NSData *installation=[NSJSONSerialization dataWithJSONObject:metadata options:NSJSONWritingPrettyPrinted error:error];
    if(!installation||![installation writeToURL:[tempDestination URLByAppendingPathComponent:@"environment-install.json"] options:NSDataWritingAtomic error:error]){[NSFileManager.defaultManager removeItemAtURL:tempDestination error:nil];return NO;}
#endif
    if (![NSFileManager.defaultManager moveItemAtURL:tempDestination toURL:destination error:error]) {
        [NSFileManager.defaultManager removeItemAtURL:tempDestination error:nil];
        return NO;
    }

    void (^addRoot)(void) = ^{
        [[self mutableOrderedSetValueForKey:@"roots"] addObject:name];
    };
    if (!NSThread.isMainThread)
        dispatch_sync(dispatch_get_main_queue(), addRoot);
    else
        addRoot();
    return YES;
}

- (BOOL)exportRootNamed:(NSString *)name toArchive:(NSURL *)archive error:(NSError **)error progressReporter:(id<ProgressReporter> _Nullable)progress {
    NSAssert([self.roots containsObject:name], @"trying to export a root that doesn't exist: %@", name);
    struct fakefsify_error fs_err;
    if (!fakefs_export([self rootUrl:name].fileSystemRepresentation,
                       archive.fileSystemRepresentation,
                       &fs_err, (struct progress) {(__bridge void *) progress, root_progress_callback})) {
        // TODO: dedup with above method
        NSString *domain = NSPOSIXErrorDomain;
        if (fs_err.type == ERR_SQLITE)
            domain = @"SQLite";
        *error = [NSError errorWithDomain:domain
                                     code:fs_err.code
                                 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:fs_err.message]}];
        if (fs_err.type == ERR_CANCELLED)
            *error = nil;
        free(fs_err.message);
        return NO;
    }
    return YES;
}

- (BOOL)destroyRootNamed:(NSString *)name error:(NSError **)error {
    __block BOOL exists = NO;
    __block BOOL isDefault = NO;
    void (^checkState)(void) = ^{
        exists = [self.roots containsObject:name];
        isDefault = [name isEqualToString:self.defaultRoot];
    };
    if (NSThread.isMainThread) checkState(); else dispatch_sync(dispatch_get_main_queue(), checkState);
#ifdef LINUXRUNNER
    if (!validRunnerRoot(name) || !exists) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:@{NSLocalizedDescriptionKey:@"Invalid or missing distribution."}];
        return NO;
    }
#endif
    if (isDefault) {
        if (error) *error = [NSError errorWithDomain:@"ios-linuxkit" code:0 userInfo:@{NSLocalizedDescriptionKey: @"Cannot delete the default filesystem"}];
        return NO;
    }
    NSAssert(exists, @"root does not exist: %@", name);
    if (![NSFileManager.defaultManager removeItemAtURL:[self rootUrl:name] error:error])
        return NO;
    void (^removeRoot)(void) = ^{ [[self mutableOrderedSetValueForKey:@"roots"] removeObject:name]; };
    if (NSThread.isMainThread) removeRoot(); else dispatch_sync(dispatch_get_main_queue(), removeRoot);
    return YES;
}

- (BOOL)renameRoot:(NSString *)name toName:(NSString *)newName error:(NSError **)error {
#ifdef LINUXRUNNER
    if (!validRunnerRoot(newName)) {
        if (error) *error = [NSError errorWithDomain:@"dev.linuxrunner.rootfs" code:EINVAL
            userInfo:@{NSLocalizedDescriptionKey:@"Invalid filesystem name. Use a single name without path separators."}];
        return NO;
    }
#endif
    if (name.length == 0) {
        *error = [NSError errorWithDomain:@"ios-linuxkit" code:0 userInfo:@{NSLocalizedDescriptionKey: @"Filesystem name can't be empty"}];
        return NO;
    }
    if ([name containsString:@"/"]) {
        *error = [NSError errorWithDomain:@"ios-linuxkit" code:0 userInfo:@{NSLocalizedDescriptionKey: @"Filesystem name can't contain /"}];
        return NO;
    }
    if ([name isEqualToString:@"."] || [name isEqualToString:@".."]) {
        *error = [NSError errorWithDomain:@"ios-linuxkit" code:0 userInfo:@{NSLocalizedDescriptionKey: @"Filesystem name can't be . or .."}];
        return NO;
    }
    if ([name isEqualToString:self.defaultRoot]) {
        *error = [NSError errorWithDomain:@"ios-linuxkit" code:0 userInfo:@{NSLocalizedDescriptionKey: @"Cannot rename the default filesystem"}];
        return NO;
    }
    NSAssert([self.roots containsObject:name], @"root does not exist: %@", name);
    
    if (![NSFileManager.defaultManager moveItemAtURL:[self rootUrl:name] toURL:[self rootUrl:newName] error:error])
        return NO;
    NSUInteger index = [self.roots indexOfObject:name];
    [[self mutableOrderedSetValueForKey:@"roots"] replaceObjectAtIndex:index withObject:newName];
    return YES;
}

+ (instancetype)instance {
    static Roots *instance;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        instance = [Roots new];
    });
    return instance;
}

@end

//
//  AppGroup.m
//  iSH
//
//  Created by Theodore Dubois on 2/28/20.
//

#import "AppGroup.h"
#import <Foundation/Foundation.h>
#import <mach-o/ldsyms.h>
#import <mach-o/loader.h>
#import <mach-o/getsect.h>
#import <dlfcn.h>
#if defined(LINUXRUNNER) && !defined(ISH_FILE_PROVIDER)
#import "LinuxRunner/BootLog.h"
#endif

#define CSMAGIC_EMBEDDED_SIGNATURE 0xfade0cc0
#define CSMAGIC_EMBEDDED_ENTITLEMENTS 0xfade7171

struct cs_blob_index {
    uint32_t type;
    uint32_t offset;
};

struct cs_superblob {
    uint32_t magic;
    uint32_t length;
    uint32_t count;
    struct cs_blob_index index[];
};

struct cs_entitlements {
    uint32_t magic;
    uint32_t length;
    char entitlements[];
};

static NSDictionary *AppEntitlements(void) {
    static NSDictionary *entitlements;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const struct mach_header_64 *header = &_mh_execute_header;

        // Simulator executables carry entitlements in __TEXT,__entitlements.
        size_t entitlements_size = 0;
        char *entitlements_data = (char *) getsectiondata(header, "__TEXT", "__entitlements", &entitlements_size);
        if (entitlements_data != NULL && entitlements_size > 0) {
            NSData *data = [NSData dataWithBytesNoCopy:entitlements_data
                                                length:entitlements_size
                                          freeWhenDone:NO];
            id parsed = [NSPropertyListSerialization propertyListWithData:data
                                                                  options:NSPropertyListImmutable
                                                                   format:nil
                                                                    error:nil];
            if ([parsed isKindOfClass:NSDictionary.class]) {
                entitlements = parsed;
                return;
            }
        }

        // Locate LC_CODE_SIGNATURE in the Mach-O header.
        struct load_command *lc = (void *) (header + 1);
        struct linkedit_data_command *cs_lc = NULL;
        for (uint32_t i = 0; i < header->ncmds; i++) {
            if (lc->cmd == LC_CODE_SIGNATURE && lc->cmdsize >= sizeof(struct linkedit_data_command)) {
                cs_lc = (void *) lc;
                break;
            }
            if (lc->cmdsize == 0)
                break;
            lc = (void *) ((char *) lc + lc->cmdsize);
        }
        if (cs_lc == NULL || cs_lc->datasize < sizeof(struct cs_superblob))
            return;

        NSFileHandle *fileHandle = [NSFileHandle fileHandleForReadingFromURL:NSBundle.mainBundle.executableURL error:nil];
        if (fileHandle == nil)
            return;
        NSData *csData = nil;
        @try {
            [fileHandle seekToFileOffset:cs_lc->dataoff];
            csData = [fileHandle readDataOfLength:cs_lc->datasize];
        } @catch (NSException *exception) {
            csData = nil;
        }
        [fileHandle closeFile];
        if (csData.length < sizeof(struct cs_superblob))
            return;

        const struct cs_superblob *cs = csData.bytes;
        if (ntohl(cs->magic) != CSMAGIC_EMBEDDED_SIGNATURE)
            return;

        uint32_t count = ntohl(cs->count);
        if ((size_t)count > (csData.length - sizeof(struct cs_superblob)) / sizeof(struct cs_blob_index))
            return;

        NSData *entitlementsData = nil;
        for (uint32_t i = 0; i < count; i++) {
            uint32_t offset = ntohl(cs->index[i].offset);
            if (offset > csData.length || csData.length - offset < sizeof(struct cs_entitlements))
                continue;
            const struct cs_entitlements *ents = (const void *) ((const char *) cs + offset);
            uint32_t length = ntohl(ents->length);
            if (ntohl(ents->magic) == CSMAGIC_EMBEDDED_ENTITLEMENTS &&
                length >= offsetof(struct cs_entitlements, entitlements) &&
                length <= csData.length - offset) {
                entitlementsData = [NSData dataWithBytes:ents->entitlements
                                                  length:length - offsetof(struct cs_entitlements, entitlements)];
                break;
            }
        }
        if (entitlementsData == nil)
            return;

        id parsed = [NSPropertyListSerialization propertyListWithData:entitlementsData
                                                              options:NSPropertyListImmutable
                                                               format:nil
                                                                error:nil];
        if ([parsed isKindOfClass:NSDictionary.class])
            entitlements = parsed;
    });
    return entitlements;
}

static void LRAddCandidateGroup(NSMutableOrderedSet<NSString *> *candidates, id value) {
    if ([value isKindOfClass:NSString.class]) {
        NSString *group = (NSString *)value;
        if (group.length > 0 && ![group containsString:@"$("])
            [candidates addObject:group];
    } else if ([value isKindOfClass:NSArray.class]) {
        for (id item in (NSArray *)value)
            LRAddCandidateGroup(candidates, item);
    }
}

NSArray<NSString *> *CurrentAppGroups(void) {
#if defined(LINUXRUNNER) || defined(ISH_FILE_PROVIDER)
    static NSArray<NSString *> *resolved;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableOrderedSet<NSString *> *candidates = [NSMutableOrderedSet new];
        // 1. Signed Mach-O entitlements (matches AltStore/SideStore/Sideloadly/Xcode re-signing).
        LRAddCandidateGroup(candidates, AppEntitlements()[@"com.apple.security.application-groups"]);
        // 2. File Provider extension document group in Info.plist.
        NSDictionary *ext = [NSBundle.mainBundle objectForInfoDictionaryKey:@"NSExtension"];
        if ([ext isKindOfClass:NSDictionary.class])
            LRAddCandidateGroup(candidates, ext[@"NSExtensionFileProviderDocumentGroup"]);
        // 3. Main app Info.plist app group key.
        LRAddCandidateGroup(candidates, [NSBundle.mainBundle objectForInfoDictionaryKey:@"LinuxRunnerAppGroup"]);
        // 4. Derived from bundle identifier (works even with DER-only entitlements).
        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
        if (bundleID.length > 0) {
            if ([bundleID hasSuffix:@".FileProvider"])
                bundleID = [bundleID substringToIndex:bundleID.length - @".FileProvider".length];
            LRAddCandidateGroup(candidates, [@"group." stringByAppendingString:bundleID]);
        }

        NSMutableArray<NSString *> *usable = [NSMutableArray new];
        NSFileManager *fm = NSFileManager.defaultManager;
        for (NSString *group in candidates) {
            if ([fm containerURLForSecurityApplicationGroupIdentifier:group] != nil)
                [usable addObject:group];
        }
        resolved = [usable copy];
    });
    return resolved ?: @[];
#else
    return AppEntitlements()[@"com.apple.security.application-groups"] ?: @[];
#endif
}

#if defined(LINUXRUNNER) && !defined(ISH_FILE_PROVIDER)
static void LRMigrateLegacyPrivateContainerIfNeeded(NSURL *sharedContainer) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *support = [fm URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *legacy = [support URLByAppendingPathComponent:@"LinuxRunner" isDirectory:YES];
    NSURL *legacyRoots = [legacy URLByAppendingPathComponent:@"roots" isDirectory:YES];
    NSArray<NSString *> *legacyEntries = [fm contentsOfDirectoryAtPath:legacyRoots.path error:nil];
    if (legacyEntries.count == 0)
        return;

    NSURL *sharedRoots = [sharedContainer URLByAppendingPathComponent:@"roots" isDirectory:YES];
    NSArray<NSString *> *sharedEntries = [fm contentsOfDirectoryAtPath:sharedRoots.path error:nil];
    if (sharedEntries.count > 0)
        return; // Shared container already populated.

    LRBootEvent("migrating existing rootfs from private Application Support into shared App Group container for Apple Files");
    [fm removeItemAtURL:sharedRoots error:nil];
    for (NSString *item in @[@"roots", @"exchanges", @"environments.json", @"downloads"]) {
        NSURL *src = [legacy URLByAppendingPathComponent:item];
        NSURL *dst = [sharedContainer URLByAppendingPathComponent:item];
        if (![fm fileExistsAtPath:src.path])
            continue;
        [fm removeItemAtURL:dst error:nil];
        NSError *moveError = nil;
        if (![fm moveItemAtURL:src toURL:dst error:&moveError]) {
            LRBootEvent([[NSString stringWithFormat:@"container migration skipped %@: %@", item, moveError.localizedDescription] UTF8String]);
        }
    }
}
#endif

NSURL *ContainerURL(void) {
#if defined(LINUXRUNNER) || defined(ISH_FILE_PROVIDER)
    static NSURL *container;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        NSString *group = CurrentAppGroups().firstObject;
        container = group ? [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group] : nil;
#if defined(LINUXRUNNER) && !defined(ISH_FILE_PROVIDER)
        if (container) {
            LRMigrateLegacyPrivateContainerIfNeeded(container);
            LRBootEvent([[NSString stringWithFormat:@"sandbox path resolved: shared App Group container (%@)", group] UTF8String]);
        } else {
            NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
            container = [support URLByAppendingPathComponent:@"LinuxRunner" isDirectory:YES];
            LRBootEvent("sandbox path resolved: private Application Support; shared group unavailable");
        }
#endif
    });
    return container;
#elif ISH_AOT_BOOTSTRAP
    // This isolated target has no file-provider extension or shared container.
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                                        inDomains:NSUserDomainMask].firstObject;
    return [support URLByAppendingPathComponent:@"LinuxKitAOTBootstrap" isDirectory:YES];
#else
    NSString *appGroup = CurrentAppGroups().firstObject;
    return appGroup ? [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:appGroup] : nil;
#endif
}

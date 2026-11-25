#import "RuntimeBridge.h"
#import <FileProvider/FileProvider.h>
#import <CommonCrypto/CommonDigest.h>
NSString *const LRSystemCPUCoresKey = @"LinuxRunnerSystem.cpuCores";
NSString *const LRSystemMemoryMBKey = @"LinuxRunnerSystem.memoryMB";
#include "LinuxAccountPolicy.h"
#include <sys/utsname.h>
#include <math.h>
#import "FileTransfer.h"
#import "FileArchive.h"
#import "DiagnosticLogTail.h"
#import "DebianBootstrap.h"
#import "BootLog.h"
#import "LinuxRunner-Swift.h"
#import "UserPreferences.h"
#include <pthread.h>
#include <stdatomic.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <sys/proc.h>
#include <os/log.h>
#include <errno.h>
#include <stdio.h>
#include <time.h>
#include "fs/netlink.h"
#include "fs/sockrestart.h"
#include "fs/devices.h"
#include <mach/mach.h>
#include <archive.h>
#include <archive_entry.h>
#import "../Roots.h"
#import "../AppGroup.h"
#import "../AppDelegate.h"
#import "../iOSFS.h"
#include "PasswordHash.h"
static int LRTransferStaging(void);
@interface LRRuntimeBridge (LRSupportInstall)
+ (void)runSupportInstall:(NSArray<NSString *> *)arguments title:(NSString *)title progress:(void (^)(NSString *))progress completion:(void (^)(NSError * _Nullable))completion;
+ (void)runHeadlessCommand:(NSArray<NSString *> *)command directory:(NSString *)directory stdinData:(NSData * _Nullable)stdinData timeout:(NSTimeInterval)timeout completion:(void (^ _Nullable)(int exitCode))completion;
@end
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/resource.h>
#include "kernel/init.h"
#include "kernel/task.h"
#include "kernel/calls.h"
#include "kernel/mm.h"
#include "kernel/resource.h"
#include "kernel/signal.h"
#include "kernel/futex.h"
#include "fs/proc.h"
#include "fs/real.h"
#include "kernel/fs.h"
#include "kernel/errno.h"
#include "fs/path.h"
#include "fs/fd.h"

static void LRConvertCommandToArgs(NSArray<NSString *> *command, char *argv, size_t maxSize) {
    char *p = argv;
    for (NSString *cmd in command) {
        const char *c = cmd.UTF8String;
        while (p < argv + maxSize - 1 && (*p++ = *c++));
        *p = '\0';
    }
    if (p < argv + maxSize - 1)
        *++p = '\0';
    else if (maxSize > 0)
        argv[maxSize - 1] = '\0';
}

// Persistent startup trace, initialized in main before UIKit delegates/roots.
// Never called by an OS signal handler. Fatal signals remain Apple's crash reports.
static NSURL *bootLogDirectory;
static NSTimeInterval runtimeStartedAt;
static atomic_int diagnosticLevel=2, diagnosticPID=-1, diagnosticSyscall=-1;
static atomic_bool diagnosticErrorsOnly=true;
static int bootLogFD = -1;
static pthread_mutex_t bootLogLock = PTHREAD_MUTEX_INITIALIZER;
static char lastMilestone[2048] = "not initialized";
struct LRBootSnapshot { _Atomic uint64_t version, pid, pc, sp, syscall, opcode; };
static struct LRBootSnapshot *bootSnapshot;
static atomic_flag snapshotWriter = ATOMIC_FLAG_INIT;
__attribute__((constructor)) static void LRProcessStarted(void) {
    const char message[] = "[BOOT] process started (C constructor)\n";
    write(STDERR_FILENO, message, sizeof(message) - 1);
}
static void LRBootLogSync(void) {
    int saved = errno;
    pthread_mutex_lock(&bootLogLock);
    if (bootLogFD >= 0) fsync(bootLogFD);
    pthread_mutex_unlock(&bootLogLock);
    errno = saved;
}
void LRBootEvent(const char *message) {
    if (!message) return;
    int saved = errno;
    pthread_mutex_lock(&bootLogLock);
    snprintf(lastMilestone, sizeof(lastMilestone), "%s", message);
    char line[2300]; struct timespec now; clock_gettime(CLOCK_REALTIME, &now);
    int n = snprintf(line, sizeof(line), "%lld.%03ld [BOOT] %s\n", (long long)now.tv_sec, now.tv_nsec / 1000000, lastMilestone);
    if (n > 0) {
        size_t count = (size_t)n < sizeof(line) ? (size_t)n : sizeof(line) - 1;
        write(STDERR_FILENO, line, count);
        if (bootLogFD >= 0) {
            struct stat st;
            if (fstat(bootLogFD, &st) == 0 && st.st_size < 1024 * 1024) {
                write(bootLogFD, line, count);
                if (strstr(lastMilestone, "FATAL") != NULL) fsync(bootLogFD);
            }
        }
        os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "%{public}s", lastMilestone);
    }
    pthread_mutex_unlock(&bootLogLock);
    @autoreleasepool {
        NSString *text=[NSString stringWithUTF8String:message]?:@"unreadable event";
        int severity=([text containsString:@"fault"]||[text containsString:@"FAIL"]||[text containsString:@"error="])?0:2;
        NSString *category=@"RUNTIME";
        if ([text hasPrefix:@"["]) { NSRange close=[text rangeOfString:@"]"]; if(close.location!=NSNotFound && close.location<32) category=[text substringWithRange:NSMakeRange(1,close.location-1)]; }
        [LRDiagnosticCenter record:category severity:severity message:text pid:0 tid:0];
    }
    errno = saved;
}
void LRBootSnapshot(int pid, uint64_t pc, uint64_t sp, uint64_t syscall, uint64_t opcode) {
    if (!bootSnapshot || atomic_flag_test_and_set_explicit(&snapshotWriter, memory_order_acquire)) return;
    atomic_store(&bootSnapshot->pid, pid); atomic_store(&bootSnapshot->pc, pc);
    atomic_store(&bootSnapshot->sp, sp); atomic_store(&bootSnapshot->syscall, syscall);
    if (opcode) atomic_store(&bootSnapshot->opcode, opcode);
    atomic_flag_clear_explicit(&snapshotWriter, memory_order_release);
}
void LRStartupInitialize(void) {
    // No installer can survive process termination; verified package caches do.
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"InstallerActive"];
    [LRDiagnosticCenter configure:[[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"LinuxRunnerDiagnostics" isDirectory:YES]];
    [LRGuestCrashCenter configure:[[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"LinuxRunnerDiagnostics/application-crashes" isDirectory:YES]];
    bootLogDirectory = [[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"LinuxRunnerLogs" isDirectory:YES];
    NSError *error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtURL:bootLogDirectory withIntermediateDirectories:YES attributes:nil error:&error]) { LRBootEvent("persistent startup log unavailable"); return; }
    for (NSString *name in @[@"startup.log", @"runtime-snapshot.bin"]) {
        NSURL *source = [bootLogDirectory URLByAppendingPathComponent:name];
        NSURL *previous = [bootLogDirectory URLByAppendingPathComponent:[@"previous-" stringByAppendingString:name]];
        [NSFileManager.defaultManager removeItemAtURL:previous error:nil];
        [NSFileManager.defaultManager moveItemAtURL:source toURL:previous error:nil];
    }
    bootLogFD = open([bootLogDirectory URLByAppendingPathComponent:@"startup.log"].fileSystemRepresentation, O_WRONLY|O_CREAT|O_APPEND|O_NOFOLLOW, 0600);
    int fd = open([bootLogDirectory URLByAppendingPathComponent:@"runtime-snapshot.bin"].fileSystemRepresentation, O_RDWR|O_CREAT|O_NOFOLLOW, 0600);
    if (fd >= 0 && ftruncate(fd, sizeof(struct LRBootSnapshot)) == 0) {
        void *map = mmap(NULL, sizeof(struct LRBootSnapshot), PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0);
        if (map != MAP_FAILED) { bootSnapshot = map; atomic_store(&bootSnapshot->version, 1); }
    }
    if (fd >= 0) close(fd);
    LRBootEvent("process entered main; persistent log initialized");
    // Raise the host soft limit once (shared by all guest processes; the guest
    // RLIMIT_NOFILE is separate) and record the inherited and resulting values.
    extern const char *host_nofile_describe(char *buf, size_t size);
    char limits[360] = "HOST_RESOURCES: ";
    host_nofile_describe(limits + strlen(limits), sizeof limits - strlen(limits));
    LRBootEvent(limits);
}
static void LRObserveSyscall(int pid, uint64_t pc, uint64_t sp, unsigned syscall) { LRBootSnapshot(pid, pc, sp, syscall, 0); }
static void LRObserveMemory(const char *operation, uint64_t address, uint64_t length, int protection, int flags, int error) {
    char message[256]; snprintf(message, sizeof(message), "MEMORY %s address=0x%llx length=%llu prot=%d flags=%d errno=%d", operation, (unsigned long long)address, (unsigned long long)length, protection, flags, error);
    LRBootEvent(message);
}
extern void (*runtime_syscall_observer)(int, uint64_t, uint64_t, unsigned);
extern void (*runtime_guest_fault)(int, int, const char *, uint64_t, uint64_t, int, uint64_t, uint32_t);
extern void (*runtime_fault_context)(const char *);
static void LRGuestFault(int pid,int ppid,const char *comm,uint64_t pc,uint64_t sp,int signal,uint64_t address,uint32_t instruction) {
    char line[300];snprintf(line,sizeof line,"guest fault pid=%d ppid=%d comm=%.16s signal=%d pc=%#llx sp=%#llx address=%#llx instruction=%#x",pid,ppid,comm,signal,(unsigned long long)pc,(unsigned long long)sp,(unsigned long long)address,instruction);LRBootEvent(line);
    LRBootLogSync();
    @autoreleasepool {
        char executable[MAX_PATH] = "";
        if(current && current->mm && current->mm->exefile) generic_getpath(current->mm->exefile,executable);
        uint64_t lr = current ? current->cpu.regs[30] : 0;
        NSString *root = LRRuntimeBridge.activeRootName.length ? LRRuntimeBridge.activeRootName : @"unknown";
        NSString *decoded = (instruction & 0xffe0001f) == 0xd4200000 ? [NSString stringWithFormat:@"BRK #%u",(instruction>>5)&65535] : instruction == 0x2ea07842 ? @"SQNEG v2.2s, v2.2s" : @"raw instruction; full disassembly unavailable";
        [LRGuestCrashCenter begin:@{@"application":[NSString stringWithUTF8String:comm]?:@"unknown",@"executable":[NSString stringWithUTF8String:executable]?:@"unknown",@"pid":@(current?current->tgid:pid).stringValue,@"tid":@(pid).stringValue,@"ppid":@(ppid).stringValue,@"signal":@(signal).stringValue,@"signal_name":signal==4?@"SIGILL":signal==5?@"SIGTRAP":signal==6?@"SIGABRT":signal==7?@"SIGBUS":signal==11?@"SIGSEGV":@"none",@"pc":[NSString stringWithFormat:@"%#llx",(unsigned long long)pc],@"lr":[NSString stringWithFormat:@"%#llx",(unsigned long long)lr],@"sp":[NSString stringWithFormat:@"%#llx",(unsigned long long)sp],@"address":[NSString stringWithFormat:@"%#llx",(unsigned long long)address],@"instruction":[NSString stringWithFormat:@"%#x",instruction],@"disassembly":decoded,@"rootfs":root,@"version":[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]?:@"unknown",@"build":[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"]?:@"unknown",@"source_commit":[NSBundle.mainBundle objectForInfoDictionaryKey:@"LinuxRunnerSourceCommit"]?:@"unknown",@"environment":@"iOS ARM64 interpreter; 4 KB guest pages"}];
    }
}
extern void (*runtime_guest_output)(int,int,int,const char *);
static void LRGuestOutput(int tid,int tgid,int fd,const char *text) {
    @autoreleasepool {
        NSString *safe=[LRDiagnosticCenter crashOutput:[NSString stringWithUTF8String:text]?:@"unreadable output"];
        [LRGuestCrashCenter append:[NSString stringWithFormat:@"FAULT_%@ tid=%d tgid=%d %@",fd==2?@"STDERR":@"STDOUT",tid,tgid,safe] tid:tid];
    }
}
extern void (*runtime_guest_terminated)(int,int,int);
static void LRGuestTerminated(int tid,int signal,int exitCode) {
    if (signal != 0) LRBootLogSync();
    @autoreleasepool { [LRGuestCrashCenter finish:tid signal:signal exitCode:exitCode]; }
}
static void LRFaultContext(const char *line) {
    LRBootEvent(line);
    @autoreleasepool { [LRGuestCrashCenter append:[NSString stringWithUTF8String:line]?:@"" tid:current?current->pid:0]; }
}
extern atomic_bool runtime_syscall_timing_enabled;
extern atomic_bool runtime_futex_pi_trace_enabled;
extern void (*runtime_syscall_result_observer)(int, int, unsigned, const uint64_t *, int64_t, uint64_t);
static const char *LRCallName(unsigned n) {
    switch(n){case 22:return "epoll_pwait";case 25:return "fcntl";case 52:return "fchmod";case 54:return "fchownat";case 452:return "fchmodat2";case 56:return "openat";case 57:return "close";case 63:return "read";case 64:return "write";case 73:return "ppoll";case 93:return "exit";case 94:return "exit_group";case 95:return "waitid";case 98:return "futex";case 129:return "kill";case 134:return "rt_sigaction";case 135:return "rt_sigprocmask";case 198:return "socket";case 199:return "socketpair";case 208:return "sendto";case 211:return "sendmsg";case 212:return "recvmsg";case 214:return "brk";case 215:return "munmap";case 220:return "clone";case 221:return "execve";case 222:return "mmap";case 226:return "mprotect";case 279:return "memfd_create";case 435:return "clone3";default:return "aarch64-syscall";}
}
static void LRObserveCompletedCall(int tid,int pid,unsigned number,const uint64_t *args,int64_t result,uint64_t duration) {
    int level=atomic_load(&diagnosticLevel),p=atomic_load(&diagnosticPID),n=atomic_load(&diagnosticSyscall);
    if((p>=0&&p!=pid&&p!=tid)||(n>=0&&n!=(int)number))return;
    BOOL lifecycle=number==93||number==94||number==220||number==221||number==435||number==95||number==129;
    if(level<3&&!lifecycle&&result!=-38&&result!=-12&&result!=-24&&result!=-23)return;
    if(level<4&&atomic_load(&diagnosticErrorsOnly)&&!lifecycle&&result>=0)return;
    @autoreleasepool {
        NSString *message=[NSString stringWithFormat:@"name=%s number=%u result=%lld errno=%lld duration_ns=%llu duration_measured=%d args=%llx,%llx,%llx,%llx,%llx,%llx",LRCallName(number),number,(long long)result,(long long)(result<0&&result>=-4095?-result:0),(unsigned long long)duration,duration!=0,(unsigned long long)args[0],(unsigned long long)args[1],(unsigned long long)args[2],(unsigned long long)args[3],(unsigned long long)args[4],(unsigned long long)args[5]];
        [LRDiagnosticCenter record:lifecycle?@"PROCESS":@"SYSCALL" severity:result<0?1:2 message:message pid:pid tid:tid];
    }
}
static void LRUpdateSyscallResultObserver(void) {
    // Only attach the completed-syscall observer when verbose diagnostics
    // (DEBUG/TRACE) or an explicit PID/syscall filter is active; default INFO
    // leaves it NULL for zero per-syscall overhead.
    bool active = atomic_load(&diagnosticLevel) >= 3 || atomic_load(&diagnosticPID) >= 0 || atomic_load(&diagnosticSyscall) >= 0;
    __atomic_store_n(&runtime_syscall_result_observer, active ? LRObserveCompletedCall : NULL, __ATOMIC_RELEASE);
}
extern void (*runtime_memory_failure)(const char *, uint64_t, uint64_t, int, int, int);

extern int fakefs_bind_mount(const char *, const char *, bool);
extern int fakefs_bind_mount_set_owner(const char *, uint32_t, uint32_t);
static BOOL bootAttempted;
static atomic_bool environmentDeletionActive; // also read by background importers
static BOOL snapshotOperationActive = NO;
static NSString *bootedRoot;
static int bootResult;
static NSMutableArray<NSString *> *events;
extern void (*runtime_instruction_failure)(int, uint64_t, uint32_t);
static void instructionFailure(int pid, uint64_t pc, uint32_t instruction) {
    LRBootSnapshot(pid, pc, current ? current->cpu.sp : 0, current ? current->syscall_restart_num : 0, instruction);
    @autoreleasepool {
        [LRRuntimeBridge logCategory:@"LOADER" event:[NSString stringWithFormat:
            @"unsupported instruction pid=%d pc=0x%llx encoding=0x%08x", pid, (unsigned long long)pc, instruction]];
    }
    LRBootLogSync();
}

static NSError *lrError(int code, NSString *message) {
    return [NSError errorWithDomain:@"dev.linuxrunner.runtime" code:code
                          userInfo:@{NSLocalizedDescriptionKey:message}];
}
static BOOL validRoot(NSString *name) {
    return name.length && ![name isEqual:@"."] && ![name isEqual:@".."] &&
        [name rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/\\\0"]].location == NSNotFound;
}

// ---- Managed Support Bundle Deployment -------------------------------------
static NSString * const LRSupportFolder = @".linuxrunner/support";
static NSURL *LRPreparedSupportFolder;
static NSString *LRPreparedSupportRoot;

static NSString *LRSupportSHA256(NSData *data) {
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

static NSURL *LRPrepareSupportFull(NSError **error) {
    NSString *root = LRRuntimeBridge.activeRootName;
    if (!validRoot(root)) {
        if (error) *error = lrError(ENOENT, @"No active Debian environment.");
        return nil;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *folder = [LRRuntimeBridge exchangeURL:root];
    for (NSString *component in [LRSupportFolder componentsSeparatedByString:@"/"]) {
        folder = [folder URLByAppendingPathComponent:component isDirectory:YES];
        NSNumber *symlink = nil;
        [folder getResourceValue:&symlink forKey:NSURLIsSymbolicLinkKey error:nil];
        if (symlink.boolValue) {
            if (error) *error = lrError(EINVAL, @"Managed support directory is a symbolic link.");
            return nil;
        }
        if (![fm createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error]) return nil;
    }
    NSURL *bundle = [NSBundle.mainBundle URLForResource:@"Support" withExtension:@"bundle"];
    NSData *manifestData = bundle ? [NSData dataWithContentsOfURL:[bundle URLByAppendingPathComponent:@"support-manifest.json"] options:0 error:error] : nil;
    if (!manifestData) {
        if (error && !*error) *error = lrError(ENOENT, @"Bundled support manifest is missing.");
        return nil;
    }
    NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:error];
    if (![manifest isKindOfClass:NSDictionary.class] || ![manifest[@"schema"] isEqual:@1] || ![manifest[@"resources"] isKindOfClass:NSArray.class]) {
        if (error) *error = lrError(EINVAL, @"Invalid bundled support manifest.");
        return nil;
    }
    [LRRuntimeBridge logCategory:@"SUPPORT_DEPLOY" event:[NSString stringWithFormat:@"version=%@ destination=/home/mobile/Downloads/%@", manifest[@"version"], LRSupportFolder]];
    NSMutableArray *resources = [manifest[@"resources"] mutableCopy];
    [resources addObject:@{@"name":@"support.sha256", @"mode":@"0644"}];
    [resources addObject:@{@"name":@"support-manifest.json", @"mode":@"0644"}];
    for (NSDictionary *resource in resources) {
        NSString *name = resource[@"name"];
        if (![name isKindOfClass:NSString.class] || !name.length || ![name isEqual:name.lastPathComponent] || [name hasPrefix:@"."]) {
            if (error) *error = lrError(EINVAL, @"Invalid support-resource name.");
            return nil;
        }
        NSData *source = [NSData dataWithContentsOfURL:[bundle URLByAppendingPathComponent:name] options:0 error:error];
        if (!source) return nil;
        if (resource[@"sha256"] && ![LRSupportSHA256(source) isEqual:resource[@"sha256"]]) {
            if (error) *error = lrError(EINVAL, [NSString stringWithFormat:@"Bundled support checksum mismatch: %@", name]);
            return nil;
        }
        NSURL *destination = [folder URLByAppendingPathComponent:name];
        NSNumber *symlink = nil;
        [destination getResourceValue:&symlink forKey:NSURLIsSymbolicLinkKey error:nil];
        BOOL same = !symlink.boolValue && [[NSData dataWithContentsOfURL:destination] isEqual:source];
        if (!same && ![source writeToURL:destination options:NSDataWritingAtomic error:error]) return nil;
        NSNumber *permissions = [resource[@"mode"] isEqual:@"0755"] ? @0755 : @0644;
        if (![fm setAttributes:@{NSFilePosixPermissions:permissions} ofItemAtPath:destination.path error:error]) return nil;
        [LRRuntimeBridge logCategory:@"SUPPORT_DEPLOY" event:[NSString stringWithFormat:@"%@=%@", name, same ? @"unchanged" : @"installed"]];
    }
    [LRRuntimeBridge logCategory:@"SUPPORT_DEPLOY" event:@"result=PASS"];
    return folder;
}

static NSURL *LRPrepareSupport(NSError **error) {
    NSString *root = LRRuntimeBridge.activeRootName;
    if (!validRoot(root)) {
        if (error) *error = lrError(ENOENT, @"No active Debian environment.");
        return nil;
    }
    @synchronized(NSFileManager.class) {
        if (LRPreparedSupportFolder && [LRPreparedSupportRoot isEqualToString:root] &&
            [NSFileManager.defaultManager fileExistsAtPath:[LRPreparedSupportFolder URLByAppendingPathComponent:@"support-manifest.json"].path])
            return LRPreparedSupportFolder;
    }
    NSURL *folder = LRPrepareSupportFull(error);
    if (folder) @synchronized(NSFileManager.class) { LRPreparedSupportRoot = [root copy]; LRPreparedSupportFolder = folder; }
    return folder;
}

@interface LRDeviceDiagnosticsController : UIViewController
@property UILabel *details;
@property UIButton *startButton;
@property UIButton *managerButton;
@property UISwitch *autoStartSwitch;
@end

@interface LRInstallProgress : NSObject <ProgressReporter>
@property(copy) void (^progress)(double,NSString *);
@property(copy) BOOL (^cancel)(void);
@end
@implementation LRInstallProgress
- (void)updateProgress:(double)value message:(NSString *)message { if(self.progress)self.progress(value,message); }
- (BOOL)shouldCancel { return self.cancel&&self.cancel(); }
@end
static int LRPackageProgress(void *context,size_t value,size_t total) { LRInstallProgress *reporter=(__bridge LRInstallProgress *)context;[reporter updateProgress:(double)value/MAX(total,1) message:@"Assembling verified Debian packages"];return reporter.shouldCancel; }
static int LRPackageCancel(void *context) { return ((__bridge LRInstallProgress *)context).shouldCancel; }
static void LRPackageDiagnostic(void *context,int severity,const char *message) {
    (void)context;
    @autoreleasepool { [LRDiagnosticCenter installer:severity message:[NSString stringWithUTF8String:message]?:@"bootstrap diagnostic encoding failure"]; }
}

@interface LRTransferControl ()
@property BOOL stopped;
@property uint64_t transferred,total;
@end
@implementation LRTransferControl
- (void)cancel { @synchronized(self){_stopped=YES;} }
- (NSDictionary *)snapshot { @synchronized(self){return @{@"cancelled":@(_stopped),@"bytes":@(_transferred),@"total":@(_total)};} }
- (void)recordBytes:(uint64_t)bytes total:(uint64_t)total { @synchronized(self){_transferred=bytes;_total=total;} }
@end
static bool LRTransferCancelled(void *context){return [((__bridge LRTransferControl *)context).snapshot[@"cancelled"] boolValue];}
static void LRTransferProgress(void *context,uint64_t bytes,uint64_t total){[(__bridge LRTransferControl *)context recordBytes:bytes total:total];}
static struct lr_transfer_control LRTransferCallbacks(LRTransferControl *control){return (struct lr_transfer_control){LRTransferCancelled,LRTransferProgress,(__bridge void *)control};}

@implementation LRRuntimeBridge
#if TARGET_OS_SIMULATOR
+ (NSDictionary *)networkABIContract {
    struct header {uint32_t len;uint16_t type,flags;uint32_t seq,pid;};
    struct {struct header h;uint8_t family,pad[3];} req={.h={17,18,0x301,41,0}};
    NSMutableDictionary *result=[NSMutableDictionary new];BOOL ok=YES;
    char *buffer=malloc(NETLINK_SNAPSHOT_SIZE);
    if(!buffer)return @{@"status":@"FAIL",@"reason":@"allocation"};
    for(NSNumber *type in @[@18,@22,@26]) {
        req.h.type=type.unsignedShortValue;
        int n=netlink_snapshot(&req,sizeof(req),73,buffer,NETLINK_SNAPSHOT_SIZE);
        unsigned messages=0;BOOL done=NO;int error=0;
        for(size_t at=0;n>0&&at<(size_t)n;) {
            struct header h;if((size_t)n-at<sizeof(h)){error=-1;break;}
            memcpy(&h,buffer+at,sizeof(h));
            if(h.len<sizeof(h)||h.len>(size_t)n-at||h.seq!=41||h.pid!=73){error=-1;break;}
            if(h.type==2&&h.len>=sizeof(h)+4)memcpy(&error,buffer+at+sizeof(h),4);
            else if(h.type==3)done=YES;else messages++;
            at+=((size_t)h.len+3)&~(size_t)3;
        }
        BOOL passed=n>0&&done&&!error&&(type.intValue==26||messages>0);
        result[type.stringValue]=@{@"status":passed?@"PASS":@"FAIL",@"messages":@(messages),@"linux_error":@(n<0?n:error)};ok=ok&&passed;
    }
    free(buffer);result[@"status"]=ok?@"PASS":@"FAIL";
    result[@"scope"]=@"Simulator sandbox, real host snapshots encoded as Linux link/address/route replies; no physical Wi-Fi transition";
    return result;
}
#endif

+ (BOOL)autoStart {
    id configured = [NSUserDefaults.standardUserDefaults objectForKey:@"LinuxRunnerRuntimeAutoStart"];
    return configured ? [configured boolValue] : ![[NSBundle.mainBundle objectForInfoDictionaryKey:@"LinuxRunnerDiagnostic"] boolValue];
}
+ (BOOL)canStartRuntime { return !bootAttempted; }
+ (int)startRuntime {
    NSAssert(NSThread.isMainThread, @"Boot is serialized on the main thread");
    return [(AppDelegate *)UIApplication.sharedApplication.delegate startLinuxRuntime];
}
+ (BOOL)beginBoot {
    NSAssert(NSThread.isMainThread, @"Boot is serialized on the main thread");
    if (bootAttempted) return NO; // Partial initialization cannot safely restart.
    if (!Roots.instance.defaultRoot) return NO;
    bootAttempted = YES;
#if TARGET_OS_IOS && !TARGET_OS_SIMULATOR
    // Scale the Asbestos translation cache cap with device RAM while leaving
    // headroom for guest data and UIKit within iOS Jetsam limits.
    unsigned long long physMem = NSProcessInfo.processInfo.physicalMemory;
    const char *codeCapMB = physMem >= (10ULL << 30) ? "96"
                          : physMem >= (7ULL << 30)  ? "64"
                          : "32";
    setenv("ISH_CODE_CAP_MB", codeCapMB, 0);
    setenv("ISH_CODE_IDLE_FLUSH_S", "60", 0);
#endif
    extern void arm64_memory_pc_fusion_set_enabled_from_env(const char *);
    id fusionSetting = [NSUserDefaults.standardUserDefaults objectForKey:@"LinuxRunner.experimentalMemoryPCFusion"];
    BOOL memoryFusion = fusionSetting ? [fusionSetting boolValue] : YES;
    arm64_memory_pc_fusion_set_enabled_from_env(memoryFusion ? "1" : "0");
    LRBootEvent(memoryFusion ? (fusionSetting ? "[RUNTIME] Asbestos memory dispatch fusion enabled (Settings)" : "[RUNTIME] Asbestos memory dispatch fusion enabled (default)") : "[RUNTIME] Asbestos previous memory dispatch selected in Settings");
    // Settings › CPU & Memory: CPU cores and memory Linux programs see (0 =
    // automatic). The runtime reads them once, so they apply from this launch.
    {
        NSInteger cores = [NSUserDefaults.standardUserDefaults integerForKey:LRSystemCPUCoresKey];
        NSInteger memoryMB = [NSUserDefaults.standardUserDefaults integerForKey:LRSystemMemoryMBKey];
        NSInteger hostCores = NSProcessInfo.processInfo.activeProcessorCount;
        if (cores > 0) setenv("LINUXRUNNER_CPU_CORES", [NSString stringWithFormat:@"%ld", (long)MIN(cores, MAX(hostCores, 1))].UTF8String, 1);
        else unsetenv("LINUXRUNNER_CPU_CORES");
        if (memoryMB > 0) setenv("LINUXRUNNER_MEMORY_MB", [NSString stringWithFormat:@"%ld", (long)memoryMB].UTF8String, 1);
        else unsetenv("LINUXRUNNER_MEMORY_MB");
        LRBootEvent([[NSString stringWithFormat:@"[RUNTIME] CPU cores=%@ memory=%@ (host cores %ld)", cores > 0 ? @(cores).stringValue : @"automatic (4)",
            memoryMB > 0 ? [NSString stringWithFormat:@"%ld MB", (long)memoryMB] : @"automatic", (long)hostCores] UTF8String]);
    }
    // All anonymous guest shared-memory backing stays inside this sandbox.
    NSString *temporary = NSTemporaryDirectory();
    if (temporary.length) setenv("TMPDIR", temporary.fileSystemRepresentation, 1);
    LRBootEvent("guest shared-memory backing configured in application temporary directory");
    id networkView=[NSUserDefaults.standardUserDefaults objectForKey:@"LinuxRunnerNetworkInterfaceView"];
    setenv("ISH_NETLINK_STUB",(!networkView||[networkView boolValue])?"1":"0",1);
    LRBootEvent("read-only host network interface compatibility configured; XNU retains network ownership");
    __atomic_store_n(&runtime_syscall_observer, LRObserveSyscall, __ATOMIC_RELEASE);
    runtime_guest_fault = LRGuestFault;
    runtime_fault_context = LRFaultContext;
    runtime_guest_terminated = LRGuestTerminated;
    runtime_guest_output = LRGuestOutput;
    extern volatile bool g_trace_syscalls, g_trace_faults;
    g_trace_syscalls = g_trace_faults = [NSUserDefaults.standardUserDefaults boolForKey:@"LinuxRunnerVerboseRuntime"];
    runtime_memory_failure = LRObserveMemory;
    runtimeStartedAt=NSProcessInfo.processInfo.systemUptime;
    atomic_store(&diagnosticLevel,[NSUserDefaults.standardUserDefaults objectForKey:@"DiagnosticLevel"]?[NSUserDefaults.standardUserDefaults integerForKey:@"DiagnosticLevel"]:2);
    int initialLevel = atomic_load(&diagnosticLevel);
    atomic_store(&runtime_syscall_timing_enabled, initialLevel >= 3);
    atomic_store(&runtime_futex_pi_trace_enabled, initialLevel >= 3 && (atomic_load(&diagnosticSyscall) < 0 || atomic_load(&diagnosticSyscall) == 98));
    LRUpdateSyscallResultObserver();
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(thermalStateChanged:) name:NSProcessInfoThermalStateDidChangeNotification object:nil];
    LRBootEvent("manual/automatic boot requested; optional numeric observers installed");
    return YES;
}
+ (UIViewController *)diagnosticsController { return [LRDeviceDiagnosticsController new]; }
+ (NSDictionary<NSString *,NSString *> *)deviceDiagnostics {
    extern bool arm64_memory_pc_fusion_is_enabled(void);
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSString *name = [NSUserDefaults.standardUserDefaults stringForKey:@"Default Root"];
    NSURL *root = name.length ? [[ContainerURL() URLByAppendingPathComponent:@"roots"] URLByAppendingPathComponent:name] : nil;
    NSURL *debianBundle = [NSBundle.mainBundle URLForResource:@"DebianSupport" withExtension:@"bundle"];
    pthread_mutex_lock(&bootLogLock); NSString *last = [NSString stringWithUTF8String:lastMilestone]; pthread_mutex_unlock(&bootLogLock);
    return @{
        @"Device architecture": @"arm64", @"iOS": UIDevice.currentDevice.systemVersion,
        @"Distribution": @"Debian GNU/Linux 13 (trixie) minimal",
        @"Asbestos memory dispatch": !bootAttempted ? @"not started" : arm64_memory_pc_fusion_is_enabled() ? @"experimental fusion" : @"stable dispatch",
        @"App bundle path": NSBundle.mainBundle.bundlePath,
        @"Application Support": support.path ?: @"unavailable", @"Runtime container": ContainerURL().path ?: @"unavailable",
        @"Debian manifest bundle": debianBundle.path ?: @"missing",
        @"Writable rootfs path": root.path ?: @"not installed yet", @"Writable rootfs exists": root && [NSFileManager.defaultManager fileExistsAtPath:[root URLByAppendingPathComponent:@"meta.db"].path] ? @"yes" : @"no (not installed yet)",
        @"Runtime state": self.runtimeStatus, @"Last startup milestone": last ?: @"unknown",
        @"Last runtime error": bootResult < 0 ? [NSString stringWithFormat:@"boot errno=%d; relaunch to retry", bootResult] : LRGuestCrashCenter.latestSummary,
        @"Host startup error": bootResult < 0 ? @(bootResult).stringValue : @"none recorded",
        @"Latest guest application failure": LRGuestCrashCenter.latestSummary,
        @"Startup logs": bootLogDirectory.path ?: @"stderr only", @"Host page size": [NSString stringWithFormat:@"%ld", sysconf(_SC_PAGESIZE)]
    };
}
+ (NSURL *)managedStorageURL { return ContainerURL(); }
+ (NSArray *)diagnosticEntries { return [LRDiagnosticCenter entries]; }

+ (NSString *)redactDiagnosticText:(NSString *)text application:(BOOL)application { return [LRDiagnosticCenter redact:text application:application]; }
+ (void)configureDiagnostics:(int)level process:(int)pid syscall:(int)number errorsOnly:(BOOL)errorsOnly {
    atomic_store(&diagnosticLevel,level);atomic_store(&diagnosticPID,pid);atomic_store(&diagnosticSyscall,number);atomic_store(&diagnosticErrorsOnly,errorsOnly);
    atomic_store(&runtime_syscall_timing_enabled,level>=3);
    atomic_store(&runtime_futex_pi_trace_enabled,level>=3 && (number<0||number==98));
    LRUpdateSyscallResultObserver();
    [LRDiagnosticCenter setLevel:level];
}
static NSString *LRThermalState(void) {
    switch(NSProcessInfo.processInfo.thermalState){case NSProcessInfoThermalStateNominal:return @"Nominal";case NSProcessInfoThermalStateFair:return @"Fair";case NSProcessInfoThermalStateSerious:return @"Serious";case NSProcessInfoThermalStateCritical:return @"Critical";default:return @"Unknown";}
}
+ (void)thermalStateChanged:(NSNotification *)note {
    [self logCategory:@"MEMORY" event:[NSString stringWithFormat:@"host thermal state changed: %@ (iOS category; no temperature measurement)",LRThermalState()]];
}
+ (NSArray *)taskSnapshot {
    struct row { int pid, ppid, uid, threads; char state; char name[17]; uint64_t cpu_us; struct mm *mm; };
    struct row *rows = calloc(MAX_PID, sizeof *rows); int count = 0;
    if (!rows) return @[];
    lock(&pids_lock);
    for (int i = 1; i < MAX_PID; i++) {
        struct task *task = pid_get_task(i);
        if (!task || task->pid != task->tgid || task->exiting) continue;
        struct row *r = &rows[count++];
        r->pid = task->pid; r->ppid = task_parent_pid(task); r->uid = (int) task->uid;
        snprintf(r->name, sizeof r->name, "%s", task->comm);
        bool running = false; struct task *thread;
        lock(&task->group->lock);
        list_for_each_entry(&task->group->threads, thread, group_links) { r->threads++; if (!thread->blocking) running = true; }
        bool stopped = task->group->stopped;
        unlock(&task->group->lock);
        r->state = task->zombie ? 'Z' : stopped ? 'T' : running ? 'R' : 'S';
        struct rusage_ usage = rusage_get_group_locked(task->group);
        r->cpu_us = (uint64_t) usage.utime.sec * 1000000 + usage.utime.usec + (uint64_t) usage.stime.sec * 1000000 + usage.stime.usec;
        lock(&task->general_lock);
        r->mm = task->mm; if (r->mm) mm_retain(r->mm);
        unlock(&task->general_lock);
    }
    unlock(&pids_lock);
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:count];
    for (int i = 0; i < count; i++) {
        struct row *r = &rows[i];
        unsigned long mapped = 0, shared = 0, anonymous = 0;
        if (r->mm) { mem_page_counts(&r->mm->mem, &mapped, &shared, &anonymous); mm_release(r->mm); }   // outside pids_lock
        [result addObject:@{@"pid": @(r->pid), @"ppid": @(r->ppid), @"uid": @(r->uid), @"name": @(r->name), @"state": [NSString stringWithFormat:@"%c", r->state],
            @"threads": @(r->threads), @"cpu_ms": @(r->cpu_us / 1000), @"cpu_us": @(r->cpu_us), @"mapped_kb": @(mapped * (PAGE_SIZE / 1024)),
            @"anonymous_kb": @(anonymous * (PAGE_SIZE / 1024)), @"shared_kb": @(shared * (PAGE_SIZE / 1024))}];
    }
    free(rows);
    return result;
}
+ (uint64_t)appFootprintBytes {
    task_vm_info_data_t info = {0}; mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    return task_info(mach_task_self(), TASK_VM_INFO, (task_info_t) &info, &count) == KERN_SUCCESS ? info.phys_footprint : 0;
}
+ (NSDictionary<NSString *, NSNumber *> *)networkIOBytes {
    extern void sock_network_totals(uint64_t *rx_bytes, uint64_t *tx_bytes);
    uint64_t rx = 0, tx = 0;
    sock_network_totals(&rx, &tx);
    return @{@"rx_bytes": @(rx), @"tx_bytes": @(tx)};
}
+ (BOOL)terminateProcess:(int)pid force:(BOOL)force {
    if (pid <= 1) return NO;   // init (the session's root) is never terminated from here
    lock(&pids_lock);
    struct task *task = pid_get_task(pid);
    BOOL found = task && task->pid == task->tgid && !task->zombie;
    if (found) send_signal(task, force ? SIGKILL_ : SIGTERM_, SIGINFO_NIL);
    unlock(&pids_lock);
    [self logCategory:@"PROCESS" event:[NSString stringWithFormat:@"Task Manager sent %@ to pid %d (%@)", force ? @"SIGKILL" : @"SIGTERM", pid, found ? @"delivered" : @"no such process"]];
    return found;
}
+ (NSDictionary *)healthSummary {
    int processes=0,threads=0;
    lock(&pids_lock);
    for(int i=1;i<MAX_PID;i++){struct task *task=pid_get_task(i);if(task&&!task->exiting&&!task->zombie){threads++;if(task->pid==task->tgid)processes++;}}
    unlock(&pids_lock);
    mach_task_basic_info_data_t info={0};mach_msg_type_number_t count=MACH_TASK_BASIC_INFO_COUNT;
    BOOL haveMemory=task_info(mach_task_self(),MACH_TASK_BASIC_INFO,(task_info_t)&info,&count)==KERN_SUCCESS;
    return @{@"runtime":self.runtimeStatus,@"source_commit":[NSBundle.mainBundle objectForInfoDictionaryKey:@"LinuxRunnerSourceCommit"]?:@"unavailable",@"distribution_root":self.activeRootName.length?self.activeRootName:@"none",@"distribution":@"debian",@"architecture":@"aarch64",@"backend":@"ARM64 interpreter",@"host_page_size":@(getpagesize()),@"guest_page_size":@4096,@"host_resident_bytes":haveMemory?@(info.resident_size):@0,@"memory_measured":@(haveMemory),@"host_thermal_state":LRThermalState(),@"low_power_mode":@(NSProcessInfo.processInfo.lowPowerModeEnabled),@"guest_processes":@(processes),@"guest_threads":@(threads),@"runtime_uptime_seconds":@(runtimeStartedAt?NSProcessInfo.processInfo.systemUptime-runtimeStartedAt:0),@"thread_state_limit":@"Counts are live tasks; no claim of precise sleeping/blocked state"};
}
+ (NSURL *)catalogURL { return [ContainerURL() URLByAppendingPathComponent:@"environments.json"]; }
+ (NSArray<NSString *> *)rootNames { return Roots.instance.roots.array; }
+ (NSString *)activeRootName { return bootedRoot ?: Roots.instance.defaultRoot ?: @""; }
+ (NSString *)nextRootName { return Roots.instance.defaultRoot ?: @""; }
+ (void)setNextRootName:(NSString *)name {
    if (environmentDeletionActive || snapshotOperationActive) return;
    if (validRoot(name) && [Roots.instance.roots containsObject:name]) Roots.instance.defaultRoot = name;
}
+ (NSURL *)rootURL:(NSString *)name {
    NSParameterAssert(validRoot(name));
    return [Roots.instance rootUrl:name];
}
+ (NSURL *)exchangeURL:(NSString *)name {
    NSParameterAssert(validRoot(name));
    return [[ContainerURL() URLByAppendingPathComponent:@"exchanges" isDirectory:YES]
            URLByAppendingPathComponent:name isDirectory:YES];
}
+ (BOOL)isRunning {
    if (!bootAttempted || bootResult < 0) return NO;
    lock(&pids_lock);
    BOOL running = pid_get_task(1) != NULL;
    unlock(&pids_lock);
    return running;
}
+ (NSString *)runtimeStatus {
    if (!Roots.instance.defaultRoot) return @"Not installed — set up Debian minimal to begin";
    if (!bootAttempted) return @"Not started";
    return bootResult < 0 ? [NSString stringWithFormat:@"Boot failed (%d)", bootResult] :
        ([self isRunning] ? @"Running" : @"Stopped — relaunch required");
}
+ (void)recordBoot:(NSString *)root error:(int)error {
    bootedRoot = [root copy]; bootResult = error;
    if (error == 0) {
        // Boot succeeded: detach the per-syscall boot-snapshot observer to avoid
        // snapshotWriter contention and MAP_SHARED writes on every guest syscall.
        __atomic_store_n(&runtime_syscall_observer, NULL, __ATOMIC_RELEASE);
    }
    [self logCategory:@"EXEC" event:[NSString stringWithFormat:@"boot result=%d backend=asbestos", error]];
    if (error != 0) {
        LRBootLogSync();
    }
    if (error == 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self syncServiceManagerAndAutostart];
        });
    }
}
static BOOL LRServiceManagerSyncInFlight;
static BOOL LRServiceManagerSyncPending;
static NSUInteger LRServiceManagerInitRetries;
+ (void)syncServiceManagerAndAutostart {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self syncServiceManagerAndAutostart]; });
        return;
    }
    if (!self.isRunning) return;
    NSString *root = self.activeRootName;
    if (validRoot(root)) {
        NSURL *initMarker = [[Roots.instance rootUrl:root] URLByAppendingPathComponent:@"data/var/lib/linuxrunner/initialized"];
        if (![NSFileManager.defaultManager fileExistsAtPath:initMarker.path]) {
            if (LRServiceManagerInitRetries < 30) {
                LRServiceManagerInitRetries++;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self syncServiceManagerAndAutostart];
                });
            }
            return;
        }
    }
    if (LRServiceManagerSyncInFlight) {
        LRServiceManagerSyncPending = YES;
        return;
    }
    NSError *error = nil;
    if (!LRPrepareSupport(&error)) {
        [self logCategory:@"SERVICE" event:[NSString stringWithFormat:@"prepare support failed: %@", error.localizedDescription ?: @"unknown"]];
        return;
    }
    LRServiceManagerSyncInFlight = YES;
    LRServiceManagerSyncPending = NO;
    NSString *script =
        @"src=/home/mobile/Downloads/.linuxrunner/support/service-manager.sh\n"
        "[ -f \"$src\" ] || exit 1\n"
        "mkdir -p /usr/lib/linuxrunner /usr/local/bin /run/debianrunner-systemd/system /var/log/debianrunner-systemd /var/lib/systemd/linger\n"
        "chmod 1777 /run/debianrunner-systemd 2>/dev/null || true\n"
        "if ! cmp -s \"$src\" /usr/lib/linuxrunner/service-manager.sh 2>/dev/null; then\n"
        "  tmp=/usr/lib/linuxrunner/.service-manager.sh.tmp.$$\n"
        "  cp \"$src\" \"$tmp\" && chmod 755 \"$tmp\" && mv -f \"$tmp\" /usr/lib/linuxrunner/service-manager.sh\n"
        "fi\n"
        "ln -sf /usr/lib/linuxrunner/service-manager.sh /usr/local/bin/systemctl\n"
        "ln -sf /usr/lib/linuxrunner/service-manager.sh /usr/local/bin/journalctl\n"
        "ln -sf /usr/lib/linuxrunner/service-manager.sh /usr/local/bin/loginctl\n"
        "/usr/lib/linuxrunner/service-manager.sh boot-autostart\n";
    [self runHeadlessCommand:@[@"/bin/sh", @"-c", script] directory:@"/" completion:^(int exitCode) {
        [self logCategory:@"SERVICE" event:[NSString stringWithFormat:@"sync service-manager exit=%d", exitCode]];
        dispatch_async(dispatch_get_main_queue(), ^{
            LRServiceManagerSyncInFlight = NO;
            if (LRServiceManagerSyncPending) {
                LRServiceManagerSyncPending = NO;
                [self syncServiceManagerAndAutostart];
            }
        });
    }];
}
+ (int)prepareExchange:(NSString *)root {
    runtime_instruction_failure = instructionFailure;
    NSError *error;
    NSURL *exchange = [self exchangeURL:root];
    if (![NSFileManager.defaultManager createDirectoryAtURL:exchange withIntermediateDirectories:YES attributes:nil error:&error]) return _EIO;
    for (const char **path = (const char *[]){"/home", "/home/mobile", NULL}; *path; path++) {
        int result = generic_mkdirat(AT_PWD, *path, 0755);
        if (result < 0 && result != _EEXIST) return result;
    }
    int result = fakefs_bind_mount("/home/mobile/Downloads", exchange.fileSystemRepresentation, false);
    [self logCategory:@"FS" event:[NSString stringWithFormat:@"exchange mount result=%d", result]];
    return result;
}
+ (NSString *)activeDistributionID {
    return self.activeRootName.length ? @"debian" : nil;
}
+ (BOOL)activeEnvironmentIsDebian {
    return self.activeRootName.length > 0;
}
+ (BOOL)assembleDebianPackages:(NSArray<NSString *> *)packages toArchive:(NSURL *)archive progress:(void (^)(double))progress cancel:(BOOL (^)(void))cancel error:(NSError **)error {
    LRInstallProgress *reporter=[LRInstallProgress new];reporter.progress=^(double value,NSString *message){progress(value);};reporter.cancel=cancel;
    const char **paths=calloc(packages.count,sizeof(char *));if(!paths){if(error)*error=lrError(ENOMEM,@"Package path allocation failed");return NO;}
    for(NSUInteger i=0;i<packages.count;i++)paths[i]=packages[i].fileSystemRepresentation;
    struct lr_debian_bootstrap_options options={.progress=LRPackageProgress,.cancel=LRPackageCancel,.log=LRPackageDiagnostic,.context=(__bridge void *)reporter,.trace_entries=atomic_load(&diagnosticLevel)>=3};
    char message[2048]={0};int result=lr_debian_bootstrap_diagnosed(paths,packages.count,archive.fileSystemRepresentation,&options,message,sizeof message);free(paths);
    [LRDiagnosticCenter flush];
    if(result&&error)*error=lrError(result,[NSString stringWithUTF8String:message]);return result==0;
}
+ (BOOL)importVerifiedEnvironment:(NSURL *)archive root:(NSString *)root sha256:(NSString *)sha256 progress:(void (^)(double,NSString *))progress cancel:(BOOL (^)(void))cancel error:(NSError **)error {
    if (environmentDeletionActive) { if (error) *error=lrError(EBUSY, @"Wait for environment deletion to finish."); return NO; }
    LRInstallProgress *reporter=[LRInstallProgress new];reporter.progress=progress;reporter.cancel=cancel;
    return [Roots.instance importVerifiedRootFromArchive:archive name:root sha256:sha256 metadata:@{@"distributionID":@"debian",@"distribution":@"Debian GNU/Linux",@"version":@"13.7",@"packageManager":@"apt",@"defaultShell":@"/bin/bash"} error:error progressReporter:reporter];
}
static NSString * const LRPendingWipeKey = @"DebianRunner.pendingWipe";

+ (BOOL)isWipePending {
    return [NSUserDefaults.standardUserDefaults boolForKey:LRPendingWipeKey];
}

static void LRClearAllEnvironmentUserDefaults(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults removeObjectForKey:@"Default Root"];
    [defaults removeObjectForKey:@"LinuxRunnerSetup.root"];
    [defaults setObject:@"welcome" forKey:@"LinuxRunnerSetup.step"];
    for (NSString *key in defaults.dictionaryRepresentation.allKeys) {
        if ([key hasPrefix:@"LinuxRunnerDefaultUser."])
            [defaults removeObjectForKey:key];
    }
    [defaults synchronize];
}

+ (void)performPendingWipeIfNeeded {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (![defaults boolForKey:LRPendingWipeKey]) return;
    [defaults removeObjectForKey:LRPendingWipeKey];
    [defaults synchronize];

    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *container = ContainerURL();
    for (NSString *item in @[@"roots", @"exchanges", @"environments.json", @"downloads", @"installer-temporary"]) {
        [fm removeItemAtURL:[container URLByAppendingPathComponent:item] error:nil];
    }
    NSURL *docs = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    if (docs) [fm removeItemAtURL:[docs URLByAppendingPathComponent:@"Shared"] error:nil];
    LRClearAllEnvironmentUserDefaults();
    @synchronized(NSFileManager.class) {
        LRPreparedSupportFolder = nil;
        LRPreparedSupportRoot = nil;
    }
    if (CurrentAppGroups().count > 0) {
        [NSFileProviderManager removeAllDomainsWithCompletionHandler:^(NSError * _Nullable error) {
            if (error) NSLog(@"wipe file provider domain cleanup error: %@", error);
        }];
    }
    LRBootEvent("[WIPE] completed pending Debian Minimal wipe before runtime mount");
}

// ---- Environment Snapshots (preserved across Wipe) --------------------------

static NSURL *LRSnapshotsDirectoryURL(void) {
    NSURL *dir = [ContainerURL() URLByAppendingPathComponent:@"snapshots" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static BOOL LRValidSnapshotID(NSString *snapshotID) {
    if (![snapshotID isKindOfClass:NSString.class] || snapshotID.length == 0 || snapshotID.length > 80)
        return NO;
    for (NSUInteger i = 0; i < snapshotID.length; i++) {
        unichar c = [snapshotID characterAtIndex:i];
        BOOL ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_';
        if (!ok) return NO;
    }
    return YES;
}

static NSString *LRSHA256ForFileURL(NSURL *fileURL, uint64_t *sizeOut, BOOL (^cancel)(void), NSError **error) {
    int fd = open(fileURL.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) {
        if (error) *error = lrError(errno, @"Snapshot archive could not be opened for verification.");
        return nil;
    }
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    uint8_t buf[65536];
    uint64_t total = 0;
    for (;;) {
        if (cancel && cancel()) {
            close(fd);
            if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil];
            return nil;
        }
        ssize_t n = read(fd, buf, sizeof(buf));
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) {
            int err = errno;
            close(fd);
            if (error) *error = lrError(err, @"Failed reading snapshot archive while computing checksum.");
            return nil;
        }
        if (n == 0) break;
        CC_SHA256_Update(&ctx, buf, (CC_LONG)n);
        total += (uint64_t)n;
    }
    close(fd);
    if (sizeOut) *sizeOut = total;
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++)
        [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

+ (NSArray<NSDictionary<NSString *, id> *> *)snapshots {
    NSURL *dir = LRSnapshotsDirectoryURL();
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSURL *> *files = [fm contentsOfDirectoryAtURL:dir includingPropertiesForKeys:@[NSURLFileSizeKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    NSMutableArray<NSDictionary<NSString *, id> *> *list = [NSMutableArray new];
    for (NSURL *file in files) {
        if (![file.pathExtension isEqualToString:@"json"]) continue;
        NSData *data = [NSData dataWithContentsOfURL:file];
        if (!data) continue;
        NSDictionary *meta = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![meta isKindOfClass:NSDictionary.class]) continue;
        NSString *sid = [meta[@"id"] isKindOfClass:NSString.class] ? meta[@"id"] : nil;
        if (!LRValidSnapshotID(sid)) continue;
        NSURL *archive = [dir URLByAppendingPathComponent:[sid stringByAppendingString:@".tar.gz"]];
        if (![fm fileExistsAtPath:archive.path]) continue;
        [list addObject:meta];
    }
    [list sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        double ta = [a[@"created_at"] doubleValue];
        double tb = [b[@"created_at"] doubleValue];
        if (ta > tb) return NSOrderedAscending;
        if (ta < tb) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    return list;
}

+ (NSURL *)snapshotArchiveURLForID:(NSString *)snapshotID {
    if (!LRValidSnapshotID(snapshotID)) return nil;
    NSURL *archive = [LRSnapshotsDirectoryURL() URLByAppendingPathComponent:[snapshotID stringByAppendingString:@".tar.gz"]];
    return [NSFileManager.defaultManager fileExistsAtPath:archive.path] ? archive : nil;
}

+ (BOOL)isSnapshotOperationActive {
    return snapshotOperationActive;
}

+ (BOOL)deleteSnapshotWithID:(NSString *)snapshotID error:(NSError **)error {
    if (snapshotOperationActive || environmentDeletionActive) {
        if (error) *error = lrError(EBUSY, @"Wait for the current environment operation to finish.");
        return NO;
    }
    if (!LRValidSnapshotID(snapshotID)) {
        if (error) *error = lrError(EINVAL, @"Invalid snapshot identifier.");
        return NO;
    }
    NSURL *dir = LRSnapshotsDirectoryURL();
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *archive = [dir URLByAppendingPathComponent:[snapshotID stringByAppendingString:@".tar.gz"]];
    NSURL *meta = [dir URLByAppendingPathComponent:[snapshotID stringByAppendingString:@".json"]];
    NSError *err = nil;
    if ([fm fileExistsAtPath:archive.path] && ![fm removeItemAtURL:archive error:&err]) {
        if (error) *error = err;
        return NO;
    }
    if ([fm fileExistsAtPath:meta.path] && ![fm removeItemAtURL:meta error:&err]) {
        if (error) *error = err;
        return NO;
    }
    [self logCategory:@"SNAPSHOT" event:[NSString stringWithFormat:@"deleted snapshot id=%@", snapshotID]];
    return YES;
}

+ (void)createSnapshotNamed:(NSString *)name
                   progress:(void (^)(double fraction, NSString *message))progress
                     cancel:(BOOL (^)(void))cancel
                 completion:(void (^)(NSDictionary<NSString *, id> * _Nullable snapshot, NSError * _Nullable error))completion {
    NSAssert(NSThread.isMainThread, @"Snapshot creation starts on the main thread");
    if (snapshotOperationActive || environmentDeletionActive || [NSUserDefaults.standardUserDefaults boolForKey:@"InstallerActive"]) {
        completion(nil, lrError(EBUSY, @"Wait for the current environment operation to finish."));
        return;
    }
    NSString *rootName = self.activeRootName.length ? self.activeRootName : Roots.instance.defaultRoot;
    if (!validRoot(rootName) || ![Roots.instance.roots containsObject:rootName]) {
        completion(nil, lrError(ENOENT, @"No Debian Minimal installation found to snapshot."));
        return;
    }
    NSString *trimmedName = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSDate *now = NSDate.date;
    if (trimmedName.length == 0) {
        NSDateFormatter *fmt = [NSDateFormatter new];
        fmt.dateFormat = @"MMM d, HH:mm";
        trimmedName = [NSString stringWithFormat:@"Snapshot %@", [fmt stringFromDate:now]];
    }
    NSString *defaultUser = self.defaultLinuxUser ?: @"root";
    NSDateFormatter *idFmt = [NSDateFormatter new];
    idFmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    idFmt.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *shortUUID = [[NSUUID.UUID.UUIDString substringToIndex:6] lowercaseString];
    NSString *snapshotID = [NSString stringWithFormat:@"snap-%@-%@", [idFmt stringFromDate:now], shortUUID];

    snapshotOperationActive = YES;
    [self beginAwake:@"snapshot-create"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSURL *dir = LRSnapshotsDirectoryURL();
        NSURL *tmpArchive = [dir URLByAppendingPathComponent:[snapshotID stringByAppendingString:@".tar.gz.tmp"]];
        NSURL *finalArchive = [dir URLByAppendingPathComponent:[snapshotID stringByAppendingString:@".tar.gz"]];
        NSURL *metaURL = [dir URLByAppendingPathComponent:[snapshotID stringByAppendingString:@".json"]];
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm removeItemAtURL:tmpArchive error:nil];

        LRInstallProgress *reporter = [LRInstallProgress new];
        reporter.progress = ^(double value, NSString *message) {
            double scaled = MIN(0.85, MAX(0.0, value * 0.85));
            NSString *label = message.length ? message : @"Archiving Debian Minimal filesystem…";
            dispatch_async(dispatch_get_main_queue(), ^{
                if (progress) progress(scaled, label);
            });
        };
        reporter.cancel = cancel;

        NSError *err = nil;
        BOOL exported = [Roots.instance exportRootNamed:rootName toArchive:tmpArchive error:&err progressReporter:reporter];
        if (!exported) {
            [fm removeItemAtURL:tmpArchive error:nil];
            if (!err && cancel && cancel())
                err = [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                snapshotOperationActive = NO;
                [self endAwake:@"snapshot-create"];
                completion(nil, err ?: lrError(EIO, @"Failed to export Debian Minimal snapshot."));
            });
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (progress) progress(0.90, @"Computing snapshot checksum…");
        });
        uint64_t sizeBytes = 0;
        NSString *sha256 = LRSHA256ForFileURL(tmpArchive, &sizeBytes, cancel, &err);
        if (!sha256) {
            [fm removeItemAtURL:tmpArchive error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                snapshotOperationActive = NO;
                [self endAwake:@"snapshot-create"];
                completion(nil, err ?: lrError(EIO, @"Failed to verify snapshot checksum."));
            });
            return;
        }

        if (![fm moveItemAtURL:tmpArchive toURL:finalArchive error:&err]) {
            [fm removeItemAtURL:tmpArchive error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                snapshotOperationActive = NO;
                [self endAwake:@"snapshot-create"];
                completion(nil, err);
            });
            return;
        }

        NSDictionary<NSString *, id> *meta = @{
            @"id": snapshotID,
            @"name": trimmedName,
            @"created_at": @(now.timeIntervalSince1970),
            @"size_bytes": @(sizeBytes),
            @"sha256": sha256,
            @"default_user": defaultUser,
            @"distribution": @"Debian GNU/Linux",
            @"version": @"13.7",
        };
        NSData *json = [NSJSONSerialization dataWithJSONObject:meta options:NSJSONWritingPrettyPrinted error:&err];
        if (!json || ![json writeToURL:metaURL options:NSDataWritingAtomic error:&err]) {
            [fm removeItemAtURL:finalArchive error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                snapshotOperationActive = NO;
                [self endAwake:@"snapshot-create"];
                completion(nil, err ?: lrError(EIO, @"Failed to save snapshot metadata."));
            });
            return;
        }

        [self logCategory:@"SNAPSHOT" event:[NSString stringWithFormat:@"created id=%@ name=%@ bytes=%llu user=%@", snapshotID, trimmedName, (unsigned long long)sizeBytes, defaultUser]];
        dispatch_async(dispatch_get_main_queue(), ^{
            snapshotOperationActive = NO;
            [self endAwake:@"snapshot-create"];
            if (progress) progress(1.0, @"Snapshot saved");
            completion(meta, nil);
        });
    });
}

+ (void)restoreSnapshotWithID:(NSString *)snapshotID
                     progress:(void (^)(double fraction, NSString *message))progress
                       cancel:(BOOL (^)(void))cancel
                   completion:(void (^)(NSString * _Nullable rootName, NSError * _Nullable error))completion {
    NSAssert(NSThread.isMainThread, @"Snapshot restore starts on the main thread");
    if (snapshotOperationActive || environmentDeletionActive || [NSUserDefaults.standardUserDefaults boolForKey:@"InstallerActive"]) {
        completion(nil, lrError(EBUSY, @"Wait for the current environment operation to finish."));
        return;
    }
    if (bootAttempted) {
        completion(nil, lrError(EBUSY, @"Debian Minimal is already running in this session. Wipe Debian Minimal and reopen the app to restore a snapshot cleanly."));
        return;
    }
    if (!LRValidSnapshotID(snapshotID)) {
        completion(nil, lrError(EINVAL, @"Invalid snapshot identifier."));
        return;
    }
    NSURL *dir = LRSnapshotsDirectoryURL();
    NSURL *archiveURL = [dir URLByAppendingPathComponent:[snapshotID stringByAppendingString:@".tar.gz"]];
    NSURL *metaURL = [dir URLByAppendingPathComponent:[snapshotID stringByAppendingString:@".json"]];
    NSData *metaData = [NSData dataWithContentsOfURL:metaURL];
    NSDictionary *meta = metaData ? [NSJSONSerialization JSONObjectWithData:metaData options:0 error:nil] : nil;
    NSString *sha256 = [meta[@"sha256"] isKindOfClass:NSString.class] ? meta[@"sha256"] : nil;
    if (!meta || sha256.length != 64 || ![NSFileManager.defaultManager fileExistsAtPath:archiveURL.path]) {
        completion(nil, lrError(ENOENT, @"Snapshot files are missing or corrupted."));
        return;
    }
    NSString *defaultUser = [meta[@"default_user"] isKindOfClass:NSString.class] ? meta[@"default_user"] : @"root";
    NSString *dist = [meta[@"distribution"] isKindOfClass:NSString.class] ? meta[@"distribution"] : @"Debian GNU/Linux";
    NSString *ver = [meta[@"version"] isKindOfClass:NSString.class] ? meta[@"version"] : @"13.7";
    NSArray<NSString *> *previousRoots = Roots.instance.roots.array.copy;
    NSString *shortSuffix = [[NSUUID.UUID.UUIDString substringToIndex:6] lowercaseString];
    NSString *rootName = [NSString stringWithFormat:@"debian-%lld-%@", (long long)NSDate.date.timeIntervalSince1970, shortSuffix];

    snapshotOperationActive = YES;
    [self beginAwake:@"snapshot-restore"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        LRInstallProgress *reporter = [LRInstallProgress new];
        reporter.progress = ^(double value, NSString *message) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (progress) progress(value, message.length ? message : @"Restoring snapshot…");
            });
        };
        reporter.cancel = cancel;

        // Verify and import the snapshot into a fresh unique root BEFORE touching
        // any existing installation, so cancel/checksum/disk failure leaves the
        // user's existing environment intact.
        NSError *err = nil;
        NSDictionary *rootMeta = @{
            @"distributionID": @"debian",
            @"distribution": dist,
            @"version": ver,
            @"packageManager": @"apt",
            @"defaultShell": @"/bin/bash",
            @"restoredFromSnapshot": snapshotID,
        };
        BOOL ok = [Roots.instance importVerifiedRootFromArchive:archiveURL name:rootName sha256:sha256 metadata:rootMeta error:&err progressReporter:reporter];
        if (!ok) {
            dispatch_async(dispatch_get_main_queue(), ^{
                snapshotOperationActive = NO;
                [self endAwake:@"snapshot-restore"];
                completion(nil, err ?: lrError(EIO, @"Failed to restore snapshot."));
            });
            return;
        }
        // Switch defaultRoot to the newly verified root on main thread, then remove
        // replaced roots and their orphaned exchange/Shared directories.
        dispatch_sync(dispatch_get_main_queue(), ^{
            Roots.instance.defaultRoot = rootName;
        });
        NSFileManager *fm = NSFileManager.defaultManager;
        NSURL *exchangesDir = [ContainerURL() URLByAppendingPathComponent:@"exchanges" isDirectory:YES];
        NSURL *docs = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        NSURL *sharedDir = docs ? [docs URLByAppendingPathComponent:@"Shared" isDirectory:YES] : nil;
        for (NSString *oldRoot in previousRoots) {
            if ([oldRoot isEqualToString:rootName]) continue;
            [Roots.instance destroyRootNamed:oldRoot error:nil];
            [fm removeItemAtURL:[exchangesDir URLByAppendingPathComponent:oldRoot] error:nil];
            if (sharedDir) [fm removeItemAtURL:[sharedDir URLByAppendingPathComponent:oldRoot] error:nil];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            snapshotOperationActive = NO;
            [self endAwake:@"snapshot-restore"];
            if (defaultUser.length > 0 && ![defaultUser isEqualToString:@"root"]) {
                [NSUserDefaults.standardUserDefaults setObject:defaultUser forKey:[@"LinuxRunnerDefaultUser." stringByAppendingString:rootName]];
            }
            [NSUserDefaults.standardUserDefaults synchronize];
            [self logCategory:@"SNAPSHOT" event:[NSString stringWithFormat:@"restored id=%@ into root=%@ user=%@", snapshotID, rootName, defaultUser]];
            if (progress) progress(1.0, @"Snapshot restored");
            completion(rootName, nil);
        });
    });
}

+ (void)wipeEnvironmentWithCompletion:(void (^)(BOOL needsRestart, NSError * _Nullable error))completion {
    NSAssert(NSThread.isMainThread, @"Environment wipe starts on the main thread");
    if (environmentDeletionActive || snapshotOperationActive || [NSUserDefaults.standardUserDefaults boolForKey:@"InstallerActive"]) {
        completion(NO, lrError(EBUSY, @"Wait for the current environment operation to finish."));
        return;
    }
    if (bootAttempted) {
        // Root filesystem is mounted in this process. Schedule clean wipe at next launch
        // before Roots/mount_root opens meta.db, and politely stop guest daemons first.
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:LRPendingWipeKey];
        [NSUserDefaults.standardUserDefaults synchronize];
        if (self.isRunning) {
            lock(&pids_lock);
            for (int i = 2; i < MAX_PID; i++) {
                struct task *task = pid_get_task(i);
                if (task && task->pid == task->tgid && !task->zombie && !task->exiting)
                    send_signal(task, SIGTERM_, SIGINFO_NIL);
            }
            unlock(&pids_lock);
        }
        [self logCategory:@"WIPE" event:@"scheduled Debian Minimal wipe for next launch (runtime mounted)"];
        completion(YES, nil);
        return;
    }

    environmentDeletionActive = YES;
    [self beginAwake:@"environment-wipe"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error = nil;
        [Roots.instance forceDestroyAllRoots:&error];
        NSFileManager *fm = NSFileManager.defaultManager;
        NSURL *container = ContainerURL();
        for (NSString *item in @[@"exchanges", @"environments.json", @"downloads", @"installer-temporary"]) {
            [fm removeItemAtURL:[container URLByAppendingPathComponent:item] error:nil];
        }
        NSURL *docs = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        if (docs) [fm removeItemAtURL:[docs URLByAppendingPathComponent:@"Shared"] error:nil];
        @synchronized(NSFileManager.class) {
            LRPreparedSupportFolder = nil;
            LRPreparedSupportRoot = nil;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            environmentDeletionActive = NO;
            [self endAwake:@"environment-wipe"];
            LRClearAllEnvironmentUserDefaults();
            [self logCategory:@"WIPE" event:error ? [NSString stringWithFormat:@"immediate wipe finished with error: %@", error.localizedDescription] : @"immediate Debian Minimal wipe completed"];
            completion(NO, error);
        });
    });
}

+ (void)handleDidEnterBackground {
    [self logCategory:@"LIFECYCLE" event:@"entered background"];
    LRBootLogSync();
    if (self.isRunning) {
        sockrestart_on_suspend();
    }
}

+ (void)handleWillEnterForeground {
    [self logCategory:@"LIFECYCLE" event:@"returning to foreground"];
    if (!self.isRunning) return;
    sockrestart_recover_dead_listeners();
    if (self.sshAutoStart && self.sshBinaryInstalled) {
        [self runSSHAction:@"status" completion:^(NSDictionary<NSString *, NSString *> *status) {
            if (![status[@"ssh"] isEqualToString:@"running"] && self.sshAutoStart && self.sshBinaryInstalled) {
                [self logCategory:@"SSH" event:@"sshd stopped while backgrounded; restarting"];
                [self runSSHAction:@"start" completion:nil];
            }
        }];
    }
    [self syncServiceManagerAndAutostart];
}

+ (BOOL)fileProviderEnabled {
    return CurrentAppGroups().count > 0;
}

+ (NSString *)activeAppGroup {
    return CurrentAppGroups().firstObject ?: @"";
}

+ (void)refreshFileProviderDomains {
    [Roots.instance syncFileProviderDomains];
}

+ (NSString *)environmentDeletionUnavailableReason:(NSString *)root {
    if (!validRoot(root) || ![Roots.instance.roots containsObject:root]) return @"This environment is no longer installed.";
    if (environmentDeletionActive || snapshotOperationActive || [NSUserDefaults.standardUserDefaults boolForKey:@"InstallerActive"])
        return @"Wait for the current environment operation to finish.";
    if ([root isEqual:bootedRoot] || (bootAttempted && [root isEqual:self.activeRootName]))
        return @"This environment is mounted. Choose another environment for the next launch, fully close LinuxRunner, then reopen it before deleting this one.";
    if ([root isEqual:Roots.instance.defaultRoot])
        return @"Choose another environment for the next launch before deleting this one.";
    return nil;
}
+ (void)deleteEnvironment:(NSString *)root completion:(void (^)(NSError *))completion {
    NSAssert(NSThread.isMainThread, @"Environment deletion starts on the main thread");
    NSString *reason = [self environmentDeletionUnavailableReason:root];
    if (reason) { completion(lrError(EBUSY, reason)); return; }
    environmentDeletionActive = YES;
    [self beginAwake:@"environment-delete"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error = nil;
        BOOL removed = [Roots.instance destroyRootNamed:root error:&error];
        if (removed) {
            NSURL *exchange = [self exchangeURL:root];
            NSError *cleanup = nil;
            if (![NSFileManager.defaultManager removeItemAtURL:exchange error:&cleanup] && cleanup.code != NSFileNoSuchFileError)
                error = lrError(EIO, [@"The environment was deleted, but its imported-file folder could not be removed: " stringByAppendingString:cleanup.localizedDescription]);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            environmentDeletionActive = NO;
            [self endAwake:@"environment-delete"];
            if (removed) {
                [NSUserDefaults.standardUserDefaults removeObjectForKey:[@"LinuxRunnerDefaultUser." stringByAppendingString:root]];
                if ([[NSUserDefaults.standardUserDefaults stringForKey:@"LinuxRunnerSetup.root"] isEqual:root]) {
                    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"LinuxRunnerSetup.root"];
                    [NSUserDefaults.standardUserDefaults setObject:@"welcome" forKey:@"LinuxRunnerSetup.step"];
                }
            }
            completion(error ?: (removed ? nil : lrError(EIO, @"The environment could not be deleted. Its catalog entry has been kept.")));
        });
    });
}
+ (NSString *)boundedDiagnosticTail:(NSURL *)url maxBytes:(NSUInteger)bytes {
    return LRDiagnosticTailString(LRReadDiagnosticTail(url,MIN(bytes,(NSUInteger)262144)))?:@"";
}
+ (NSArray *)discoverApplications {
#if TARGET_OS_SIMULATOR
    NSTimeInterval scanStarted=NSProcessInfo.processInfo.systemUptime;
    BOOL scanOnMain=NSThread.isMainThread;
#endif
    struct fs_info *fs = NULL;
    lock(&pids_lock);
    struct task *task = pid_get_task(1);
    if (task) {
        lock(&task->general_lock);
        fs = task->fs;
        if (fs) atomic_fetch_add(&fs->refcount, 1);
        unlock(&task->general_lock);
    }
    unlock(&pids_lock);
    if (!fs) return @[];
    struct task context = {.euid = 0, .egid = 0, .fs = fs};
    struct task *previous = current;
    current = &context;
    NSMutableArray *result = [NSMutableArray new];
    for (NSString *name in @[@"python3", @"git", @"vim", @"nano", @"node", @"curl", @"htop", @"gcc", @"tmux"]) {
        for (NSString *base in @[@"/usr/local/bin", @"/usr/bin", @"/bin"]) {
            NSString *path = [base stringByAppendingPathComponent:name];
            struct fd *fd = generic_open_in_fs(fs, path.UTF8String, O_RDONLY_, 0);
            if (IS_ERR(fd)) continue;
            struct statbuf st;
            BOOL executable = fd->mount->fs->fstat(fd, &st) == 0 && S_ISREG(st.mode) && (st.mode & 0111);
            fd_close(fd);
            if (executable) { [result addObject:@{@"name":name, @"command":path}]; break; }
        }
    }
    current = previous;
    fs_info_release(fs);
#if TARGET_OS_SIMULATOR
    [NSNotificationCenter.defaultCenter postNotificationName:@"LRSimulatorApplicationDiscovery" object:nil userInfo:@{@"kind":@"terminal",@"mainThread":@(scanOnMain),@"milliseconds":@((NSProcessInfo.processInfo.systemUptime-scanStarted)*1000),@"entries":@(result.count)}];
#endif
    return result;
}
#if TARGET_OS_SIMULATOR
+ (NSDictionary *)applicationDiscoveryContextContract {
    struct task canary={0};struct task *previous=current;current=&canary;
    NSArray *commands=[self discoverApplications];BOOL commandsRestored=current==&canary;
    current=previous;
    return @{@"terminal_context_restored":@(commandsRestored),@"terminal_entries":@(commands.count)};
}
#endif
static NSString *GuestExecutable(struct fs_info *fs, NSString *command) {
    NSArray *paths=[command hasPrefix:@"/"]?@[command]:@[[[@"/usr/local/bin/" stringByAppendingString:command] copy],[@"/usr/bin/" stringByAppendingString:command],[@"/bin/" stringByAppendingString:command]];
    for(NSString *path in paths){
        struct fd *fd=generic_open_in_fs(fs,path.UTF8String,O_RDONLY_,0);if(IS_ERR(fd))continue;
        struct statbuf st;BOOL valid=fd->mount->fs->fstat(fd,&st)==0&&S_ISREG(st.mode)&&(st.mode&0111);fd_close(fd);
        if(valid)return path;
    }return nil;
}
// Retain PID 1's fs rather than reading fakefs host backing paths. The private
// inspection context is restored on every exit and never becomes a live task.
static struct fs_info *LRAccountFS(void) {
    struct fs_info *fs = NULL;
    lock(&pids_lock);
    struct task *task = pid_get_task(1);
    if (task) {
        lock(&task->general_lock);
        fs = task->fs;
        if (fs) atomic_fetch_add(&fs->refcount, 1);
        unlock(&task->general_lock);
    }
    unlock(&pids_lock);
    return fs;
}
+ (NSArray *)linuxAccounts {
    struct fs_info *fs = LRAccountFS();
    if (!fs) return @[];
    struct task context = {.euid = 0, .egid = 0, .fs = fs};
    struct task *previous = current; current = &context;
    struct fd *file = generic_open_in_fs(fs, "/etc/passwd", O_RDONLY_, 0);
    NSMutableData *data = [NSMutableData new];
    BOOL valid = NO;
    if (!IS_ERR(file)) {
        struct statbuf st;
        valid = file->mount->fs->fstat(file, &st) == 0 && S_ISREG(st.mode) && st.size <= 262144;
        char buffer[4096]; ssize_t count;
        if (valid && file->ops->read) {
            while (data.length < 262144 && (count = file->ops->read(file, buffer, MIN(sizeof buffer, 262144-data.length))) > 0)
                [data appendBytes:buffer length:count];
            valid = data.length == (NSUInteger)st.size;
        } else valid = NO;
        fd_close(file);
    }
    current = previous; fs_info_release(fs);
    NSString *text = valid ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    NSMutableArray *accounts = [NSMutableArray new];
    NSMutableSet *seen = [NSMutableSet new];
    for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSArray<NSString *> *fields = [line componentsSeparatedByString:@":"];
        if (fields.count != 7 || !lr_linux_account_name_valid(fields[0].UTF8String) || [seen containsObject:fields[0]]) continue;
        NSCharacterSet *nonDigits = [NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet;
        if (!fields[2].length || !fields[3].length || [fields[2] rangeOfCharacterFromSet:nonDigits].location != NSNotFound ||
            [fields[3] rangeOfCharacterFromSet:nonDigits].location != NSNotFound || fields[2].longLongValue >= UINT32_MAX || fields[3].longLongValue >= UINT32_MAX) continue;
        if ((fields[2].longLongValue == 0 && ![fields[0] isEqual:@"root"]) ||
            ![fields[5] hasPrefix:@"/"] || ![fields[6] hasPrefix:@"/"] ||
            [@[@"nologin", @"false"] containsObject:fields[6].lastPathComponent]) continue;
        [seen addObject:fields[0]];
        [accounts addObject:@{@"name":fields[0], @"uid":fields[2], @"gid":fields[3], @"home":fields[5], @"shell":fields[6]}];
        if (accounts.count >= 1024) break;
    }
    return accounts;
}
static NSString *LRDefaultAccountKey(void) {
    return [@"LinuxRunnerDefaultUser." stringByAppendingString:LRRuntimeBridge.activeRootName];
}
+ (NSString *)defaultLinuxUser {
    if (!self.activeRootName.length) return @"root";
    return [NSUserDefaults.standardUserDefaults stringForKey:LRDefaultAccountKey()] ?: @"root";
}
+ (BOOL)setDefaultLinuxUser:(NSString *)name error:(NSError **)error {
    for (NSDictionary *account in self.linuxAccounts) {
        if ([account[@"name"] isEqual:name]) {
            [NSUserDefaults.standardUserDefaults setObject:name forKey:LRDefaultAccountKey()];
            [self applySharedFolderOwnership];
            return YES;
        }
    }
    if (error) *error = lrError(ENOENT, @"The account is not a login account in the active guest /etc/passwd. Refresh the list.");
    return NO;
}
static NSString *LRAccountTool(NSArray<NSString *> *paths) {
    struct fs_info *fs = LRAccountFS(); if (!fs) return nil;
    struct task context = {.euid=0, .egid=0, .fs=fs}; struct task *previous = current; current=&context;
    NSString *tool = nil;
    for (NSString *path in paths) if ((tool = GuestExecutable(fs, path))) break;
    current=previous; fs_info_release(fs); return tool;
}
static NSDictionary *LRLoginAccount(NSString *name) {
    if (!lr_linux_account_name_valid(name.UTF8String)) return nil;
    for (NSDictionary *account in LRRuntimeBridge.linuxAccounts) if ([account[@"name"] isEqual:name]) return account;
    return nil;
}
+ (NSArray<NSDictionary<NSString *, NSString *> *> *)sharedFolders { return iosfs_external_folder_mounts(); }
+ (BOOL)addSharedFolder:(NSURL *)url error:(NSError **)error {
    if (!self.isRunning) { if (error) *error = lrError(EAGAIN, @"Start the Linux runtime first."); return NO; }
    if (!iosfs_add_external_folder_mount_url(url, error)) return NO;
    [self applySharedFolderOwnership];
    return YES;
}
+ (void)removeSharedFolder:(NSString *)name { iosfs_remove_external_folder_mount(name); }
static int LRDatalessPolicyResult = -1;
void LRSetDatalessMaterialization(void) {
    LRDatalessPolicyResult = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_ON) == 0 ? 1 : 0;
    LRBootEvent(LRDatalessPolicyResult ? "[FILES] dataless materialization on" : "[FILES] dataless materialization unavailable");
}
+ (void)checkSharedFolder:(NSString *)name completion:(void (^)(NSString *summary))completion {
    NSDictionary *folder = nil; for (NSDictionary *f in iosfs_external_folder_mounts()) if ([f[@"name"] isEqual:name]) folder = f;
    if (!folder) { completion(@"This shared folder is no longer registered."); return; }
    NSURL *url = iosfs_external_folder_url(name); NSError *listError = nil;
    NSMutableArray *iosLines = [NSMutableArray new];
    if (!url) [iosLines addObject:@"iOS: access not restored (bookmark could not be resolved or permission was revoked; the folder may be moved or its drive disconnected)"];
    else {
        NSArray *items = [NSFileManager.defaultManager contentsOfDirectoryAtURL:url includingPropertiesForKeys:@[NSURLUbiquitousItemDownloadingStatusKey] options:0 error:&listError];
        NSUInteger dataless = 0; for (NSURL *item in items) { NSString *status = nil; [item getResourceValue:&status forKey:NSURLUbiquitousItemDownloadingStatusKey error:nil]; if (status && ![status isEqual:NSURLUbiquitousItemDownloadingStatusCurrent]) dataless++; }
        NSNumber *ubiquitous = nil, *local = nil; [url getResourceValue:&ubiquitous forKey:NSURLIsUbiquitousItemKey error:nil]; [url getResourceValue:&local forKey:NSURLVolumeIsLocalKey error:nil];
        NSString *volume = nil; [url getResourceValue:&volume forKey:NSURLVolumeNameKey error:nil];
        NSString *kind = ubiquitous.boolValue ? @"iCloud Drive" : [url.path containsString:@"/LiveFiles/"] ? @"external drive" : [url.path containsString:@"File Provider Storage"] ? @"On My iPhone / app folder" : @"other provider";
        [iosLines addObject:items ? [NSString stringWithFormat:@"iOS: %lu items (%lu not downloaded; download-on-open %@) · %@ · volume %@", (unsigned long)items.count, (unsigned long)dataless, LRDatalessPolicyResult == 1 ? @"on" : @"off", kind, volume ?: @"?"]
                                  : [NSString stringWithFormat:@"iOS: cannot list — %@ · %@", listError.localizedDescription, kind]];
        if (validRoot(self.activeRootName)) {
            NSURL *link = [[[self rootURL:self.activeRootName] URLByAppendingPathComponent:@"data"] URLByAppendingPathComponent:[folder[@"mountPoint"] substringFromIndex:1]];
            struct stat linkTarget, host; char target[PATH_MAX]; ssize_t n = readlink(link.fileSystemRepresentation, target, sizeof target - 1);
            BOOL same = stat(link.fileSystemRepresentation, &linkTarget) == 0 && stat(url.fileSystemRepresentation, &host) == 0 && linkTarget.st_dev == host.st_dev && linkTarget.st_ino == host.st_ino;
            [iosLines addObject:[NSString stringWithFormat:@"Mount: %@ link=%@ resolves-to-folder=%@", folder[@"mountPoint"], n > 0 ? @"present" : [NSString stringWithFormat:@"missing (errno %d)", errno], same ? @"yes" : @"NO"]];
        }
    }
    NSString *ios = [iosLines componentsJoinedByString:@"\n"];
    NSError *error = nil; NSURL *support = LRPrepareSupport(&error);
    if (!support || !self.isRunning) { completion([ios stringByAppendingString:@"\nLinux: runtime not running"]); return; }
    NSString *token = [[NSUUID.UUID.UUIDString substringToIndex:8] lowercaseString];
    NSString *resultName = [NSString stringWithFormat:@"share-check-%@.txt", name];
    NSURL *result = [support URLByAppendingPathComponent:resultName]; [NSFileManager.defaultManager removeItemAtURL:result error:nil];
    NSString *guestOut = [@"/home/mobile/Downloads/.linuxrunner/support/" stringByAppendingString:resultName];
    NSString *script = @"u=$1 d=$2 out=$3 token=$4 tmp=/tmp/lr-share-check.$$\n"
        "if [ \"$u\" = root ]; then sh /home/mobile/Downloads/.linuxrunner/support/share-check.sh \"$d\" \"$tmp\" \"$token\"\n"
        "else su -l \"$u\" -s /bin/sh -c \"sh /home/mobile/Downloads/.linuxrunner/support/share-check.sh '$d' '$tmp' '$token'\"; fi\n"
        "cp \"$tmp\" \"$out.tmp\" && mv \"$out.tmp\" \"$out\"; rm -f \"$tmp\"\n";
    NSArray *command = @[@"/bin/sh", @"-c", script, @"linuxrunner-share-check", self.defaultLinuxUser, folder[@"mountPoint"], guestOut, token];
    [self runHeadlessCommand:command directory:@"/" timeout:60.0 completion:^(int exitCode) {
        (void)exitCode;
        NSString *text = [[NSString stringWithContentsOfURL:result encoding:NSUTF8StringEncoding error:nil] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *linux = text.length ? [@"Linux: " stringByAppendingString:[text stringByReplacingOccurrencesOfString:@"\n" withString:@" · "]] : @"Linux: the check did not finish";
        NSString *roundTrip = @"";
        if (url && [text containsString:@"rename=ok"]) {
            NSURL *kept = [url URLByAppendingPathComponent:[NSString stringWithFormat:@"LinuxRunner-check-%@-renamed.txt", token]];
            NSString *content = [NSString stringWithContentsOfURL:kept encoding:NSUTF8StringEncoding error:nil];
            BOOL seen = [content hasPrefix:@"linuxrunner-check\nmodified"];
            BOOL removed = [NSFileManager.defaultManager removeItemAtURL:kept error:nil];
            roundTrip = [NSString stringWithFormat:@"\nRound trip: Linux file visible in iOS=%@ removed-by-iOS=%@", seen ? @"yes" : @"NO", removed ? @"yes" : @"no"];
        }
        [self logCategory:@"FILES" event:[NSString stringWithFormat:@"shared folder check %@ | %@ | %@%@", folder[@"mountPoint"], [ios stringByReplacingOccurrencesOfString:@"\n" withString:@" | "], linux, [roundTrip stringByReplacingOccurrencesOfString:@"\n" withString:@" "]]];
        completion([NSString stringWithFormat:@"%@\n%@%@", ios, linux, roundTrip]);
    }];
}
+ (void)checkAppSharedFolder:(void (^)(NSString *summary))completion {
    NSString *root = self.activeRootName;
    if (!validRoot(root)) { completion(@"Linux: no Debian environment installed"); return; }
    NSURL *url = [self sharedExchangeURL:root];
    NSArray *items = [NSFileManager.defaultManager contentsOfDirectoryAtPath:url.path error:nil];
    NSString *ios = items ? [NSString stringWithFormat:@"iOS: %lu items in Shared/%@", (unsigned long)items.count, root] : @"iOS: the Shared folder does not exist yet";
    NSError *error = nil; NSURL *support = LRPrepareSupport(&error);
    if (!support || !self.isRunning) { completion([ios stringByAppendingString:@"\nLinux: runtime not running"]); return; }
    NSString *token = [[NSUUID.UUID.UUIDString substringToIndex:8] lowercaseString];
    NSURL *result = [support URLByAppendingPathComponent:@"share-check-app.txt"]; [NSFileManager.defaultManager removeItemAtURL:result error:nil];
    NSString *script = @"u=$1 d=$2 out=$3 token=$4 tmp=/tmp/lr-share-check.$$\n"
        "if [ \"$u\" = root ]; then sh /home/mobile/Downloads/.linuxrunner/support/share-check.sh \"$d\" \"$tmp\" \"$token\"\n"
        "else su -l \"$u\" -s /bin/sh -c \"sh /home/mobile/Downloads/.linuxrunner/support/share-check.sh '$d' '$tmp' '$token'\"; fi\n"
        "cp \"$tmp\" \"$out.tmp\" && mv \"$out.tmp\" \"$out\"; rm -f \"$tmp\"\n";
    NSArray *command = @[@"/bin/sh", @"-c", script, @"linuxrunner-share-check", self.defaultLinuxUser, @"/mnt/LinuxRunnerShared", @"/home/mobile/Downloads/.linuxrunner/support/share-check-app.txt", token];
    [self runHeadlessCommand:command directory:@"/" timeout:60.0 completion:^(int exitCode) {
        (void)exitCode;
        NSString *text = [[NSString stringWithContentsOfURL:result encoding:NSUTF8StringEncoding error:nil] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *linux = text.length ? [@"Linux: " stringByAppendingString:[text stringByReplacingOccurrencesOfString:@"\n" withString:@" · "]] : @"Linux: the check did not finish";
        NSString *roundTrip = @"";
        if ([text containsString:@"rename=ok"]) {
            NSURL *kept = [url URLByAppendingPathComponent:[NSString stringWithFormat:@"LinuxRunner-check-%@-renamed.txt", token]];
            NSString *content = [NSString stringWithContentsOfURL:kept encoding:NSUTF8StringEncoding error:nil];
            BOOL seen = [content hasPrefix:@"linuxrunner-check\nmodified"];
            BOOL removed = [NSFileManager.defaultManager removeItemAtURL:kept error:nil];
            roundTrip = [NSString stringWithFormat:@"\nRound trip: Linux file visible in iOS=%@ removed-by-iOS=%@", seen ? @"yes" : @"NO", removed ? @"yes" : @"no"];
        }
        [self logCategory:@"FILES" event:[NSString stringWithFormat:@"app shared folder check | %@ | %@%@", ios, linux, [roundTrip stringByReplacingOccurrencesOfString:@"\n" withString:@" "]]];
        completion([NSString stringWithFormat:@"%@\n%@%@", ios, linux, roundTrip]);
    }];
}
+ (void)prepareUserSharedFolder:(NSDictionary *)account {
    if (!self.isRunning || !validRoot(self.activeRootName)) return;
    int stage=LRTransferStaging();if(stage>=0)close(stage);
    NSURL *shared=[self sharedExchangeURL:self.activeRootName];
    if(![NSFileManager.defaultManager createDirectoryAtURL:shared withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil])return;
    struct fs_info *fs=LRAccountFS();if(!fs)return;
    uint32_t uid=[account[@"uid"] unsignedIntValue],gid=[account[@"gid"] unsignedIntValue];
    struct task context={.uid=0,.euid=0,.gid=0,.egid=0,.fs=fs};struct task *previous=current;current=&context;
    int result=generic_mkdirat(AT_PWD,"/mnt",0755);
    if(!result||result==_EEXIST)result=fakefs_bind_mount("/mnt/LinuxRunnerShared",shared.fileSystemRepresentation,false);
    if(!result)result=fakefs_bind_mount_set_owner("/mnt/LinuxRunnerShared",uid,gid);
    NSString *home=account[@"home"];
    if(!result&&home.length){NSString *alias=[home stringByAppendingPathComponent:@"Shared"];struct statbuf st;
        context.uid=context.euid=uid;context.gid=context.egid=gid;
        if(generic_statat(AT_PWD,alias.UTF8String,&st,false)==_ENOENT)generic_symlinkat("/mnt/LinuxRunnerShared",AT_PWD,alias.UTF8String);
    }
    current=previous;fs_info_release(fs);
    [self logCategory:@"FILES" event:[NSString stringWithFormat:@"persistent shared folder mount result=%d",result]];
}
+ (void)applySharedFolderOwnership {
    NSDictionary *account = LRLoginAccount(self.defaultLinuxUser);
    uint32_t uid = [account[@"uid"] unsignedIntValue], gid = [account[@"gid"] unsignedIntValue];
    fakefs_bind_mount_set_owner("/home/mobile/Downloads",uid,gid);
    [self prepareUserSharedFolder:account];
    for (NSDictionary *folder in iosfs_external_folder_mounts()) {
        NSString *mountPoint = folder[@"mountPoint"];
        int err = fakefs_bind_mount_set_owner(mountPoint.fileSystemRepresentation, uid, gid);
        [self logCategory:@"FILES" event:[NSString stringWithFormat:@"shared folder %@ owner=%u:%u result=%d", folder[@"mountPoint"], uid, gid, err]];
    }
}
+ (BOOL)canGrantAdministrator { return LRAccountTool(@[@"/usr/bin/sudo", @"/bin/sudo"]) != nil; }
// ---- Native account setup ---------------------------------------------------
static NSData *LRReadGuestFile(NSString *path, size_t limit) {
    struct fs_info *fs = LRAccountFS(); if (!fs) return nil;
    struct task context = {.euid = 0, .egid = 0, .fs = fs}; struct task *previous = current; current = &context;
    NSMutableData *data = nil;
    struct fd *file = generic_open_in_fs(fs, path.UTF8String, O_RDONLY_, 0);
    if (!IS_ERR(file)) {
        data = [NSMutableData new]; char buffer[4096]; ssize_t count;
        while (file->ops->read && data.length < limit && (count = file->ops->read(file, buffer, MIN(sizeof buffer, limit - data.length))) > 0) [data appendBytes:buffer length:count];
        fd_close(file);
    }
    current = previous; fs_info_release(fs);
    return data;
}
+ (BOOL)accountToolsPresent {
    return LRAccountTool(@[@"/usr/bin/passwd", @"/bin/passwd"]) && LRAccountTool(@[@"/usr/sbin/chpasswd", @"/sbin/chpasswd", @"/usr/bin/chpasswd", @"/bin/chpasswd"]) &&
        LRAccountTool(@[@"/usr/sbin/useradd", @"/usr/bin/useradd"]);
}
+ (void)createLinuxUser:(NSString *)name password:(NSString *)password administrator:(BOOL)administrator
               progress:(void (^)(NSString *))progress completion:(void (^)(NSError *))completion {
    [self createLinuxUser:name password:password administrator:administrator passwordlessSudo:administrator progress:progress completion:completion];
}
+ (void)createLinuxUser:(NSString *)name password:(NSString *)password administrator:(BOOL)administrator passwordlessSudo:(BOOL)passwordlessSudo
               progress:(void (^)(NSString *))progress completion:(void (^)(NSError *))completion {
    if (!lr_linux_account_name_valid(name.UTF8String) || [name isEqual:@"root"]) { completion(lrError(EINVAL, @"Use 1–32 lowercase letters, digits, - or _, starting with a letter.")); return; }
    if (password.length < 4) { completion(lrError(EINVAL, @"Use a password of at least 4 characters.")); return; }
    for (NSDictionary *account in self.linuxAccounts) if ([account[@"name"] isEqual:name]) { completion(lrError(EEXIST, @"That Linux account already exists; choose it under Existing Accounts.")); return; }
    char salt[17], hash[160];
    if (lr_random_salt(salt) || lr_sha512_crypt(password.UTF8String, salt, hash, sizeof hash)) { completion(lrError(EIO, @"The password could not be prepared.")); return; }
    NSString *hashed = @(hash); memset(hash, 0, sizeof hash);
    BOOL grantNopasswd = administrator && passwordlessSudo;
    void (^create)(void) = ^{
        progress(@"Creating your account");
        NSString *grant = @"";
        if (administrator) {
            grant = @"{ getent group sudo >/dev/null || groupadd --system sudo; }; usermod -aG sudo -- \"$1\"\n";
            if (grantNopasswd) {
                grant = [grant stringByAppendingString:
                    @"mkdir -p /etc/sudoers.d && chmod 750 /etc/sudoers.d\n"
                    "printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\\n' \"$1\" > \"/etc/sudoers.d/90-debianrunner-$1.tmp\"\n"
                    "chmod 440 \"/etc/sudoers.d/90-debianrunner-$1.tmp\"\n"
                    "chown 0:0 \"/etc/sudoers.d/90-debianrunner-$1.tmp\" 2>/dev/null || true\n"
                    "if command -v visudo >/dev/null 2>&1; then visudo -cf \"/etc/sudoers.d/90-debianrunner-$1.tmp\" >/dev/null || { rm -f \"/etc/sudoers.d/90-debianrunner-$1.tmp\"; exit 1; }; fi\n"
                    "mv -f \"/etc/sudoers.d/90-debianrunner-$1.tmp\" \"/etc/sudoers.d/90-debianrunner-$1\"\n"];
            }
        }
        NSString *script = [NSString stringWithFormat:@"set -e\n"
            "useradd --create-home --shell /bin/bash -- \"$1\"\n"
            "%@IFS= read -r hash\nprintf '%%s:%%s\\n' \"$1\" \"$hash\" | chpasswd -e\n", grant];
        NSData *stdinData = [[hashed stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
        [self runHeadlessCommand:@[@"/bin/sh", @"-c", script, @"linuxrunner-create-user", name]
                       directory:@"/"
                       stdinData:stdinData
                         timeout:120.0
                      completion:^(int exitCode) {
            NSString *shadow = [[NSString alloc] initWithData:LRReadGuestFile(@"/etc/shadow", 1 << 20) ?: [NSData data] encoding:NSUTF8StringEncoding];
            BOOL stored = NO;
            for (NSString *line in [shadow componentsSeparatedByString:@"\n"]) {
                NSArray *fields = [line componentsSeparatedByString:@":"];
                if (fields.count > 1 && [fields[0] isEqual:name] && [fields[1] isEqual:hashed]) stored = YES;
            }
            BOOL exists = NO; for (NSDictionary *account in self.linuxAccounts) if ([account[@"name"] isEqual:name]) exists = YES;
            [self logCategory:@"ACCOUNT" event:[NSString stringWithFormat:@"native create user=%@ admin=%d nopasswd=%d exit=%d exists=%d password_set=%d", name, administrator, grantNopasswd, exitCode, exists, stored]];
            if (exists && stored) completion(nil);
            else completion(lrError(EIO, exists ? @"The account was created but its password could not be set. Set it in Linux Users." : @"The account could not be created. Details are in Runtime Diagnostics (ACCOUNT)."));
        }];
    };
    [self ensureAccountTools:administrator progress:progress then:create failure:completion];
}
// Installs missing account tools (and sudo) through debian-support.sh accounts.
+ (void)ensureAccountTools:(BOOL)administrator progress:(void (^)(NSString *))progress then:(void (^)(void))then failure:(void (^)(NSError *))failure {
    BOOL needTools = !self.accountToolsPresent, needSudo = administrator && !self.canGrantAdministrator;
    if (!needTools && !needSudo) { then(); return; }
    NSArray *arguments = administrator ? @[@"accounts", @"sudo"] : @[@"accounts"];
    [self runSupportInstall:arguments title:needTools ? @"Installing Account Tools" : @"Installing Administrator Tools (sudo)" progress:progress completion:^(NSError *error) {
        BOOL ok = !error && self.accountToolsPresent && (!administrator || self.canGrantAdministrator);
        [self logCategory:@"ACCOUNT" event:[NSString stringWithFormat:@"account tools install ok=%d error=%@", ok, error.localizedDescription ?: @"none"]];
        if (ok) then();
        else failure(error ?: lrError(EIO, @"The account tools were reported installed but are missing. Export diagnostics and try again."));
    }];
}
+ (void)setLinuxPassword:(NSString *)name password:(NSString *)password progress:(void (^)(NSString *))progress completion:(void (^)(NSError *))completion {
    if (password.length < 4) { completion(lrError(EINVAL, @"Use a password of at least 4 characters.")); return; }
    BOOL exists = NO; for (NSDictionary *account in self.linuxAccounts) if ([account[@"name"] isEqual:name]) exists = YES;
    if (!exists) { completion(lrError(ENOENT, @"That Linux account no longer exists.")); return; }
    char salt[17], hash[160];
    if (lr_random_salt(salt) || lr_sha512_crypt(password.UTF8String, salt, hash, sizeof hash)) { completion(lrError(EIO, @"The password could not be prepared.")); return; }
    NSString *hashed = @(hash); memset(hash, 0, sizeof hash);
    [self ensureAccountTools:NO progress:progress then:^{
        progress(@"Setting the password");
        NSData *stdinData = [[hashed stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
        [self runHeadlessCommand:@[@"/bin/sh", @"-c", @"IFS= read -r hash\nprintf '%s:%s\\n' \"$1\" \"$hash\" | chpasswd -e\n", @"linuxrunner-set-password", name]
                       directory:@"/"
                       stdinData:stdinData
                         timeout:60.0
                      completion:^(int exitCode) {
            NSString *shadow = [[NSString alloc] initWithData:LRReadGuestFile(@"/etc/shadow", 1 << 20) ?: [NSData data] encoding:NSUTF8StringEncoding];
            BOOL stored = NO;
            for (NSString *line in [shadow componentsSeparatedByString:@"\n"]) { NSArray *f = [line componentsSeparatedByString:@":"]; if (f.count > 1 && [f[0] isEqual:name] && [f[1] isEqual:hashed]) stored = YES; }
            [self logCategory:@"ACCOUNT" event:[NSString stringWithFormat:@"native password user=%@ exit=%d set=%d", name, exitCode, stored]];
            completion(stored ? nil : lrError(EIO, @"The password could not be set."));
        }];
    } failure:completion];
}

// ---- Headless Guest Command Runner & Built-in OpenSSH Server ---------------
// Spawns guest commands attached to /dev/null (or a short host pipe for stdin)
// with zero WebViews and zero PTYs.
+ (void)runHeadlessCommand:(NSArray<NSString *> *)command directory:(NSString *)directory completion:(void (^ _Nullable)(int exitCode))completion {
    [self runHeadlessCommand:command directory:directory stdinData:nil timeout:20.0 completion:completion];
}
+ (void)runHeadlessCommand:(NSArray<NSString *> *)command directory:(NSString *)directory timeout:(NSTimeInterval)timeout completion:(void (^ _Nullable)(int exitCode))completion {
    [self runHeadlessCommand:command directory:directory stdinData:nil timeout:timeout completion:completion];
}
+ (void)runHeadlessCommand:(NSArray<NSString *> *)command directory:(NSString *)directory stdinData:(NSData * _Nullable)stdinData timeout:(NSTimeInterval)timeout completion:(void (^ _Nullable)(int exitCode))completion {
    void (^launch)(void) = ^{
        if (!self.isRunning || command.count == 0) {
            if (completion) completion(-1);
            return;
        }
        size_t bytes = 1;
        for (NSString *argument in command) {
            size_t length = [argument lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
            if (length + 1 > 4096 - bytes || strlen(argument.UTF8String) != length) {
                if (completion) completion(-1);
                return;
            }
            bytes += length + 1;
        }
        if (stdinData.length > 4096) {
            if (completion) completion(-EINVAL);
            return;
        }
#if !ISH_LINUX
        int err = become_new_init_child();
        if (err < 0) {
            [self logCategory:@"EXEC" event:[NSString stringWithFormat:@"headless child failed err=%d", err]];
            if (completion) completion(err);
            return;
        }
        void (^failLaunch)(int) = ^(int code) {
            task_discard_unstarted(current);
            current = NULL;
            [self logCategory:@"EXEC" event:[NSString stringWithFormat:@"headless exec failed err=%d", code]];
            if (completion) completion(code);
        };
        err = create_stdio("/dev/null", MEM_MAJOR, DEV_NULL_MINOR);
        if (err < 0) { failLaunch(err); return; }
        if (stdinData.length > 0) {
            int p[2] = {-1, -1};
            if (pipe(p) != 0) { failLaunch(-errno); return; }
            fcntl(p[0], F_SETFD, FD_CLOEXEC);
            fcntl(p[1], F_SETFD, FD_CLOEXEC);
            const uint8_t *ptr = (const uint8_t *)stdinData.bytes;
            size_t remaining = stdinData.length;
            while (remaining > 0) {
                ssize_t written = write(p[1], ptr, remaining);
                if (written < 0) {
                    if (errno == EINTR) continue;
                    int saved = errno;
                    close(p[0]); close(p[1]);
                    failLaunch(-saved);
                    return;
                }
                ptr += written;
                remaining -= (size_t)written;
            }
            close(p[1]);
            struct fd *stdinFd = adhoc_fd_create(&realfs_fdops);
            if (!stdinFd) {
                close(p[0]);
                failLaunch(_ENOMEM);
                return;
            }
            stdinFd->real_fd = p[0];
            stdinFd->dir = NULL;
            stdinFd->type = S_IFIFO;
            stdinFd->stat.mode = S_IFIFO | 0600;
            stdinFd->flags = O_RDONLY_;
            fd_close(current->files->files[0]);
            current->files->files[0] = stdinFd;
        }
        if (directory.length) {
            struct fd *dir = generic_open(directory.UTF8String, O_RDONLY_ | O_DIRECTORY_, 0);
            if (!IS_ERR(dir)) fs_chdir(current->fs, dir);
        }
        char argv[4096];
        LRConvertCommandToArgs(command, argv, sizeof(argv));
        const char *envp = "TERM=dumb\0"
            "HOME=/root\0"
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\0"
#if defined(GUEST_ARM64)
            "PYTHONMALLOC=malloc\0"
#endif
            ;
        err = do_execve(command[0].UTF8String, command.count, argv, envp);
        if (err < 0) { failLaunch(err); return; }
        int pid = current->pid;
        __block BOOL completed = NO;
        __block id observer = nil;
        __block NSTimer *timer = nil;
        void (^finish)(int) = ^(int code) {
            if (completed) return;
            completed = YES;
            if (observer) { [NSNotificationCenter.defaultCenter removeObserver:observer]; observer = nil; }
            if (timer) { [timer invalidate]; timer = nil; }
            if (completion) completion(code);
        };
        if (completion) {
            observer = [NSNotificationCenter.defaultCenter addObserverForName:ProcessExitedNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                if ([note.userInfo[@"pid"] intValue] == pid) {
                    int rawCode = [note.userInfo[@"code"] intValue];
                    int exitStatus = (rawCode & 0x7f) ? -(rawCode & 0x7f) : ((rawCode >> 8) & 255);
                    finish(exitStatus);
                }
            }];
            if (timeout > 0) {
                timer = [NSTimer scheduledTimerWithTimeInterval:timeout repeats:NO block:^(NSTimer * _Nonnull t) {
                    (void)t;
                    finish(-ETIMEDOUT);
                }];
            }
        }
        err = task_start(current);
        if (err < 0) {
            if (observer) { [NSNotificationCenter.defaultCenter removeObserver:observer]; observer = nil; }
            if (timer) { [timer invalidate]; timer = nil; }
            failLaunch(err);
            return;
        }
        current = NULL;
        return;
#else
        if (completion) completion(-1);
#endif
    };
    if (NSThread.isMainThread) launch();
    else dispatch_async(dispatch_get_main_queue(), launch);
}

static NSString * const LRSSHAutoStartKey = @"DebianRunner.sshAutoStart";
static NSString * const LRSSHAllowRootKey = @"DebianRunner.sshAllowRootLogin";
static BOOL LRSSHActionInFlight = NO;
static NSMutableArray<void (^)(void)> *LRSSHActionQueue = nil;

+ (BOOL)sshBinaryInstalled {
    if (!self.isRunning) return NO;
    return LRAccountTool(@[@"/usr/sbin/sshd", @"/usr/bin/sshd"]) != nil;
}

+ (BOOL)sshAutoStart {
    id stored = [NSUserDefaults.standardUserDefaults objectForKey:LRSSHAutoStartKey];
    return stored ? [stored boolValue] : YES;
}

+ (void)setSshAutoStart:(BOOL)enabled {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:LRSSHAutoStartKey];
}

+ (BOOL)sshAllowRootLogin {
    return [NSUserDefaults.standardUserDefaults boolForKey:LRSSHAllowRootKey];
}

+ (void)setSshAllowRootLogin:(BOOL)enabled {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:LRSSHAllowRootKey];
}

+ (void)installSSHWithProgress:(void (^)(NSString *stage))progress completion:(void (^)(NSError * _Nullable error))completion {
    [self runSupportInstall:@[@"mode-ssh"] title:@"Installing OpenSSH Server" progress:progress completion:completion];
}

+ (void)runNextSSHActionLocked {
    if (LRSSHActionInFlight || LRSSHActionQueue.count == 0) return;
    void (^next)(void) = LRSSHActionQueue.firstObject;
    [LRSSHActionQueue removeObjectAtIndex:0];
    LRSSHActionInFlight = YES;
    next();
}

+ (void)runSSHAction:(NSString *)action completion:(void (^ _Nullable)(NSDictionary<NSString *, NSString *> *status))completion {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!LRSSHActionQueue) LRSSHActionQueue = [NSMutableArray new];
        // Collapse duplicate queued status checks so timers never pile up.
        if ([action isEqualToString:@"status"] && LRSSHActionInFlight && LRSSHActionQueue.count > 0) {
            if (completion) completion(self.sshStatus);
            return;
        }
        [LRSSHActionQueue addObject:^{
            NSError *error = nil;
            if (!self.isRunning || !LRPrepareSupport(&error)) {
                LRSSHActionInFlight = NO;
                if (completion) completion(self.sshStatus);
                [self runNextSSHActionLocked];
                return;
            }
            NSMutableArray<NSString *> *args = [NSMutableArray arrayWithObjects:@"/bin/sh", @"/home/mobile/Downloads/.linuxrunner/support/modes.sh", nil];
            NSString *permitRoot = self.sshAllowRootLogin ? @"yes" : @"no";
            if ([action isEqualToString:@"start"]) {
                [args addObjectsFromArray:@[@"start", @"ssh", permitRoot]];
            } else if ([action isEqualToString:@"restart"]) {
                [args addObjectsFromArray:@[@"restart", @"ssh", permitRoot]];
            } else if ([action isEqualToString:@"stop"]) {
                [args addObjectsFromArray:@[@"stop", @"ssh"]];
            } else {
                [args addObject:@"status"];
            }
            [self runHeadlessCommand:args directory:@"/root" completion:^(int exitCode) {
                (void)exitCode;
                LRSSHActionInFlight = NO;
                NSDictionary<NSString *, NSString *> *status = self.sshStatus;
                if (![action isEqualToString:@"status"]) {
                    [self logCategory:@"SSH" event:[NSString stringWithFormat:@"action=%@ state=%@ port=%@", action, status[@"ssh"] ?: @"unknown", status[@"ssh.port"] ?: @"2222"]];
                }
                if (completion) completion(status);
                [self runNextSSHActionLocked];
            }];
        }];
        [self runNextSSHActionLocked];
    });
}

+ (NSDictionary<NSString *, NSString *> *)sshStatus {
    NSError *error = nil; NSURL *support = LRPrepareSupport(&error);
    NSString *text = support ? [NSString stringWithContentsOfURL:[support URLByAppendingPathComponent:@"modes-status"] encoding:NSUTF8StringEncoding error:nil] : nil;
    NSMutableDictionary<NSString *, NSString *> *status = [NSMutableDictionary dictionary];
    for (NSString *line in [text ?: @"" componentsSeparatedByString:@"\n"]) {
        NSRange eq = [line rangeOfString:@"="]; if (eq.location == NSNotFound) continue;
        NSString *owner = [line substringToIndex:eq.location];
        NSArray<NSString *> *fields = [line componentsSeparatedByString:@" "];
        for (NSUInteger i = 0; i < fields.count; i++) {
            NSRange e = [fields[i] rangeOfString:@"="]; if (e.location == NSNotFound) continue;
            NSString *key = [fields[i] substringToIndex:e.location];
            status[i == 0 ? key : [NSString stringWithFormat:@"%@.%@", owner, key]] = [fields[i] substringFromIndex:NSMaxRange(e)];
        }
    }
    if (self.isRunning) {
        status[@"ssh_installed"] = self.sshBinaryInstalled ? @"1" : @"0";
    } else {
        status[@"ssh"] = @"stopped";
    }
    if (!status[@"ssh.port"]) status[@"ssh.port"] = @"2222";
    return status;
}

+ (NSString *)sshLogTail {
    NSError *error = nil;
    NSURL *support = LRPrepareSupport(&error);
    if (!support) return @"";
    return [self boundedDiagnosticTail:[support URLByAppendingPathComponent:@"modes.log"] maxBytes:16384];
}

// ---- Support installations: one runner, real progress ----------------------
NSNotificationName const LRInstallProgressNotification = @"LRInstallProgressNotification";
static NSString *LRActiveInstall;
+ (BOOL)installationRunning { return LRActiveInstall != nil; }
static NSString *LRInstallFailureMessage(NSString *category, NSString *detail) {
    NSDictionary *advice = @{
        @"NETWORK_UNAVAILABLE": @"LinuxRunner could not reach the Debian package servers. Check the internet connection and try again.",
        @"TLS_CERTIFICATE_ERROR": @"A secure connection to the Debian package servers failed. Check that the date and time are correct, then try again.",
        @"PACKAGE_MANAGER_BUSY": @"Another package operation is using apt/dpkg. Wait for it to finish, then try again.",
        @"INSUFFICIENT_STORAGE": @"There is not enough free storage on this device. Free some space and try again.",
        @"PACKAGE_NOT_FOUND": @"The Debian repositories did not offer a required package. Try again later.",
        @"REPOSITORY_METADATA_ERROR": @"The package lists could not be verified or downloaded. Try again later.",
        @"DEPENDENCY_CONFLICT": @"The packages have conflicting dependencies. Check Diagnostics and Repair Center.",
        @"PACKAGE_DATABASE_RECOVERY_REQUIRED": @"Debian package setup needs attention. Review the retained package log and Repair Center before retrying.",
        @"PACKAGE_MANAGER_STUCK": @"Debian first-start setup stopped making progress. Restart LinuxRunner and try again.",
        @"FILESYSTEM_ERROR": @"Linux could not write its files. Restart LinuxRunner and try again.",
        @"ACCOUNT_TOOL_BROKEN": @"The account tools were installed but do not run. Export diagnostics and try again.",
    };
    NSString *base = advice[category] ?: @"The installation failed.";
    return detail.length ? [NSString stringWithFormat:@"%@\n\nDetail: %@", base, detail] : base;
}
static NSArray<NSString *> *LRInstallSteps;
static NSString *LRInstallKind = @"";
+ (void)postInstall:(NSString *)title phase:(NSString *)phase stage:(NSString *)stage detail:(NSString *)detail fraction:(double)fraction elapsed:(NSTimeInterval)elapsed error:(NSString *)error log:(NSString *)log {
    NSMutableDictionary *info = [@{@"title": title, @"phase": phase, @"stage": stage ?: @"", @"detail": detail ?: @"", @"fraction": @(fraction), @"elapsed": @(elapsed),
                                   @"steps": LRInstallSteps ?: @[], @"kind": LRInstallKind ?: @""} mutableCopy];
    if (error) info[@"error"] = error;
    if (log) info[@"log"] = log;
    [NSNotificationCenter.defaultCenter postNotificationName:LRInstallProgressNotification object:nil userInfo:info];
}
+ (void)runSupportInstall:(NSArray<NSString *> *)arguments title:(NSString *)title progress:(void (^)(NSString *))progress completion:(void (^)(NSError * _Nullable))completion {
    if (LRActiveInstall) { completion(lrError(EBUSY, [NSString stringWithFormat:@"“%@” is already running. Wait for it to finish, then try again.", LRActiveInstall])); return; }
    NSError *error = nil; NSURL *support = LRPrepareSupport(&error);
    if (!support) { completion(error); return; }
    for (NSString *name in @[@"install-result", @"apt-status"]) [NSFileManager.defaultManager removeItemAtURL:[support URLByAppendingPathComponent:name] error:nil];
    NSURL *logURL = [support URLByAppendingPathComponent:@"debian-support.sh.log"], *resultURL = [support URLByAppendingPathComponent:@"install-result"], *statusURL = [support URLByAppendingPathComponent:@"apt-status"];
    [NSFileManager.defaultManager removeItemAtURL:logURL error:nil];
    if (!self.isRunning) { completion(lrError(EIO, @"The installer could not be started because Debian Minimal is not running.")); return; }
    LRActiveInstall = title;
    [self beginAwake:@"installation"];
    [self logCategory:@"SETUP" event:[NSString stringWithFormat:@"support install started: %@ (%@)", title, [arguments componentsJoinedByString:@" "]]];
    NSDate *start = NSDate.date; __block BOOL processEnded = NO; __block NSDate *endedAt = nil; __block NSString *reported = nil; __block NSDate *lastChange = NSDate.date; __block NSUInteger lastSignature = 0;
    LRInstallSteps = @[]; LRInstallKind = @"";
    [self postInstall:title phase:@"running" stage:@"Checking existing installation" detail:@"" fraction:-1 elapsed:0 error:nil log:nil];
    NSArray<NSString *> *command = [@[@"/bin/sh", @"/home/mobile/Downloads/.linuxrunner/support/installer-run.sh", @"debian-support.sh"] arrayByAddingObjectsFromArray:arguments];
    [self runHeadlessCommand:command directory:@"/root" stdinData:nil timeout:0 completion:^(int exitCode) {
        (void)exitCode;
        processEnded = YES;
        if (!endedAt) endedAt = NSDate.date;
    }];
    [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        NSString *log = [NSString stringWithContentsOfURL:logURL encoding:NSUTF8StringEncoding error:nil] ?: @"";
        NSString *stage = nil, *detail = @"", *category = nil, *failureDetail = nil, *kind = @""; long done = -1, total = -1;
        NSMutableArray<NSString *> *steps = [NSMutableArray array];
        for (NSString *line in [log componentsSeparatedByString:@"\n"]) {
            if ([line hasPrefix:@"PROFILE_STAGE: "]) { stage = [line substringFromIndex:15]; detail = @""; done = total = -1; if (![steps.lastObject isEqualToString:stage]) [steps addObject:stage]; }
            else if ([line hasPrefix:@"PACKAGE_STAGE: "]) {
                NSString *text = [line substringFromIndex:15]; NSRange colon = [text rangeOfString:@": "];
                stage = colon.location == NSNotFound ? text : [text substringToIndex:colon.location];
                detail = colon.location == NSNotFound ? @"" : [text substringFromIndex:NSMaxRange(colon)];
            } else if ([line hasPrefix:@"PACKAGE_PROGRESS: "]) {
                NSArray *parts = [[line substringFromIndex:18] componentsSeparatedByString:@" "];
                if (parts.count == 2) { done = [parts[0] integerValue]; total = [parts[1] integerValue]; }
            } else if ([line hasPrefix:@"PROFILE_FAILURE: "] || [line hasPrefix:@"PACKAGE_LOCK: category="]) {
                NSRange c = [line rangeOfString:@"category="]; NSString *rest = [line substringFromIndex:NSMaxRange(c)];
                NSRange space = [rest rangeOfString:@" "]; category = space.location == NSNotFound ? rest : [rest substringToIndex:space.location];
                NSRange d = [rest rangeOfString:@"detail="]; failureDetail = d.location == NSNotFound ? (space.location == NSNotFound ? @"" : [rest substringFromIndex:space.location + 1]) : [rest substringFromIndex:NSMaxRange(d)];
            }
        }
        double fraction = -1;
        if (done >= 0 && total > 0) fraction = MIN(1.0, (double)done / total);
        else if (stage) {
            NSString *status = [[[NSString stringWithContentsOfURL:statusURL encoding:NSUTF8StringEncoding error:nil] ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsSeparatedByString:@"\n"].lastObject;
            NSArray *f = [status componentsSeparatedByString:@":"];
            if (f.count >= 4 && ([f[0] isEqual:@"dlstatus"] || [f[0] isEqual:@"pmstatus"])) {
                fraction = MAX(0, MIN(1.0, [f[2] doubleValue] / 100.0));
                kind = [f[0] isEqual:@"dlstatus"] ? @"download" : @"install";
                detail = [[f subarrayWithRange:NSMakeRange(3, f.count - 3)] componentsJoinedByString:@":"];
                if ([f[0] isEqual:@"dlstatus"] && [stage hasPrefix:@"Installing"]) detail = [@"Downloading: " stringByAppendingString:detail];
            }
        }
        NSString *result = [[NSString stringWithContentsOfURL:resultURL encoding:NSUTF8StringEncoding error:nil] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (processEnded && !endedAt) endedAt = NSDate.date;
        NSTimeInterval elapsed = -[start timeIntervalSinceNow];
        NSUInteger signature = log.length ^ ([[NSString stringWithContentsOfURL:statusURL encoding:NSUTF8StringEncoding error:nil] ?: @"" hash] << 1);
        if (signature != lastSignature) { lastSignature = signature; lastChange = NSDate.date; }
        BOOL stalled = -[lastChange timeIntervalSinceNow] > 45 * 60;
        BOOL finished = result.length || (endedAt && -[endedAt timeIntervalSinceNow] > 5) || stalled;
        if (finished) {
            [timer invalidate];
            LRActiveInstall = nil;
            [self endAwake:@"installation"];
            [self logCategory:@"SETUP" event:[NSString stringWithFormat:@"support install finished: %@ result=%@ stage=%@ category=%@ seconds=%.0f", title, result ?: @"none", stage ?: @"none", category ?: @"none", elapsed]];
            if ([result isEqual:@"0"]) {
                [self postInstall:title phase:@"succeeded" stage:@"Installation complete" detail:@"" fraction:1 elapsed:elapsed error:nil log:nil];
                completion(nil);
                return;
            }
            NSString *message = category ? LRInstallFailureMessage(category, failureDetail) :
                result.length ? [NSString stringWithFormat:@"The installation failed at “%@”. Export diagnostics and try again.", stage ?: @"start"] :
                endedAt ? @"The installer stopped before finishing. Try again; if it repeats, export diagnostics." :
                @"The installation made no progress for 45 minutes. Restart LinuxRunner and try again; completed packages are kept.";
            NSArray *lines = [log componentsSeparatedByString:@"\n"];
            NSString *tail = [[lines subarrayWithRange:NSMakeRange(lines.count > 25 ? lines.count - 25 : 0, MIN((NSUInteger)25, lines.count))] componentsJoinedByString:@"\n"];
            [self postInstall:title phase:@"failed" stage:stage ?: @"Starting" detail:detail fraction:-1 elapsed:elapsed error:message log:tail];
            completion(lrError(EIO, message));
            return;
        }
        if (stage && ![stage isEqual:reported]) { reported = stage; progress(stage); }
        LRInstallSteps = [steps copy]; LRInstallKind = kind;
        [self postInstall:title phase:@"running" stage:stage ?: @"Waiting for the package manager" detail:detail fraction:fraction elapsed:elapsed error:nil log:nil];
    }];
}

// ---- Keep Screen Awake During Operations ------------------------------------
static NSCountedSet<NSString *> *LRAwakeSet;
+ (void)beginAwake:(NSString *)reason {
    dispatch_async(dispatch_get_main_queue(), ^{ if (!LRAwakeSet) LRAwakeSet = [NSCountedSet new]; [LRAwakeSet addObject:reason]; [self refreshAwake]; });
}
+ (void)endAwake:(NSString *)reason {
    dispatch_async(dispatch_get_main_queue(), ^{ if ([LRAwakeSet countForObject:reason]) [LRAwakeSet removeObject:reason]; [self refreshAwake]; });
}
+ (NSArray<NSString *> *)awakeReasons { return LRAwakeSet.allObjects ?: @[]; }
+ (void)refreshAwake {
    dispatch_async(dispatch_get_main_queue(), ^{
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { [self refreshAwake]; }];
        });
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        BOOL enabled = [defaults objectForKey:@"LinuxRunner.keepScreenAwake"] ? [defaults boolForKey:@"LinuxRunner.keepScreenAwake"] : YES;
        BOOL keep = UserPreferences.shared.shouldDisableDimming || (enabled && LRAwakeSet.count > 0);
        if (UIApplication.sharedApplication.idleTimerDisabled != keep) {
            UIApplication.sharedApplication.idleTimerDisabled = keep;
            [self logCategory:@"POWER" event:[NSString stringWithFormat:@"screen awake=%d setting=%d reasons=%@", keep, enabled, [LRAwakeSet.allObjects componentsJoinedByString:@","] ?: @""]];
        }
    });
}
+ (void)removeLinuxUserKeepingHome:(NSString *)name completion:(void (^)(NSError * _Nullable))completion {
    NSDictionary *account = LRLoginAccount(name);
    if (!account) { completion(lrError(ENOENT, @"Refresh the account list first.")); return; }
    if ([account[@"uid"] longLongValue] < 1000 || [name isEqual:self.defaultLinuxUser]) {
        completion(lrError(EPERM, @"System accounts and the default login cannot be removed. Select a different default login first."));
        return;
    }
    NSString *remove = LRAccountTool(@[@"/usr/sbin/userdel", @"/usr/bin/userdel"]);
    if (!remove) { completion(lrError(ENOENT, @"Debian's account-removal tool (userdel) is missing. Install passwd first.")); return; }
    [self runHeadlessCommand:@[@"/bin/sh", @"-c", @"\"$2\" -- \"$1\" && rm -f \"/etc/sudoers.d/90-debianrunner-$1\"", @"linuxrunner-remove-user", name, remove]
                   directory:@"/"
                     timeout:60.0
                  completion:^(int exitCode) {
        BOOL stillExists = LRLoginAccount(name) != nil;
        [self logCategory:@"ACCOUNT" event:[NSString stringWithFormat:@"native remove user=%@ exit=%d still_exists=%d", name, exitCode, stillExists]];
        if (!stillExists) completion(nil);
        else completion(lrError(EIO, @"The account could not be removed. Close any active SSH sessions for this user and try again."));
    }];
}
+ (NSURL *)prepareApplicationSupport:(NSError **)error { return LRPrepareSupport(error); }
+ (void)logCategory:(NSString *)category event:(NSString *)event {
    LRBootEvent([[NSString stringWithFormat:@"[%@] %@", category, event] UTF8String]);
    @synchronized(self) {
        if (!events) events = [NSMutableArray new];
        [events addObject:[NSString stringWithFormat:@"%@ [%@] %@", [[NSISO8601DateFormatter new] stringFromDate:NSDate.date], category, event]];
        if (events.count > 500) [events removeObjectAtIndex:0];
    }
}
+ (NSArray *)logLines { @synchronized(self) { return events.copy ?: @[]; } }
+ (NSURL *)exportLogs:(NSError **)error {
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"LinuxRunner-diagnostics-%@.txt", NSUUID.UUID.UUIDString]]];
    NSString *header = [NSString stringWithFormat:@"LinuxRunner %@ (%@)\nDebian 13 (trixie) minimal ARM64 compatibility runtime\nExecution: ARM64 Interpreter\n%@\n",
        [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
        [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"],
        self.runtimeStatus];
    LRBootLogSync();
    if (bootSnapshot) msync(bootSnapshot, sizeof(*bootSnapshot), MS_SYNC);
    NSMutableString *text = [header mutableCopy];
    [text appendFormat:@"Device diagnostics: %@\n", [self deviceDiagnostics]];
    struct proc_data pi = {0};
    futex_pi_show(&pi);
    NSString *piText = [[NSString alloc] initWithBytes:pi.data length:pi.size encoding:NSUTF8StringEncoding];
    [text appendFormat:@"\n--- PI futex snapshot ---\n%@", piText ?: @"unavailable\n"];
    free(pi.data);
    for (NSString *name in @[@"previous-startup.log", @"startup.log"])
        [text appendFormat:@"\n--- %@ ---\n%@", name, [NSString stringWithContentsOfURL:[bootLogDirectory URLByAppendingPathComponent:name] encoding:NSUTF8StringEncoding error:nil] ?: @"unavailable\n"];
    if (bootSnapshot) [text appendFormat:@"\nLast observed guest context (best effort): pid=%llu pc=%llx sp=%llx syscall=%llu unsupported-opcode=%llx\n",
        (unsigned long long)atomic_load(&bootSnapshot->pid), (unsigned long long)atomic_load(&bootSnapshot->pc), (unsigned long long)atomic_load(&bootSnapshot->sp), (unsigned long long)atomic_load(&bootSnapshot->syscall), (unsigned long long)atomic_load(&bootSnapshot->opcode)];
    return [[self redactDiagnosticText:text application:NO] writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:error] ? url : nil;
}
+ (NSURL *)exportFullDiagnosticBundle:(NSError **)error {
    LRBootLogSync();
    [LRDiagnosticCenter flush];
    NSMutableDictionary<NSString *,NSData *> *entries=[NSMutableDictionary new];
    entries[@"health.json"]=[NSJSONSerialization dataWithJSONObject:self.healthSummary options:NSJSONWritingPrettyPrinted error:nil];
    entries[@"events.json"]=[NSJSONSerialization dataWithJSONObject:self.diagnosticEntries options:NSJSONWritingPrettyPrinted error:nil];
    NSURL *installerLogs=[[[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"LinuxRunnerDiagnostics"] URLByAppendingPathComponent:@"debian-installer"];
    for(NSString *name in @[@"events.jsonl",@"events.1.jsonl",@"events.2.jsonl"]){
        NSURL *path=[installerLogs URLByAppendingPathComponent:name];int fd=open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW);if(fd<0)continue;struct stat st;if(fstat(fd,&st)||!S_ISREG(st.st_mode)){close(fd);continue;}
        off_t offset=st.st_size>1024*1024?st.st_size-1024*1024:0;NSMutableData *data=[NSMutableData dataWithLength:st.st_size-offset];ssize_t n=pread(fd,data.mutableBytes,data.length,offset);close(fd);if(n<0)continue;data.length=n;
        NSString *text=[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding]?:@"non-UTF8 installer output omitted";
        entries[[@"debian-installer/" stringByAppendingString:name]]=[[self redactDiagnosticText:text application:NO] dataUsingEncoding:NSUTF8StringEncoding];
    }
    NSDictionary *catalog=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:self.catalogURL]?:[NSData data] options:0 error:nil];
    NSMutableArray *safeEnvironments=[NSMutableArray new];
    for(NSDictionary *item in catalog[@"environments"]){NSMutableDictionary *safe=[NSMutableDictionary new];for(NSString *key in @[@"id",@"distribution",@"distributionID",@"architecture",@"rootfsName",@"rootfsVersion",@"packageManager",@"lastBootedAt"]){if(item[key])safe[key]=item[key];}[safeEnvironments addObject:safe];}
    entries[@"environments.json"]=[NSJSONSerialization dataWithJSONObject:safeEnvironments options:NSJSONWritingPrettyPrinted error:nil];
    for(NSString *name in @[@"startup.log",@"previous-startup.log"]){NSString *text=[NSString stringWithContentsOfURL:[bootLogDirectory URLByAppendingPathComponent:name] encoding:NSUTF8StringEncoding error:nil];if(text)entries[name]=[[self redactDiagnosticText:text application:NO] dataUsingEncoding:NSUTF8StringEncoding];}
    for(NSString *root in self.rootNames){
        NSURL *base=[[[self exchangeURL:root] URLByAppendingPathComponent:@".linuxrunner"] URLByAppendingPathComponent:@"support"];
        for(NSString *name in @[@"package-operation.log",@"package-operation.previous.log",@"package-result",@"package-interrupted",@"debian-support.sh.log"]){
            NSURL *url=[base URLByAppendingPathComponent:name];int fd=open(url.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW);if(fd<0)continue;struct stat st;if(fstat(fd,&st)||!S_ISREG(st.st_mode)){close(fd);continue;}
            off_t offset=st.st_size>1024*1024?st.st_size-1024*1024:0;NSMutableData *data=[NSMutableData dataWithLength:st.st_size-offset];ssize_t n=pread(fd,data.mutableBytes,data.length,offset);close(fd);if(n<0)continue;data.length=n;
            NSString *text=[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding]?:@"non-UTF8 package output omitted";
            entries[[NSString stringWithFormat:@"packages/%@/%@",root,name]]=[[self redactDiagnosticText:text application:NO] dataUsingEncoding:NSUTF8StringEncoding];
        }
        NSString *modesLog=[self boundedDiagnosticTail:[base URLByAppendingPathComponent:@"modes.log"] maxBytes:262144];
        if(modesLog.length)entries[[NSString stringWithFormat:@"support/%@/modes.log",root]]=[[self redactDiagnosticText:modesLog application:YES] dataUsingEncoding:NSUTF8StringEncoding];
    }
    NSURL *url=[NSFileManager.defaultManager.temporaryDirectory URLByAppendingPathComponent:[NSString stringWithFormat:@"LinuxRunner-Diagnostics-%@.zip",NSUUID.UUID.UUIDString]];
    struct archive *archive=archive_write_new();archive_write_set_format_zip(archive);
    int result=archive_write_open_filename(archive,url.fileSystemRepresentation);
    if(result==ARCHIVE_OK)for(NSString *name in entries){NSData *data=entries[name];struct archive_entry *entry=archive_entry_new();archive_entry_set_pathname(entry,name.UTF8String);archive_entry_set_filetype(entry,AE_IFREG);archive_entry_set_perm(entry,0600);archive_entry_set_size(entry,data.length);result=archive_write_header(archive,entry);if(result==ARCHIVE_OK&&archive_write_data(archive,data.bytes,data.length)!=(la_ssize_t)data.length)result=ARCHIVE_FATAL;archive_entry_free(entry);if(result!=ARCHIVE_OK)break;}
    if(archive_write_close(archive)!=ARCHIVE_OK)result=ARCHIVE_FATAL;archive_write_free(archive);
    if(result!=ARCHIVE_OK){[NSFileManager.defaultManager removeItemAtURL:url error:nil];if(error)*error=lrError(EIO,@"Diagnostic archive creation failed");return nil;}
    return url;
}
+ (NSURL *)sharedExchangeURL:(NSString *)root {
    NSParameterAssert(validRoot(root));
    NSURL *documents=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    return [[documents URLByAppendingPathComponent:@"Shared" isDirectory:YES] URLByAppendingPathComponent:root isDirectory:YES];
}
static BOOL LRTransferString(NSString *value){return value&&strlen(value.UTF8String)==[value lengthOfBytesUsingEncoding:NSUTF8StringEncoding];}
static int LRTransferStaging(void) {
    static dispatch_once_t once;static NSURL *url;static int failure;
    dispatch_once(&once,^{
        NSURL *support=[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
        url=[support URLByAppendingPathComponent:@"LinuxRunnerTransferStaging" isDirectory:YES];
        if(![NSFileManager.defaultManager createDirectoryAtURL:url withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil]){failure=EIO;return;}
        int fd=open(url.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);
        failure=fd<0?errno:lr_clean_import_staging(fd);if(fd>=0)close(fd);
    });
    if(failure){errno=failure;return -1;}
    return open(url.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);
}
static int LRSharedDirectory(NSString *root,NSString *relative){
    if(!validRoot(root)||!LRTransferString(relative)){errno=EINVAL;return -1;}
    NSURL *base=[LRRuntimeBridge sharedExchangeURL:root];
    NSError *error=nil;if(![NSFileManager.defaultManager createDirectoryAtURL:base withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error]){errno=EIO;return -1;}
    int parent=open(base.URLByDeletingLastPathComponent.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);
    if(parent<0)return -1;
    int directory=openat(parent,root.UTF8String,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);int saved=errno;close(parent);if(directory<0){errno=saved;return -1;}
    int result=lr_open_subdirectory(directory,relative.UTF8String);saved=errno;close(directory);errno=saved;return result;
}
+ (NSArray<NSDictionary *> *)sharedEntries:(NSString *)relative root:(NSString *)root error:(NSError **)error {
    int fd=LRSharedDirectory(root,relative);if(fd<0){if(error)*error=lrError(errno,@"Cannot open the shared folder. Symbolic links are not followed.");return nil;}
    DIR *directory=fdopendir(fd);if(!directory){int saved=errno;close(fd);if(error)*error=lrError(saved,@"Cannot list this folder.");return nil;}
    NSMutableArray *items=[NSMutableArray new];struct dirent *entry;int failure=0;
    for(;;){errno=0;entry=readdir(directory);if(!entry){failure=errno;break;}if(entry->d_name[0]=='.')continue;
        struct stat st;if(fstatat(fd,entry->d_name,&st,AT_SYMLINK_NOFOLLOW)<0)continue;
        if(!S_ISREG(st.st_mode)&&!S_ISDIR(st.st_mode))continue;
        NSString *name=[NSString stringWithUTF8String:entry->d_name];if(!name)continue;
        [items addObject:@{@"name":name,@"directory":@(S_ISDIR(st.st_mode)),@"bytes":@(st.st_size)}];if(items.count>4096){failure=EFBIG;break;}
    }
    closedir(directory);if(failure){if(error)*error=lrError(failure,@"Folder could not be listed completely (maximum 4096 entries).");return nil;}
    [items sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){if([a[@"directory"] boolValue]!=[b[@"directory"] boolValue])return [a[@"directory"] boolValue]?NSOrderedAscending:NSOrderedDescending;return [a[@"name"] localizedStandardCompare:b[@"name"]];}];return items;
}
+ (BOOL)createSharedDirectory:(NSString *)leaf relative:(NSString *)relative root:(NSString *)root error:(NSError **)error {
    if(!LRTransferString(leaf)||!lr_valid_leaf(leaf.UTF8String)){if(error)*error=lrError(EINVAL,@"Choose a single folder name.");return NO;}
    int fd=LRSharedDirectory(root,relative);int result=fd<0?-1:mkdirat(fd,leaf.UTF8String,0700);int saved=errno;if(fd>=0)close(fd);
    if(result<0&&error)*error=lrError(saved,@"Cannot create the folder; an existing item is never replaced.");return result==0;
}
+ (BOOL)importSharedFile:(NSURL *)source relative:(NSString *)relative root:(NSString *)root control:(LRTransferControl *)control error:(NSError **)error {
    BOOL scoped=[source startAccessingSecurityScopedResource];__block int result=0;
    NSFileCoordinator *coordinator=[[NSFileCoordinator alloc]initWithFilePresenter:nil];NSError *coordError=nil;
    struct lr_transfer_control callbacks=LRTransferCallbacks(control);
    [coordinator coordinateReadingItemAtURL:source options:0 error:&coordError byAccessor:^(NSURL *url){
        int input=open(url.fileSystemRepresentation,O_RDONLY|O_NONBLOCK|O_NOFOLLOW);int saved=errno;
        int directory=LRSharedDirectory(root,relative),directoryError=directory<0?errno:0;
        int stage=LRTransferStaging(),stageError=stage<0?errno:0;
        result=input<0?saved:directoryError?directoryError:stageError?stageError:!LRTransferString(source.lastPathComponent)?EINVAL:lr_copy_in_staged(input,directory,source.lastPathComponent.UTF8String,stage,&callbacks);
        if(input>=0)close(input);if(directory>=0)close(directory);if(stage>=0)close(stage);
    }];
    if(scoped)[source stopAccessingSecurityScopedResource];
    if(coordError||result){if(error)*error=coordError?:lrError(result,result==ECANCELED?@"Transfer cancelled; no destination file was published.":result==EEXIST?@"That name already exists. Choose a different folder or rename the source.":result==EBUSY?@"The source changed during copying. Close its editor and retry.":@"Import failed. Use a regular file up to 512 MiB; existing items and symbolic links are not replaced.");return NO;}
    [self logCategory:@"FILES" event:@"shared file import completed"];return YES;
}
+ (NSURL *)exportSharedItem:(NSString *)leaf relative:(NSString *)relative root:(NSString *)root control:(LRTransferControl *)control error:(NSError **)error {
    if(!LRTransferString(leaf)||!lr_valid_leaf(leaf.UTF8String)){if(error)*error=lrError(EINVAL,@"Invalid filename.");return nil;}
    int directory=LRSharedDirectory(root,relative);struct stat st;int failure=directory<0?errno:fstatat(directory,leaf.UTF8String,&st,AT_SYMLINK_NOFOLLOW)<0?errno:0;
    NSURL *folder=[NSFileManager.defaultManager.temporaryDirectory URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    if(!failure&&![NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:error]){close(directory);return nil;}
    NSString *name=!failure&&S_ISDIR(st.st_mode)?[leaf stringByAppendingString:@".zip"]:leaf;NSURL *target=[folder URLByAppendingPathComponent:name];
    int output=failure?-1:open(target.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);
    if(!failure&&output<0)failure=errno;
    struct lr_transfer_control callbacks=LRTransferCallbacks(control);
    if(!failure)failure=S_ISDIR(st.st_mode)?lr_archive_directory(directory,leaf.UTF8String,output,&callbacks):lr_copy_out_controlled(directory,leaf.UTF8String,output,&callbacks);
    if(output>=0&&close(output)<0&&!failure)failure=errno;if(directory>=0)close(directory);
    if(failure){[NSFileManager.defaultManager removeItemAtURL:folder error:nil];if(error)*error=lrError(failure,failure==ECANCELED?@"Export cancelled; the temporary copy was removed.":failure==EBUSY?@"The selected item changed during export. Close applications writing to it and retry.":@"Export failed. Use regular files or directories without links/special files, up to 512 MiB, 4096 entries and 32 directory levels.");return nil;}
    [self logCategory:@"FILES" event:@"shared export snapshot prepared"];return target;
}
+ (BOOL)importFile:(NSURL *)source root:(NSString *)root error:(NSError **)error {
    BOOL scoped = [source startAccessingSecurityScopedResource];
    __block int result = 0;
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    NSError *coordError;
    [coordinator coordinateReadingItemAtURL:source options:0 error:&coordError byAccessor:^(NSURL *url) {
        int input = open(url.fileSystemRepresentation, O_RDONLY | O_NONBLOCK | O_NOFOLLOW);
        int directory = open([self exchangeURL:root].fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        if (input < 0 || directory < 0) result = errno;
        else result = lr_copy_in(input, directory, source.lastPathComponent.UTF8String);
        if (input >= 0) close(input);
        if (directory >= 0) close(directory);
    }];
    if (scoped) [source stopAccessingSecurityScopedResource];
    if (coordError || result) {
        if (error) *error = coordError ?: lrError(result, result == EEXIST ? @"A file with that name already exists. Rename the source before importing." : @"Import failed. Only regular files up to 512 MiB are supported.");
        [self logCategory:@"FS" event:[NSString stringWithFormat:@"import failed code=%d", result]];
        return NO;
    }
    [self logCategory:@"FS" event:@"file imported"];
    return YES;
}
+ (NSURL *)exportFile:(NSString *)leaf root:(NSString *)root error:(NSError **)error {
    if (!lr_valid_leaf(leaf.UTF8String)) {
        if (error) *error = lrError(EINVAL, @"Invalid export filename.");
        return nil;
    }
    NSURL *folder = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
    if (![NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:NO attributes:nil error:error]) return nil;
    NSURL *url = [folder URLByAppendingPathComponent:leaf];
    int directory = open([self exchangeURL:root].fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    int output = open(url.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    int result = directory < 0 || output < 0 ? errno : lr_copy_out(directory, leaf.UTF8String, output);
    if (directory >= 0) close(directory);
    if (output >= 0) close(output);
    if (result) {
        [NSFileManager.defaultManager removeItemAtURL:folder error:nil];
        if (error) *error = lrError(result, @"Export failed. Select a regular file up to 512 MiB; symlinks are refused.");
        return nil;
    }
    [self logCategory:@"FS" event:@"file exported"];
    return url;
}
+ (void)deleteExport:(NSURL *)url {
    NSString *base=NSFileManager.defaultManager.temporaryDirectory.URLByStandardizingPath.path;
    NSURL *standard=url.URLByStandardizingPath;NSString *prefix=[base stringByAppendingString:@"/"];
    if(!url.isFileURL||![standard.path hasPrefix:prefix])return;
    NSString *relative=[standard.path substringFromIndex:prefix.length],*leaf=relative.lastPathComponent,*parent=relative.stringByDeletingLastPathComponent;
    if(!LRTransferString(leaf)||!lr_valid_leaf(leaf.UTF8String))return;
    int root=open(base.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);if(root<0)return;
    int directory=lr_open_subdirectory(root,[parent isEqual:@"."]?"":parent.UTF8String);
    if(directory>=0){struct stat st;if(!fstatat(directory,leaf.UTF8String,&st,AT_SYMLINK_NOFOLLOW)&&!S_ISDIR(st.st_mode))unlinkat(directory,leaf.UTF8String,0);close(directory);}
    if([[NSUUID alloc]initWithUUIDString:parent]&&[parent isEqual:parent.lastPathComponent])unlinkat(root,parent.UTF8String,AT_REMOVEDIR);
    close(root);
}
@end

@implementation LRDeviceDiagnosticsController
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor = UIColor.systemBackgroundColor;
    UIScrollView *scroll = [UIScrollView new]; scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    UIStackView *stack = [UIStackView new]; stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 14; stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor], [scroll.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor], [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:20], [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-20],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:20], [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-20],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40]]];
    UILabel *title = [UILabel new]; title.text = @"LinuxRunner Device Diagnostics"; title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle1]; title.numberOfLines = 0; [stack addArrangedSubview:title];
    UILabel *label = [UILabel new]; label.text = @"Runtime Auto Start (next launch)"; [stack addArrangedSubview:label];
    self.autoStartSwitch = [UISwitch new]; self.autoStartSwitch.accessibilityIdentifier = @"Runtime Auto Start"; self.autoStartSwitch.on = LRRuntimeBridge.autoStart;
    [self.autoStartSwitch addTarget:self action:@selector(toggleAutoStart) forControlEvents:UIControlEventValueChanged]; [stack addArrangedSubview:self.autoStartSwitch];
    self.details = [UILabel new]; self.details.numberOfLines = 0; self.details.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular]; self.details.accessibilityIdentifier = @"Device diagnostic details"; [stack addArrangedSubview:self.details];
    self.startButton = [self button:@"Start Linux Runtime" selector:@selector(startRuntime)]; [stack addArrangedSubview:self.startButton];
    self.managerButton = [self button:@"Open Environment Manager" selector:@selector(openManager)]; [stack addArrangedSubview:self.managerButton];
    UIButton *stop = [self button:@"Stop Runtime — requires full app relaunch" selector:NULL]; stop.enabled = NO; [stack addArrangedSubview:stop];
    [stack addArrangedSubview:[self button:@"Export Logs" selector:@selector(exportLogs)]];
    [stack addArrangedSubview:[self button:@"Refresh Diagnostics" selector:@selector(refresh)]];
    [self refresh];
}
- (UIButton *)button:(NSString *)title selector:(SEL)selector {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem]; [button setTitle:title forState:UIControlStateNormal];
    if (selector) [button addTarget:self action:selector forControlEvents:UIControlEventTouchUpInside];
    return button;
}
- (void)viewDidAppear:(BOOL)animated { [super viewDidAppear:animated]; LRBootEvent("UI attached: native diagnostics (Linux not required)"); [self refresh]; }
- (void)toggleAutoStart { [NSUserDefaults.standardUserDefaults setBool:self.autoStartSwitch.on forKey:@"LinuxRunnerRuntimeAutoStart"]; LRBootEvent(self.autoStartSwitch.on ? "runtime auto start enabled for next launch" : "runtime auto start disabled for next launch"); }
- (void)refresh {
    NSDictionary *info = LRRuntimeBridge.deviceDiagnostics; NSMutableString *text = [NSMutableString new];
    for (NSString *key in [info.allKeys sortedArrayUsingSelector:@selector(compare:)]) [text appendFormat:@"%@: %@\n\n", key, info[key]];
    self.details.text = text; self.startButton.enabled = !bootAttempted && Roots.instance.defaultRoot != nil; self.managerButton.enabled = LRRuntimeBridge.isRunning;
}
- (void)startRuntime {
    self.startButton.enabled = NO; LRBootEvent("Start Linux Runtime pressed"); [self refresh];
    dispatch_async(dispatch_get_main_queue(), ^{
        [(AppDelegate *)UIApplication.sharedApplication.delegate startLinuxRuntime]; [self refresh];
    });
}
- (void)openManager {
    if (!LRRuntimeBridge.isRunning) return;
    self.view.window.rootViewController = [LinuxRunnerShell makeController];
    LRBootEvent("UI attached: environment manager after manual runtime start");
}
- (void)exportLogs {
    NSError *error; NSURL *url = [LRRuntimeBridge exportLogs:&error];
    if (!url) { self.details.text = error.localizedDescription; return; }
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    share.popoverPresentationController.sourceView = self.view;
    share.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, 40, 1, 1);
    share.completionWithItemsHandler = ^(UIActivityType type, BOOL complete, NSArray *items, NSError *failure) { [NSFileManager.defaultManager removeItemAtURL:url error:nil]; };
    [self presentViewController:share animated:YES completion:nil];
}
@end

#import <UIKit/UIKit.h>
#import "../TerminalViewController.h"

NS_ASSUME_NONNULL_BEGIN
// Settings › CPU & Memory (NSInteger, 0 = automatic); applied at the next launch.
extern NSString *const LRSystemCPUCoresKey;
extern NSString *const LRSystemMemoryMBKey;
void LRSetDatalessMaterialization(void);

@interface LRTransferControl : NSObject
- (void)cancel;
- (NSDictionary<NSString *, NSNumber *> *)snapshot;
@end

@interface LRRuntimeBridge : NSObject
#if TARGET_OS_SIMULATOR
+ (NSDictionary *)applicationDiscoveryContextContract;
+ (NSDictionary *)networkABIContract;
#endif
+ (BOOL)autoStart;
+ (BOOL)canStartRuntime;
+ (int)startRuntime;
+ (BOOL)beginBoot;
+ (UIViewController *)diagnosticsController;
+ (NSDictionary<NSString *, NSString *> *)deviceDiagnostics;
+ (NSURL *)catalogURL;
+ (NSURL *)managedStorageURL;
+ (NSDictionary *)healthSummary;
+ (NSArray<NSDictionary *> *)diagnosticEntries;
+ (void)configureDiagnostics:(int)level process:(int)pid syscall:(int)number errorsOnly:(BOOL)errorsOnly;
+ (NSURL * _Nullable)exportFullDiagnosticBundle:(NSError **)error;
+ (NSString *)redactDiagnosticText:(NSString *)text application:(BOOL)application;
+ (NSArray<NSString *> *)rootNames;
+ (NSString *)activeRootName;
+ (NSString *)nextRootName;
+ (void)setNextRootName:(NSString *)name;
+ (NSURL *)rootURL:(NSString *)name;
+ (NSURL *)exchangeURL:(NSString *)name;
+ (BOOL)isRunning;
+ (NSString *)runtimeStatus;
+ (void)recordBoot:(NSString *)root error:(int)error;
+ (int)prepareExchange:(NSString *)root;
+ (BOOL)assembleDebianPackages:(NSArray<NSString *> *)packages toArchive:(NSURL *)archive progress:(void (^)(double))progress cancel:(BOOL (^)(void))cancel error:(NSError **)error;
+ (BOOL)importVerifiedEnvironment:(NSURL *)archive root:(NSString *)root sha256:(NSString *)sha256 progress:(void (^)(double, NSString *))progress cancel:(BOOL (^)(void))cancel error:(NSError **)error;
+ (BOOL)activeEnvironmentIsDebian;
+ (nullable NSString *)activeDistributionID;
+ (NSDictionary *)probeJITPermissions;
/// Execution backend. The JIT exists only in the JIT-capable build variant and
/// runs only after iOS grants executable memory (an attached debugger such as
/// StikDebug); the interpreter is the default and always available.
+ (BOOL)jitCompiledIn;
// Task Manager: live guest processes. Each entry: pid, ppid, name, uid, state
// (R running, S sleeping in a blocking call, T stopped, Z zombie), threads,
// cpu_ms (user+system time of all its threads, host-measured), and the pages
// in its guest page table: mapped_kb, anonymous_kb, shared_kb (mapped address
// space, not host residency; shared pages count in every process mapping them).
+ (NSArray<NSDictionary<NSString *, id> *> *)taskSnapshot;
// SIGTERM, or SIGKILL with force. Returns NO if the process no longer exists.
+ (BOOL)terminateProcess:(int)pid force:(BOOL)force;
// The whole LinuxRunner app's memory as iOS accounts it (phys_footprint), 0 if unavailable.
+ (uint64_t)appFootprintBytes;
+ (NSString *)executionMode;            // interpreter | automatic | jit
+ (void)setExecutionMode:(NSString *)mode;
+ (BOOL)debuggerAttached;
+ (NSDictionary *)jitStatusReport;           // state (Interpreter Active … JIT Active), detail, counters
+ (void)retryJITWhenAuthorized;
+ (BOOL)requiresPreparedJITRegion;      // iOS 26+: StikDebug's TXM script protocol
+ (NSDictionary *)executionBackendStatus;
+ (BOOL)activateJIT:(NSString * _Nullable * _Nullable)detail;
+ (BOOL)retryJITAfterFailure:(NSString * _Nullable * _Nullable)detail;
+ (NSURL * _Nullable)stikDebugRequestURL;
+ (void)prepareExecutionBackendAtLaunch;
// The mounted root stays in use until app relaunch, even after guest init exits.
+ (nullable NSString *)environmentDeletionUnavailableReason:(NSString *)root;
+ (void)deleteEnvironment:(NSString *)root completion:(void (^)(NSError * _Nullable))completion;
+ (NSArray<NSDictionary<NSString *, NSString *> *> *)discoverApplications;
/// Read at most 256 KiB before allocation, refusing symlinks and non-regular files.
+ (NSString *)boundedDiagnosticTail:(NSURL *)url maxBytes:(NSUInteger)bytes;
+ (NSURL * _Nullable)prepareApplicationSupport:(NSError **)error;
+ (TerminalViewController *)terminalForCommand:(NSArray<NSString *> *)command directory:(NSString *)directory;
// Real guest account database and distro-managed password prompts. No passwords
// cross this bridge or enter native preferences/logs.
+ (NSArray<NSDictionary<NSString *, NSString *> *> *)linuxAccounts;
+ (NSString *)defaultLinuxUser;
// Shared iPhone folders (Files › document picker), bind-mounted at /mnt/<name>.
// Host files there without guest metadata belong to the default Linux user.
+ (NSArray<NSDictionary<NSString *, NSString *> *> *)sharedFolders;
+ (BOOL)addSharedFolder:(NSURL *)url error:(NSError **)error;
+ (void)removeSharedFolder:(NSString *)name;
+ (void)applySharedFolderOwnership;
+ (void)checkSharedFolder:(NSString *)name completion:(void (^)(NSString *summary))completion;
+ (void)checkAppSharedFolder:(void (^)(NSString *summary))completion;
+ (BOOL)setDefaultLinuxUser:(NSString *)name error:(NSError **)error;
+ (NSArray<NSString *> * _Nullable)defaultLinuxLoginCommand:(NSError **)error;
+ (TerminalViewController * _Nullable)createLinuxUser:(NSString *)name error:(NSError **)error;
+ (TerminalViewController * _Nullable)createLinuxUser:(NSString *)name administrator:(BOOL)administrator error:(NSError **)error;
+ (BOOL)canGrantAdministrator;
// Native account setup (no terminal): installs missing account tools/sudo,
// creates the user, sets the password from an app-side SHA-512 crypt hash and
// verifies it in /etc/shadow. Completion and progress run on the main thread.
+ (void)createLinuxUser:(NSString *)name password:(NSString *)password administrator:(BOOL)administrator
               progress:(void (^)(NSString *message))progress completion:(void (^)(NSError * _Nullable error))completion;
+ (BOOL)accountToolsPresent;
+ (void)setLinuxPassword:(NSString *)name password:(NSString *)password progress:(void (^)(NSString *message))progress completion:(void (^)(NSError * _Nullable error))completion;
// LinuxRunner Modes (Settings > Modes): opt-in headless services run by modes.sh.
+ (void)installMode:(NSString *)mode progress:(void (^)(NSString *stage))progress completion:(void (^)(NSError * _Nullable error))completion;
+ (nullable TerminalViewController *)modesCommand:(NSArray<NSString *> *)arguments;   // status | start/stop ssh|liftoff|pocket | agent <user>
+ (NSDictionary<NSString *, NSString *> *)modesStatus;   // parsed modes-status (key=value lines)
/// True while a support installation (account tools, mode packages) runs; a
/// second one is refused until it finishes.
+ (BOOL)installationRunning;
// Keep Screen Awake During Operations (setting LinuxRunner.keepScreenAwake,
// default on): reasons are reference-counted; while any is active the idle
// timer is off. The only writer of UIApplication.idleTimerDisabled (the older
// "disable dimming" preference is honoured here too). Main thread or any queue.
+ (void)beginAwake:(NSString *)reason;
+ (void)endAwake:(NSString *)reason;
+ (void)refreshAwake;
+ (NSArray<NSString *> *)awakeReasons;
+ (TerminalViewController * _Nullable)changeLinuxPassword:(NSString *)name error:(NSError **)error;
+ (TerminalViewController * _Nullable)removeLinuxUserKeepingHome:(NSString *)name error:(NSError **)error;
+ (TerminalViewController * _Nullable)terminalForLinuxUser:(NSString *)name error:(NSError **)error;
+ (void)logCategory:(NSString *)category event:(NSString *)event;
+ (NSArray<NSString *> *)logLines;
+ (NSURL * _Nullable)exportLogs:(NSError **)error;
+ (BOOL)importFile:(NSURL *)source root:(NSString *)root error:(NSError **)error;
+ (NSURL * _Nullable)exportFile:(NSString *)leaf root:(NSString *)root error:(NSError **)error;
+ (NSURL *)sharedExchangeURL:(NSString *)root;
+ (NSArray<NSDictionary *> * _Nullable)sharedEntries:(NSString *)relative root:(NSString *)root error:(NSError **)error;
+ (BOOL)createSharedDirectory:(NSString *)leaf relative:(NSString *)relative root:(NSString *)root error:(NSError **)error;
+ (BOOL)importSharedFile:(NSURL *)source relative:(NSString *)relative root:(NSString *)root control:(LRTransferControl *)control error:(NSError **)error;
+ (NSURL * _Nullable)exportSharedItem:(NSString *)leaf relative:(NSString *)relative root:(NSString *)root control:(LRTransferControl *)control error:(NSError **)error;
+ (void)deleteExport:(NSURL *)url;
@end

/// Posted on the main queue during a support installation. userInfo: title,
/// stage, detail (NSString), fraction (NSNumber 0…1, or -1 when not measurable),
/// elapsed (NSNumber seconds), phase ("running" | "succeeded" | "failed"),
/// error and log (NSString, failure only).
extern NSNotificationName const LRInstallProgressNotification;
NS_ASSUME_NONNULL_END

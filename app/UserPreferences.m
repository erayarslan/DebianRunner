//
//  UserPreferences.m
//  iSH
//
//  Created by Charlie Melbye on 11/12/18.
//

#import "UserPreferences.h"
#import "fs/proc/ish.h"

static NSString *const kPreferenceDisableDimmingKey = @"Disable Dimming";
NSString *const kPreferenceLaunchCommandKey = @"Init Command";
NSString *const kPreferenceBootCommandKey = @"Boot Command";
NSString *const kHostnameOverrideKey = @"hostnameOverride";

NSDictionary<NSString *, NSString *> *friendlyPreferenceMapping;
NSDictionary<NSString *, NSString *> *friendlyPreferenceReverseMapping;
NSDictionary<NSString *, NSString *> *kvoProperties;

@interface UserPreferences () {
    BOOL _hostnameIsOverridden;
}
@end

char **get_all_defaults_keys_impl(void) {
    NSArray<NSString *> *preferenceKeys = NSUserDefaults.standardUserDefaults.dictionaryRepresentation.allKeys;
    char **entries = malloc((preferenceKeys.count + 1) * sizeof(*entries));
    for (NSUInteger i = 0; i < preferenceKeys.count; ++i)
        entries[i] = strdup(preferenceKeys[i].UTF8String);
    entries[preferenceKeys.count] = NULL;
    return entries;
}

char *get_friendly_name_impl(const char *name) {
    const char *friendly_name = friendlyPreferenceReverseMapping[[NSString stringWithUTF8String:name]].UTF8String;
    if (friendly_name == NULL)
        return NULL;
    return strdup(friendly_name);
}

char *get_underlying_name_impl(const char *name) {
    return strdup(friendlyPreferenceMapping[[NSString stringWithUTF8String:name]].UTF8String);
}

bool get_user_default_impl(const char *name, char **buffer, size_t *size) {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:[NSString stringWithUTF8String:name]];
    if (!value || ![NSJSONSerialization isValidJSONObject:@[value]]) {
        return false;
    }
    NSError *error;
    NSJSONWritingOptions options = NSJSONWritingFragmentsAllowed | NSJSONWritingSortedKeys | NSJSONWritingPrettyPrinted;
    if (@available(iOS 13.0, *)) {
        options |= NSJSONWritingWithoutEscapingSlashes;
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:options error:&error];
    if (error) {
        return false;
    }
    *buffer = malloc(data.length + 1);
    memcpy(*buffer, data.bytes, data.length);
    (*buffer)[data.length] = '\n';
    *size = data.length + 1;
    return true;
}

bool set_user_default_impl(const char *name, char *buffer, size_t size) {
    NSString *key = [NSString stringWithUTF8String:name];
    NSData *data = [NSData dataWithBytesNoCopy:buffer length:size freeWhenDone:NO];
    NSError *error;
    id value = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:&error];
    if (error) {
        return false;
    }
    NSString *property = kvoProperties[key];
    if (property) {
        if ([UserPreferences.shared validateValue:&value forKey:property error:nil]) {
            [UserPreferences.shared setValue:value forKey:property];
        } else {
            return false;
        }
    } else {
        [NSUserDefaults.standardUserDefaults setValue:value forKey:key];
    }
    return true;
}

bool remove_user_default_impl(const char *name) {
    NSString *key = [NSString stringWithUTF8String:name];
    NSString *property = kvoProperties[key];
    if (property) {
        [UserPreferences.shared willChangeValueForKey:property];
    }
    [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
    if (property) {
        [UserPreferences.shared didChangeValueForKey:property];
    }
    return true;
}

#if ISH_LINUX
char **(*get_all_defaults_keys)(void);
char *(*get_friendly_name)(const char *name);
char *(*get_underlying_name)(const char *name);
bool (*get_user_default)(const char *name, char **buffer, size_t *size);
bool (*set_user_default)(const char *name, char *buffer, size_t size);
bool (*remove_user_default)(const char *name);
#endif

@implementation UserPreferences {
    NSUserDefaults *_defaults;
}

+ (instancetype)shared {
    static UserPreferences *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    self->_hostnameIsOverridden = !![NSUserDefaults.standardUserDefaults stringForKey:kHostnameOverrideKey];
    if (self) {
        _defaults = [NSUserDefaults standardUserDefaults];
        [_defaults registerDefaults:@{
            kPreferenceDisableDimmingKey: @(NO),
            kPreferenceLaunchCommandKey: @[@"/bin/login", @"-f", @"root"],
            kPreferenceBootCommandKey: @[@"/sbin/init"],
            kHostnameOverrideKey: UIDevice.currentDevice.name,
        }];
        get_all_defaults_keys = get_all_defaults_keys_impl;
        get_friendly_name = get_friendly_name_impl;
        get_underlying_name = get_underlying_name_impl;
        get_user_default = get_user_default_impl;
        set_user_default = set_user_default_impl;
        remove_user_default = remove_user_default_impl;
        friendlyPreferenceMapping = @{
            @"disable_dimming": kPreferenceDisableDimmingKey,
            @"launch_command": kPreferenceLaunchCommandKey,
            @"boot_command": kPreferenceBootCommandKey,
            @"hostname_override": kHostnameOverrideKey,
        };
        NSMutableDictionary<NSString *, NSString *> *reverseMapping = [NSMutableDictionary new];
        for (NSString *key in friendlyPreferenceMapping) {
            reverseMapping[friendlyPreferenceMapping[key]] = key;
        }
        friendlyPreferenceReverseMapping = reverseMapping;
#define property(x) NSStringFromSelector(@selector(x))
        kvoProperties = @{
            kPreferenceDisableDimmingKey: property(shouldDisableDimming),
            kPreferenceLaunchCommandKey: property(launchCommand),
            kPreferenceBootCommandKey: property(bootCommand),
        };
#undef property
    }
    return self;
}

- (BOOL)shouldDisableDimming {
    return [_defaults boolForKey:kPreferenceDisableDimmingKey];
}

- (void)setShouldDisableDimming:(BOOL)dim {
    [_defaults setBool:dim forKey:kPreferenceDisableDimmingKey];
}

- (BOOL)validateShouldDisableDimming:(id *)value error:(NSError **)error {
    return [*value isKindOfClass:NSNumber.class];
}

- (NSArray<NSString *> *)launchCommand {
    return [_defaults stringArrayForKey:kPreferenceLaunchCommandKey];
}

- (void)setLaunchCommand:(NSArray<NSString *> *)launchCommand {
    [_defaults setObject:launchCommand forKey:kPreferenceLaunchCommandKey];
}

- (BOOL)validateLaunchCommand:(id *)value error:(NSError **)error {
    if (![*value isKindOfClass:NSArray.class]) {
        return NO;
    }
    for (id element in (NSArray *)(*value)) {
        if (![element isKindOfClass:NSString.class]) {
            return NO;
        }
    }
    return YES;
}

- (BOOL)hasChangedLaunchCommand {
    NSArray *defaultLaunchCommand = [[[NSUserDefaults alloc] initWithSuiteName:NSRegistrationDomain] stringArrayForKey:kPreferenceLaunchCommandKey];
    return ![self.launchCommand isEqual:defaultLaunchCommand];
}

- (NSArray<NSString *> *)bootCommand {
    return [_defaults stringArrayForKey:kPreferenceBootCommandKey];
}

- (void)setBootCommand:(NSArray<NSString *> *)bootCommand {
    [_defaults setObject:bootCommand forKey:kPreferenceBootCommandKey];
}

- (BOOL)validateBootCommand:(id *)value error:(NSError **)error {
    if (![*value isKindOfClass:NSArray.class]) {
        return NO;
    }
    for (id element in (NSArray *)(*value)) {
        if (![element isKindOfClass:NSString.class]) {
            return NO;
        }
    }
    return YES;
}

- (NSString *)hostnameOverride {
    return [_defaults stringForKey:kHostnameOverrideKey];
}

- (void)setHostnameOverride:(NSString *)hostnameOverride {
    [_defaults setValue:hostnameOverride forKey:kHostnameOverrideKey];
}

- (BOOL)validateHostnameOverride:(id *)value error:(NSError **)error {
    return [*value isKindOfClass:NSString.class];
}

- (NSString *)_hostnameOverride {
    return _hostnameIsOverridden ? self.hostnameOverride : nil;
}

@end

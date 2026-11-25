//
//  UserPreferences.h
//  iSH
//
//  Created by Charlie Melbye on 11/12/18.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface UserPreferences : NSObject

@property BOOL shouldDisableDimming;
@property NSArray<NSString *> *launchCommand;
@property NSArray<NSString *> *bootCommand;
@property NSString *hostnameOverride;
// Same as above but returns nil if the user has never set the hostname
@property (readonly, nullable) NSString *_hostnameOverride;

+ (instancetype)shared;

- (BOOL)hasChangedLaunchCommand;

@end

extern NSString *const kPreferenceLaunchCommandKey;
extern NSString *const kPreferenceBootCommandKey;
extern NSString *const kHostnameOverrideKey;

NS_ASSUME_NONNULL_END

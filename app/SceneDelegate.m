//
//  SceneDelegate.m
//  iSH
//
//  Created by Theodore Dubois on 10/26/19.
//

#import "SceneDelegate.h"
#ifdef LINUXRUNNER
#import "LinuxRunner-Swift.h"
#import "LinuxRunner/RuntimeBridge.h"
#endif

UIViewController *currentRootViewController = NULL;

@implementation SceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    if (![scene isKindOfClass:UIWindowScene.class])
        return;
    UIWindowScene *windowScene = (UIWindowScene *)scene;
    self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
#ifdef LINUXRUNNER
    self.window.rootViewController = [LinuxRunnerShell makeController];
#else
    self.window.rootViewController = [UIViewController new];
#endif
    [self.window makeKeyAndVisible];
    currentRootViewController = self.window.rootViewController;
}

- (NSUserActivity *)stateRestorationActivityForScene:(UIScene *)scene {
    return [[NSUserActivity alloc] initWithActivityType:@"dev.linuxrunner.scene"];
}

- (void)sceneDidBecomeActive:(UIScene *)scene {
    currentRootViewController = self.window.rootViewController;
#ifdef LINUXRUNNER
    [LRRuntimeBridge logCategory:@"UI" event:@"foreground"];
#endif
}

- (void)sceneWillResignActive:(UIScene *)scene {
#ifdef LINUXRUNNER
    [LRRuntimeBridge logCategory:@"UI" event:@"inactive/background"];
#endif
    if (currentRootViewController == self.window.rootViewController) {
        currentRootViewController = NULL;
    }
}

- (void)sceneDidEnterBackground:(UIScene *)scene {
#if !ISH_LINUX && defined(LINUXRUNNER)
    [LRRuntimeBridge handleDidEnterBackground];
#endif
}

- (void)sceneWillEnterForeground:(UIScene *)scene {
#if !ISH_LINUX && defined(LINUXRUNNER)
    [LRRuntimeBridge handleWillEnterForeground];
#endif
}

@end

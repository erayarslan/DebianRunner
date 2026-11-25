#import <XCTest/XCTest.h>

@interface LinuxRunnerUITests : XCTestCase
@end

@implementation LinuxRunnerUITests

- (void)shot:(XCUIApplication *)app name:(NSString *)name {
    XCTAttachment *a = [XCTAttachment attachmentWithScreenshot:app.screenshot];
    a.name = name;
    a.lifetime = XCTAttachmentLifetimeKeepAlways;
    [self addAttachment:a];
}

- (void)testSSHServerAndDebianMinimalLifecycle {
    self.continueAfterFailure = NO;
    XCUIApplication *app = [XCUIApplication new];
    NSString *root = NSProcessInfo.processInfo.environment[@"LR_TEST_DEBIAN_ROOT"];
    XCTSkipIf(!root.length, @"Set LR_TEST_DEBIAN_ROOT to an installed Debian minimal environment root");
    app.launchArguments = @[@"-Default Root", root];
    [app launch];
    XCTAssertTrue([app.buttons[@"SSH Server"] waitForExistenceWithTimeout:30]);
    [app.buttons[@"SSH Server"] tap];
    XCTAssertTrue([app.navigationBars[@"SSH Server"] waitForExistenceWithTimeout:10]);
    [self shot:app name:@"Headless Debian minimal ARM64 SSH Server"];
}

- (void)testReleaseScreenshots {
    self.continueAfterFailure = YES;
    XCUIApplication *app = [XCUIApplication new];
    NSString *root = NSProcessInfo.processInfo.environment[@"LR_SCREENSHOT_ROOT"] ?: @"sim-debian-1";
    app.launchArguments = @[@"-Default Root", root];
    [app launch];
    XCTAssertTrue([app.tabBars.buttons[@"Home"] waitForExistenceWithTimeout:30]);
    [NSThread sleepForTimeInterval:4];
    [self shot:app name:@"linuxrunner-home"];
    [app.tabBars.buttons[@"Debian"] tap];
    [NSThread sleepForTimeInterval:2];
    [self shot:app name:@"linuxrunner-debian"];
    [app.tabBars.buttons[@"Settings"] tap];
    [NSThread sleepForTimeInterval:2];
    [self shot:app name:@"linuxrunner-settings-1"];
    [app swipeUp];
    [NSThread sleepForTimeInterval:1];
    [self shot:app name:@"linuxrunner-settings-2"];
    [app.tabBars.buttons[@"Home"] tap];
    [NSThread sleepForTimeInterval:1];
    XCUIElement *ssh = app.buttons[@"SSH Server"];
    if ([ssh waitForExistenceWithTimeout:10]) {
        [ssh tap];
        [NSThread sleepForTimeInterval:2];
        [self shot:app name:@"linuxrunner-ssh-server"];
    }
}

@end

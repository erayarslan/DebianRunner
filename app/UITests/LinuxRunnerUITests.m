#import <XCTest/XCTest.h>
#import <Vision/Vision.h>

@interface LinuxRunnerUITests : XCTestCase
@end

@implementation LinuxRunnerUITests

- (void)shot:(XCUIApplication *)app name:(NSString *)name {
    XCTAttachment *a = [XCTAttachment attachmentWithScreenshot:app.screenshot];
    a.name = name;
    a.lifetime = XCTAttachmentLifetimeKeepAlways;
    [self addAttachment:a];
}

- (BOOL)waitForRenderedText:(NSString *)expected app:(XCUIApplication *)app {
    return [self waitForRenderedText:expected app:app timeout:30];
}

- (BOOL)waitForRenderedText:(NSString *)expected app:(XCUIApplication *)app timeout:(NSTimeInterval)timeout {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    NSString *last = @"";
    NSString *needle = [[expected componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsJoinedByString:@""].lowercaseString;
    do {
        VNRecognizeTextRequest *request = [VNRecognizeTextRequest new];
        request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
        request.recognitionLanguages = @[@"en-US"];
        request.usesLanguageCorrection = NO;
        UIImage *image = app.screenshot.image;
        const CGImagePropertyOrientation orientations[] = {
            kCGImagePropertyOrientationUp, kCGImagePropertyOrientationDown,
            kCGImagePropertyOrientationLeft, kCGImagePropertyOrientationRight,
            kCGImagePropertyOrientationUpMirrored, kCGImagePropertyOrientationDownMirrored,
            kCGImagePropertyOrientationLeftMirrored, kCGImagePropertyOrientationRightMirrored
        };
        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image.CGImage orientation:orientations[image.imageOrientation] options:@{}];
        NSError *error = nil;
        if (![handler performRequests:@[request] error:&error]) { NSLog(@"Terminal OCR: %@", error); return NO; }
        NSMutableString *text = [NSMutableString new];
        for (VNRecognizedTextObservation *line in request.results)
            [text appendFormat:@"%@\n", [line topCandidates:1].firstObject.string ?: @""];
        last = text;
        NSString *normalized = [[text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsJoinedByString:@""].lowercaseString;
        if ([needle isEqualToString:@"exitstatus:0"])
            normalized = [normalized stringByReplacingOccurrencesOfString:@"exitstatus:o" withString:@"exitstatus:0"];
        if ([normalized containsString:needle]) return YES;
        [NSThread sleepForTimeInterval:1];
    } while ([deadline timeIntervalSinceNow] > 0);
    NSLog(@"Last rendered terminal text: %@", last);
    return NO;
}

- (BOOL)tapFirst:(NSArray<XCUIElement *> *)candidates timeout:(NSTimeInterval)timeout {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([end timeIntervalSinceNow] > 0) {
        for (XCUIElement *e in candidates) if (e.exists && e.isHittable) { [e tap]; return YES; }
        [NSThread sleepForTimeInterval:0.5];
    }
    return NO;
}

- (void)openFileSharing:(XCUIApplication *)app {
    XCTAssertTrue([app.tabBars.buttons[@"Settings"] waitForExistenceWithTimeout:60]);
    [app.tabBars.buttons[@"Settings"] tap];
    XCUIElement *row = app.buttons[@"File Sharing"];
    for (int i = 0; i < 8 && !(row.exists && row.isHittable); i++) [app swipeUp];
    XCTAssertTrue(row.exists);
    [row tap];
    XCTAssertTrue([app.navigationBars[@"File Sharing"] waitForExistenceWithTimeout:10]);
}

- (void)testTerminalAndDebianMinimalLifecycle {
    self.continueAfterFailure = NO;
    XCUIApplication *app = [XCUIApplication new];
    NSString *root = NSProcessInfo.processInfo.environment[@"LR_TEST_DEBIAN_ROOT"];
    XCTSkipIf(!root.length, @"Set LR_TEST_DEBIAN_ROOT to an installed Debian minimal environment root");
    app.launchArguments = @[@"-Default Root", root];
    [app launch];
    XCTAssertTrue([app.buttons[@"Open Terminal"] waitForExistenceWithTimeout:30]);
    [app.buttons[@"Open Terminal"] tap];
    XCTAssertTrue([app.buttons[@"Done"] waitForExistenceWithTimeout:10]);
    NSString *file = [NSString stringWithFormat:@"terminal-%@.txt", NSUUID.UUID.UUIDString];
    [app typeText:[NSString stringWithFormat:@"uname -m; grep -E '^(ID|VERSION_CODENAME)=' /etc/os-release; echo verified > /home/mobile/Downloads/%@\n", file]];
    XCTAssertTrue([self waitForRenderedText:@"aarch64" app:app timeout:30]);
    XCTAssertTrue([self waitForRenderedText:@"id=debian" app:app timeout:30]);
    [self shot:app name:@"Interactive Debian minimal ARM64 terminal"];
    [app.buttons[@"Done"] tap];
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
    [app.tabBars.buttons[@"Environments"] tap];
    [NSThread sleepForTimeInterval:2];
    [self shot:app name:@"linuxrunner-environments"];
    [app.tabBars.buttons[@"Settings"] tap];
    [NSThread sleepForTimeInterval:2];
    [self shot:app name:@"linuxrunner-settings-1"];
    [app swipeUp];
    [NSThread sleepForTimeInterval:1];
    [self shot:app name:@"linuxrunner-settings-2"];
    [app.tabBars.buttons[@"Home"] tap];
    [NSThread sleepForTimeInterval:1];
    XCUIElement *terminal = app.buttons[@"Open Terminal"];
    if ([terminal waitForExistenceWithTimeout:10]) {
        [terminal tap];
        [NSThread sleepForTimeInterval:6];
        [app typeText:@"uname -sm; . /etc/os-release; echo $PRETTY_NAME; whoami\n"];
        [NSThread sleepForTimeInterval:5];
        [self shot:app name:@"linuxrunner-terminal"];
        XCUIElement *done = app.buttons[@"Done"];
        if ([done waitForExistenceWithTimeout:3]) [done tap];
    }
}

@end

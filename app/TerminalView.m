//
//  TerminalView.m
//  iSH
//
//  Created by Theodore Dubois on 11/3/17.
//

#import <QuartzCore/QuartzCore.h>
#import "ScrollbarView.h"
#import "TerminalView.h"
#import "UserPreferences.h"
#import "UIApplication+OpenURL.h"
#import "NSObject+SaneKVO.h"

#include <math.h>

struct rowcol {
    int row;
    int col;
};

@interface WeakScriptMessageHandler : NSObject <WKScriptMessageHandler>
@property (weak) id <WKScriptMessageHandler> handler;
@end
@implementation WeakScriptMessageHandler
- (instancetype)initWithHandler:(id <WKScriptMessageHandler>)handler {
    if (self = [super init]) {
        self.handler = handler;
    }
    return self;
}
- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    [self.handler userContentController:userContentController didReceiveScriptMessage:message];
}
@end

@interface LRTerminalSelectionHandle : UIView
@property (nonatomic) BOOL isStart;
@property (nonatomic) CGFloat lineHeight;
- (void)positionAtX:(CGFloat)x topY:(CGFloat)topY bottomY:(CGFloat)bottomY;
@end

@implementation LRTerminalSelectionHandle

- (instancetype)initWithIsStart:(BOOL)isStart {
    if (self = [super initWithFrame:CGRectMake(0, 0, 44, 44)]) {
        _isStart = isStart;
        _lineHeight = 16;
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        self.hidden = YES;
        self.accessibilityLabel = isStart ? @"Selection start handle" : @"Selection end handle";
    }
    return self;
}

- (void)positionAtX:(CGFloat)x topY:(CGFloat)topY bottomY:(CGFloat)bottomY {
    CGFloat barHeight = MAX(12.0, bottomY - topY);
    CGFloat midY = (topY + bottomY) * 0.5;
    CGFloat width = 44.0;
    CGFloat height = MAX(44.0, barHeight + 36.0);
    BOOL needsRedraw = fabs(self.lineHeight - barHeight) > 0.5;
    self.lineHeight = barHeight;
    self.frame = CGRectMake(round(x - width * 0.5), round(midY - height * 0.5), width, height);
    if (needsRedraw)
        [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx)
        return;
    UIColor *accent = UIColor.systemBlueColor;
    [accent setFill];
    CGFloat midX = CGRectGetMidX(self.bounds);
    CGFloat barWidth = 2.0;
    CGFloat barHeight = MAX(12.0, self.lineHeight);
    CGFloat barTop = (self.bounds.size.height - barHeight) * 0.5;
    CGFloat knobDiameter = 11.0;
    CGFloat knobRadius = knobDiameter * 0.5;

    CGRect barRect = CGRectMake(midX - barWidth * 0.5, barTop, barWidth, barHeight);
    CGContextFillRect(ctx, barRect);

    CGFloat knobCenterY = self.isStart ? (barTop - knobRadius + 1.0) : (barTop + barHeight + knobRadius - 1.0);
    CGRect knobRect = CGRectMake(midX - knobRadius, knobCenterY - knobRadius, knobDiameter, knobDiameter);
    CGContextFillEllipseInRect(ctx, knobRect);
}

@end

@interface TerminalView () <UIEditMenuInteractionDelegate, UIGestureRecognizerDelegate>

@property (nonatomic) NSMutableArray<UIKeyCommand *> *keyCommands;
@property ScrollbarView *scrollbarView;
@property (nonatomic) BOOL terminalFocused;
@property (nonatomic) BOOL updatingTerminalScroll;
@property UIEditMenuInteraction *terminalEditMenu API_AVAILABLE(ios(16.0));
@property (nonatomic) UITapGestureRecognizer *singleTapGesture;
@property (nonatomic) UITapGestureRecognizer *doubleTapGesture;
@property (nonatomic) UILongPressGestureRecognizer *selectionGesture;
@property (nonatomic) UIPanGestureRecognizer *altScrollGesture;
@property (nonatomic) LRTerminalSelectionHandle *startSelectionHandle;
@property (nonatomic) LRTerminalSelectionHandle *endSelectionHandle;
@property (nonatomic, copy, nullable) NSString *activeDragHandle;
@property (nonatomic) CGPoint handleDragOffset;
@property (nonatomic) BOOL selectionActive;
@property (nonatomic) BOOL draggingSelection;
@property (nonatomic) BOOL draggingHandle;
@property (nonatomic) CGPoint lastSelectionMenuPoint;
@property (nonatomic) CGPoint lastDragPointInWebView;
@property (nonatomic, nullable) NSTimer *selectionAutoScrollTimer;
@property (nonatomic) NSInteger selectionAutoScrollDirection;
@property (nonatomic, copy, nullable) NSString *selectedLinkURL;

// Smooth native scroll + alternate-screen momentum state
@property (nonatomic) CGFloat terminalCellHeight;
@property (nonatomic) CGFloat terminalCellWidth;
@property (nonatomic) NSInteger terminalCols;
@property (nonatomic) NSInteger terminalRows;
@property (nonatomic) NSInteger terminalBaseY;
@property (nonatomic) BOOL terminalAltScreen;
@property (nonatomic) BOOL terminalMouseTracking;
@property (nonatomic) BOOL pinnedToBottom;
@property (nonatomic) NSInteger lastSentScrollLine;
@property (nonatomic) NSInteger pendingScrollLine;
@property (nonatomic) BOOL hasPendingScrollLine;
@property (nonatomic) BOOL scrollEvalInFlight;
@property (nonatomic) CGFloat altScrollAccumulator;
@property (nonatomic) CGFloat altScrollVelocity;
@property (nonatomic) CFTimeInterval altScrollLastTimestamp;
@property (nonatomic) CGPoint altScrollLastPointInWeb;
@property (nonatomic, nullable) CADisplayLink *altScrollDisplayLink;

@property (nullable) NSString *markedText;
@property (nullable) NSString *selectedText;
@property UITextRange *markedRange;
@property UITextRange *selectedRange;

@property struct rowcol floatingCursor;
@property CGSize floatingCursorSensitivity;
@property CGSize actualFloatingCursorSensitivity;

@end

static NSString *LRTerminalBackground(NSString *hex) {
    // LinuxRunner's terminal: true black for dark themes (default on).
    id setting = [NSUserDefaults.standardUserDefaults objectForKey:@"LinuxRunnerTerminal.trueBlack"];
    if (setting && ![setting boolValue]) return hex;
    UIColor *c = [[UIColor alloc] ish_initWithHexString:hex]; CGFloat w = 1;
    if ([c getWhite:&w alpha:NULL] && w < 0.3) return @"#000000";
    CGFloat r = 1, g = 1, b = 1; if ([c getRed:&r green:&g blue:&b alpha:NULL] && (r + g + b) / 3 < 0.3) return @"#000000";
    return hex;
}
@implementation TerminalView
@synthesize inputDelegate;
@synthesize tokenizer;
@synthesize canBecomeFirstResponder;

- (void)awakeFromNib {
    [super awakeFromNib];
    self.inputAssistantItem.leadingBarButtonGroups = @[];
    self.inputAssistantItem.trailingBarButtonGroups = @[];

    ScrollbarView *scrollbarView = self.scrollbarView = [[ScrollbarView alloc] initWithFrame:self.bounds];
    scrollbarView.delegate = self;
    scrollbarView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scrollbarView.bounces = YES;
    scrollbarView.alwaysBounceVertical = YES;
    scrollbarView.showsVerticalScrollIndicator = YES;
    scrollbarView.showsHorizontalScrollIndicator = NO;
    scrollbarView.decelerationRate = UIScrollViewDecelerationRateNormal;
    scrollbarView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    self.pinnedToBottom = YES;
    self.lastSentScrollLine = -1;
    self.clipsToBounds = YES;
    [self addSubview:scrollbarView];
#if USE_XTERM_RENDERER
    UITapGestureRecognizer *singleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTerminalTap:)];
    singleTap.numberOfTapsRequired = 1;
    singleTap.cancelsTouchesInView = NO;
    singleTap.delegate = self;
    [self addGestureRecognizer:singleTap];
    self.singleTapGesture = singleTap;

    UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTerminalDoubleTap:)];
    doubleTap.numberOfTapsRequired = 2;
    doubleTap.cancelsTouchesInView = NO;
    doubleTap.delegate = self;
    [self addGestureRecognizer:doubleTap];
    self.doubleTapGesture = doubleTap;
    [singleTap requireGestureRecognizerToFail:doubleTap];

    UILongPressGestureRecognizer *selectionGesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(selectTerminalText:)];
    selectionGesture.minimumPressDuration = 0.35;
    selectionGesture.allowableMovement = 18.0;
    selectionGesture.cancelsTouchesInView = YES;
    selectionGesture.delegate = self;
    [self addGestureRecognizer:selectionGesture];
    self.selectionGesture = selectionGesture;

    UIPanGestureRecognizer *altScroll = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleAltScreenScroll:)];
    altScroll.maximumNumberOfTouches = 1;
    altScroll.cancelsTouchesInView = NO;
    altScroll.delegate = self;
    [self addGestureRecognizer:altScroll];
    self.altScrollGesture = altScroll;

    self.startSelectionHandle = [[LRTerminalSelectionHandle alloc] initWithIsStart:YES];
    self.endSelectionHandle = [[LRTerminalSelectionHandle alloc] initWithIsStart:NO];
    for (LRTerminalSelectionHandle *handle in @[self.startSelectionHandle, self.endSelectionHandle]) {
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panSelectionHandle:)];
        pan.maximumNumberOfTouches = 1;
        [handle addGestureRecognizer:pan];
        [self addSubview:handle];
    }

    if (@available(iOS 16.0, *)) {
        self.terminalEditMenu = [[UIEditMenuInteraction alloc] initWithDelegate:self];
        [self addInteraction:self.terminalEditMenu];
    }
#endif

    UserPreferences *prefs = UserPreferences.shared;
    [prefs observe:@[@"capsLockMapping", @"optionMapping", @"backtickMapEscape", @"overrideControlSpace"]
           options:0 owner:self usingBlock:^(typeof(self) self) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_keyCommands = nil;
        });
    }];
    [prefs observe:@[@"colorScheme", @"fontFamily", @"fontSize", @"theme", @"cursorStyle", @"blinkCursor"]
           options:0 owner:self usingBlock:^(typeof(self) self) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _updateStyle];
        });
    }];

    self.markedRange = [UITextRange new];
    self.selectedRange = [UITextRange new];

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self
               selector:@selector(applicationDidBecomeActive:)
                   name:UIApplicationDidBecomeActiveNotification
                 object:UIApplication.sharedApplication];
    [center addObserver:self
               selector:@selector(applicationWillResignActive:)
                   name:UIApplicationWillResignActiveNotification
                 object:UIApplication.sharedApplication];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (self.terminalCellHeight > 1.0 && !self.terminalAltScreen) {
        CGFloat viewH = self.scrollbarView.bounds.size.height;
        CGFloat targetHeight = self.terminalBaseY * self.terminalCellHeight + viewH;
        BOOL userScrolling = self.scrollbarView.isTracking || self.scrollbarView.isDragging || self.scrollbarView.isDecelerating;
        if (fabs(self.scrollbarView.contentSize.height - targetHeight) > 0.5) {
            self.updatingTerminalScroll = YES;
            self.scrollbarView.contentSize = CGSizeMake(0, targetHeight);
            self.updatingTerminalScroll = NO;
        }
        if (self.pinnedToBottom && !userScrolling) {
            CGFloat maxOffset = MAX(0, targetHeight - viewH);
            if (fabs(self.scrollbarView.contentOffset.y - maxOffset) > 0.5) {
                self.updatingTerminalScroll = YES;
                [self.scrollbarView setContentOffset:CGPointMake(0, maxOffset) animated:NO];
                self.updatingTerminalScroll = NO;
            }
            self.lastSentScrollLine = self.terminalBaseY;
        }
    }
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) {
        [self stopSelectionAutoScroll];
        [self stopAltScrollMomentum];
    }
}

- (void)dealloc {
    [_selectionAutoScrollTimer invalidate];
    [_altScrollDisplayLink invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
    self.terminal = nil;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if (object == _terminal) {
        if (_terminal.loaded) {
            [self installTerminalView];
            [self _updateStyle];
        }
    }
}

static NSString *const HANDLERS[] = {@"syncFocus", @"focus", @"scrollState", @"newScrollHeight", @"newScrollTop", @"openLink", @"selectionChanged", @"selectionGeometry"};

- (void)setTerminal:(Terminal *)terminal {
    if (_terminal) {
        [_terminal removeObserver:self forKeyPath:@"loaded"];
        [self uninstallTerminalView];
    }

    _terminal = terminal;
    self.selectedText = nil;
    if (_terminal == nil)
        return;
    [self _updateStyle];
    [_terminal addObserver:self forKeyPath:@"loaded" options:NSKeyValueObservingOptionInitial context:nil];
    [self installTerminalView];
}

- (void)installTerminalView {
    UIView *superview = self.terminal.webView.superview;
    if (superview != nil) {
        NSAssert(superview == self.scrollbarView, @"installing terminal that is already installed elsewhere");
        return;
    }

    WKWebView *webView = _terminal.webView;
    if (_terminal.loaded)
        _terminal.enableVoiceOverAnnounce = YES;
    webView.scrollView.scrollEnabled = NO;
    webView.scrollView.delaysContentTouches = NO;
    webView.scrollView.canCancelContentTouches = NO;
    webView.scrollView.panGestureRecognizer.enabled = NO;
#if USE_XTERM_RENDERER
    // Let TerminalView and ScrollbarView own all touch, scroll, and selection
    // gestures natively so WKContentView never hijacks long presses.
    webView.userInteractionEnabled = NO;
#endif
    id <WKScriptMessageHandler> handler = [[WeakScriptMessageHandler alloc] initWithHandler:self];
    for (int i = 0; i < sizeof(HANDLERS)/sizeof(HANDLERS[0]); i++) {
        [webView.configuration.userContentController addScriptMessageHandler:handler name:HANDLERS[i]];
    }
    webView.frame = self.bounds;
    self.opaque = webView.opaque = NO;
    webView.backgroundColor = UIColor.clearColor;
    webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    self.scrollbarView.contentView = webView;
    [self.scrollbarView addSubview:webView];
#if USE_XTERM_RENDERER
    if (self.startSelectionHandle) [self bringSubviewToFront:self.startSelectionHandle];
    if (self.endSelectionHandle) [self bringSubviewToFront:self.endSelectionHandle];
#endif
}

- (void)uninstallTerminalView {
    [self stopSelectionAutoScroll];
    [self stopAltScrollMomentum];
    self.selectionActive = NO;
    self.draggingSelection = NO;
    self.draggingHandle = NO;
    self.selectedText = nil;
    self.selectedLinkURL = nil;
    self.pinnedToBottom = YES;
    self.terminalBaseY = 0;
    self.terminalAltScreen = NO;
    self.lastSentScrollLine = -1;
    self.hasPendingScrollLine = NO;
    self.scrollEvalInFlight = NO;
    self.updatingTerminalScroll = YES;
    self.scrollbarView.contentSize = CGSizeZero;
    self.scrollbarView.contentOffset = CGPointZero;
    self.updatingTerminalScroll = NO;
    self.startSelectionHandle.hidden = YES;
    self.endSelectionHandle.hidden = YES;
    [self dismissSelectionMenu];
    // remove old terminal
    UIView *superview = _terminal.webView.superview;
    if (superview != self.scrollbarView) {
        NSAssert(superview == nil, @"uninstalling terminal that is installed elsewhere");
        return;
    }

    [_terminal.webView removeFromSuperview];
    self.scrollbarView.contentView = nil;
    for (int i = 0; i < sizeof(HANDLERS)/sizeof(HANDLERS[0]); i++) {
        [_terminal.webView.configuration.userContentController removeScriptMessageHandlerForName:HANDLERS[i]];
    }
    _terminal.enableVoiceOverAnnounce = NO;
}

#pragma mark Styling

- (void)_updateStyle {
    NSAssert(NSThread.isMainThread, @"This method needs to be called on the main thread");
    UserPreferences *prefs = [UserPreferences shared];
    Palette *palette = prefs.palette;
    if (self.overrideAppearance != OverrideAppearanceNone) {
        palette = self.overrideAppearance == OverrideAppearanceLight ? prefs.theme.lightPalette : prefs.theme.darkPalette;
    }
    NSString *background = LRTerminalBackground(palette.backgroundColor);
    UIColor *backgroundColor = [[UIColor alloc] ish_initWithHexString:background];
    self.backgroundColor = backgroundColor;
    self.scrollbarView.backgroundColor = backgroundColor;
    if (_overrideFontSize == prefs.fontSize.doubleValue)
        _overrideFontSize = 0;
    NSMutableDictionary<NSString *, id> *themeInfo = [@{
        @"fontFamily": prefs.fontFamily,
        @"fontSize": @(self.effectiveFontSize),
        @"foregroundColor": palette.foregroundColor,
        @"backgroundColor": background,
        @"cursorColor": palette.cursorColor ?: palette.foregroundColor,
        @"blinkCursor": @(prefs.blinkCursor),
        @"cursorShape": prefs.htermCursorShape,
        @"sharpness": [NSUserDefaults.standardUserDefaults stringForKey:@"LinuxRunnerTerminal.sharpness"] ?: @"sharp",
    } mutableCopy];
    if (palette.colorPaletteOverrides) {
        themeInfo[@"colorPaletteOverrides"] = palette.colorPaletteOverrides;
    }
    NSString *json = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:themeInfo options:0 error:nil] encoding:NSUTF8StringEncoding];
    self.terminal.bootstrapStyleJSON = json;
    if (!self.terminal.loaded)
        return;
    [self.terminal.webView evaluateJavaScript:[NSString stringWithFormat:@"exports.updateStyle(%@)", json] completionHandler:^(id result, NSError *error){
        [self updateFloatingCursorSensitivity];
    }];
}

- (void)setOverrideFontSize:(CGFloat)overrideFontSize {
    _overrideFontSize = overrideFontSize;
    [self _updateStyle];
}

- (void)setOverrideAppearance:(enum OverrideAppearance)overrideAppearance {
    _overrideAppearance = overrideAppearance;
    [self _updateStyle];
}

- (CGFloat)effectiveFontSize {
    if (self.overrideFontSize != 0)
        return self.overrideFontSize;
    return UserPreferences.shared.fontSize.doubleValue;
}

#pragma mark Focus and scrolling

- (BOOL)terminalShouldRenderFocused {
    if (self.window == nil)
        return NO;
    if (@available(iOS 13.0, *))
        return self.window.windowScene.activationState == UISceneActivationStateForegroundActive;
    return UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
}

- (void)syncTerminalRenderFocus {
    self.terminalFocused = self.terminalShouldRenderFocused;
}

- (void)setTerminalFocused:(BOOL)terminalFocused {
    _terminalFocused = terminalFocused;
    NSString *script = terminalFocused ? @"exports.setFocused(true)" : @"exports.setFocused(false)";
    [self.terminal.webView evaluateJavaScript:script completionHandler:nil];
}

- (BOOL)becomeFirstResponder {
    [self syncTerminalRenderFocus];
    [self reloadInputViews];
    return [super becomeFirstResponder];
}
- (BOOL)resignFirstResponder {
    [self syncTerminalRenderFocus];
    return [super resignFirstResponder];
}
- (void)windowDidBecomeKey:(NSNotification *)notif {
    [self syncTerminalRenderFocus];
}
- (void)windowDidResignKey:(NSNotification *)notif {
    [self syncTerminalRenderFocus];
}
- (void)applicationDidBecomeActive:(NSNotification *)notif {
    self.markedText = nil;
    [self syncTerminalRenderFocus];
}
- (void)applicationWillResignActive:(NSNotification *)notif {
    self.markedText = nil;
    self.terminalFocused = NO;
}

- (IBAction)loseFocus:(id)sender {
    [self resignFirstResponder];
}

- (void)willMoveToWindow:(UIWindow *)newWindow {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    if (self.window != nil) {
        [center removeObserver:self
                          name:UIWindowDidBecomeKeyNotification
                        object:self.window];
        [center removeObserver:self
                          name:UIWindowDidResignKeyNotification
                        object:self.window];
    }
    if (newWindow != nil) {
        [center addObserver:self
                   selector:@selector(windowDidBecomeKey:)
                       name:UIWindowDidBecomeKeyNotification
                     object:newWindow];
        [center addObserver:self
                   selector:@selector(windowDidResignKey:)
                       name:UIWindowDidResignKeyNotification
                     object:newWindow];
    }
}

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    if ([message.name isEqualToString:@"syncFocus"]) {
        [self syncTerminalRenderFocus];
    } else if ([message.name isEqualToString:@"focus"]) {
        if (!self.isFirstResponder) {
            [self becomeFirstResponder];
        }
    } else if ([message.name isEqualToString:@"scrollState"]) {
        if (![message.body isKindOfClass:NSDictionary.class])
            return;
        NSDictionary *state = message.body;
        CGFloat cellHeight = [state[@"cellHeight"] doubleValue];
        CGFloat cellWidth = [state[@"cellWidth"] doubleValue];
        CGFloat newHeight = [state[@"scrollHeight"] doubleValue];
        CGFloat newOffset = [state[@"scrollTop"] doubleValue];
        if (isfinite(cellHeight) && cellHeight > 1.0) self.terminalCellHeight = cellHeight;
        if (isfinite(cellWidth) && cellWidth > 1.0) self.terminalCellWidth = cellWidth;
        self.terminalCols = [state[@"cols"] integerValue];
        self.terminalRows = [state[@"rows"] integerValue];
        NSInteger baseY = MAX(0, [state[@"baseY"] integerValue]);
        NSInteger viewportY = MAX(0, [state[@"viewportY"] integerValue]);
        self.terminalBaseY = baseY;
        BOOL altScreen = [state[@"altScreen"] boolValue];
        self.terminalAltScreen = altScreen;
        self.terminalMouseTracking = [state[@"mouseTracking"] boolValue];
        if (!altScreen)
            [self stopAltScrollMomentum];
        self.scrollbarView.scrollEnabled = !altScreen && !self.draggingSelection;

        BOOL userScrolling = self.scrollbarView.isTracking || self.scrollbarView.isDragging || self.scrollbarView.isDecelerating;
        CGFloat viewH = self.scrollbarView.bounds.size.height;
        // Derive contentSize from baseY * cellHeight + scrollbarView height so
        // maxOffset == baseY * cellHeight exactly (ignoring CSS padding differences).
        CGFloat targetHeight = self.terminalCellHeight > 1.0 ? (baseY * self.terminalCellHeight + viewH) : newHeight;
        if (isfinite(targetHeight) && targetHeight >= 0 && fabs(self.scrollbarView.contentSize.height - targetHeight) > 0.5) {
            self.updatingTerminalScroll = YES;
            self.scrollbarView.contentSize = CGSizeMake(0, targetHeight);
            self.updatingTerminalScroll = NO;
        }
        if (!userScrolling && !altScreen) {
            CGFloat maxOffset = MAX(0, self.scrollbarView.contentSize.height - viewH);
            BOOL jsAtBottom = (viewportY >= baseY);
            CGFloat desired = jsAtBottom || self.pinnedToBottom
                ? maxOffset
                : (self.terminalCellHeight > 1.0 ? MIN(viewportY * self.terminalCellHeight, maxOffset) : MIN(MAX(0, newOffset), maxOffset));
            if (jsAtBottom) self.pinnedToBottom = YES;
            if (fabs(self.scrollbarView.contentOffset.y - desired) > 0.5) {
                self.updatingTerminalScroll = YES;
                [self.scrollbarView setContentOffset:CGPointMake(0, desired) animated:NO];
                self.updatingTerminalScroll = NO;
            }
            if (self.terminalCellHeight > 1.0)
                self.lastSentScrollLine = self.pinnedToBottom ? baseY : llround(desired / self.terminalCellHeight);
        }
    } else if ([message.name isEqualToString:@"newScrollHeight"]) {
        if (self.terminalCellHeight > 1.0 || ![message.body isKindOfClass:NSNumber.class])
            return;
        CGFloat newHeight = [message.body doubleValue];
        if (!isfinite(newHeight) || newHeight < 0)
            return;
        if (fabs(self.scrollbarView.contentSize.height - newHeight) > 0.5) {
            self.updatingTerminalScroll = YES;
            self.scrollbarView.contentSize = CGSizeMake(0, newHeight);
            self.updatingTerminalScroll = NO;
        }
    } else if ([message.name isEqualToString:@"newScrollTop"]) {
        if (self.terminalCellHeight > 1.0 || ![message.body isKindOfClass:NSNumber.class])
            return;
        // Never fight UIKit while the user is dragging or flicking with momentum.
        if (self.scrollbarView.isTracking || self.scrollbarView.isDragging || self.scrollbarView.isDecelerating)
            return;
        CGFloat newOffset = [message.body doubleValue];
        if (!isfinite(newOffset) || newOffset < 0)
            return;
        newOffset = MIN(newOffset, MAX(0, self.scrollbarView.contentSize.height - self.scrollbarView.bounds.size.height));
        if (fabs(self.scrollbarView.contentOffset.y - newOffset) <= 0.5)
            return;
        self.updatingTerminalScroll = YES;
        [self.scrollbarView setContentOffset:CGPointMake(0, newOffset) animated:NO];
        self.updatingTerminalScroll = NO;
    } else if ([message.name isEqualToString:@"openLink"]) {
        if ([message.body isKindOfClass:NSString.class])
            [UIApplication openURL:message.body];
    } else if ([message.name isEqualToString:@"selectionChanged"]) {
        if ([message.body isKindOfClass:NSString.class]) {
            NSString *text = message.body;
            self.selectedText = text.length > 0 ? text : nil;
        }
    } else if ([message.name isEqualToString:@"selectionGeometry"]) {
        if ([message.body isKindOfClass:NSDictionary.class]) {
            [self applySelectionGeometry:message.body];
        }
    }
}

- (void)sendCoalescedScrollToLine:(NSInteger)line {
    if (line == self.lastSentScrollLine && !self.scrollEvalInFlight)
        return;
    if (self.scrollEvalInFlight) {
        self.pendingScrollLine = line;
        self.hasPendingScrollLine = YES;
        return;
    }
    self.scrollEvalInFlight = YES;
    self.lastSentScrollLine = line;
    self.hasPendingScrollLine = NO;
    __weak TerminalView *weakSelf = self;
    NSString *script = [NSString stringWithFormat:@"exports.scrollToLine(%ld)", (long)line];
    [self.terminal.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        TerminalView *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.scrollEvalInFlight = NO;
        if (strongSelf.hasPendingScrollLine) {
            NSInteger nextLine = strongSelf.pendingScrollLine;
            strongSelf.hasPendingScrollLine = NO;
            if (nextLine != strongSelf.lastSentScrollLine) {
                [strongSelf sendCoalescedScrollToLine:nextLine];
            }
        }
    }];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    if (self.selectionActive) {
        [self dismissSelectionMenu];
    }
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    if (!decelerate && self.selectionActive && !self.draggingSelection) {
        [self refreshAndPresentSelectionMenu];
    }
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    if (self.selectionActive && !self.draggingSelection) {
        [self refreshAndPresentSelectionMenu];
    }
}

- (void)scrollToBottomForUserInput {
    if (self.terminalAltScreen)
        return;
    self.pinnedToBottom = YES;
    self.hasPendingScrollLine = NO;
    CGFloat maxOffset = MAX(0, self.scrollbarView.contentSize.height - self.scrollbarView.bounds.size.height);
    self.updatingTerminalScroll = YES;
    [self.scrollbarView setContentOffset:CGPointMake(0, maxOffset) animated:NO];
    self.updatingTerminalScroll = NO;
    self.lastSentScrollLine = self.terminalBaseY;
    [self.terminal.webView evaluateJavaScript:@"exports.scrollToBottom?.()" completionHandler:nil];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    // Terminal output and layout updates move the indicator, not the user's scroll position.
    if (self.updatingTerminalScroll || self.terminalAltScreen)
        return;
    BOOL userDriven = scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating;
    if (!userDriven)
        return;
    if (self.terminalCellHeight > 1.0 && self.terminalBaseY >= 0) {
        NSInteger targetLine = llround(scrollView.contentOffset.y / self.terminalCellHeight);
        targetLine = MAX(0, MIN(self.terminalBaseY, targetLine));
        self.pinnedToBottom = (targetLine >= self.terminalBaseY);
        [self sendCoalescedScrollToLine:targetLine];
    } else {
        [self.terminal.webView evaluateJavaScript:[NSString stringWithFormat:@"exports.newScrollTop(%f)", scrollView.contentOffset.y] completionHandler:nil];
    }
}

- (void)emitAltScrollStep:(NSInteger)direction atPoint:(CGPoint)pointInWeb {
    // direction < 0 => scroll up (earlier content); direction > 0 => scroll down (later content)
    if (self.terminalMouseTracking && self.terminalCellWidth > 0 && self.terminalCellHeight > 0) {
        NSInteger col = MAX(1, MIN(MAX(1, self.terminalCols), (NSInteger)floor(pointInWeb.x / self.terminalCellWidth) + 1));
        NSInteger row = MAX(1, MIN(MAX(1, self.terminalRows), (NSInteger)floor(pointInWeb.y / self.terminalCellHeight) + 1));
        NSInteger button = direction < 0 ? 64 : 65; // SGR wheel up / wheel down
        NSString *seq = [NSString stringWithFormat:@"\x1b[<%ld;%ld;%ldM", (long)button, (long)col, (long)row];
        [self.terminal sendInput:[seq dataUsingEncoding:NSUTF8StringEncoding]];
    } else {
        NSString *seq = [self.terminal arrow:(direction < 0 ? 'A' : 'B')];
        if (seq.length > 0)
            [self.terminal sendInput:[seq dataUsingEncoding:NSUTF8StringEncoding]];
    }
}

- (void)stopAltScrollMomentum {
    [self.altScrollDisplayLink invalidate];
    self.altScrollDisplayLink = nil;
    self.altScrollVelocity = 0;
    self.altScrollAccumulator = 0;
}

- (void)stepAltScrollMomentum:(CADisplayLink *)link {
    if (!self.terminalAltScreen || self.selectionActive) {
        [self stopAltScrollMomentum];
        return;
    }
    CFTimeInterval now = link.timestamp;
    CFTimeInterval dt = self.altScrollLastTimestamp > 0 ? MIN(0.05, MAX(0.001, now - self.altScrollLastTimestamp)) : (1.0 / 60.0);
    self.altScrollLastTimestamp = now;

    CGFloat stepHeight = MAX(14.0, self.terminalCellHeight > 1.0 ? self.terminalCellHeight : 16.0);
    self.altScrollAccumulator += self.altScrollVelocity * dt;
    NSInteger emitted = 0;
    while (fabs(self.altScrollAccumulator) >= stepHeight && emitted < 6) {
        NSInteger dir = self.altScrollAccumulator > 0 ? -1 : 1;
        self.altScrollAccumulator -= (self.altScrollAccumulator > 0 ? stepHeight : -stepHeight);
        [self emitAltScrollStep:dir atPoint:self.altScrollLastPointInWeb];
        emitted++;
    }
    self.altScrollVelocity *= pow(0.91, dt * 60.0);
    if (fabs(self.altScrollVelocity) < 45.0) {
        [self stopAltScrollMomentum];
    }
}

- (void)handleAltScreenScroll:(UIPanGestureRecognizer *)gesture {
    if (!self.terminalAltScreen || self.selectionActive || self.draggingSelection)
        return;
    CGPoint ptInWeb = [gesture locationInView:self.terminal.webView];
    self.altScrollLastPointInWeb = ptInWeb;
    if (gesture.state == UIGestureRecognizerStateBegan) {
        [self stopAltScrollMomentum];
    } else if (gesture.state == UIGestureRecognizerStateChanged) {
        CGPoint delta = [gesture translationInView:self];
        [gesture setTranslation:CGPointZero inView:self];
        CGFloat stepHeight = MAX(14.0, self.terminalCellHeight > 1.0 ? self.terminalCellHeight : 16.0);
        self.altScrollAccumulator += delta.y;
        NSInteger emitted = 0;
        while (fabs(self.altScrollAccumulator) >= stepHeight && emitted < 8) {
            // Dragging finger down (delta.y > 0) reveals earlier lines above (scroll up -> -1).
            NSInteger dir = self.altScrollAccumulator > 0 ? -1 : 1;
            self.altScrollAccumulator -= (self.altScrollAccumulator > 0 ? stepHeight : -stepHeight);
            [self emitAltScrollStep:dir atPoint:ptInWeb];
            emitted++;
        }
    } else if (gesture.state == UIGestureRecognizerStateEnded) {
        CGFloat vy = [gesture velocityInView:self].y;
        [self stopAltScrollMomentum];
        if (fabs(vy) > 140.0) {
            self.altScrollVelocity = MAX(-3600.0, MIN(3600.0, vy));
            self.altScrollLastTimestamp = 0;
            self.altScrollDisplayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(stepAltScrollMomentum:)];
            [self.altScrollDisplayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
        }
    } else {
        [self stopAltScrollMomentum];
    }
}

- (void)setKeyboardAppearance:(UIKeyboardAppearance)keyboardAppearance {
    BOOL needsFirstResponderDance = self.isFirstResponder && _keyboardAppearance != keyboardAppearance;
    if (needsFirstResponderDance) {
        [self resignFirstResponder];
    }
    _keyboardAppearance = keyboardAppearance;
    if (needsFirstResponderDance) {
        [self becomeFirstResponder];
    }
    if (keyboardAppearance == UIKeyboardAppearanceLight) {
        self.scrollbarView.indicatorStyle = UIScrollViewIndicatorStyleBlack;
    } else {
        self.scrollbarView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    }
}

#pragma mark Keyboard Input

// implementing these makes a keyboard pop up when this view is first responder

- (void)insertText:(NSString *)text {
    self.markedText = nil;
#if USE_XTERM_RENDERER
    if (self.selectionActive) {
        [self clearTerminalSelection];
    }
#endif

    if (self.controlKey.highlighted)
        self.controlKey.selected = YES;
    if (self.controlKey.selected) {
        if (!self.controlKey.highlighted) {
            self.controlKey.selected = NO;
            self.controlKey.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1.0];
        }
        if (text.length == 1)
            return [self insertControlChar:[text characterAtIndex:0]];
    }

    text = [text stringByReplacingOccurrencesOfString:@"\n" withString:@"\r"];
    if (self.altKey.selected && text.length == 1) {
        self.altKey.selected = NO;
        self.altKey.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1.0];
        [self.altKey sendActionsForControlEvents:UIControlEventValueChanged];
        text = [@"\x1b" stringByAppendingString:text];
    }
    [self scrollToBottomForUserInput];
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    [self.terminal sendInput:data];
}

- (void)insertControlChar:(char)ch {
    if (strchr(controlKeys, ch) != NULL) {
        if (ch == ' ') ch = '\0';
        if (ch == '2') ch = '@';
        if (ch == '6') ch = '^';
        if (ch != '\0')
            ch = toupper(ch) ^ 0x40;
        [self scrollToBottomForUserInput];
        [self.terminal sendInput:[NSData dataWithBytes:&ch length:1]];
    }
}

- (void)deleteBackward {
    self.markedText = nil;
#if USE_XTERM_RENDERER
    if (self.selectionActive) {
        [self clearTerminalSelection];
    }
#endif
    if (self.controlKey.selected && !self.controlKey.highlighted) {
        self.controlKey.selected = NO;
        self.controlKey.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1.0];
    }
    if (self.altKey.selected) {
        self.altKey.selected = NO;
        self.altKey.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1.0];
        [self.altKey sendActionsForControlEvents:UIControlEventValueChanged];
    }
    [self scrollToBottomForUserInput];
    static const uint8_t del = 0x7f;
    [self.terminal sendInput:[NSData dataWithBytes:&del length:1]];
}

- (BOOL)hasText {
    return YES; // it's always ok to send a "delete"
}

#pragma mark IME Input and Selection

- (void)setMarkedText:(nullable NSString *)markedText selectedRange:(NSRange)selectedRange {
    self.markedText = markedText;
}

- (void)unmarkText {
    NSString *text = self.markedText;
    self.markedText = nil;
    if (text.length > 0) {
        [self insertText:text];
    }
}

- (UITextRange *)markedTextRange {
    if (self.markedText != nil)
        return self.markedRange;
    return nil;
}

// The only reason to have this selected range is to prevent the "speak selection" context action from failing to get the current selection and falling back on calling copy:. It doesn't even have to work, it seems...

- (UITextRange *)selectedTextRange {
    return self.selectedRange;
}

- (NSString *)textInRange:(UITextRange *)range {
    if (range == self.markedRange)
        return self.markedText;
    if (range == self.selectedRange)
        return @"";
    return nil;
}

- (id)insertDictationResultPlaceholder {
    return @"";
}
- (void)removeDictationResultPlaceholder:(id)placeholder willInsertResult:(BOOL)willInsertResult {
}

#pragma mark Keyboard Actions

- (void)paste:(id)sender {
    self.markedText = nil;
    NSString *string = UIPasteboard.generalPasteboard.string;
    if (string.length == 0)
        return;
#if USE_XTERM_RENDERER
    if (self.selectionActive) {
        [self clearTerminalSelection];
    }
    if (self.terminal.bracketedPaste) {
        // Strip embedded bracketed-paste end marker to prevent escape injection.
        NSString *safe = [string stringByReplacingOccurrencesOfString:@"\x1b[201~" withString:@""];
        safe = [safe stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\r"];
        safe = [safe stringByReplacingOccurrencesOfString:@"\n" withString:@"\r"];
        NSString *wrapped = [NSString stringWithFormat:@"\x1b[200~%@\x1b[201~", safe];
        NSData *data = [wrapped dataUsingEncoding:NSUTF8StringEncoding];
        [self scrollToBottomForUserInput];
        if (data)
            [self.terminal sendInput:data];
        return;
    }
#endif
    [self insertText:string];
}

- (void)copy:(id)sender {
#if USE_XTERM_RENDERER
    if (self.selectedText.length > 0) {
        UIPasteboard.generalPasteboard.string = self.selectedText;
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [feedback impactOccurred];
        [self clearTerminalSelection];
        return;
    }
#endif
    [self.terminal.webView evaluateJavaScript:@"exports.copy()" completionHandler:^(id result, NSError *error) {
        if (error == nil && [result isKindOfClass:NSString.class] && [result length] > 0) {
            UIPasteboard.generalPasteboard.string = result;
#if USE_XTERM_RENDERER
            UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [feedback impactOccurred];
            [self clearTerminalSelection];
#endif
        }
    }];
}

- (BOOL)canPerformAction:(SEL)action withSender:(id)sender {
#if USE_XTERM_RENDERER
    if (action == @selector(copy:))
        return self.selectedText.length > 0;
    if (action == @selector(paste:))
        return UIPasteboard.generalPasteboard.hasStrings;
    if (action == @selector(selectAll:))
        return self.terminal.loaded;
#endif
    return [super canPerformAction:action withSender:sender];
}

- (void)selectAll:(id)sender {
    if (!self.terminal.loaded)
        return;
    [self.terminal.webView evaluateJavaScript:@"exports.selectAll?.()" completionHandler:^(id result, NSError *error) {
        if ([result isKindOfClass:NSDictionary.class]) {
            [self applySelectionGeometry:result];
        }
        if (self.selectionActive) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (self.selectionActive && !self.draggingSelection)
                    [self presentSelectionMenuAtPoint:self.lastSelectionMenuPoint];
            });
        }
    }];
}

- (void)selectLine:(id)sender {
    if (!self.terminal.loaded)
        return;
    [self.terminal.webView evaluateJavaScript:@"exports.selectLine?.()" completionHandler:^(id result, NSError *error) {
        if ([result isKindOfClass:NSDictionary.class]) {
            [self applySelectionGeometry:result];
        }
        if (self.selectionActive) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (self.selectionActive && !self.draggingSelection)
                    [self presentSelectionMenuAtPoint:self.lastSelectionMenuPoint];
            });
        }
    }];
}

- (void)clearTerminalSelection {
    [self stopSelectionAutoScroll];
    self.selectionActive = NO;
    self.draggingSelection = NO;
    self.draggingHandle = NO;
    self.activeDragHandle = nil;
    self.selectedText = nil;
    self.selectedLinkURL = nil;
    self.scrollbarView.scrollEnabled = !self.terminalAltScreen;
    self.startSelectionHandle.hidden = YES;
    self.endSelectionHandle.hidden = YES;
    [self dismissSelectionMenu];
    if (self.terminal.loaded) {
        [self.terminal.webView evaluateJavaScript:@"exports.clearSelection?.()" completionHandler:nil];
    }
}

- (void)applySelectionGeometry:(NSDictionary *)geom {
    BOOL hasSelection = [geom[@"hasSelection"] boolValue];
    NSString *text = [geom[@"text"] isKindOfClass:NSString.class] ? geom[@"text"] : @"";
    NSString *linkUrl = [geom[@"linkUrl"] isKindOfClass:NSString.class] ? geom[@"linkUrl"] : @"";
    self.selectionActive = hasSelection;
    self.selectedText = (hasSelection && text.length > 0) ? text : nil;
    self.selectedLinkURL = (hasSelection && linkUrl.length > 0) ? linkUrl : nil;

    if (self.draggingHandle && [geom[@"activeHandle"] isKindOfClass:NSString.class]) {
        self.activeDragHandle = geom[@"activeHandle"];
    }

    if (!hasSelection || self.terminal.webView.superview == nil) {
        self.startSelectionHandle.hidden = YES;
        self.endSelectionHandle.hidden = YES;
        return;
    }

    BOOL startVisible = [geom[@"startVisible"] boolValue];
    BOOL endVisible = [geom[@"endVisible"] boolValue];

    CGPoint startTop = [self convertPoint:CGPointMake([geom[@"startX"] doubleValue], [geom[@"startTopY"] doubleValue]) fromView:self.terminal.webView];
    CGPoint startBottom = [self convertPoint:CGPointMake([geom[@"startX"] doubleValue], [geom[@"startBottomY"] doubleValue]) fromView:self.terminal.webView];
    [self.startSelectionHandle positionAtX:startTop.x topY:startTop.y bottomY:startBottom.y];
    self.startSelectionHandle.hidden = !startVisible;

    CGPoint endTop = [self convertPoint:CGPointMake([geom[@"endX"] doubleValue], [geom[@"endTopY"] doubleValue]) fromView:self.terminal.webView];
    CGPoint endBottom = [self convertPoint:CGPointMake([geom[@"endX"] doubleValue], [geom[@"endBottomY"] doubleValue]) fromView:self.terminal.webView];
    [self.endSelectionHandle positionAtX:endTop.x topY:endTop.y bottomY:endBottom.y];
    self.endSelectionHandle.hidden = !endVisible;

    CGPoint menuPt = [self convertPoint:CGPointMake([geom[@"menuX"] doubleValue], [geom[@"menuY"] doubleValue]) fromView:self.terminal.webView];
    self.lastSelectionMenuPoint = menuPt;
}

- (void)presentSelectionMenuAtPoint:(CGPoint)point {
    if (self.window == nil)
        return;
    CGFloat minX = MIN(24.0, self.bounds.size.width * 0.5);
    CGFloat maxX = MAX(minX, self.bounds.size.width - 24.0);
    CGFloat minY = MIN(24.0, self.bounds.size.height * 0.5);
    CGFloat maxY = MAX(minY, self.bounds.size.height - 24.0);
    CGPoint clamped = CGPointMake(MAX(minX, MIN(maxX, point.x)), MAX(minY, MIN(maxY, point.y)));

    if (@available(iOS 16.0, *)) {
        UIEditMenuConfiguration *config = [UIEditMenuConfiguration configurationWithIdentifier:nil sourcePoint:clamped];
        [self.terminalEditMenu presentEditMenuWithConfiguration:config];
    } else {
        if (!self.isFirstResponder && self.canBecomeFirstResponder) {
            [self becomeFirstResponder];
        }
        [UIMenuController.sharedMenuController showMenuFromView:self rect:CGRectMake(clamped.x, clamped.y, 1, 1)];
    }
}

- (void)dismissSelectionMenu {
    if (@available(iOS 16.0, *)) {
        [self.terminalEditMenu dismissMenu];
    } else {
        [UIMenuController.sharedMenuController hideMenuFromView:self];
    }
}

- (void)refreshAndPresentSelectionMenu {
    if (!self.terminal.loaded)
        return;
    [self.terminal.webView evaluateJavaScript:@"exports.selectionGeometry?.()" completionHandler:^(id result, NSError *error) {
        if ([result isKindOfClass:NSDictionary.class]) {
            [self applySelectionGeometry:result];
        }
        if (self.selectionActive && (!self.startSelectionHandle.hidden || !self.endSelectionHandle.hidden)) {
            [self presentSelectionMenuAtPoint:self.lastSelectionMenuPoint];
        }
    }];
}

- (void)updateAutoScrollForPointInSelf:(CGPoint)point isHandle:(BOOL)isHandle {
    CGFloat edge = 36.0;
    NSInteger direction = 0;
    if (point.y < edge) {
        direction = -1;
    } else if (point.y > self.bounds.size.height - edge) {
        direction = 1;
    }
    self.selectionAutoScrollDirection = direction;
    self.draggingHandle = isHandle;
    if (direction == 0) {
        [self stopSelectionAutoScroll];
        return;
    }
    if (!self.selectionAutoScrollTimer) {
        __weak TerminalView *weakSelf = self;
        self.selectionAutoScrollTimer = [NSTimer scheduledTimerWithTimeInterval:0.07 repeats:YES block:^(NSTimer *timer) {
            TerminalView *strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.draggingSelection || strongSelf.selectionAutoScrollDirection == 0) {
                [timer invalidate];
                return;
            }
            NSInteger delta = strongSelf.selectionAutoScrollDirection;
            CGPoint pt = strongSelf.lastDragPointInWebView;
            NSString *script;
            if (strongSelf.draggingHandle) {
                script = [NSString stringWithFormat:@"exports.scrollByLines(%ld); exports.moveSelectionHandle(%f,%f)",
                          (long)delta, pt.x, pt.y];
            } else {
                script = [NSString stringWithFormat:@"exports.scrollByLines(%ld); exports.extendSelection(%f,%f)",
                          (long)delta, pt.x, pt.y];
            }
            [strongSelf.terminal.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
                if ([result isKindOfClass:NSDictionary.class]) {
                    [strongSelf applySelectionGeometry:result];
                }
            }];
        }];
    }
}

- (void)stopSelectionAutoScroll {
    [self.selectionAutoScrollTimer invalidate];
    self.selectionAutoScrollTimer = nil;
    self.selectionAutoScrollDirection = 0;
}

- (void)handleTerminalTap:(UITapGestureRecognizer *)gesture {
    [self stopAltScrollMomentum];
    if (self.selectionActive) {
        [self clearTerminalSelection];
        return;
    }
    if (self.terminal.loaded) {
        CGPoint point = [gesture locationInView:self.terminal.webView];
        NSString *script = [NSString stringWithFormat:@"exports.linkAt?.(%f,%f)", point.x, point.y];
        __weak TerminalView *weakSelf = self;
        [self.terminal.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
            TerminalView *strongSelf = weakSelf;
            if (!strongSelf) return;
            NSString *url = ([result isKindOfClass:NSDictionary.class] && [result[@"url"] isKindOfClass:NSString.class]) ? result[@"url"] : nil;
            if (url.length > 0 && ([url hasPrefix:@"http://"] || [url hasPrefix:@"https://"])) {
                UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
                [feedback impactOccurred];
                [UIApplication openURL:url];
                return;
            }
            if (!strongSelf.isFirstResponder && strongSelf.canBecomeFirstResponder) {
                [strongSelf becomeFirstResponder];
            }
        }];
        return;
    }
    if (!self.isFirstResponder && self.canBecomeFirstResponder) {
        [self becomeFirstResponder];
    }
}

- (void)handleTerminalDoubleTap:(UITapGestureRecognizer *)gesture {
    if (!self.terminal.loaded)
        return;
    CGPoint point = [gesture locationInView:self.terminal.webView];
    NSString *script = [NSString stringWithFormat:@"exports.selectWordAt(%f,%f)", point.x, point.y];
    [self.terminal.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        if ([result isKindOfClass:NSDictionary.class]) {
            [self applySelectionGeometry:result];
            if (self.selectionActive) {
                UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
                [feedback impactOccurred];
                [self presentSelectionMenuAtPoint:self.lastSelectionMenuPoint];
            }
        }
    }];
}

- (void)selectTerminalText:(UILongPressGestureRecognizer *)gesture {
    if (!self.terminal.loaded)
        return;
    CGPoint point = [gesture locationInView:self.terminal.webView];
    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.draggingSelection = YES;
        self.draggingHandle = NO;
        self.scrollbarView.scrollEnabled = NO;
        self.lastDragPointInWebView = point;
        [self dismissSelectionMenu];
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [feedback impactOccurred];
        NSString *script = [NSString stringWithFormat:@"exports.beginSelection(%f,%f)", point.x, point.y];
        [self.terminal.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
            if ([result isKindOfClass:NSDictionary.class]) {
                [self applySelectionGeometry:result];
            }
        }];
    } else if (gesture.state == UIGestureRecognizerStateChanged) {
        self.lastDragPointInWebView = point;
        [self updateAutoScrollForPointInSelf:[gesture locationInView:self] isHandle:NO];
        NSString *script = [NSString stringWithFormat:@"exports.extendSelection(%f,%f)", point.x, point.y];
        [self.terminal.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
            if ([result isKindOfClass:NSDictionary.class]) {
                [self applySelectionGeometry:result];
            }
        }];
    } else if (gesture.state == UIGestureRecognizerStateEnded) {
        [self stopSelectionAutoScroll];
        self.draggingSelection = NO;
        self.scrollbarView.scrollEnabled = !self.terminalAltScreen;
        CGPoint fallbackAnchor = [gesture locationInView:self];
        [self.terminal.webView evaluateJavaScript:@"exports.selectionGeometry?.()" completionHandler:^(id result, NSError *error) {
            if ([result isKindOfClass:NSDictionary.class]) {
                [self applySelectionGeometry:result];
            }
            CGPoint anchor = self.selectionActive ? self.lastSelectionMenuPoint : fallbackAnchor;
            [self presentSelectionMenuAtPoint:anchor];
        }];
    } else if (gesture.state == UIGestureRecognizerStateCancelled || gesture.state == UIGestureRecognizerStateFailed) {
        [self stopSelectionAutoScroll];
        self.draggingSelection = NO;
        self.scrollbarView.scrollEnabled = !self.terminalAltScreen;
    }
}

- (void)panSelectionHandle:(UIPanGestureRecognizer *)gesture {
    if (!self.terminal.loaded || ![gesture.view isKindOfClass:LRTerminalSelectionHandle.class])
        return;
    LRTerminalSelectionHandle *handle = (LRTerminalSelectionHandle *)gesture.view;
    CGPoint touchInWeb = [gesture locationInView:self.terminal.webView];
    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.draggingSelection = YES;
        self.draggingHandle = YES;
        self.scrollbarView.scrollEnabled = NO;
        NSString *which = handle.isStart ? @"start" : @"end";
        self.activeDragHandle = which;
        CGPoint anchorInWeb = [self convertPoint:handle.center toView:self.terminal.webView];
        self.handleDragOffset = CGPointMake(anchorInWeb.x - touchInWeb.x, anchorInWeb.y - touchInWeb.y);
        [self dismissSelectionMenu];
        UISelectionFeedbackGenerator *feedback = [UISelectionFeedbackGenerator new];
        [feedback selectionChanged];
        NSString *script = [NSString stringWithFormat:@"exports.beginSelectionHandle('%@')", which];
        [self.terminal.webView evaluateJavaScript:script completionHandler:nil];
    } else if (gesture.state == UIGestureRecognizerStateChanged) {
        CGPoint targetInWeb = CGPointMake(touchInWeb.x + self.handleDragOffset.x, touchInWeb.y + self.handleDragOffset.y);
        self.lastDragPointInWebView = targetInWeb;
        [self updateAutoScrollForPointInSelf:[gesture locationInView:self] isHandle:YES];
        NSString *script = [NSString stringWithFormat:@"exports.moveSelectionHandle(%f,%f)", targetInWeb.x, targetInWeb.y];
        [self.terminal.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
            if ([result isKindOfClass:NSDictionary.class]) {
                [self applySelectionGeometry:result];
            }
        }];
    } else if (gesture.state == UIGestureRecognizerStateEnded ||
               gesture.state == UIGestureRecognizerStateCancelled ||
               gesture.state == UIGestureRecognizerStateFailed) {
        [self stopSelectionAutoScroll];
        self.draggingSelection = NO;
        self.draggingHandle = NO;
        self.activeDragHandle = nil;
        self.scrollbarView.scrollEnabled = !self.terminalAltScreen;
        [self.terminal.webView evaluateJavaScript:@"exports.endSelectionHandle?.(); exports.selectionGeometry?.()" completionHandler:^(id result, NSError *error) {
            if ([result isKindOfClass:NSDictionary.class]) {
                [self applySelectionGeometry:result];
            }
            if (self.selectionActive) {
                [self presentSelectionMenuAtPoint:self.lastSelectionMenuPoint];
            }
        }];
    }
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer == self.altScrollGesture) {
        return self.terminalAltScreen && !self.selectionActive && !self.draggingSelection;
    }
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    if (touch.view == self.startSelectionHandle || touch.view == self.endSelectionHandle) {
        return NO;
    }
    return YES;
}

- (UIMenu *)editMenuInteraction:(UIEditMenuInteraction *)interaction menuForConfiguration:(UIEditMenuConfiguration *)configuration suggestedActions:(NSArray<UIMenuElement *> *)suggestedActions API_AVAILABLE(ios(16.0)) {
    __weak TerminalView *view = self;
    NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
    if (self.selectedText.length > 0) {
        [actions addObject:[UIAction actionWithTitle:@"Copy" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction *action) { [view copy:nil]; }]];
    }
    NSString *linkUrl = self.selectedLinkURL;
    if (linkUrl.length == 0 && self.selectedText.length > 0) {
        NSString *trimmed = [self.selectedText stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (([trimmed hasPrefix:@"http://"] || [trimmed hasPrefix:@"https://"]) &&
            [trimmed rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location == NSNotFound) {
            linkUrl = trimmed;
        }
    }
    if (linkUrl.length > 0) {
        [actions addObject:[UIAction actionWithTitle:@"Open Link" image:[UIImage systemImageNamed:@"safari"] identifier:nil handler:^(UIAction *action) {
            [UIApplication openURL:linkUrl];
            [view clearTerminalSelection];
        }]];
        NSString *trimmedSelected = [self.selectedText stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (![linkUrl isEqualToString:trimmedSelected]) {
            [actions addObject:[UIAction actionWithTitle:@"Copy Link" image:[UIImage systemImageNamed:@"link"] identifier:nil handler:^(UIAction *action) {
                UIPasteboard.generalPasteboard.string = linkUrl;
                UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
                [feedback impactOccurred];
                [view clearTerminalSelection];
            }]];
        }
    }
    if (UIPasteboard.generalPasteboard.hasStrings) {
        [actions addObject:[UIAction actionWithTitle:@"Paste" image:[UIImage systemImageNamed:@"doc.on.clipboard"] identifier:nil handler:^(UIAction *action) { [view paste:nil]; }]];
    }
    if (self.selectedText.length > 0) {
        [actions addObject:[UIAction actionWithTitle:@"Select Line" image:nil identifier:nil handler:^(UIAction *action) { [view selectLine:nil]; }]];
    }
    [actions addObject:[UIAction actionWithTitle:@"Select All" image:nil identifier:nil handler:^(UIAction *action) { [view selectAll:nil]; }]];
    return [UIMenu menuWithChildren:actions];
}

- (void)clearScrollback:(UIKeyCommand *)command {
    [self.terminal.webView evaluateJavaScript:@"exports.clearScrollback()" completionHandler:nil];
}

#pragma mark Floating cursor

- (void)updateFloatingCursorSensitivity {
    [self.terminal.webView evaluateJavaScript:@"exports.getCharacterSize()" completionHandler:^(NSArray *charSizeRaw, NSError *error) {
        if (error != nil) {
            NSLog(@"error getting character size: %@", error);
            return;
        }
        if (![charSizeRaw isKindOfClass:NSArray.class] || charSizeRaw.count < 2 ||
            ![charSizeRaw[0] isKindOfClass:NSNumber.class] || ![charSizeRaw[1] isKindOfClass:NSNumber.class])
            return;
        CGSize charSize = CGSizeMake([charSizeRaw[0] doubleValue], [charSizeRaw[1] doubleValue]);
        if (!isfinite(charSize.width) || !isfinite(charSize.height) || charSize.width <= 0 || charSize.height <= 0)
            return;
        double sensitivity = 0.5;
        self.floatingCursorSensitivity = CGSizeMake(charSize.width / sensitivity, charSize.height / sensitivity);
    }];
}

- (struct rowcol)rowcolFromPoint:(CGPoint)point {
    CGSize sensitivity = self.actualFloatingCursorSensitivity;
    if (!isfinite(sensitivity.width) || !isfinite(sensitivity.height) ||
        sensitivity.width < 1.0 || sensitivity.height < 1.0) {
        return (struct rowcol) {0, 0};
    }
    return (struct rowcol) {
        .row = (int) (-point.y / sensitivity.height),
        .col = (int) (point.x / sensitivity.width),
    };
}

- (void)beginFloatingCursorAtPoint:(CGPoint)point {
    self.actualFloatingCursorSensitivity = self.floatingCursorSensitivity;
    self.floatingCursor = [self rowcolFromPoint:point];
}

- (void)updateFloatingCursorAtPoint:(CGPoint)point {
    CGSize sensitivity = self.actualFloatingCursorSensitivity;
    if (!isfinite(sensitivity.width) || !isfinite(sensitivity.height) ||
        sensitivity.width < 1.0 || sensitivity.height < 1.0) {
        return;
    }
    struct rowcol newPos = [self rowcolFromPoint:point];
    int rowDiff = MAX(-64, MIN(64, newPos.row - self.floatingCursor.row));
    int colDiff = MAX(-64, MIN(64, newPos.col - self.floatingCursor.col));
    if (rowDiff == 0 && colDiff == 0)
        return;
    NSMutableString *arrows = [NSMutableString string];
    for (int i = 0; i < abs(rowDiff); i++) {
        [arrows appendString:[self.terminal arrow:rowDiff > 0 ? 'A': 'B']];
    }
    for (int i = 0; i < abs(colDiff); i++) {
        [arrows appendString:[self.terminal arrow:colDiff > 0 ? 'C': 'D']];
    }
    [self insertText:arrows];
    self.floatingCursor = newPos;
}

- (void)endFloatingCursor {
    self.floatingCursor = (struct rowcol) {};
}

#pragma mark Keyboard Traits

- (UITextSmartDashesType)smartDashesType API_AVAILABLE(ios(11)) {
    return UITextSmartDashesTypeNo;
}
- (UITextSmartQuotesType)smartQuotesType API_AVAILABLE(ios(11)) {
    return UITextSmartQuotesTypeNo;
}
- (UITextSmartInsertDeleteType)smartInsertDeleteType API_AVAILABLE(ios(11)) {
    return UITextSmartInsertDeleteTypeNo;
}
- (UITextAutocapitalizationType)autocapitalizationType {
    return UITextAutocapitalizationTypeNone;
}
- (UITextAutocorrectionType)autocorrectionType {
    return UITextAutocorrectionTypeNo;
}
// Apparently required on iOS 15+: https://stackoverflow.com/a/72359764
- (UITextSpellCheckingType)spellCheckingType {
    return UITextSpellCheckingTypeNo;
}
#if defined(__IPHONE_17_0) && __IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_17_0
- (UITextInlinePredictionType)inlinePredictionType API_AVAILABLE(ios(17.0)) {
    return UITextInlinePredictionTypeNo;
}
#endif
#if defined(__IPHONE_18_0) && __IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_18_0
- (UITextMathExpressionCompletionType)mathExpressionCompletionType API_AVAILABLE(ios(18.0)) {
    return UITextMathExpressionCompletionTypeNo;
}
- (UIWritingToolsBehavior)writingToolsBehavior API_AVAILABLE(ios(18.0)) {
    return UIWritingToolsBehaviorNone;
}
#endif

#pragma mark Hardware Keyboard

- (void)handleKeyCommand:(UIKeyCommand *)command {
    NSString *key = command.input;
    if (command.modifierFlags == 0) {
        if ([key isEqualToString:@"`"] && UserPreferences.shared.backtickMapEscape)
            key = UIKeyInputEscape;
        if ([key isEqualToString:UIKeyInputEscape])
            key = @"\x1b";
        else if ([key isEqualToString:UIKeyInputUpArrow])
            key = [self.terminal arrow:'A'];
        else if ([key isEqualToString:UIKeyInputDownArrow])
            key = [self.terminal arrow:'B'];
        else if ([key isEqualToString:UIKeyInputLeftArrow])
            key = [self.terminal arrow:'D'];
        else if ([key isEqualToString:UIKeyInputRightArrow])
            key = [self.terminal arrow:'C'];
        [self insertText:key];
    } else if (command.modifierFlags & UIKeyModifierShift) {
        [self insertText:[key uppercaseString]];
    } else if (command.modifierFlags & UIKeyModifierAlternate) {
        [self insertText:[@"\x1b" stringByAppendingString:key]];
    } else if (command.modifierFlags & UIKeyModifierAlphaShift) {
        [self handleCapsLockWithCommand:command];
    } else if (command.modifierFlags & UIKeyModifierControl || command.modifierFlags & UIKeyModifierAlphaShift) {
        if (key.length == 0)
            return;
        if ([key isEqualToString:@"2"])
            key = @"@";
        else if ([key isEqualToString:@"6"])
            key = @"^";
        else if ([key isEqualToString:@"-"])
            key = @"_";
        [self insertControlChar:[key characterAtIndex:0]];
    }
}

static const char *alphabet = "abcdefghijklmnopqrstuvwxyz";
static const char *controlKeys = "abcdefghijklmnopqrstuvwxyz@^26-=[]\\ ";
static const char *metaKeys = "abcdefghijklmnopqrstuvwxyz0123456789-=[]\\;',./";

- (NSArray<UIKeyCommand *> *)keyCommands {
    if (_keyCommands != nil)
        return _keyCommands;
    _keyCommands = [NSMutableArray new];
    [self addKeys:controlKeys withModifiers:UIKeyModifierControl];
    for (NSString *specialKey in @[UIKeyInputEscape, UIKeyInputUpArrow, UIKeyInputDownArrow,
                                   UIKeyInputLeftArrow, UIKeyInputRightArrow, @"\t"]) {
        [self addKey:specialKey withModifiers:0];
    }
    if (UserPreferences.shared.capsLockMapping != CapsLockMapNone) {
        if (@available(iOS 13, *)); else {
            [self addKeys:controlKeys withModifiers:UIKeyModifierAlphaShift];
            [self addKeys:alphabet withModifiers:0];
            [self addKeys:alphabet withModifiers:UIKeyModifierShift];
            [self addKey:@"" withModifiers:UIKeyModifierAlphaShift]; // otherwise tap of caps lock can switch layouts
        }
    }
    if (UserPreferences.shared.optionMapping == OptionMapEsc) {
        [self addKeys:metaKeys withModifiers:UIKeyModifierAlternate];
    }
    if (UserPreferences.shared.backtickMapEscape) {
        [self addKey:@"`" withModifiers:0];
    }
    [_keyCommands addObject:[UIKeyCommand keyCommandWithInput:@"k"
                                                modifierFlags:UIKeyModifierCommand|UIKeyModifierShift
                                                       action:@selector(clearScrollback:)
                                         discoverabilityTitle:@"Clear Scrollback"]];
    return _keyCommands;
}

- (void)addKeys:(const char *)keys withModifiers:(UIKeyModifierFlags)modifiers {
    for (size_t i = 0; keys[i] != '\0'; i++) {
        [self addKey:[NSString stringWithFormat:@"%c", keys[i]] withModifiers:modifiers];
    }
}

- (void)addKey:(NSString *)key withModifiers:(UIKeyModifierFlags)modifiers {
    UIKeyCommand *command = [UIKeyCommand keyCommandWithInput:key
                                                modifierFlags:modifiers
                                                       action:@selector(handleKeyCommand:)];
    if (@available(iOS 15, *)) {
        command.wantsPriorityOverSystemBehavior = YES;
    }
    [_keyCommands addObject:command];
}

- (void)keyCommandTriggered:(UIKeyCommand *)sender {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self handleKeyCommand:sender];
    });
}

- (void)handleCapsLockWithCommand:(UIKeyCommand *)command {
    CapsLockMapping target = UserPreferences.shared.capsLockMapping;
    NSString *newInput = command.input ? command.input : @"";
    UIKeyModifierFlags flags = command.modifierFlags;
    flags ^= UIKeyModifierAlphaShift;
    if(target == CapsLockMapEscape) {
        newInput = UIKeyInputEscape;
    } else if(target == CapsLockMapControl) {
        if([newInput length] == 0) {
            return;
        }
        flags |= UIKeyModifierControl;
    } else {
        return;
    }

    UIKeyCommand *newCommand = [UIKeyCommand keyCommandWithInput:newInput
                                                   modifierFlags:flags
                                                          action:@selector(keyCommandTriggered:)];
    [self handleKeyCommand:newCommand];
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    if (@available(iOS 13.4, *)) {
        UIKey *key = presses.anyObject.key;
        if (UserPreferences.shared.overrideControlSpace &&
            key.keyCode == UIKeyboardHIDUsageKeyboardSpacebar &&
            key.modifierFlags & UIKeyModifierControl) {
            return [self insertControlChar:' '];
        }
    }
    return [super pressesBegan:presses withEvent:event];
}

#pragma mark UITextInput stubs

#if 0
#define LogStub() NSLog(@"%s", __func__)
#else
#define LogStub()
#endif

- (NSWritingDirection)baseWritingDirectionForPosition:(nonnull UITextPosition *)position inDirection:(UITextStorageDirection)direction { LogStub(); return NSWritingDirectionLeftToRight; }
- (void)setBaseWritingDirection:(NSWritingDirection)writingDirection forRange:(nonnull UITextRange *)range { LogStub(); }
- (UITextPosition *)beginningOfDocument { LogStub(); return nil; }
- (CGRect)caretRectForPosition:(nonnull UITextPosition *)position { LogStub(); return CGRectZero; }
- (nullable UITextRange *)characterRangeAtPoint:(CGPoint)point { LogStub(); return nil; }
- (nullable UITextRange *)characterRangeByExtendingPosition:(nonnull UITextPosition *)position inDirection:(UITextLayoutDirection)direction { LogStub(); return nil; }
- (nullable UITextPosition *)closestPositionToPoint:(CGPoint)point { LogStub(); return nil; }
- (nullable UITextPosition *)closestPositionToPoint:(CGPoint)point withinRange:(nonnull UITextRange *)range { LogStub(); return nil; }
- (NSComparisonResult)comparePosition:(nonnull UITextPosition *)position toPosition:(nonnull UITextPosition *)other { LogStub(); return NSOrderedSame; }
- (UITextPosition *)endOfDocument { LogStub(); return nil; }
- (CGRect)firstRectForRange:(nonnull UITextRange *)range { LogStub(); return CGRectZero; }
- (NSDictionary<NSAttributedStringKey,id> *)markedTextStyle { LogStub(); return nil; }
- (void)setMarkedTextStyle:(NSDictionary<NSAttributedStringKey,id> *)markedTextStyle { LogStub(); }
- (NSInteger)offsetFromPosition:(nonnull UITextPosition *)from toPosition:(nonnull UITextPosition *)toPosition { LogStub(); return 0; }
- (nullable UITextPosition *)positionFromPosition:(nonnull UITextPosition *)position inDirection:(UITextLayoutDirection)direction offset:(NSInteger)offset { LogStub(); return nil; }
- (nullable UITextPosition *)positionFromPosition:(nonnull UITextPosition *)position offset:(NSInteger)offset { LogStub(); return nil; }
- (nullable UITextPosition *)positionWithinRange:(nonnull UITextRange *)range farthestInDirection:(UITextLayoutDirection)direction { LogStub(); return nil; }
- (void)replaceRange:(nonnull UITextRange *)range withText:(nonnull NSString *)text { LogStub(); }
- (void)setSelectedTextRange:(UITextRange *)selectedTextRange { LogStub(); }
- (nonnull NSArray<UITextSelectionRect *> *)selectionRectsForRange:(nonnull UITextRange *)range { LogStub(); return @[]; }
- (nullable UITextRange *)textRangeFromPosition:(nonnull UITextPosition *)fromPosition toPosition:(nonnull UITextPosition *)toPosition { LogStub(); return nil; }

// conforming to UITextInput makes this view default to being an accessibility element, which blocks selecting anything in it
- (BOOL)isAccessibilityElement { return NO; }

@end

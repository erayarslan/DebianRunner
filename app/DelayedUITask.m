//
//  DelayedUITask.m
//  iSH
//
//  Created by Theodore Dubois on 11/8/17.
//

#import "DelayedUITask.h"

@interface DelayedUITask ()

@property (weak) id target;
@property SEL action;
@property BOOL scheduled;

@end

@implementation DelayedUITask

- (instancetype)initWithTarget:(id)target action:(SEL)action {
    if (self = [super init]) {
        self.target = target;
        self.action = action;
    }
    return self;
}

- (void)schedule {
    @synchronized (self) {
        if (self.scheduled)
            return;
        self.scheduled = YES;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized (self) {
            self.scheduled = NO;
        }
        id target = self.target;
        if (target == nil)
            return;
        ((void (*)(id, SEL)) [target methodForSelector:self.action])(target, self.action);
    });
}

@end

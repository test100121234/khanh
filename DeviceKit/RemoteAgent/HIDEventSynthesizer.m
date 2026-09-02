#import "HIDEventSynthesizer.h"
#import "ApplePrivateHeaders.h"
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <UIKit/UIKit.h>

@implementation HIDEventSynthesizer {
    void *_bksHandle;
    void *_ioKitHandle;
    BKSHIDServicesPostEventFunc _BKSHIDServicesPostEvent;
    IOHIDEventCreateDigitizerFingerEventWithUserDataFunc _IOHIDEventCreateDigitizerFingerEventWithUserData;
    IOHIDEventCreateDigitizerEventFunc _IOHIDEventCreateDigitizerEvent;
    IOHIDEventCreateKeyboardEventFunc _IOHIDEventCreateKeyboardEvent;
    IOHIDEventAppendEventFunc _IOHIDEventAppendEvent;
    IOHIDEventSetIntegerValueFunc _IOHIDEventSetIntegerValue;
    IOHIDEventSetSenderIDFunc _IOHIDEventSetSenderID;
    IOHIDEventSystemClientRef _hidSystemClient;
    IOHIDEventSystemClientDispatchEventFunc _IOHIDEventSystemClientDispatchEvent;
}

+ (instancetype)sharedInstance {
    static HIDEventSynthesizer *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[HIDEventSynthesizer alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self loadPrivateSymbols];
    }
    return self;
}

- (void)loadPrivateSymbols {
    const char *bksPaths[] = {
        "/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices",
        "/System/Library/Frameworks/BackBoardServices.framework/BackBoardServices",
        NULL
    };

    for (int i = 0; bksPaths[i] != NULL; i++) {
        _bksHandle = dlopen(bksPaths[i], RTLD_NOW | RTLD_GLOBAL);
        if (_bksHandle) break;
    }

    const char *ioKitPaths[] = {
        "/System/Library/Frameworks/IOKit.framework/IOKit",
        "/System/Library/PrivateFrameworks/IOKit.framework/IOKit",
        NULL
    };

    for (int i = 0; ioKitPaths[i] != NULL; i++) {
        _ioKitHandle = dlopen(ioKitPaths[i], RTLD_NOW | RTLD_GLOBAL);
        if (_ioKitHandle) break;
    }

    if (_bksHandle) {
        _BKSHIDServicesPostEvent = (BKSHIDServicesPostEventFunc)dlsym(_bksHandle, "BKSHIDServicesPostEvent");
    }
    if (_ioKitHandle) {
        _IOHIDEventCreateDigitizerFingerEventWithUserData = (IOHIDEventCreateDigitizerFingerEventWithUserDataFunc)dlsym(_ioKitHandle, "IOHIDEventCreateDigitizerFingerEventWithUserData");
        _IOHIDEventCreateDigitizerEvent = (IOHIDEventCreateDigitizerEventFunc)dlsym(_ioKitHandle, "IOHIDEventCreateDigitizerEvent");
        _IOHIDEventCreateKeyboardEvent = (IOHIDEventCreateKeyboardEventFunc)dlsym(_ioKitHandle, "IOHIDEventCreateKeyboardEvent");
        _IOHIDEventAppendEvent = (IOHIDEventAppendEventFunc)dlsym(_ioKitHandle, "IOHIDEventAppendEvent");
        _IOHIDEventSetIntegerValue = (IOHIDEventSetIntegerValueFunc)dlsym(_ioKitHandle, "IOHIDEventSetIntegerValue");
        _IOHIDEventSetSenderID = (IOHIDEventSetSenderIDFunc)dlsym(_ioKitHandle, "IOHIDEventSetSenderID");
        
        IOHIDEventSystemClientCreateFunc clientCreate = (IOHIDEventSystemClientCreateFunc)dlsym(_ioKitHandle, "IOHIDEventSystemClientCreate");
        _IOHIDEventSystemClientDispatchEvent = (IOHIDEventSystemClientDispatchEventFunc)dlsym(_ioKitHandle, "IOHIDEventSystemClientDispatchEvent");
        if (clientCreate) {
            _hidSystemClient = clientCreate(kCFAllocatorDefault);
        }
    }
}

// =============================================================================
// 1. Single Finger Digitizer Event Posting
// =============================================================================

- (void)postDigitizerEventAtX:(CGFloat)x y:(CGFloat)y touch:(BOOL)touch isStart:(BOOL)isStart {
    if (!_IOHIDEventCreateDigitizerEvent || !_IOHIDEventCreateDigitizerFingerEventWithUserData) {
        return;
    }

    @try {
        uint64_t timestamp = mach_absolute_time();
        CGSize screenSize = [UIScreen mainScreen].bounds.size;
        
        IOHIDFloat normX = (IOHIDFloat)fmax(0.0, fmin(1.0, x / screenSize.width));
        IOHIDFloat normY = (IOHIDFloat)fmax(0.0, fmin(1.0, y / screenSize.height));

        uint32_t eventMask = kIOHIDDigitizerEventPosition;
        if (isStart || !touch) eventMask |= (kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch);

        IOHIDEventRef parentEvent = _IOHIDEventCreateDigitizerEvent(
            kCFAllocatorDefault, timestamp,
            kIOHIDDigitizerTransducerTypeFinger,
            0, 1, eventMask, 0,
            normX, normY, 0.0, 0.0, 0.0,
            touch, touch, 0
        );

        IOHIDEventRef fingerEvent = _IOHIDEventCreateDigitizerFingerEventWithUserData(
            kCFAllocatorDefault, timestamp,
            1, 2, eventMask,
            normX, normY, 0.0,
            touch ? 1.0 : 0.0, 0.0,
            touch, touch, 0, NULL
        );

        if (parentEvent && fingerEvent) {
            if (_IOHIDEventSetSenderID) {
                _IOHIDEventSetSenderID(parentEvent, 0xdefac83fa1100000ULL);
                _IOHIDEventSetSenderID(fingerEvent, 0xdefac83fa1100000ULL);
            }
            if (_IOHIDEventSetIntegerValue) {
                _IOHIDEventSetIntegerValue(parentEvent, kIOHIDDigitizerEventFieldChildEventMask, eventMask);
            }
            if (_IOHIDEventAppendEvent) {
                _IOHIDEventAppendEvent(parentEvent, fingerEvent);
            }
            if (_hidSystemClient && _IOHIDEventSystemClientDispatchEvent) {
                _IOHIDEventSystemClientDispatchEvent(_hidSystemClient, parentEvent);
            }
            if (_BKSHIDServicesPostEvent) {
                _BKSHIDServicesPostEvent(parentEvent);
            }
            CFRelease(fingerEvent);
            CFRelease(parentEvent);
        }
    } @catch (NSException *e) {
    }
}

// =============================================================================
// 2. Precision Coordinate Tap, Double Tap, & Long Press
// =============================================================================

- (void)sendTapAtX:(CGFloat)x y:(CGFloat)y duration:(NSTimeInterval)duration {
    [self postDigitizerEventAtX:x y:y touch:YES isStart:YES];
    NSTimeInterval tapDur = (duration <= 0) ? 0.05 : duration;
    [NSThread sleepForTimeInterval:tapDur];
    [self postDigitizerEventAtX:x y:y touch:NO isStart:NO];
}

- (void)sendDoubleTapAtX:(CGFloat)x y:(CGFloat)y {
    [self sendTapAtX:x y:y duration:0.04];
    [NSThread sleepForTimeInterval:0.08];
    [self sendTapAtX:x y:y duration:0.04];
}

- (void)sendLongPressAtX:(CGFloat)x y:(CGFloat)y duration:(NSTimeInterval)duration {
    NSTimeInterval pressDur = (duration <= 0) ? 1.0 : duration;
    [self postDigitizerEventAtX:x y:y touch:YES isStart:YES];
    [NSThread sleepForTimeInterval:pressDur];
    [self postDigitizerEventAtX:x y:y touch:NO isStart:NO];
}

// =============================================================================
// 3. Human-like Bezier Trajectory Swipe (Anti-Bot Bypass)
// =============================================================================

- (void)sendSwipeFrom:(CGPoint)from to:(CGPoint)to duration:(NSTimeInterval)duration {
    [self sendHumanSwipeFrom:from to:to duration:duration curviness:0.0];
}

- (void)sendHumanSwipeFrom:(CGPoint)from to:(CGPoint)to duration:(NSTimeInterval)duration curviness:(CGFloat)curviness {
    NSTimeInterval swDur = (duration <= 0) ? 0.35 : duration;
    int steps = (int)(swDur * 60.0);
    if (steps < 10) steps = 10;

    CGFloat dx = to.x - from.x;
    CGFloat dy = to.y - from.y;
    CGFloat dist = sqrt(dx * dx + dy * dy);

    // Normal vector perpendicular to trajectory
    CGFloat nx = (dist > 0) ? -dy / dist : 0;
    CGFloat ny = (dist > 0) ? dx / dist : 0;
    CGFloat curveOffset = dist * curviness * 0.2;

    // Cubic Bezier Control Points
    CGPoint p0 = from;
    CGPoint p1 = CGPointMake(from.x + dx * 0.25 + nx * curveOffset, from.y + dy * 0.25 + ny * curveOffset);
    CGPoint p2 = CGPointMake(from.x + dx * 0.75 + nx * curveOffset * 0.5, from.y + dy * 0.75 + ny * curveOffset * 0.5);
    CGPoint p3 = to;

    [self postDigitizerEventAtX:p0.x y:p0.y touch:YES isStart:YES];
    NSTimeInterval interval = swDur / (double)steps;

    for (int i = 1; i <= steps; ++i) {
        double rawT = (double)i / (double)steps;
        // Ease-in-out cubic smoothing: t = 3t^2 - 2t^3
        double t = 3.0 * rawT * rawT - 2.0 * rawT * rawT * rawT;
        double u = 1.0 - t;

        CGFloat x = u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x;
        CGFloat y = u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y;

        [NSThread sleepForTimeInterval:interval];
        [self postDigitizerEventAtX:x y:y touch:YES isStart:NO];
    }
    [self postDigitizerEventAtX:to.x y:to.y touch:NO isStart:NO];
}

// =============================================================================
// 4. Multi-Touch Pinch & Zoom (2 Simultaneous Hardware Fingers)
// =============================================================================

- (void)postMultiTouchFingersF1:(CGPoint)f1 f2:(CGPoint)f2 touch:(BOOL)touch isStart:(BOOL)isStart {
    if (!_BKSHIDServicesPostEvent || !_IOHIDEventCreateDigitizerEvent || !_IOHIDEventCreateDigitizerFingerEventWithUserData) {
        return;
    }

    @try {
        uint64_t timestamp = mach_absolute_time();
        CGSize screenSize = [UIScreen mainScreen].bounds.size;
        
        IOHIDFloat norm1X = (IOHIDFloat)fmax(0.0, fmin(1.0, f1.x / screenSize.width));
        IOHIDFloat norm1Y = (IOHIDFloat)fmax(0.0, fmin(1.0, f1.y / screenSize.height));
        IOHIDFloat norm2X = (IOHIDFloat)fmax(0.0, fmin(1.0, f2.x / screenSize.width));
        IOHIDFloat norm2Y = (IOHIDFloat)fmax(0.0, fmin(1.0, f2.y / screenSize.height));

        uint32_t eventMask = kIOHIDDigitizerEventPosition;
        if (isStart || !touch) eventMask |= (kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch);

        IOHIDEventRef parentEvent = _IOHIDEventCreateDigitizerEvent(
            kCFAllocatorDefault, timestamp,
            kIOHIDDigitizerTransducerTypeFinger,
            0, 2, eventMask, 0,
            (norm1X + norm2X) / 2.0, (norm1Y + norm2Y) / 2.0, 0.0, 0.0, 0.0,
            touch, touch, 0
        );

        IOHIDEventRef finger1 = _IOHIDEventCreateDigitizerFingerEventWithUserData(
            kCFAllocatorDefault, timestamp,
            1, 10, eventMask,
            norm1X, norm1Y, 0.0,
            touch ? 1.0 : 0.0, 0.0,
            touch, touch, 0, NULL
        );

        IOHIDEventRef finger2 = _IOHIDEventCreateDigitizerFingerEventWithUserData(
            kCFAllocatorDefault, timestamp,
            2, 20, eventMask,
            norm2X, norm2Y, 0.0,
            touch ? 1.0 : 0.0, 0.0,
            touch, touch, 0, NULL
        );

        if (parentEvent && finger1 && finger2) {
            if (_IOHIDEventSetSenderID) {
                _IOHIDEventSetSenderID(parentEvent, 0xdefac83fa1100000ULL);
                _IOHIDEventSetSenderID(finger1, 0xdefac83fa1100000ULL);
                _IOHIDEventSetSenderID(finger2, 0xdefac83fa1100000ULL);
            }
            if (_IOHIDEventSetIntegerValue) {
                _IOHIDEventSetIntegerValue(parentEvent, kIOHIDDigitizerEventFieldChildEventMask, eventMask);
            }
            if (_IOHIDEventAppendEvent) {
                _IOHIDEventAppendEvent(parentEvent, finger1);
                _IOHIDEventAppendEvent(parentEvent, finger2);
            }
            if (_hidSystemClient && _IOHIDEventSystemClientDispatchEvent) {
                _IOHIDEventSystemClientDispatchEvent(_hidSystemClient, parentEvent);
            }
            if (_BKSHIDServicesPostEvent) {
                _BKSHIDServicesPostEvent(parentEvent);
            }
            CFRelease(finger1);
            CFRelease(finger2);
            CFRelease(parentEvent);
        }
    } @catch (NSException *e) {
    }
}

- (void)sendPinchAtCenter:(CGPoint)center scale:(CGFloat)scale duration:(NSTimeInterval)duration {
    CGFloat baseRadius = 120.0;
    CGFloat targetRadius = baseRadius * scale;
    if (targetRadius < 20.0) targetRadius = 20.0;

    CGPoint f1Start = CGPointMake(center.x - baseRadius, center.y);
    CGPoint f1End   = CGPointMake(center.x - targetRadius, center.y);
    CGPoint f2Start = CGPointMake(center.x + baseRadius, center.y);
    CGPoint f2End   = CGPointMake(center.x + targetRadius, center.y);

    [self sendMultiTouchPinchWithFinger1Start:f1Start end:f1End finger2Start:f2Start end:f2End duration:duration];
}

- (void)sendMultiTouchPinchWithFinger1Start:(CGPoint)f1Start end:(CGPoint)f1End finger2Start:(CGPoint)f2Start end:(CGPoint)f2End duration:(NSTimeInterval)duration {
    NSTimeInterval dur = (duration <= 0) ? 0.4 : duration;
    int steps = (int)(dur * 60.0);
    if (steps < 10) steps = 10;

    [self postMultiTouchFingersF1:f1Start f2:f2Start touch:YES isStart:YES];
    NSTimeInterval interval = dur / (double)steps;

    for (int i = 1; i <= steps; ++i) {
        double t = (double)i / (double)steps;
        CGPoint f1Curr = CGPointMake(f1Start.x + (f1End.x - f1Start.x) * t, f1Start.y + (f1End.y - f1Start.y) * t);
        CGPoint f2Curr = CGPointMake(f2Start.x + (f2End.x - f2Start.x) * t, f2Start.y + (f2End.y - f2Start.y) * t);
        
        [NSThread sleepForTimeInterval:interval];
        [self postMultiTouchFingersF1:f1Curr f2:f2Curr touch:YES isStart:NO];
    }

    [self postMultiTouchFingersF1:f1End f2:f2End touch:NO isStart:NO];
}

// =============================================================================
// 5. Hardware Buttons & Keyboard Typing
// =============================================================================

- (void)sendKeyEventWithUsagePage:(uint32_t)usagePage usage:(uint32_t)usage down:(BOOL)down {
    if (!_IOHIDEventCreateKeyboardEvent) return;
    @try {
        uint64_t timestamp = mach_absolute_time();
        IOHIDEventRef event = _IOHIDEventCreateKeyboardEvent(kCFAllocatorDefault, timestamp, usagePage, usage, down, 0);
        if (event) {
            if (_IOHIDEventSetSenderID) {
                _IOHIDEventSetSenderID(event, 0xdefac83fa1100000ULL);
            }
            if (_hidSystemClient && _IOHIDEventSystemClientDispatchEvent) {
                _IOHIDEventSystemClientDispatchEvent(_hidSystemClient, event);
            }
            if (_BKSHIDServicesPostEvent) {
                _BKSHIDServicesPostEvent(event);
            }
            CFRelease(event);
        }
    } @catch (NSException *e) {
    }
}

- (void)sendText:(NSString *)text {
    if (!text) return;
    for (NSUInteger i = 0; i < [text length]; i++) {
        unichar c = [text characterAtIndex:i];
        uint32_t usage = 0;
        BOOL shift = NO;

        if (c >= 'a' && c <= 'z') usage = 0x04 + (c - 'a');
        else if (c >= 'A' && c <= 'Z') { usage = 0x04 + (c - 'A'); shift = YES; }
        else if (c >= '1' && c <= '9') usage = 0x1E + (c - '1');
        else if (c == '0') usage = 0x27;
        else if (c == ' ') usage = 0x2C;
        else if (c == '\n') usage = 0x28;
        else if (c == '\b') usage = 0x2A;

        if (usage != 0) {
            if (shift) [self sendKeyEventWithUsagePage:0x07 usage:0xE1 down:YES];
            [self sendKeyEventWithUsagePage:0x07 usage:usage down:YES];
            [NSThread sleepForTimeInterval:0.015];
            [self sendKeyEventWithUsagePage:0x07 usage:usage down:NO];
            if (shift) [self sendKeyEventWithUsagePage:0x07 usage:0xE1 down:NO];
            [NSThread sleepForTimeInterval:0.015];
        }
    }
}

- (void)sendHardwareButton:(NSString *)buttonName {
    uint32_t usagePage = 0x0C; // Consumer Page
    uint32_t usage = 0;

    if ([buttonName isEqualToString:@"home"]) usage = 0x40; // Menu / Home
    else if ([buttonName isEqualToString:@"power"] || [buttonName isEqualToString:@"lock"]) usage = 0x30;
    else if ([buttonName isEqualToString:@"volume_up"]) usage = 0xE9;
    else if ([buttonName isEqualToString:@"volume_down"]) usage = 0xEA;

    if (usage != 0) {
        [self sendKeyEventWithUsagePage:usagePage usage:usage down:YES];
        [NSThread sleepForTimeInterval:0.08];
        [self sendKeyEventWithUsagePage:usagePage usage:usage down:NO];
    }
}

@end

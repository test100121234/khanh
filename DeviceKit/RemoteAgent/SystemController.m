#import "SystemController.h"
#import "ApplePrivateHeaders.h"
#import "HIDEventSynthesizer.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <os/proc.h>

@implementation SystemController

+ (instancetype)sharedInstance {
    static SystemController *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SystemController alloc] init];
    });
    return instance;
}

// =============================================================================
// 1. Clipboard Management
// =============================================================================

- (NSString *)getClipboardText {
    __block NSString *result = @"";
    dispatch_block_t block = ^{
        @try {
            result = [UIPasteboard generalPasteboard].string ?: @"";
        } @catch (NSException *e) {
            result = @"";
        }
    };

    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
    return result;
}

- (void)setClipboardText:(NSString *)text {
    if (!text) return;
    dispatch_block_t block = ^{
        @try {
            [UIPasteboard generalPasteboard].string = text;
        } @catch (NSException *e) {
        }
    };

    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
}

// =============================================================================
// 2. Application Lifecycle, Background Switching & Deep Links
// =============================================================================

- (BOOL)openBundleID:(NSString *)bundleID {
    if (!bundleID || bundleID.length == 0) return NO;

    Class LSWorkspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (LSWorkspaceClass) {
        id workspace = [LSWorkspaceClass performSelector:NSSelectorFromString(@"defaultWorkspace")];
        SEL openSel = NSSelectorFromString(@"openApplicationWithBundleID:");
        if (workspace && [workspace respondsToSelector:openSel]) {
            NSMethodSignature *sig = [workspace methodSignatureForSelector:openSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:workspace];
            [inv setSelector:openSel];
            [inv setArgument:&bundleID atIndex:2];
            [inv invoke];
            BOOL ret = NO;
            [inv getReturnValue:&ret];
            if (ret) return YES;
        }
    }

    NSString *scheme = [NSString stringWithFormat:@"%@://", bundleID];
    return [self openURLString:scheme];
}

- (BOOL)activateAppWithBundleID:(NSString *)bundleID {
    return [self openBundleID:bundleID];
}

- (BOOL)backgroundAppWithDuration:(NSTimeInterval)duration bundleID:(nullable NSString *)bundleID {
    // 1. Send Home button to push app to background
    [[HIDEventSynthesizer sharedInstance] sendHardwareButton:@"home"];
    
    // 2. Wait in background state
    NSTimeInterval bgDur = (duration <= 0) ? 2.0 : duration;
    [NSThread sleepForTimeInterval:bgDur];

    // 3. Reactivate app if bundleID specified
    if (bundleID && bundleID.length > 0) {
        return [self openBundleID:bundleID];
    }
    return YES;
}

- (BOOL)openURLString:(NSString *)urlString {
    if (!urlString) return NO;
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return NO;

    Class LSWorkspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (LSWorkspaceClass) {
        id workspace = [LSWorkspaceClass performSelector:NSSelectorFromString(@"defaultWorkspace")];
        SEL openURLSel = NSSelectorFromString(@"openURL:");
        if (workspace && [workspace respondsToSelector:openURLSel]) {
            NSMethodSignature *sig = [workspace methodSignatureForSelector:openURLSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:workspace];
            [inv setSelector:openURLSel];
            [inv setArgument:&url atIndex:2];
            [inv invoke];
            BOOL ret = NO;
            [inv getReturnValue:&ret];
            if (ret) return YES;
        }
    }

    __block BOOL success = NO;
    dispatch_block_t openBlock = ^{
        if ([[UIApplication sharedApplication] canOpenURL:url]) {
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:^(BOOL successOpen) {
                success = successOpen;
            }];
            success = YES;
        }
    };

    if ([NSThread isMainThread]) {
        openBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), openBlock);
    }

    return success;
}

- (void)terminateAppWithBundleID:(NSString *)bundleID {
    if (!bundleID) return;
    void *handle = dlopen("/System/Library/PrivateFrameworks/AssertionServices.framework/AssertionServices", RTLD_NOW | RTLD_GLOBAL);
    if (!handle) {
        handle = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW | RTLD_GLOBAL);
    }
    if (handle) {
        BKSTerminateApplicationForReasonAndReportWithDescriptionFunc terminateFunc = 
            (BKSTerminateApplicationForReasonAndReportWithDescriptionFunc)dlsym(handle, "BKSTerminateApplicationForReasonAndReportWithDescription");
        if (terminateFunc) {
            terminateFunc(bundleID, 1, false, @"Remote Automation Termination");
        }
    }
}

// =============================================================================
// 3. System Alert Auto-Handling (Permission Modals, Location, Camera, Push)
// =============================================================================

- (void)acceptSystemAlert {
    // 1. Try sending Enter/Return key event
    [[HIDEventSynthesizer sharedInstance] sendText:@"\n"];
    
    // 2. Also simulate tap on standard iOS permission alert "Allow" / "OK" button location (bottom right of center modal)
    CGSize size = [UIScreen mainScreen].bounds.size;
    CGFloat allowX = size.width * 0.70;
    CGFloat allowY = size.height * 0.58;
    [[HIDEventSynthesizer sharedInstance] sendTapAtX:allowX y:allowY duration:0.05];
}

- (void)dismissSystemAlert {
    // 1. Simulate tap on standard iOS permission alert "Don't Allow" / "Cancel" button location (bottom left of center modal)
    CGSize size = [UIScreen mainScreen].bounds.size;
    CGFloat cancelX = size.width * 0.30;
    CGFloat cancelY = size.height * 0.58;
    [[HIDEventSynthesizer sharedInstance] sendTapAtX:cancelX y:cancelY duration:0.05];
}

// =============================================================================
// 4. System Telemetry & Protection
// =============================================================================

- (void)setScreenBrightness:(CGFloat)brightness {
    CGFloat clamped = fmaxf(0.0f, fminf(1.0f, (float)brightness));
    dispatch_block_t bBlock = ^{
        [UIScreen mainScreen].brightness = clamped;
    };
    if ([NSThread isMainThread]) {
        bBlock();
    } else {
        dispatch_async(dispatch_get_main_queue(), bBlock);
    }
}

- (CGFloat)getScreenBrightness {
    __block CGFloat b = 1.0;
    dispatch_block_t bBlock = ^{
        b = [UIScreen mainScreen].brightness;
    };
    if ([NSThread isMainThread]) {
        bBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), bBlock);
    }
    return b;
}

- (NSDictionary *)getSystemTelemetry {
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
    float batteryLevel = [UIDevice currentDevice].batteryLevel;
    UIDeviceBatteryState batteryState = [UIDevice currentDevice].batteryState;
    NSProcessInfoThermalState thermalState = [NSProcessInfo processInfo].thermalState;
    CGFloat brightness = [self getScreenBrightness];

    struct mach_task_basic_info info;
    mach_msg_type_number_t size = MACH_TASK_BASIC_INFO_COUNT;
    kern_return_t kerr = task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &size);
    double residentMemoryMB = (kerr == KERN_SUCCESS) ? ((double)info.resident_size / (1024.0 * 1024.0)) : 0.0;

    size_t availableMemoryBytes = 0;
    if (&os_proc_available_memory != NULL) {
        availableMemoryBytes = os_proc_available_memory();
    }
    double availableMemoryMB = (double)availableMemoryBytes / (1024.0 * 1024.0);

    return @{
        @"battery_level": @(batteryLevel),
        @"battery_state": @((int)batteryState),
        @"thermal_state": @((int)thermalState),
        @"memory_usage_mb": @(residentMemoryMB),
        @"available_memory_mb": @(availableMemoryMB),
        @"screen_brightness": @(brightness),
        @"system_uptime": @([[NSProcessInfo processInfo] systemUptime]),
        @"os_version": [[UIDevice currentDevice] systemVersion] ?: @"18.0"
    };
}

@end

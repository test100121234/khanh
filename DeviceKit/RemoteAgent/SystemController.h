#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface SystemController : NSObject

+ (instancetype)sharedInstance;

// 1. Clipboard Management
- (NSString *)getClipboardText;
- (void)setClipboardText:(NSString *)text;

// 2. Application Lifecycle & Deep Link Routing
- (BOOL)openBundleID:(NSString *)bundleID;
- (BOOL)openURLString:(NSString *)urlString;
- (void)terminateAppWithBundleID:(NSString *)bundleID;
- (BOOL)backgroundAppWithDuration:(NSTimeInterval)duration bundleID:(nullable NSString *)bundleID;
- (BOOL)activateAppWithBundleID:(NSString *)bundleID;

// 3. System Alerts Handling
- (void)acceptSystemAlert;
- (void)dismissSystemAlert;

// 4. System Telemetry & Protection
- (NSDictionary *)getSystemTelemetry;
- (void)setScreenBrightness:(CGFloat)brightness;
- (CGFloat)getScreenBrightness;

@end

NS_ASSUME_NONNULL_END

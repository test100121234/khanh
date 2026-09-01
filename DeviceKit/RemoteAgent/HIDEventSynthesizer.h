#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface HIDEventSynthesizer : NSObject

+ (instancetype)sharedInstance;

// 1. Precision Coordinate Tap & Long Press
- (void)sendTapAtX:(CGFloat)x y:(CGFloat)y duration:(NSTimeInterval)duration;
- (void)sendDoubleTapAtX:(CGFloat)x y:(CGFloat)y;
- (void)sendLongPressAtX:(CGFloat)x y:(CGFloat)y duration:(NSTimeInterval)duration;

// 2. Hardware Button Simulation (Home, Power/Lock, Volume Up/Down)
- (void)sendHardwareButton:(NSString *)buttonName;
- (void)sendText:(NSString *)text;

// 3. Human-like Trajectory Swipe (W3C Actions & Bezier Curves for Anti-Bot Bypass)
- (void)sendSwipeFrom:(CGPoint)from to:(CGPoint)to duration:(NSTimeInterval)duration;
- (void)sendHumanSwipeFrom:(CGPoint)from to:(CGPoint)to duration:(NSTimeInterval)duration curviness:(CGFloat)curviness;

// 4. Multi-Touch Gestures (Pinch-to-Zoom / Zoom In / Zoom Out)
- (void)sendPinchAtCenter:(CGPoint)center scale:(CGFloat)scale duration:(NSTimeInterval)duration;
- (void)sendMultiTouchPinchWithFinger1Start:(CGPoint)f1Start end:(CGPoint)f1End finger2Start:(CGPoint)f2Start end:(CGPoint)f2End duration:(NSTimeInterval)duration;

@end

NS_ASSUME_NONNULL_END

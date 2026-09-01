#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SilentAudioQueue : NSObject

+ (instancetype)sharedInstance;

- (BOOL)start;
- (void)stop;
- (BOOL)isRunning;

@end

NS_ASSUME_NONNULL_END

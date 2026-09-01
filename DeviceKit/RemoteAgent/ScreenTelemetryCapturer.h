#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

@interface ScreenTelemetryCapturer : NSObject

+ (instancetype)sharedInstance;

- (nullable NSData *)captureSingleHardwareJPEGWithQuality:(float)quality;

@end

NS_ASSUME_NONNULL_END

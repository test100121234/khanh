#import "ScreenTelemetryCapturer.h"
#import <UIKit/UIKit.h>
#import <IOSurface/IOSurfaceRef.h>
#import <mach/mach_time.h>

// Private CoreGraphics / UIKit SPI for fast screen extraction
OBJC_EXPORT CGImageRef UIGetScreenImage(void);

struct CompressionContext {
    __unsafe_unretained NSMutableData *outputData;
    dispatch_semaphore_t semaphore;
};

static void VTCompressionOutputCallback(void *outputCallbackRefCon,
                                        void *sourceFrameRefCon,
                                        OSStatus status,
                                        VTEncodeInfoFlags infoFlags,
                                        CMSampleBufferRef sampleBuffer) {
    struct CompressionContext *ctx = (struct CompressionContext *)outputCallbackRefCon;
    if (status == noErr && sampleBuffer) {
        CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
        if (blockBuffer) {
            size_t lengthAtOffset, totalLength;
            char *dataPointer;
            if (CMBlockBufferGetDataPointer(blockBuffer, 0, &lengthAtOffset, &totalLength, &dataPointer) == noErr) {
                [ctx->outputData appendBytes:dataPointer length:totalLength];
            }
        }
    }
    dispatch_semaphore_signal(ctx->semaphore);
}

@implementation ScreenTelemetryCapturer {
    VTCompressionSessionRef _compressionSession;
    int32_t _cachedWidth;
    int32_t _cachedHeight;
    float _cachedQuality;
    CVPixelBufferPoolRef _bufferPool;
    dispatch_semaphore_t _lock;
}

+ (instancetype)sharedInstance {
    static ScreenTelemetryCapturer *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ScreenTelemetryCapturer alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = dispatch_semaphore_create(1);
        _cachedWidth = 0;
        _cachedHeight = 0;
        _cachedQuality = -1.0f;
    }
    return self;
}

- (void)dealloc {
    [self destroySession];
}

- (void)destroySession {
    if (_compressionSession) {
        VTCompressionSessionInvalidate(_compressionSession);
        CFRelease(_compressionSession);
        _compressionSession = NULL;
    }
    if (_bufferPool) {
        CVPixelBufferPoolRelease(_bufferPool);
        _bufferPool = NULL;
    }
}

- (BOOL)ensureCompressionSessionForWidth:(int32_t)width height:(int32_t)height quality:(float)quality {
    if (_compressionSession && _cachedWidth == width && _cachedHeight == height && fabs(_cachedQuality - quality) < 0.01) {
        return YES;
    }

    [self destroySession];

    _cachedWidth = width;
    _cachedHeight = height;
    _cachedQuality = quality;

    OSStatus status = VTCompressionSessionCreate(kCFAllocatorDefault,
                                                 width,
                                                 height,
                                                 kCMVideoCodecType_JPEG,
                                                 NULL, NULL, NULL,
                                                 VTCompressionOutputCallback,
                                                 NULL, // set dynamically per frame
                                                 &_compressionSession);

    if (status != noErr || !_compressionSession) {
        return NO;
    }

    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_Quality, (__bridge CFTypeRef)@(quality));
    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFTypeRef)@(1));

    // Initialize reusable pixel buffer pool
    NSDictionary *poolAttributes = @{
        (id)kCVPixelBufferPoolMinimumBufferCountKey: @2
    };
    NSDictionary *pixelBufferAttributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @(width),
        (id)kCVPixelBufferHeightKey: @(height),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };

    CVPixelBufferPoolCreate(kCFAllocatorDefault,
                            (__bridge CFDictionaryRef)poolAttributes,
                            (__bridge CFDictionaryRef)pixelBufferAttributes,
                            &_bufferPool);

    return YES;
}

- (CVPixelBufferRef)createPixelBufferFromScreen {
    CGImageRef screenImage = NULL;
    
    if (&UIGetScreenImage != NULL) {
        screenImage = UIGetScreenImage();
    }
    
    if (!screenImage) {
        dispatch_block_t drawBlock = ^{
            CGRect bounds = [UIScreen mainScreen].bounds;
            CGFloat scale = [UIScreen mainScreen].scale;
            UIGraphicsBeginImageContextWithOptions(bounds.size, NO, scale);
            UIWindow *keyWindow = [UIApplication sharedApplication].keyWindow;
            if (!keyWindow && [UIApplication sharedApplication].windows.count > 0) {
                keyWindow = [UIApplication sharedApplication].windows.firstObject;
            }
            [keyWindow drawViewHierarchyInRect:bounds afterScreenUpdates:NO];
            UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
            if (image) {
                screenImage = CGImageCreateCopy(image.CGImage);
            }
        };
        if ([NSThread isMainThread]) {
            drawBlock();
        } else {
            dispatch_sync(dispatch_get_main_queue(), drawBlock);
        }
    }
    
    if (!screenImage) return NULL;

    size_t width = CGImageGetWidth(screenImage);
    size_t height = CGImageGetHeight(screenImage);

    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn status = kCVReturnError;

    if (_bufferPool) {
        status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _bufferPool, &pixelBuffer);
    }

    if (status != kCVReturnSuccess || !pixelBuffer) {
        NSDictionary *options = @{
            (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
            (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
        };
        status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                     kCVPixelFormatType_32BGRA,
                                     (__bridge CFDictionaryRef)options,
                                     &pixelBuffer);
    }

    if (status != kCVReturnSuccess || !pixelBuffer) {
        CGImageRelease(screenImage);
        return NULL;
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    void *pxdata = CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);

    CGColorSpaceRef rgbColorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pxdata, width, height, 8, bytesPerRow,
                                                 rgbColorSpace,
                                                 kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), screenImage);
    
    CGColorSpaceRelease(rgbColorSpace);
    CGContextRelease(context);
    CGImageRelease(screenImage);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

    return pixelBuffer;
}

- (nullable NSData *)captureSingleHardwareJPEGWithQuality:(float)quality {
    dispatch_semaphore_wait(_lock, DISPATCH_TIME_FOREVER);

    CVPixelBufferRef pixelBuffer = [self createPixelBufferFromScreen];
    if (!pixelBuffer) {
        dispatch_semaphore_signal(_lock);
        return nil;
    }

    int32_t width = (int32_t)CVPixelBufferGetWidth(pixelBuffer);
    int32_t height = (int32_t)CVPixelBufferGetHeight(pixelBuffer);

    if (![self ensureCompressionSessionForWidth:width height:height quality:quality]) {
        CVPixelBufferRelease(pixelBuffer);
        dispatch_semaphore_signal(_lock);
        return nil;
    }

    NSMutableData *jpegData = [NSMutableData data];
    struct CompressionContext ctx;
    ctx.outputData = jpegData;
    ctx.semaphore = dispatch_semaphore_create(0);

    CMTime presentationTimeStamp = CMTimeMake(mach_absolute_time(), 1000000000);
    
    // Encode frame with custom callback reference context
    VTCompressionSessionEncodeFrameWithOutputHandler(_compressionSession,
                                                     pixelBuffer,
                                                     presentationTimeStamp,
                                                     kCMTimeInvalid,
                                                     NULL,
                                                     NULL,
                                                     ^(OSStatus status, VTEncodeInfoFlags infoFlags, CMSampleBufferRef sampleBuffer) {
        if (status == noErr && sampleBuffer) {
            CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
            if (blockBuffer) {
                size_t lengthAtOffset, totalLength;
                char *dataPointer;
                if (CMBlockBufferGetDataPointer(blockBuffer, 0, &lengthAtOffset, &totalLength, &dataPointer) == noErr) {
                    [jpegData appendBytes:dataPointer length:totalLength];
                }
            }
        }
        dispatch_semaphore_signal(ctx.semaphore);
    });

    VTCompressionSessionCompleteFrames(_compressionSession, kCMTimeInvalid);
    dispatch_semaphore_wait(ctx.semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(100 * NSEC_PER_MSEC)));

    CVPixelBufferRelease(pixelBuffer);
    dispatch_semaphore_signal(_lock);

    return (jpegData.length > 0) ? jpegData : nil;
}

@end

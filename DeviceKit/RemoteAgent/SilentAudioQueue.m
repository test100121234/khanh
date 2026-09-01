#import "SilentAudioQueue.h"

#define NUM_BUFFERS 3
#define BUFFER_SIZE 8192 // 8KB @ 8kHz = ~0.512s per buffer (reduces wakeups to ~2Hz)

@interface SilentAudioQueue () {
    AudioQueueRef _audioQueue;
    AudioQueueBufferRef _buffers[NUM_BUFFERS];
    BOOL _running;
    dispatch_source_t _heartbeatTimer;
    dispatch_queue_t _audioControlQueue;
}
@end

static void HandleOutputBuffer(void *aqData, AudioQueueRef inAQ, AudioQueueBufferRef inBuffer) {
    SilentAudioQueue *self = (__bridge SilentAudioQueue *)aqData;
    if (!self->_running) return;
    
    // Fill buffer with 0s (PCM silence) - 0.00% CPU consumption
    memset(inBuffer->mAudioData, 0, inBuffer->mAudioDataBytesCapacity);
    inBuffer->mAudioDataByteSize = inBuffer->mAudioDataBytesCapacity;
    AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, NULL);
}

@implementation SilentAudioQueue

+ (instancetype)sharedInstance {
    static SilentAudioQueue *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SilentAudioQueue alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _audioControlQueue = dispatch_queue_create("com.devicekit.audio.control", DISPATCH_QUEUE_SERIAL);
        [self registerSystemNotifications];
        [self startHeartbeatWatchdog];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (_heartbeatTimer) {
        dispatch_source_cancel(_heartbeatTimer);
        _heartbeatTimer = nil;
    }
}

- (void)registerSystemNotifications {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    AVAudioSession *session = [AVAudioSession sharedInstance];

    // 1. Audio Interruption Handling
    [nc addObserver:self selector:@selector(handleAudioInterruption:) name:AVAudioSessionInterruptionNotification object:session];
    
    // 2. Route Changes (Bluetooth / Lightning / Ethernet)
    [nc addObserver:self selector:@selector(handleRouteChange:) name:AVAudioSessionRouteChangeNotification object:session];
    
    // 3. iOS 18 mediaserverd reset recovery (Critical for 24/7 stability)
    [nc addObserver:self selector:@selector(handleMediaServerReset:) name:AVAudioSessionMediaServicesWereResetNotification object:session];
    [nc addObserver:self selector:@selector(handleMediaServerLost:) name:AVAudioSessionMediaServicesWereLostNotification object:session];

    // 4. Memory pressure handling
    [nc addObserver:self selector:@selector(handleMemoryWarning:) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
}

- (void)startHeartbeatWatchdog {
    // Check every 10 seconds if AudioQueue is alive; restart automatically if stalled
    _heartbeatTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _audioControlQueue);
    dispatch_source_set_timer(_heartbeatTimer, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), 10 * NSEC_PER_SEC, 1 * NSEC_PER_SEC);
    
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_heartbeatTimer, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (strongSelf->_running) {
            UInt32 isRunning = 0;
            UInt32 size = sizeof(isRunning);
            if (strongSelf->_audioQueue) {
                OSStatus status = AudioQueueGetProperty(strongSelf->_audioQueue, kAudioQueueProperty_IsRunning, &isRunning, &size);
                if (status != noErr || !isRunning) {
                    [strongSelf restartQueue];
                }
            } else {
                [strongSelf restartQueue];
            }
        }
    });
    
    dispatch_resume(_heartbeatTimer);
}

- (void)handleAudioInterruption:(NSNotification *)notification {
    dispatch_async(_audioControlQueue, ^{
        NSDictionary *info = notification.userInfo;
        AVAudioSessionInterruptionType type = [info[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];

        if (type == AVAudioSessionInterruptionTypeEnded) {
            [self start];
        }
    });
}

- (void)handleRouteChange:(NSNotification *)notification {
    dispatch_async(_audioControlQueue, ^{
        if (self->_running && self->_audioQueue) {
            AudioQueueStart(self->_audioQueue, NULL);
        }
    });
}

- (void)handleMediaServerReset:(NSNotification *)notification {
    // When mediaserverd crashes on iOS 18, all AudioQueues are destroyed. Recreate completely.
    dispatch_async(_audioControlQueue, ^{
        [self stop];
        [self start];
    });
}

- (void)handleMediaServerLost:(NSNotification *)notification {
    dispatch_async(_audioControlQueue, ^{
        self->_running = NO;
        self->_audioQueue = NULL;
    });
}

- (void)handleMemoryWarning:(NSNotification *)notification {
    // Zero-cost acknowledgment of memory warning
}

- (void)restartQueue {
    [self stop];
    [self start];
}

- (BOOL)isRunning {
    return _running;
}

- (BOOL)start {
    __block BOOL success = YES;
    dispatch_block_t startBlock = ^{
        if (self->_running && self->_audioQueue) {
            AudioQueueStart(self->_audioQueue, NULL);
            return;
        }

        NSError *error = nil;
        AVAudioSession *session = [AVAudioSession sharedInstance];
        [session setCategory:AVAudioSessionCategoryPlayback
                 withOptions:AVAudioSessionCategoryOptionMixWithOthers | AVAudioSessionCategoryOptionAllowBluetooth | AVAudioSessionCategoryOptionAllowAirPlay
                       error:&error];
        [session setActive:YES error:&error];

        AudioStreamBasicDescription format;
        memset(&format, 0, sizeof(format));
        format.mSampleRate       = 8000.0;
        format.mFormatID         = kAudioFormatLinearPCM;
        format.mFormatFlags      = kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
        format.mBytesPerPacket   = 2;
        format.mFramesPerPacket  = 1;
        format.mBytesPerFrame    = 2;
        format.mChannelsPerFrame = 1;
        format.mBitsPerChannel   = 16;

        OSStatus status = AudioQueueNewOutput(&format, HandleOutputBuffer, (__bridge void *)self,
                                              CFRunLoopGetCurrent(), kCFRunLoopCommonModes, 0, &self->_audioQueue);
        if (status != noErr) {
            success = NO;
            return;
        }

        self->_running = YES;

        for (int i = 0; i < NUM_BUFFERS; ++i) {
            AudioQueueAllocateBuffer(self->_audioQueue, BUFFER_SIZE, &self->_buffers[i]);
            memset(self->_buffers[i]->mAudioData, 0, BUFFER_SIZE);
            self->_buffers[i]->mAudioDataByteSize = BUFFER_SIZE;
            AudioQueueEnqueueBuffer(self->_audioQueue, self->_buffers[i], 0, NULL);
        }

        status = AudioQueueStart(self->_audioQueue, NULL);
        success = (status == noErr);
    };

    if (dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL) == dispatch_queue_get_label(_audioControlQueue)) {
        startBlock();
    } else {
        dispatch_sync(_audioControlQueue, startBlock);
    }
    return success;
}

- (void)stop {
    dispatch_block_t stopBlock = ^{
        if (!self->_running) return;
        self->_running = NO;
        if (self->_audioQueue) {
            AudioQueueStop(self->_audioQueue, YES);
            AudioQueueDispose(self->_audioQueue, YES);
            self->_audioQueue = NULL;
        }
    };

    if (dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL) == dispatch_queue_get_label(_audioControlQueue)) {
        stopBlock();
    } else {
        dispatch_sync(_audioControlQueue, stopBlock);
    }
}

@end

#import "AgentWebSocketServer.h"
#import "ScreenTelemetryCapturer.h"
#import "HIDEventSynthesizer.h"
#import "SystemController.h"
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <sys/socket.h>
#import <unistd.h>
#import <fcntl.h>
#import <CommonCrypto/CommonDigest.h>
#import <UIKit/UIKit.h>

static NSString *const kWebSocketGUID = @"258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
static NSString *const kDefaultSessionID = @"DEVICEKIT-SESSION-001";

@interface AgentWebSocketClient : NSObject
@property (nonatomic, assign) int socketFD;
@property (nonatomic, strong) dispatch_queue_t clientQueue;
@property (nonatomic, strong) dispatch_source_t readSource;
@property (nonatomic, strong) NSMutableData *readBuffer;
@property (nonatomic, assign) BOOL isWebSocket;
@property (nonatomic, assign) BOOL isHandshakeComplete;
@property (nonatomic, assign) NSTimeInterval lastActivityTimestamp;
- (instancetype)initWithSocket:(int)socket;
- (void)sendBinaryData:(NSData *)data;
- (void)sendTextMessage:(NSString *)text;
- (void)sendHTTPResponse:(int)statusCode statusText:(NSString *)statusText contentType:(NSString *)contentType body:(NSData *)body keepAlive:(BOOL)keepAlive;
- (void)close;
- (BOOL)isStaleWithTimeout:(NSTimeInterval)timeout;
@end

@implementation AgentWebSocketClient

- (instancetype)initWithSocket:(int)socket {
    self = [super init];
    if (self) {
        _socketFD = socket;
        _readBuffer = [NSMutableData data];
        _isWebSocket = NO;
        _isHandshakeComplete = NO;
        _lastActivityTimestamp = [NSDate timeIntervalSinceReferenceDate];
        _clientQueue = dispatch_queue_create("com.devicekit.client", DISPATCH_QUEUE_SERIAL);

        // 1. TCP_NODELAY for sub-millisecond latency
        int flag = 1;
        setsockopt(_socketFD, IPPROTO_TCP, TCP_NODELAY, (char *)&flag, sizeof(int));
        
        // 2. SO_NOSIGPIPE to prevent SIGPIPE signal crashes on abrupt client disconnect
        int noSigPipe = 1;
        setsockopt(_socketFD, SOL_SOCKET, SO_NOSIGPIPE, (void *)&noSigPipe, sizeof(noSigPipe));

        // 3. TCP Keepalive configuration for iOS 18 Wi-Fi power saving on Aruba APs
        int keepAlive = 1;
        setsockopt(_socketFD, SOL_SOCKET, SO_KEEPALIVE, (void *)&keepAlive, sizeof(keepAlive));
        int keepIdle = 10;
        setsockopt(_socketFD, IPPROTO_TCP, TCP_KEEPALIVE, (void *)&keepIdle, sizeof(keepIdle));

        // 4. Non-blocking mode
        int flags = fcntl(_socketFD, F_GETFL, 0);
        fcntl(_socketFD, F_SETFL, flags | O_NONBLOCK);

        [self setupReadSource];
    }
    return self;
}

- (void)setupReadSource {
    _readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, _socketFD, 0, _clientQueue);
    __weak typeof(self) weakSelf = self;
    
    dispatch_source_set_event_handler(_readSource, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        char buf[32768];
        ssize_t bytesRead = read(strongSelf->_socketFD, buf, sizeof(buf));
        if (bytesRead > 0) {
            strongSelf->_lastActivityTimestamp = [NSDate timeIntervalSinceReferenceDate];
            [strongSelf->_readBuffer appendBytes:buf length:bytesRead];
            [strongSelf processBuffer];
        } else if (bytesRead == 0 || (bytesRead < 0 && errno != EAGAIN && errno != EWOULDBLOCK)) {
            [strongSelf close];
        }
    });

    dispatch_source_set_cancel_handler(_readSource, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf && strongSelf->_socketFD > 0) {
            close(strongSelf->_socketFD);
            strongSelf->_socketFD = -1;
        }
    });

    dispatch_resume(_readSource);
}

- (BOOL)isStaleWithTimeout:(NSTimeInterval)timeout {
    return ([NSDate timeIntervalSinceReferenceDate] - _lastActivityTimestamp) > timeout;
}

- (void)processBuffer {
    if (!_isHandshakeComplete) {
        [self processInitialRequest];
        return;
    }
    if (_isWebSocket) {
        [self parseWebSocketFrames];
    } else {
        [self processInitialRequest];
    }
}

- (void)processInitialRequest {
    NSString *requestStr = [[NSString alloc] initWithData:_readBuffer encoding:NSUTF8StringEncoding];
    if (!requestStr || ![requestStr containsString:@"\r\n\r\n"]) return;

    if ([requestStr.lowercaseString containsString:@"upgrade: websocket"]) {
        _isWebSocket = YES;
        [self performWebSocketHandshakeWithRequest:requestStr];
        return;
    }

    [self handleHTTPRESTRequest:requestStr];
}

- (void)performWebSocketHandshakeWithRequest:(NSString *)requestStr {
    NSString *secKey = nil;
    NSArray *lines = [requestStr componentsSeparatedByString:@"\r\n"];
    for (NSString *line in lines) {
        if ([line.lowercaseString hasPrefix:@"sec-websocket-key:"]) {
            secKey = [[line substringFromIndex:18] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            break;
        }
    }

    if (!secKey) return;

    NSString *acceptKeyStr = [secKey stringByAppendingString:kWebSocketGUID];
    NSData *acceptKeyData = [acceptKeyStr dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char hash[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(acceptKeyData.bytes, (CC_LONG)acceptKeyData.length, hash);
    NSData *hashData = [NSData dataWithBytes:hash length:CC_SHA1_DIGEST_LENGTH];
    NSString *secWebSocketAccept = [hashData base64EncodedStringWithOptions:0];

    NSString *response = [NSString stringWithFormat:
                          @"HTTP/1.1 101 Switching Protocols\r\n"
                          "Upgrade: websocket\r\n"
                          "Connection: Upgrade\r\n"
                          "Sec-WebSocket-Accept: %@\r\n\r\n", secWebSocketAccept];

    NSData *resData = [response dataUsingEncoding:NSUTF8StringEncoding];
    write(_socketFD, resData.bytes, resData.length);

    _isHandshakeComplete = YES;
    NSRange range = [requestStr rangeOfString:@"\r\n\r\n"];
    NSUInteger headerEnd = range.location + range.length;
    if (_readBuffer.length > headerEnd) {
        [_readBuffer replaceBytesInRange:NSMakeRange(0, headerEnd) withBytes:NULL length:0];
        [self parseWebSocketFrames];
    } else {
        [_readBuffer setLength:0];
    }
}

- (void)handleW3CActions:(NSArray *)actions {
    if (!actions || ![actions isKindOfClass:[NSArray class]]) return;

    for (NSDictionary *actionMap in actions) {
        if (![actionMap isKindOfClass:[NSDictionary class]]) continue;
        NSArray *subActions = actionMap[@"actions"];
        if (!subActions || ![subActions isKindOfClass:[NSArray class]]) continue;

        CGPoint lastPos = CGPointZero;
        for (NSDictionary *act in subActions) {
            NSString *type = act[@"type"];
            if ([type isEqualToString:@"pointerMove"]) {
                CGFloat x = [act[@"x"] doubleValue];
                CGFloat y = [act[@"y"] doubleValue];
                lastPos = CGPointMake(x, y);
            } else if ([type isEqualToString:@"pointerDown"]) {
                [[HIDEventSynthesizer sharedInstance] sendTapAtX:lastPos.x y:lastPos.y duration:0.05];
            } else if ([type isEqualToString:@"pause"]) {
                NSTimeInterval pauseDur = [act[@"duration"] doubleValue] / 1000.0;
                if (pauseDur > 0) [NSThread sleepForTimeInterval:pauseDur];
            }
        }
    }
}

- (void)handleHTTPRESTRequest:(NSString *)requestStr {
    @try {
        NSArray *lines = [requestStr componentsSeparatedByString:@"\r\n"];
        if (lines.count == 0) return;

        NSString *requestLine = lines[0];
        NSArray *parts = [requestLine componentsSeparatedByString:@" "];
        if (parts.count < 2) return;

        NSString *method = parts[0];
        NSString *path = parts[1];

        // 1. CORS Preflight Support
        if ([method isEqualToString:@"OPTIONS"]) {
            [_readBuffer setLength:0];
            [self sendHTTPResponse:200 statusText:@"OK" contentType:@"text/plain" body:nil keepAlive:YES];
            return;
        }

        NSUInteger contentLength = 0;
        BOOL keepAlive = YES;
        for (NSString *line in lines) {
            if ([line.lowercaseString hasPrefix:@"content-length:"]) {
                contentLength = [[line substringFromIndex:15] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].integerValue;
            } else if ([line.lowercaseString hasPrefix:@"connection:"]) {
                if ([line.lowercaseString containsString:@"close"]) {
                    keepAlive = NO;
                }
            }
        }

        NSRange headerEndRange = [requestStr rangeOfString:@"\r\n\r\n"];
        NSUInteger totalHeaderLength = headerEndRange.location + 4;
        
        if (_readBuffer.length < totalHeaderLength + contentLength) {
            return;
        }

        NSDictionary *jsonBody = nil;
        if (contentLength > 0) {
            NSData *bodyData = [_readBuffer subdataWithRange:NSMakeRange(totalHeaderLength, contentLength)];
            if (bodyData.length > 0) {
                jsonBody = [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:nil];
            }
        }

        NSUInteger totalRequestLength = totalHeaderLength + contentLength;
        if (_readBuffer.length >= totalRequestLength) {
            [_readBuffer replaceBytesInRange:NSMakeRange(0, totalRequestLength) withBytes:NULL length:0];
        } else {
            [_readBuffer setLength:0];
        }

        // =====================================================================
        // Ultra-Grade Fake WDA Router (Session & Status)
        // =====================================================================
        if ([path isEqualToString:@"/status"] || [path isEqualToString:@"/wda/status"]) {
            NSDictionary *statusDict = @{
                @"value": @{
                    @"message": @"WebDriverAgent is ready to accept commands",
                    @"state": @"success",
                    @"os": @{
                        @"name": @"iOS",
                        @"version": [[UIDevice currentDevice] systemVersion] ?: @"18.0",
                        @"sdkVersion": [[UIDevice currentDevice] systemVersion] ?: @"18.0"
                    },
                    @"ios": @{
                        @"simulatorVersion": [NSNull null],
                        @"ip": @"0.0.0.0",
                        @"state": @"running"
                    },
                    @"ready": @YES
                },
                @"sessionId": [NSNull null],
                @"status": @0
            };
            [self sendJSONResponse:statusDict keepAlive:keepAlive];
        } else if ([path isEqualToString:@"/health"]) {
            [self sendJSONResponse:@{@"status": @"ok", @"agent": @"devicekit-headless-ios18"} keepAlive:keepAlive];
        } else if (([path isEqualToString:@"/session"] || [path isEqualToString:@"/session/"]) && [method isEqualToString:@"POST"]) {
            NSDictionary *sessionDict = @{
                @"value": @{
                    @"sessionId": kDefaultSessionID,
                    @"capabilities": @{
                        @"device": @"iphone",
                        @"browserName": @"WebDriverAgent Fake",
                        @"sdkVersion": [[UIDevice currentDevice] systemVersion] ?: @"18.0",
                        @"CFBundleIdentifier": @"hk.com.hsbc.enterprise.hsbchkrewards.local2",
                        @"platformName": @"iOS"
                    }
                },
                @"sessionId": kDefaultSessionID,
                @"status": @0
            };
            [self sendJSONResponse:sessionDict keepAlive:keepAlive];
        } else if ([path hasPrefix:@"/session"] && [method isEqualToString:@"DELETE"]) {
            [self sendJSONResponse:@{@"value": [NSNull null], @"sessionId": kDefaultSessionID, @"status": @0} keepAlive:keepAlive];
        } else if ([path containsString:@"/window/size"]) {
            CGSize size = [UIScreen mainScreen].bounds.size;
            NSDictionary *sizeDict = @{
                @"value": @{
                    @"width": @((int)size.width),
                    @"height": @((int)size.height)
                },
                @"sessionId": kDefaultSessionID,
                @"status": @0
            };
            [self sendJSONResponse:sizeDict keepAlive:keepAlive];
        } else if ([path containsString:@"/rotation"]) {
            [self sendJSONResponse:@{@"value": @{@"x": @0, @"y": @0, @"z": @0}, @"sessionId": kDefaultSessionID, @"status": @0} keepAlive:keepAlive];
        } else if ([path containsString:@"/screenshot"]) {
            NSData *jpegData = [[ScreenTelemetryCapturer sharedInstance] captureSingleHardwareJPEGWithQuality:0.2];
            NSString *base64 = jpegData ? [jpegData base64EncodedStringWithOptions:0] : @"";
            NSDictionary *resp = @{
                @"value": base64,
                @"sessionId": kDefaultSessionID,
                @"status": @0
            };
            [self sendJSONResponse:resp keepAlive:keepAlive];

        // =====================================================================
        // Touch & Gestures Router
        // =====================================================================
        } else if ([path containsString:@"/wda/tap"]) {
            CGFloat x = [jsonBody[@"x"] doubleValue];
            CGFloat y = [jsonBody[@"y"] doubleValue];
            NSTimeInterval dur = jsonBody[@"duration"] ? [jsonBody[@"duration"] doubleValue] : 0.05;
            [[HIDEventSynthesizer sharedInstance] sendTapAtX:x y:y duration:dur];
            [self sendJSONResponse:@{@"value": @YES, @"status": @0} keepAlive:keepAlive];
        } else if ([path containsString:@"/wda/doubleTap"]) {
            CGFloat x = [jsonBody[@"x"] doubleValue];
            CGFloat y = [jsonBody[@"y"] doubleValue];
            [[HIDEventSynthesizer sharedInstance] sendDoubleTapAtX:x y:y];
            [self sendJSONResponse:@{@"value": @YES, @"status": @0} keepAlive:keepAlive];
        } else if ([path containsString:@"/wda/touchAndHold"] || [path containsString:@"/wda/longPress"]) {
            CGFloat x = [jsonBody[@"x"] doubleValue];
            CGFloat y = [jsonBody[@"y"] doubleValue];
            NSTimeInterval dur = jsonBody[@"duration"] ? [jsonBody[@"duration"] doubleValue] : 1.0;
            [[HIDEventSynthesizer sharedInstance] sendLongPressAtX:x y:y duration:dur];
            [self sendJSONResponse:@{@"value": @YES, @"status": @0} keepAlive:keepAlive];
        } else if ([path containsString:@"/actions"]) {
            [self handleW3CActions:jsonBody[@"actions"]];
            [self sendJSONResponse:@{@"value": @YES, @"status": @0} keepAlive:keepAlive];
        } else if ([path containsString:@"/wda/human_swipe"] || [path containsString:@"/wda/dragfromtoforduration"] || [path containsString:@"/wda/swipe"]) {
            CGPoint from = CGPointMake([jsonBody[@"fromX"] ?: jsonBody[@"from_x"] doubleValue], [jsonBody[@"fromY"] ?: jsonBody[@"from_y"] doubleValue]);
            CGPoint to = CGPointMake([jsonBody[@"toX"] ?: jsonBody[@"to_x"] doubleValue], [jsonBody[@"toY"] ?: jsonBody[@"to_y"] doubleValue]);
            NSTimeInterval dur = jsonBody[@"duration"] ? [jsonBody[@"duration"] doubleValue] : 0.35;
            CGFloat curviness = jsonBody[@"curviness"] ? [jsonBody[@"curviness"] doubleValue] : 0.25;
            [[HIDEventSynthesizer sharedInstance] sendHumanSwipeFrom:from to:to duration:dur curviness:curviness];
            [self sendJSONResponse:@{@"value": @YES, @"status": @0} keepAlive:keepAlive];
        } else if ([path containsString:@"/wda/scroll"]) {
            CGSize size = [UIScreen mainScreen].bounds.size;
            NSString *dir = jsonBody[@"direction"] ?: @"down";
            if ([dir isEqualToString:@"down"]) {
                [[HIDEventSynthesizer sharedInstance] sendSwipeFrom:CGPointMake(size.width/2, size.height*0.7) to:CGPointMake(size.width/2, size.height*0.3) duration:0.3];
            } else if ([dir isEqualToString:@"up"]) {
                [[HIDEventSynthesizer sharedInstance] sendSwipeFrom:CGPointMake(size.width/2, size.height*0.3) to:CGPointMake(size.width/2, size.height*0.7) duration:0.3];
            } else if ([dir isEqualToString:@"left"]) {
                [[HIDEventSynthesizer sharedInstance] sendSwipeFrom:CGPointMake(size.width*0.8, size.height/2) to:CGPointMake(size.width*0.2, size.height/2) duration:0.3];
            } else if ([dir isEqualToString:@"right"]) {
                [[HIDEventSynthesizer sharedInstance] sendSwipeFrom:CGPointMake(size.width*0.2, size.height/2) to:CGPointMake(size.width*0.8, size.height/2) duration:0.3];
            }
            [self sendJSONResponse:@{@"value": @YES, @"status": @0} keepAlive:keepAlive];
        } else if ([path containsString:@"/wda/pinch"]) {
            CGPoint center = CGPointMake([jsonBody[@"x"] doubleValue], [jsonBody[@"y"] doubleValue]);
            if (center.x == 0 && center.y == 0) {
                CGSize size = [UIScreen mainScreen].bounds.size;
                center = CGPointMake(size.width / 2.0, size.height / 2.0);
            }
            CGFloat scale = [jsonBody[@"scale"] doubleValue];
            NSTimeInterval dur = jsonBody[@"duration"] ? [jsonBody[@"duration"] doubleValue] : 0.4;
            [[HIDEventSynthesizer sharedInstance] sendPinchAtCenter:center scale:scale duration:dur];
            [self sendJSONResponse:@{@"value": @YES, @"status": @0} keepAlive:keepAlive];

        // =====================================================================
        // Hardware, Keyboard, Alerts & App Lifecycle
        // =====================================================================
        } else if ([path containsString:@"/wda/homescreen"]) {
            [[HIDEventSynthesizer sharedInstance] sendHardwareButton:@"home"];
            [self sendJSONResponse:@{@"value": @YES, @"status": @0} keepAlive:keepAlive];
        } else if ([path containsString:@"/wda/lock"] || [path containsString:@"/wda/unlock"]) {
            [[HIDEventSynthesizer sharedInstance] sendHardwareButton:@"lock"];
            [self sendJSONResponse:@{@"value": @YES, @"status": @0} keepAlive:keepAlive];
        } else if ([path containsString:@"/wda/volume"]) {
            NSString *action = jsonBody[@"action"] ?: @"up";
            [[HIDEventSynthesizer sharedInstance] sendHardwareButton:[action isEqualToString:@"up"] ? @"volume_up" : @"volume_down"];
            [self sendJSONResponse:@{@"value": @YES, @"status": @0} keepAlive:keepAlive];
        } else if ([path containsString:@"/wda/alert/accept"] || [path containsString:@"/alert/accept"]) {
            [[SystemController sharedInstance] acceptSystemAlert];
            [self sendJSONResponse:@{@"value": @YES, @"status": @0} keepAlive:keepAlive];
        } else if ([path containsString:@"/wda/alert/dismiss"] || [path containsString:@"/alert/dismiss"]) {
            [[SystemController sharedInstance] dismissSystemAlert];
            [self sendJSONResponse:@{@"value": @YES, @"status": @0} keepAlive:keepAlive];
        } else if ([path containsString:@"/wda/alert/text"] || [path containsString:@"/alert/text"]) {
            [self sendJSONResponse:@{@"value": @"System Dialog", @"status": @0} keepAlive:keepAlive];
        } else if ([path containsString:@"/wda/apps/launch"] || [path containsString:@"/wda/app/activate"]) {
            NSString *bundleID = jsonBody[@"bundleId"] ?: jsonBody[@"bundle_id"];
            BOOL success = bundleID ? [[SystemController sharedInstance] openBundleID:bundleID] : NO;
            [self sendJSONResponse:@{@"value": @(success), @"status": @0} keepAlive:keepAlive];
        } else if ([path containsString:@"/wda/app/background"]) {
            NSTimeInterval dur = jsonBody[@"duration"] ? [jsonBody[@"duration"] doubleValue] : 2.0;
            NSString *bundleID = jsonBody[@"bundleId"] ?: jsonBody[@"bundle_id"];
            BOOL success = [[SystemController sharedInstance] backgroundAppWithDuration:dur bundleID:bundleID];
            [self sendJSONResponse:@{@"value": @(success), @"status": @0} keepAlive:keepAlive];
        } else if ([path containsString:@"/wda/apps/state"]) {
            [self sendJSONResponse:@{@"value": @4, @"sessionId": kDefaultSessionID, @"status": @0} keepAlive:keepAlive]; // 4 = Running Foreground
        } else if ([path containsString:@"/wda/deeplink"] || [path containsString:@"/wda/url"]) {
            NSString *url = jsonBody[@"url"];
            BOOL success = url ? [[SystemController sharedInstance] openURLString:url] : NO;
            [self sendJSONResponse:@{@"value": @(success), @"status": @0} keepAlive:keepAlive];
        } else if ([path containsString:@"/wda/apps/terminate"]) {
            NSString *bundleID = jsonBody[@"bundleId"] ?: jsonBody[@"bundle_id"];
            if (bundleID) {
                [[SystemController sharedInstance] terminateAppWithBundleID:bundleID];
            }
            [self sendJSONResponse:@{@"value": @YES, @"status": @0} keepAlive:keepAlive];
        } else if ([path containsString:@"/wda/keys"] || [path containsString:@"/wda/keyboard/dismiss"]) {
            NSString *text = jsonBody[@"text"];
            if (!text && [jsonBody[@"value"] isKindOfClass:[NSArray class]]) {
                text = [((NSArray *)jsonBody[@"value"]) componentsJoinedByString:@""];
            }
            if (text) {
                [[HIDEventSynthesizer sharedInstance] sendText:text];
            }
            [self sendJSONResponse:@{@"value": @YES, @"status": @0} keepAlive:keepAlive];
        } else if ([path containsString:@"/wda/clipboard"]) {
            if ([method isEqualToString:@"POST"]) {
                NSString *text = jsonBody[@"text"] ?: @"";
                [[SystemController sharedInstance] setClipboardText:text];
                [self sendJSONResponse:@{@"value": @YES, @"status": @0} keepAlive:keepAlive];
            } else {
                NSString *text = [[SystemController sharedInstance] getClipboardText];
                [self sendJSONResponse:@{@"value": text ?: @"", @"status": @0} keepAlive:keepAlive];
            }
        } else if ([path containsString:@"/wda/telemetry"]) {
            NSDictionary *tel = [[SystemController sharedInstance] getSystemTelemetry];
            [self sendJSONResponse:@{@"value": tel, @"status": @0} keepAlive:keepAlive];
        } else if ([path containsString:@"/wda/screen/brightness"]) {
            CGFloat b = [jsonBody[@"brightness"] doubleValue];
            [[SystemController sharedInstance] setScreenBrightness:b];
            [self sendJSONResponse:@{@"value": @YES, @"status": @0} keepAlive:keepAlive];
        } else if ([path containsString:@"/element"] || [path containsString:@"/elements"]) {
            // Fake dummy element for WDA clients probing elements
            [self sendJSONResponse:@{@"value": @{@"ELEMENT": @"fake-element-001"}, @"status": @0} keepAlive:keepAlive];
        } else if ([path containsString:@"/source"]) {
            // Minimal XML source hierarchy
            [self sendJSONResponse:@{@"value": @"<AppHierarchy><Window active=\"true\"/></AppHierarchy>", @"status": @0} keepAlive:keepAlive];
        } else {
            [self sendJSONResponse:@{@"value": @"OK", @"status": @0} keepAlive:keepAlive];
        }
    } @catch (NSException *ex) {
        [self sendJSONResponse:@{@"status": @(-1), @"error": ex.reason ?: @"Internal Server Error"} keepAlive:NO];
    }
}

- (void)sendJSONResponse:(NSDictionary *)dict keepAlive:(BOOL)keepAlive {
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
    [self sendHTTPResponse:200 statusText:@"OK" contentType:@"application/json" body:data keepAlive:keepAlive];
}

- (void)sendHTTPResponse:(int)statusCode statusText:(NSString *)statusText contentType:(NSString *)contentType body:(NSData *)body keepAlive:(BOOL)keepAlive {
    if (_socketFD <= 0) return;
    
    NSUInteger len = body ? body.length : 0;
    NSString *connHeader = keepAlive ? @"Connection: keep-alive\r\n" : @"Connection: close\r\n";
    NSString *header = [NSString stringWithFormat:
                        @"HTTP/1.1 %d %@\r\n"
                        "Content-Type: %@\r\n"
                        "Content-Length: %lu\r\n"
                        "Access-Control-Allow-Origin: *\r\n"
                        "Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS\r\n"
                        "Access-Control-Allow-Headers: *\r\n"
                        "%@"
                        "\r\n", statusCode, statusText, contentType, (unsigned long)len, connHeader];

    NSMutableData *resp = [NSMutableData data];
    [resp appendData:[header dataUsingEncoding:NSUTF8StringEncoding]];
    if (body) {
        [resp appendData:body];
    }
    write(_socketFD, resp.bytes, resp.length);
    
    if (!keepAlive) {
        [self close];
    }
}

// =============================================================================
// WebSocket Protocol Implementation
// =============================================================================

- (void)parseWebSocketFrames {
    while (_readBuffer.length >= 2) {
        const uint8_t *bytes = (const uint8_t *)_readBuffer.bytes;
        uint8_t opcode = bytes[0] & 0x0F;
        BOOL isMasked = (bytes[1] & 0x80) != 0;
        uint64_t payloadLen = bytes[1] & 0x7F;
        size_t headerLen = 2;

        if (payloadLen == 126) {
            if (_readBuffer.length < 4) return;
            payloadLen = (bytes[2] << 8) | bytes[3];
            headerLen = 4;
        } else if (payloadLen == 127) {
            if (_readBuffer.length < 10) return;
            payloadLen = 0;
            for (int i = 0; i < 8; i++) {
                payloadLen = (payloadLen << 8) | bytes[2 + i];
            }
            headerLen = 10;
        }

        size_t maskLen = isMasked ? 4 : 0;
        if (_readBuffer.length < headerLen + maskLen + payloadLen) {
            return;
        }

        const uint8_t *maskKey = bytes + headerLen;
        const uint8_t *payloadData = bytes + headerLen + maskLen;
        NSMutableData *unmasked = [NSMutableData dataWithLength:payloadLen];
        uint8_t *unmaskedBytes = (uint8_t *)unmasked.mutableBytes;

        for (uint64_t i = 0; i < payloadLen; i++) {
            unmaskedBytes[i] = isMasked ? (payloadData[i] ^ maskKey[i % 4]) : payloadData[i];
        }

        [_readBuffer replaceBytesInRange:NSMakeRange(0, headerLen + maskLen + payloadLen) withBytes:NULL length:0];

        if (opcode == 0x08) {
            [self close];
            return;
        } else if (opcode == 0x09) {
            [self sendPong:unmasked];
        } else if (opcode == 0x01) {
            NSString *msg = [[NSString alloc] initWithData:unmasked encoding:NSUTF8StringEncoding];
            [self handleTextMessage:msg];
        }
    }
}

- (void)sendPong:(NSData *)payload {
    NSMutableData *frame = [NSMutableData data];
    uint8_t b0 = 0x8A;
    [frame appendBytes:&b0 length:1];
    uint8_t b1 = (uint8_t)(payload.length & 0x7F);
    [frame appendBytes:&b1 length:1];
    [frame appendData:payload];
    write(_socketFD, frame.bytes, frame.length);
}

- (void)handleTextMessage:(NSString *)message {
    if (!message) return;
    
    @try {
        NSError *err = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:[message dataUsingEncoding:NSUTF8StringEncoding]
                                                             options:0
                                                               error:&err];
        if (!json || err) return;

        NSString *action = json[@"action"];

        if ([action isEqualToString:@"req_frame"]) {
            NSData *jpegData = [[ScreenTelemetryCapturer sharedInstance] captureSingleHardwareJPEGWithQuality:0.15];
            if (jpegData && jpegData.length > 0) {
                [self sendBinaryData:jpegData];
            }
            return;
        }

        if ([action isEqualToString:@"tap"]) {
            CGFloat x = [json[@"x"] doubleValue];
            CGFloat y = [json[@"y"] doubleValue];
            NSTimeInterval dur = json[@"duration"] ? [json[@"duration"] doubleValue] : 0.05;
            [[HIDEventSynthesizer sharedInstance] sendTapAtX:x y:y duration:dur];
            [self sendResponse:@{@"status": @"ok"}];
        } else if ([action isEqualToString:@"double_tap"]) {
            CGFloat x = [json[@"x"] doubleValue];
            CGFloat y = [json[@"y"] doubleValue];
            [[HIDEventSynthesizer sharedInstance] sendDoubleTapAtX:x y:y];
            [self sendResponse:@{@"status": @"ok"}];
        } else if ([action isEqualToString:@"long_press"]) {
            CGFloat x = [json[@"x"] doubleValue];
            CGFloat y = [json[@"y"] doubleValue];
            NSTimeInterval dur = json[@"duration"] ? [json[@"duration"] doubleValue] : 1.0;
            [[HIDEventSynthesizer sharedInstance] sendLongPressAtX:x y:y duration:dur];
            [self sendResponse:@{@"status": @"ok"}];
        } else if ([action isEqualToString:@"hardware_btn"]) {
            NSString *btn = json[@"button"];
            [[HIDEventSynthesizer sharedInstance] sendHardwareButton:btn];
            [self sendResponse:@{@"status": @"ok"}];
        } else if ([action isEqualToString:@"accept_alert"]) {
            [[SystemController sharedInstance] acceptSystemAlert];
            [self sendResponse:@{@"status": @"ok"}];
        } else if ([action isEqualToString:@"dismiss_alert"]) {
            [[SystemController sharedInstance] dismissSystemAlert];
            [self sendResponse:@{@"status": @"ok"}];
        } else if ([action isEqualToString:@"human_swipe"] || [action isEqualToString:@"swipe"]) {
            CGPoint from = CGPointMake([json[@"from_x"] doubleValue], [json[@"from_y"] doubleValue]);
            CGPoint to = CGPointMake([json[@"to_x"] doubleValue], [json[@"to_y"] doubleValue]);
            NSTimeInterval dur = json[@"duration"] ? [json[@"duration"] doubleValue] : 0.35;
            CGFloat curviness = json[@"curviness"] ? [json[@"curviness"] doubleValue] : 0.25;
            [[HIDEventSynthesizer sharedInstance] sendHumanSwipeFrom:from to:to duration:dur curviness:curviness];
            [self sendResponse:@{@"status": @"ok"}];
        } else if ([action isEqualToString:@"pinch"]) {
            CGPoint center = CGPointMake([json[@"x"] doubleValue], [json[@"y"] doubleValue]);
            CGFloat scale = [json[@"scale"] doubleValue];
            NSTimeInterval dur = json[@"duration"] ? [json[@"duration"] doubleValue] : 0.4;
            [[HIDEventSynthesizer sharedInstance] sendPinchAtCenter:center scale:scale duration:dur];
            [self sendResponse:@{@"status": @"ok"}];
        } else if ([action isEqualToString:@"type_text"]) {
            NSString *text = json[@"text"];
            [[HIDEventSynthesizer sharedInstance] sendText:text];
            [self sendResponse:@{@"status": @"ok"}];
        } else if ([action isEqualToString:@"set_clipboard"]) {
            NSString *text = json[@"text"];
            [[SystemController sharedInstance] setClipboardText:text];
            [self sendResponse:@{@"status": @"ok"}];
        } else if ([action isEqualToString:@"get_clipboard"]) {
            NSString *text = [[SystemController sharedInstance] getClipboardText];
            [self sendResponse:@{@"status": @"ok", @"clipboard": text ?: @""}];
        } else if ([action isEqualToString:@"open_app"] || [action isEqualToString:@"activate_app"]) {
            NSString *bundleID = json[@"bundle_id"];
            BOOL success = [[SystemController sharedInstance] openBundleID:bundleID];
            [self sendResponse:@{@"status": success ? @"ok" : @"error"}];
        } else if ([action isEqualToString:@"background_app"]) {
            NSTimeInterval dur = json[@"duration"] ? [json[@"duration"] doubleValue] : 2.0;
            NSString *bundleID = json[@"bundle_id"];
            BOOL success = [[SystemController sharedInstance] backgroundAppWithDuration:dur bundleID:bundleID];
            [self sendResponse:@{@"status": success ? @"ok" : @"error"}];
        } else if ([action isEqualToString:@"open_deeplink"] || [action isEqualToString:@"open_scheme"]) {
            NSString *url = json[@"url"];
            BOOL success = [[SystemController sharedInstance] openURLString:url];
            [self sendResponse:@{@"status": success ? @"ok" : @"error"}];
        } else if ([action isEqualToString:@"terminate_app"]) {
            NSString *bundleID = json[@"bundle_id"];
            [[SystemController sharedInstance] terminateAppWithBundleID:bundleID];
            [self sendResponse:@{@"status": @"ok"}];
        } else if ([action isEqualToString:@"get_telemetry"]) {
            NSDictionary *telemetry = [[SystemController sharedInstance] getSystemTelemetry];
            [self sendResponse:@{@"status": @"ok", @"telemetry": telemetry}];
        } else if ([action isEqualToString:@"set_brightness"]) {
            CGFloat b = [json[@"brightness"] doubleValue];
            [[SystemController sharedInstance] setScreenBrightness:b];
            [self sendResponse:@{@"status": @"ok"}];
        }
    } @catch (NSException *e) {
        [self sendResponse:@{@"status": @"error", @"message": e.reason ?: @"Unknown Exception"}];
    }
}

- (void)sendResponse:(NSDictionary *)dict {
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
    NSString *jsonStr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    [self sendTextMessage:jsonStr];
}

- (void)sendTextMessage:(NSString *)text {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    [self sendFrameWithOpcode:0x01 payload:data];
}

- (void)sendBinaryData:(NSData *)data {
    [self sendFrameWithOpcode:0x02 payload:data];
}

- (void)sendFrameWithOpcode:(uint8_t)opcode payload:(NSData *)payload {
    if (_socketFD <= 0) return;

    NSMutableData *frame = [NSMutableData data];
    uint8_t b0 = 0x80 | (opcode & 0x0F);
    [frame appendBytes:&b0 length:1];

    NSUInteger length = payload.length;
    if (length < 126) {
        uint8_t b1 = (uint8_t)length;
        [frame appendBytes:&b1 length:1];
    } else if (length <= 0xFFFF) {
        uint8_t b1 = 126;
        [frame appendBytes:&b1 length:1];
        uint16_t len16 = htons((uint16_t)length);
        [frame appendBytes:&len16 length:2];
    } else {
        uint8_t b1 = 127;
        [frame appendBytes:&b1 length:1];
        uint64_t len64 = CFSwapInt64HostToBig((uint64_t)length);
        [frame appendBytes:&len64 length:8];
    }

    [frame appendData:payload];
    write(_socketFD, frame.bytes, frame.length);
}

- (void)close {
    if (_readSource) {
        dispatch_source_cancel(_readSource);
        _readSource = nil;
    }
}

@end

@implementation AgentWebSocketServer {
    int _listenSocket;
    dispatch_queue_t _serverQueue;
    dispatch_source_t _listenSource;
    dispatch_source_t _cleanupTimer;
    NSMutableArray<AgentWebSocketClient *> *_connectedClients;
}

+ (instancetype)sharedInstance {
    static AgentWebSocketServer *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AgentWebSocketServer alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _serverQueue = dispatch_queue_create("com.devicekit.wsserver", DISPATCH_QUEUE_SERIAL);
        _connectedClients = [NSMutableArray array];
        [self startStaleConnectionReaper];
    }
    return self;
}

- (void)dealloc {
    if (_cleanupTimer) {
        dispatch_source_cancel(_cleanupTimer);
        _cleanupTimer = nil;
    }
}

- (void)startStaleConnectionReaper {
    _cleanupTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _serverQueue);
    dispatch_source_set_timer(_cleanupTimer, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), 30 * NSEC_PER_SEC, 5 * NSEC_PER_SEC);
    
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_cleanupTimer, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        NSMutableArray<AgentWebSocketClient *> *toRemove = [NSMutableArray array];
        for (AgentWebSocketClient *client in strongSelf->_connectedClients) {
            if (client.socketFD <= 0 || [client isStaleWithTimeout:120.0]) {
                [client close];
                [toRemove addObject:client];
            }
        }
        [strongSelf->_connectedClients removeObjectsInArray:toRemove];
    });
    
    dispatch_resume(_cleanupTimer);
}

- (void)startServerOnPort:(NSUInteger)port {
    dispatch_async(_serverQueue, ^{
        if (self->_listenSocket > 0) return;

        self->_listenSocket = socket(AF_INET, SOCK_STREAM, 0);
        if (self->_listenSocket < 0) return;

        int opt = 1;
        setsockopt(self->_listenSocket, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
        setsockopt(self->_listenSocket, SOL_SOCKET, SO_NOSIGPIPE, &opt, sizeof(opt));

        struct sockaddr_in address;
        memset(&address, 0, sizeof(address));
        address.sin_family = AF_INET;
        address.sin_addr.s_addr = htonl(INADDR_ANY);
        address.sin_port = htons((uint16_t)port);

        if (bind(self->_listenSocket, (struct sockaddr *)&address, sizeof(address)) < 0) {
            close(self->_listenSocket);
            self->_listenSocket = -1;
            return;
        }

        if (listen(self->_listenSocket, 64) < 0) {
            close(self->_listenSocket);
            self->_listenSocket = -1;
            return;
        }

        self->_listenSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, self->_listenSocket, 0, self->_serverQueue);
        __weak typeof(self) weakSelf = self;

        dispatch_source_set_event_handler(self->_listenSource, ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            struct sockaddr_in clientAddr;
            socklen_t clientLen = sizeof(clientAddr);
            int clientFD = accept(strongSelf->_listenSocket, (struct sockaddr *)&clientAddr, &clientLen);
            if (clientFD > 0) {
                AgentWebSocketClient *client = [[AgentWebSocketClient alloc] initWithSocket:clientFD];
                [strongSelf->_connectedClients addObject:client];
            }
        });

        dispatch_resume(self->_listenSource);
    });
}

- (void)stopServer {
    dispatch_sync(_serverQueue, ^{
        if (self->_listenSource) {
            dispatch_source_cancel(self->_listenSource);
            self->_listenSource = nil;
        }
        if (self->_listenSocket > 0) {
            close(self->_listenSocket);
            self->_listenSocket = -1;
        }
        for (AgentWebSocketClient *c in self->_connectedClients) {
            [c close];
        }
        [self->_connectedClients removeAllObjects];
    });
}

@end

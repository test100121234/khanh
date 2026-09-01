#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AgentWebSocketServer : NSObject

+ (instancetype)sharedInstance;

- (void)startServerOnPort:(NSUInteger)port NS_SWIFT_NAME(start(onPort:));
- (void)stopServer;

@end

NS_ASSUME_NONNULL_END

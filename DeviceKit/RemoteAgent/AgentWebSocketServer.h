#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AgentWebSocketServer : NSObject

+ (instancetype)sharedInstance;

- (void)startServerOnPort:(NSUInteger)port;
- (void)stopServer;

@end

NS_ASSUME_NONNULL_END

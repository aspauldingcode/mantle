#ifndef _MANTLE_PROTOCOL_H_
#define _MANTLE_PROTOCOL_H_

#import <Foundation/Foundation.h>

// Protocol for FFI callbacks from server to client
@protocol MantleClientProtocol <NSObject>
- (uint64_t)getClass:(NSString *)className;
- (NSDictionary *)sendMessage:(NSString *)selector toObject:(uint64_t)target withArgs:(NSArray *)args;
- (NSData *)callCFunction:(NSString *)symbol withArgs:(NSData *)args returnType:(uint8_t)returnType;
@end

// Protocol for server methods clients can call
@protocol MantleServerProtocol <NSObject>
- (void)registerClient:(pid_t)pid name:(NSString *)name callback:(byref id<MantleClientProtocol>)callback;
- (void)unregisterClient:(pid_t)pid;
- (int32_t)ping:(int32_t)value;
- (NSData *)callCFunction:(NSString *)symbol withArgs:(NSData *)args returnType:(uint8_t)returnType forClient:(pid_t)pid;
@end

#define MANTLE_CONNECTION_NAME @"com.mantle.server"

#endif // _MANTLE_PROTOCOL_H_

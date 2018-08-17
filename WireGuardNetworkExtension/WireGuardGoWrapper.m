//
//  WireGuardGoWrapper.m
//  WireGuardNetworkExtension
//
//  Created by Jeroen Leenarts on 21-06-18.
//  Copyright © 2018 Jason A. Donenfeld <Jason@zx2c4.com>. All rights reserved.
//

#include <os/log.h>
#include <ifaddrs.h>
#include <arpa/inet.h>

#include "wireguard.h"
#import "WireGuardGoWrapper.h"

/// Trampoline function
static ssize_t do_read(const void *ctx, const unsigned char *buf, size_t len);
/// Trampoline function
static ssize_t do_write(const void *ctx, const unsigned char *buf, size_t len);
/// Trampoline function
static void do_log(int level, const char *tag, const char *msg);



@interface WireGuardGoWrapper ()

@property (nonatomic, assign) int handle;
@property (nonatomic, assign) BOOL isClosed;
@property (nonatomic, strong) NSMutableArray<NSData *> *packets;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *protocols;
@property (nonatomic, strong) dispatch_queue_t dispatchQueue;
@property (nonatomic, strong) NSString *activeinterfaceName;
@property (nonatomic, strong) NSString *activeSettings;

@property (nonatomic, strong) NSCondition *condition;

@end

@implementation WireGuardGoWrapper

- (instancetype)init
{
    self = [super init];
    if (self) {
        self.packets = [[NSMutableArray alloc]initWithCapacity:100];
        self.handle = -1;
        self.configured = false;
        self.condition = [NSCondition new];
        self.dispatchQueue = dispatch_queue_create("manager", NULL);
    }
    return self;
}

- (BOOL) reassert {
    NSString *interfaceName = self.activeinterfaceName;
    NSString *settings = self.activeSettings;

    [self turnOff];
    return [self turnOnWithInterfaceName:interfaceName settingsString:settings];
}

- (BOOL) turnOnWithInterfaceName: (NSString *)interfaceName settingsString: (NSString *)settingsString
{
    self.activeinterfaceName = interfaceName;
    self.activeSettings = settingsString;

    os_log([WireGuardGoWrapper log], "WireGuard Go Version %{public}s", wgVersion());

    wgSetLogger(do_log);

    const char * ifName = [interfaceName UTF8String];
    const char * settings = [settingsString UTF8String];

    self.handle = wgTurnOn((gostring_t){ .p = ifName, .n = interfaceName.length }, (gostring_t){ .p = settings, .n = settingsString.length }, do_read, do_write, (__bridge void *)(self));

    return self.handle >= 0;
}

- (void) turnOff
{
    self.isClosed = YES;
    self.configured = NO;
    wgTurnOff(self.handle);
    self.activeinterfaceName = nil;
    self.activeSettings = nil;
    self.handle = -1;
}

- (void) startReadingPackets {
    [self readPackets];
}

- (void) readPackets {
    dispatch_async(self.dispatchQueue, ^{
        if (self.isClosed || self.handle < 0 || !self.configured ) {
            [self readPackets];
            return;
        }

//        os_log_debug([WireGuardGoWrapper log], "readPackets - read call - on thread \"%{public}@\" - %d", NSThread.currentThread.name, (int)NSThread.currentThread);

        [self.packetFlow readPacketsWithCompletionHandler:^(NSArray<NSData *> * _Nonnull packets, NSArray<NSNumber *> * _Nonnull protocols) {
            [self.condition lock];
            @synchronized(self.packets) {
                [self.packets addObjectsFromArray:packets];
                [self.protocols addObjectsFromArray:protocols];
            }
//            os_log_debug([WireGuardGoWrapper log], "readPackets - signal - on thread \"%{public}@\" - %d", NSThread.currentThread.name, (int)NSThread.currentThread);
            [self.condition signal];
            [self.condition unlock];
            [self readPackets];
        }];
    });
}

+ (NSString *)versionWireGuardGo {
    return [NSString stringWithUTF8String:wgVersion()];
}

+ (os_log_t)log {
    static os_log_t subLog = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        subLog = os_log_create("com.wireguard.ios.WireGuard.WireGuardNetworkExtension", "WireGuard-Go");
    });

    return subLog;
}

+ (NSString *) detectAddress {
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *temp_addr = NULL;
    NSString *wifiAddress = nil;
    NSString *cellAddress = nil;

    // retrieve the current interfaces - returns 0 on success
    if(!getifaddrs(&interfaces)) {
        // Loop through linked list of interfaces
        temp_addr = interfaces;
        while(temp_addr != NULL) {
            sa_family_t sa_type = temp_addr->ifa_addr->sa_family;
            if(sa_type == AF_INET || sa_type == AF_INET6) {
                NSString *name = [NSString stringWithUTF8String:temp_addr->ifa_name];
                NSString *addr = [NSString stringWithUTF8String:inet_ntoa(((struct sockaddr_in *)temp_addr->ifa_addr)->sin_addr)]; // pdp_ip0
                //NSLog(@"NAME: \"%@\" addr: %@", name, addr); // see for yourself

                if([name isEqualToString:@"en0"]) {
                    // Interface is the wifi connection on the iPhone
                    wifiAddress = addr;
                } else
                    if([name isEqualToString:@"pdp_ip0"]) {
                        // Interface is the cell connection on the iPhone
                        cellAddress = addr;
                    }
            }
            temp_addr = temp_addr->ifa_next;
        }
        // Free memory
        freeifaddrs(interfaces);
    }
    NSString *addr = wifiAddress ? wifiAddress : cellAddress;

    return addr;
}

@end

static ssize_t do_read(const void *ctx, const unsigned char *buf, size_t len)
{
//    os_log_debug([WireGuardGoWrapper log], "do_read - start - on thread \"%{public}@\" - %d", NSThread.currentThread.name, (int)NSThread.currentThread);
    WireGuardGoWrapper *wrapper = (__bridge WireGuardGoWrapper *)ctx;
    if (wrapper.isClosed) return -1;

    if (wrapper.handle < 0 || !wrapper.configured ) {
//        os_log_debug([WireGuardGoWrapper log], "do_read - early - on thread \"%{public}@\" - %d", NSThread.currentThread.name, (int)NSThread.currentThread);

        return 0;
    }


    NSData * __block packet = nil;
//    NSNumber *protocol = nil;
    dispatch_sync(wrapper.dispatchQueue, ^{
        [wrapper.condition lock];
        @synchronized(wrapper.packets) {
            if (wrapper.packets.count == 0) {
//                os_log_debug([WireGuardGoWrapper log], "do_read - no packet - on thread \"%{public}@\" - %d", NSThread.currentThread.name, (int)NSThread.currentThread);

                return;
            }

            packet = [wrapper.packets objectAtIndex:0];
            //    protocol = [wrapper.protocols objectAtIndex:0];
            [wrapper.packets removeObjectAtIndex:0];
            [wrapper.protocols removeObjectAtIndex:0];
        }
    });

    if (packet == nil) {
//        os_log_debug([WireGuardGoWrapper log], "do_read - wait - on thread \"%{public}@\" - %d", NSThread.currentThread.name, (int)NSThread.currentThread);
        [wrapper.condition wait];
        [wrapper.condition unlock];
        return 0;
    } else {
        [wrapper.condition unlock];
    }

    NSUInteger packetLength = [packet length];
    if (packetLength > len) {
        // The packet will be dropped when we end up here.
        os_log_debug([WireGuardGoWrapper log], "do_read - drop  - on thread \"%{public}@\" - %d", NSThread.currentThread.name, (int)NSThread.currentThread);
        return 0;
    }
    memcpy(buf, [packet bytes], packetLength);
//    os_log_debug([WireGuardGoWrapper log], "do_read - packet  - on thread \"%{public}@\" - %d", NSThread.currentThread.name, (int)NSThread.currentThread);
    return packetLength;
}

static ssize_t do_write(const void *ctx, const unsigned char *buf, size_t len)
{
//    os_log_debug([WireGuardGoWrapper log], "do_write - start");

    WireGuardGoWrapper *wrapper = (__bridge WireGuardGoWrapper *)ctx;
    //TODO: determine IPv4 or IPv6 status.
    NSData *packet = [[NSData alloc] initWithBytes:buf length:len];
    [wrapper.packetFlow writePackets:@[packet] withProtocols:@[@AF_INET]];
    return len;
}

static void do_log(int level, const char *tag, const char *msg)
{
    // TODO Get some details on the log level and distribute to matching log levels.
    os_log([WireGuardGoWrapper log], "Log level %d for %{public}s: %{public}s", level, tag, msg);
}

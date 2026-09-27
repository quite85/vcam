//
//  VCamOBSAddress.m
//  VCam
//
//  本机地址工具。独立成一个文件（不依赖 FFmpeg），
//  这样 VCAM_ENABLE_OBS=0 的包里 UI 依然能显示推流地址。
//

#import "VCamOBSSource.h"
#import "VCamConfig.h"
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <net/if.h>

@implementation VCamOBSSource (Address)

+ (NSArray<NSString *> *)localIPv4Addresses {
    NSMutableArray<NSString *> *addrs = [NSMutableArray array];
    struct ifaddrs *ifa = NULL;
    if (getifaddrs(&ifa) != 0) return addrs;
    for (struct ifaddrs *cur = ifa; cur != NULL; cur = cur->ifa_next) {
        if (!cur->ifa_addr || cur->ifa_addr->sa_family != AF_INET) continue;
        if (!(cur->ifa_flags & IFF_UP)) continue;
        if (cur->ifa_flags & IFF_LOOPBACK) continue;   // 跳过 lo0
        char buf[INET_ADDRSTRLEN] = {0};
        struct sockaddr_in *sin = (struct sockaddr_in *)cur->ifa_addr;
        if (inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf))) {
            [addrs addObject:@(buf)];
        }
    }
    freeifaddrs(ifa);
    // 方便用户识别：把 USB 网络共享的常见网段放前面（有线比 Wi-Fi 稳得多）
    [addrs sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        BOOL aUSB = [a hasPrefix:@"172.20.10."] || [a hasPrefix:@"192.168.42."];
        BOOL bUSB = [b hasPrefix:@"172.20.10."] || [b hasPrefix:@"192.168.42."];
        if (aUSB != bUSB) return aUSB ? NSOrderedAscending : NSOrderedDescending;
        return [a compare:b];
    }];
    return addrs;
}

+ (NSString *)pushURLForTransport:(NSString *)transport port:(uint16_t)port {
    NSArray<NSString *> *addrs = [self localIPv4Addresses];
    NSString *ip = addrs.firstObject ?: @"192.168.1.100";
    NSString *t = [transport.lowercaseString isEqualToString:@"tcp"] ? @"tcp" : @"udp";
    return [NSString stringWithFormat:@"%@://%@:%u", t, ip, port];
}

@end

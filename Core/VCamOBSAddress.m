//
//  VCamOBSAddress.m
//  VCam
//
//  本机地址查询。用 getifaddrs 遍历网卡，取 AF_INET 且已 UP 的非回环地址。
//
//  不依赖 FFmpeg / OBS，所以 VCAM_ENABLE_OBS=0 的轻量包里也照常工作 ——
//  用户至少能在小窗里看到"应该往哪个地址推"。
//

#import "VCamOBSAddress.h"
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <net/if.h>

@implementation VCamOBSAddress

+ (NSArray<NSString *> *)localIPv4Addresses {
    NSMutableArray<NSString *> *addrs = [NSMutableArray array];

    struct ifaddrs *ifa = NULL;
    if (getifaddrs(&ifa) != 0) return addrs;

    for (struct ifaddrs *cur = ifa; cur != NULL; cur = cur->ifa_next) {
        // 跳过没有地址的条目
        if (cur->ifa_addr == NULL) continue;
        // 只要 IPv4（AF_INET）。IPv6 这里不处理：
        // OBS 的 FFmpeg 自定义输出填 IPv6 需要方括号，用户容易填错。
        if (cur->ifa_addr->sa_family != AF_INET) continue;
        // 只要已经启用的网卡
        if (!(cur->ifa_flags & IFF_UP)) continue;
        // 跳过回环 lo0（127.0.0.1 推给自己电脑，是新手最常犯的错）
        if (cur->ifa_flags & IFF_LOOPBACK) continue;

        char buf[INET_ADDRSTRLEN] = {0};
        struct sockaddr_in *sin = (struct sockaddr_in *)cur->ifa_addr;
        if (inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf)) != NULL) {
            NSString *ip = @(buf);
            if (ip.length > 0 && ![addrs containsObject:ip]) {
                [addrs addObject:ip];
            }
        }
    }
    freeifaddrs(ifa);

    // 排序：USB 网络共享优先（有线最稳），然后按字符串序保证结果稳定
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
    // 拿不到地址时给一个占位，让 UI 至少能显示格式（用户会知道该填什么）
    NSString *ip = addrs.firstObject ?: @"192.168.1.100";
    NSString *t = [transport.lowercaseString isEqualToString:@"tcp"] ? @"tcp" : @"udp";
    return [NSString stringWithFormat:@"%@://%@:%u", t, ip, port];
}

@end
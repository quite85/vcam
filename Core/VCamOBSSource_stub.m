//
//  VCamOBSSource_stub.m
//  VCam
//
//  当 VCAM_ENABLE_OBS=0 编译时（不链接 FFmpeg）提供的降级实现。
//  保持同名类，上层代码零改动。
//
//  为什么不强制依赖 FFmpeg：
//   带 FFmpeg 的 .deb 体积会从 ~200KB 涨到 ~15MB，还要处理 arm64e 下的
//   第三方库签名/加载问题。只想用相册图片或视频替换的用户没必要背这个负担。
//

#import "VCamOBSSource.h"
#import "VCamConfig.h"

@implementation VCamOBSSource

- (instancetype)init {
    if ((self = [super init])) {
        _transport = @"udp";
        _stallTimeout = 1.0;
        _holdLastFrame = YES;
    }
    return self;
}

- (NSString *)statusText { return @"OBS 支持未编译进本包"; }
- (BOOL)isReady { return NO; }
- (double)bitrateKbps { return 0; }
- (uint64_t)decodedFrames { return 0; }
- (uint64_t)droppedFrames { return 0; }
- (BOOL)receiving { return NO; }

- (BOOL)start {
    self.lastError = @"本包未编译 OBS 支持。请安装带 FFmpeg 的版本，"
                     @"或自行用 VCAM_ENABLE_OBS=1 重新编译。";
    VCamLog(@"[obs] %@", self.lastError);
    return NO;
}

- (void)stop {}
- (void)invalidate { [self stop]; }

@end

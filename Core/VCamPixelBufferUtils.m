//
//  VCamPixelBufferUtils.m
//  VCam
//

#import "VCamPixelBufferUtils.h"
#import "VCamConfig.h"
#import <CoreImage/CoreImage.h>
#import <Accelerate/Accelerate.h>
#import <AudioToolbox/AudioToolbox.h>
#import <os/lock.h>

@implementation VCamPixelBufferUtils

#pragma mark - Pool 缓存

static NSMutableDictionary<NSString *, CVPixelBufferPoolRef> *gPools = nil;
static os_unfair_lock gPoolLock = OS_UNFAIR_LOCK_INIT;

+ (CVPixelBufferPoolRef)_poolForWidth:(size_t)w
                               height:(size_t)h
                               format:(OSType)fmt
                                  key:(NSString *)key CF_RETURNS_NOT_RETAINED {
    os_unfair_lock_lock(&gPoolLock);
    if (!gPools) gPools = [NSMutableDictionary dictionary];
    CVPixelBufferPoolRef pool = (__bridge CVPixelBufferPoolRef)gPools[key];
    if (!pool) {
        NSDictionary *attrs = @{
            (id)kCVPixelBufferPoolMinimumBufferCountKey: @(6),
        };
        // IOSurface 属性：让 buffer 可以直接被 GPU / 摄像头硬件路径使用
        NSDictionary *bufAttrs = @{
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{
                (id)kCVPixelBufferIOSurfaceCoreAnimationCompatibilityKey: @(YES),
            },
            (id)kCVPixelBufferPixelFormatTypeKey: @(fmt),
            (id)kCVPixelBufferWidthKey: @(w),
            (id)kCVPixelBufferHeightKey: @(h),
            (id)kCVPixelBufferMetalCompatibilityKey: @(YES),
        };
        CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                (__bridge CFDictionaryRef)attrs,
                                (__bridge CFDictionaryRef)bufAttrs,
                                &pool);
        if (pool) {
            gPools[key] = (__bridge id)pool;
            CFRelease(pool); // 字典持有
            pool = (__bridge CVPixelBufferPoolRef)gPools[key];
        }
    }
    os_unfair_lock_unlock(&gPoolLock);
    return pool;
}

+ (CVPixelBufferRef)createPixelBufferWithWidth:(size_t)width
                                        height:(size_t)height
                                        format:(OSType)format
                                    fromPoolKey:(NSString *)key {
    if (width == 0 || height == 0) return NULL;
    NSString *poolKey = [NSString stringWithFormat:@"%@-%.0fx%.0f-%u", key,
                         (double)width, (double)height, (unsigned)format];
    CVPixelBufferPoolRef pool = [self _poolForWidth:width height:height format:format key:poolKey];
    CVPixelBufferRef pb = NULL;
    if (pool) {
        CVReturn r = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb);
        if (r != kCVReturnSuccess) pb = NULL;
    }
    if (!pb) {
        // 池失败（例如池被其它进程占用）就退回裸分配
        NSDictionary *attrs = @{
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
            (id)kCVPixelBufferMetalCompatibilityKey: @(YES),
        };
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
                            (__bridge CFDictionaryRef)attrs, &pb);
    }
    return pb;
}

+ (void)flushPools {
    os_unfair_lock_lock(&gPoolLock);
    [gPools removeAllObjects];
    os_unfair_lock_unlock(&gPoolLock);
}

#pragma mark - 图像 → NV12

+ (CVPixelBufferRef)pixelBufferFromImage:(UIImage *)image
                                   width:(size_t)width
                                  height:(size_t)height {
    if (!image || width == 0 || height == 0) return NULL;

    CVPixelBufferRef pb = [self createPixelBufferWithWidth:width
                                                    height:height
                                                    format:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                                                fromPoolKey:@"img"];
    if (!pb) return NULL;

    @try {
        // 用 CIContext 渲染：CIContext 会自动做 RGB→YCbCr 的 BT.601/709 转换
        static CIContext *ctx = nil;
        static CGColorSpaceRef srgb = NULL;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            NSDictionary *opts = @{
                kCIContextWorkingColorSpace: (__bridge id)srgb,
                kCIContextUseSoftwareRenderer: @(NO),
            };
            ctx = [CIContext contextWithOptions:opts];
        });

        CIImage *ci = [[CIImage alloc] initWithCGImage:image.CGImage];
        if (!ci) { CVPixelBufferRelease(pb); return NULL; }

        // aspect-fill：等比放大到铺满，再居中裁剪
        CGRect extent = ci.extent;
        if (extent.size.width <= 0 || extent.size.height <= 0) {
            CVPixelBufferRelease(pb);
            return NULL;
        }
        CGFloat scale = MAX(width / extent.size.width, height / extent.size.height);
        CIImage *scaled = [ci imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
        CGRect r = scaled.extent;
        CGFloat dx = (r.size.width  - width)  / 2.0;
        CGFloat dy = (r.size.height - height) / 2.0;
        CIImage *cropped = [scaled imageByCroppingToRect:CGRectMake(r.origin.x + dx,
                                                                    r.origin.y + dy,
                                                                    width, height)];
        // 平移到原点，否则 CIContext 会按 extent 偏移绘制
        CIImage *final = [cropped imageByApplyingTransform:
                          CGAffineTransformMakeTranslation(-cropped.extent.origin.x,
                                                           -cropped.extent.origin.y)];

        [ctx render:final toCVPixelBuffer:pb bounds:CGRectMake(0, 0, width, height)
             colorSpace:srgb];
    } @catch (NSException *e) {
        VCamLog(@"[pxl] pixelBufferFromImage 异常: %@", e);
        if (pb) { CVPixelBufferRelease(pb); pb = NULL; }
    }
    return pb;
}

#pragma mark - NV12 → 图像

+ (UIImage *)imageFromPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (!pixelBuffer) return nil;
    @try {
        CIImage *ci = [CIImage imageWithCVPixelBuffer:pixelBuffer];
        static CIContext *ctx = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            ctx = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @(NO)}];
        });
        CGImageRef cg = [ctx createCGImage:ci fromRect:ci.extent];
        if (!cg) return nil;
        UIImage *img = [UIImage imageWithCGImage:cg];
        CGImageRelease(cg);
        return img;
    } @catch (NSException *e) {
        VCamLog(@"[pxl] imageFromPixelBuffer 异常: %@", e);
        return nil;
    }
}

#pragma mark - 旋转 / 镜像 / 缩放

+ (CVPixelBufferRef)transformPixelBuffer:(CVPixelBufferRef)src
                                rotation:(VCamRotation)rotation
                                  mirror:(BOOL)mirror {
    if (!src) return NULL;
    size_t w = CVPixelBufferGetWidth(src);
    size_t h = CVPixelBufferGetHeight(src);
    BOOL swap = (rotation == VCamRotation90 || rotation == VCamRotation270);
    size_t outW = swap ? h : w;
    size_t outH = swap ? w : h;

    CVPixelBufferRef dst = [self createPixelBufferWithWidth:outW height:outH
                                                     format:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                                                 fromPoolKey:@"xf"];
    if (!dst) return NULL;

    CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(dst, 0);

    // Y 平面
    vImage_Buffer sy = {
        .data = CVPixelBufferGetBaseAddressOfPlane(src, 0),
        .height = h,
        .width = w,
        .rowBytes = CVPixelBufferGetBytesPerRowOfPlane(src, 0),
    };
    vImage_Buffer dy = {
        .data = CVPixelBufferGetBaseAddressOfPlane(dst, 0),
        .height = outH,
        .width = outW,
        .rowBytes = CVPixelBufferGetBytesPerRowOfPlane(dst, 0),
    };
    // UV 平面（NV12 交错，宽高都为 Y 的一半）
    vImage_Buffer suv = {
        .data = CVPixelBufferGetBaseAddressOfPlane(src, 1),
        .height = h / 2,
        .width = w / 2,
        .rowBytes = CVPixelBufferGetBytesPerRowOfPlane(src, 1),
    };
    vImage_Buffer duv = {
        .data = CVPixelBufferGetBaseAddressOfPlane(dst, 1),
        .height = outH / 2,
        .width = outW / 2,
        .rowBytes = CVPixelBufferGetBytesPerRowOfPlane(dst, 1),
    };
    // UV 平面每个像素 2 字节，旋转时宽度要 ×2
    vImage_Buffer suv2 = suv, duv2 = duv;
    suv2.width  = suv.width  * 2;
    suv2.rowBytes = suv.rowBytes;
    duv2.width  = duv.width  * 2;
    duv2.rowBytes = duv.rowBytes;

    vImage_Error err = kvImageNoError;
    switch (rotation) {
        case VCamRotation90:
            err |= vImageRotate90_Planar8(&sy, &dy, kRotateCW, 0, kvImageNoFlags);
            err |= vImageRotate90_Planar8(&suv2, &duv2, kRotateCW, 0, kvImageNoFlags);
            break;
        case VCamRotation180:
            err |= vImageRotate90_Planar8(&sy, &dy, kRotate180, 0, kvImageNoFlags);
            err |= vImageRotate90_Planar8(&suv2, &duv2, kRotate180, 0, kvImageNoFlags);
            break;
        case VCamRotation270:
            err |= vImageRotate90_Planar8(&sy, &dy, kRotateCCW, 0, kvImageNoFlags);
            err |= vImageRotate90_Planar8(&suv2, &duv2, kRotateCCW, 0, kvImageNoFlags);
            break;
        case VCamRotation0:
        default:
            err |= vImageCopyBuffer(&sy, &dy, 1, kvImageNoFlags);
            err |= vImageCopyBuffer(&suv2, &duv2, 1, kvImageNoFlags);
            break;
    }
    if (mirror) {
        // 镜像在旋转之后做：对每行做 vImageHorizontalReflect
        vImage_Buffer dym = dy, duvm = duv2;
        err |= vImageHorizontalReflect_Planar8(&dy, &dym, kvImageNoFlags);
        err |= vImageHorizontalReflect_Planar8(&duv2, &duvm, kvImageNoFlags);
    }

    CVPixelBufferUnlockBaseAddress(dst, 0);
    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);

    if (err != kvImageNoError) {
        VCamLog(@"[pxl] transform 失败 err=%ld rot=%ld mirror=%d", (long)err, (long)rotation, mirror);
        // 失败时返回原图副本，绝不让调用方拿到 NULL 而崩
        CVPixelBufferRelease(dst);
        return CVPixelBufferRetain(src);
    }
    return dst;
}

+ (CVPixelBufferRef)scalePixelBuffer:(CVPixelBufferRef)src
                             toWidth:(size_t)width
                              height:(size_t)height {
    if (!src) return NULL;
    size_t sw = CVPixelBufferGetWidth(src);
    size_t sh = CVPixelBufferGetHeight(src);
    if (sw == width && sh == height) return CVPixelBufferRetain(src);

    CVPixelBufferRef dst = [self createPixelBufferWithWidth:width height:height
                                                     format:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                                                 fromPoolKey:@"scl"];
    if (!dst) return CVPixelBufferRetain(src);

    CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(dst, 0);

    vImage_Buffer sy = { CVPixelBufferGetBaseAddressOfPlane(src,0), sh, sw,
                         CVPixelBufferGetBytesPerRowOfPlane(src,0) };
    vImage_Buffer dy = { CVPixelBufferGetBaseAddressOfPlane(dst,0), height, width,
                         CVPixelBufferGetBytesPerRowOfPlane(dst,0) };
    vImage_Buffer suv = { CVPixelBufferGetBaseAddressOfPlane(src,1), sh/2, sw,
                          CVPixelBufferGetBytesPerRowOfPlane(src,1) };
    vImage_Buffer duv = { CVPixelBufferGetBaseAddressOfPlane(dst,1), height/2, width,
                          CVPixelBufferGetBytesPerRowOfPlane(dst,1) };

    vImage_Error e1 = vImageScale_Planar8(&sy, &dy, NULL, kvImageHighQualityResampling);
    vImage_Error e2 = vImageScale_Planar8(&suv, &duv, NULL, kvImageHighQualityResampling);

    CVPixelBufferUnlockBaseAddress(dst, 0);
    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);

    if (e1 != kvImageNoError || e2 != kvImageNoError) {
        CVPixelBufferRelease(dst);
        return CVPixelBufferRetain(src);
    }
    return dst;
}

#pragma mark - 占位帧

+ (CVPixelBufferRef)placeholderPixelBufferWithWidth:(size_t)width
                                             height:(size_t)height
                                               text:(NSString *)text {
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = YES;
    fmt.scale = 1.0;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc]
                                  initWithSize:CGSizeMake(width, height) format:fmt];
    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        CGContextSetRGBFillColor(c, 0.06, 0.06, 0.08, 1.0);
        CGContextFillRect(c, CGRectMake(0, 0, width, height));
        // 细网格，肉眼可辨"这是占位而不是黑屏卡死"
        CGContextSetRGBStrokeColor(c, 0.16, 0.16, 0.2, 1.0);
        CGContextSetLineWidth(c, 1);
        for (CGFloat x = 0; x < width; x += 64) {
            CGContextMoveToPoint(c, x, 0); CGContextAddLineToPoint(c, x, height);
        }
        for (CGFloat y = 0; y < height; y += 64) {
            CGContextMoveToPoint(c, 0, y); CGContextAddLineToPoint(c, width, y);
        }
        CGContextStrokePath(c);

        NSString *t = text.length ? text : @"VCam · 等待信号";
        NSDictionary *attrs = @{
            NSFontAttributeName: [UIFont boldSystemFontOfSize:MAX(18, height / 24.0)],
            NSForegroundColorAttributeName: UIColor.whiteColor,
        };
        CGSize ts = [t sizeWithAttributes:attrs];
        [t drawAtPoint:CGPointMake((width - ts.width) / 2.0, (height - ts.height) / 2.0)
        withAttributes:attrs];
    }];
    return [self pixelBufferFromImage:img width:width height:height];
}

#pragma mark - 时间

+ (CMTime)hostTime {
    // CMClockGetTime(CMClockGetHostTimeClock()) 与 AVCaptureVideoDataOutput
    // 给出的 PTS 是同一个时基（mach_absolute_time 派生），
    // 用它做时间戳可以避免预览层"等一帧"和录制时间轴跳变。
    return CMClockGetTime(CMClockGetHostTimeClock());
}

+ (CMTime)hostTimeForStreamTime:(CMTime)streamTime anchor:(CMTime)anchor {
    if (!CMTIME_IS_VALID(streamTime) || !CMTIME_IS_VALID(anchor)) return [self hostTime];
    CMTime now = [self hostTime];
    // 相对锚点偏移 + 当前 host 时间
    CMTime delta = CMTimeSubtract(streamTime, anchor);
    CMTime out = CMTimeAdd(now, delta);
    // 保证时间戳合法（NaN/∞ 会让预览层直接黑屏）
    if (!CMTIME_IS_NUMERIC(out)) return now;
    return out;
}

#pragma mark - SampleBuffer

+ (CMSampleBufferRef)sampleBufferFromPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                        timebase:(CMTimebaseRef)timebase
                                          atTime:(CMTime)time {
    if (!pixelBuffer) return NULL;

    CMVideoFormatDescriptionRef fmt = NULL;
    OSStatus st = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault,
                                                               pixelBuffer, &fmt);
    if (st != noErr || !fmt) {
        VCamLog(@"[buf] 创建 formatDescription 失败 %d", (int)st);
        return NULL;
    }
    CMSampleTimingInfo timing = {
        .duration = kCMTimeInvalid,
        .presentationTimeStamp = CMTIME_IS_NUMERIC(time) ? time : [self hostTime],
        .decodeTimeStamp = kCMTimeInvalid,
    };
    CMSampleBufferRef sb = NULL;
    st = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault,
                                                 pixelBuffer,
                                                 fmt,
                                                 &timing,
                                                 &sb);
    CFRelease(fmt);
    if (st != noErr) {
        VCamLog(@"[buf] 创建 sampleBuffer 失败 %d", (int)st);
        return NULL;
    }
    if (timebase) {
        // 挂上 timebase 让下游（预览层 / 录制器）能正确排程
        CMSampleBufferSetInvalidateCallback(sb, NULL, 0);
        CFRetain(timebase);
    }
    return sb;
}

+ (CMSampleBufferRef)sampleBufferFromFloat32PCM:(const float *)interleaved
                                         frames:(size_t)frames
                                       channels:(UInt32)channels
                                     sampleRate:(Float64)sampleRate
                                       hostTime:(CMTime)hostTime {
    if (!interleaved || frames == 0 || channels == 0) return NULL;

    AudioStreamBasicDescription asbd = {0};
    asbd.mSampleRate = sampleRate;
    asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    asbd.mBytesPerPacket = sizeof(float) * channels;
    asbd.mFramesPerPacket = 1;
    asbd.mBytesPerFrame = sizeof(float) * channels;
    asbd.mChannelsPerFrame = channels;
    asbd.mBitsPerChannel = 32;

    CMFormatDescriptionRef fmt = NULL;
    OSStatus st = CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd,
                                                 0, NULL, 0, NULL, NULL, &fmt);
    if (st != noErr || !fmt) return NULL;

    CMBlockBufferRef bb = NULL;
    size_t len = frames * sizeof(float) * channels;
    st = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, len,
                                            kCFAllocatorDefault, NULL, 0, len,
                                            kCMBlockBufferAssureMemoryNowFlag, &bb);
    if (st != noErr || !bb) { CFRelease(fmt); return NULL; }
    CMBlockBufferReplaceDataBytes(interleaved, bb, 0, len);

    CMSampleTimingInfo timing = {
        .duration = CMTimeMake(1, (int32_t)sampleRate),
        .presentationTimeStamp = CMTIME_IS_NUMERIC(hostTime) ? hostTime : [self hostTime],
        .decodeTimeStamp = kCMTimeInvalid,
    };
    size_t sampleSize = sizeof(float) * channels;
    CMSampleBufferRef sb = NULL;
    st = CMSampleBufferCreateReady(kCFAllocatorDefault, bb, fmt, (CMItemCount)frames,
                                   1, &timing, 1, &sampleSize, &sb);
    CFRelease(bb);
    CFRelease(fmt);
    if (st != noErr) return NULL;
    return sb;
}

+ (CMSampleBufferRef)sampleBufferFromAudioBufferList:(AudioBufferList *)abl
                                              frames:(size_t)frames
                                         formatFlags:(AudioFormatFlags)flags
                                      bytesPerPacket:(UInt32)bytesPerPacket
                                     framesPerPacket:(UInt32)framesPerPacket
                                            channels:(UInt32)channels
                                          sampleRate:(Float64)sampleRate
                                            hostTime:(CMTime)hostTime {
    if (!abl || frames == 0) return NULL;
    AudioStreamBasicDescription asbd = {0};
    asbd.mSampleRate = sampleRate;
    asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mFormatFlags = flags | kAudioFormatFlagIsPacked;
    asbd.mBytesPerPacket = bytesPerPacket;
    asbd.mFramesPerPacket = framesPerPacket ?: 1;
    asbd.mBytesPerFrame = bytesPerPacket / (framesPerPacket ?: 1);
    asbd.mChannelsPerFrame = channels;
    asbd.mBitsPerChannel = asbd.mBytesPerFrame * 8 / MAX(1, channels);

    CMFormatDescriptionRef fmt = NULL;
    if (CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd, 0, NULL,
                                       0, NULL, NULL, &fmt) != noErr || !fmt) return NULL;

    CMSampleTimingInfo timing = {
        .duration = CMTimeMake((int32_t)asbd.mFramesPerPacket, (int32_t)sampleRate),
        .presentationTimeStamp = CMTIME_IS_NUMERIC(hostTime) ? hostTime : [self hostTime],
        .decodeTimeStamp = kCMTimeInvalid,
    };
    CMSampleBufferRef sb = NULL;
    OSStatus st = CMSampleBufferCreate(kCFAllocatorDefault, NULL, true, NULL, NULL,
                                       fmt, (CMItemCount)frames, 1, &timing,
                                       abl->mNumberBuffers, abl, &sb);
    CFRelease(fmt);
    if (st != noErr || !sb) return NULL;
    CMSampleBufferSetDataReady(sb);
    return sb;
}

@end

//
//  VCamVideoToolboxDecoder.m
//  VCam
//

#import "VCamVideoToolboxDecoder.h"
#import "VCamConfig.h"
#import "VCamPixelBufferUtils.h"
#import <VideoToolbox/VideoToolbox.h>
#import <os/lock.h>
#import <pthread.h>

#pragma mark - Annex-B 工具

static const uint8_t kStartCode4[4] = {0, 0, 0, 1};

/// 把 Annex-B 里的 NAL 逐个取出来（lengthSize 为输出长度前缀字节数，通常 4）
static NSData *VCamConvertAnnexBToAVCC(NSData *input, int lengthSize) {
    if (input.length < 5) return nil;
    const uint8_t *bytes = input.bytes;
    NSUInteger len = input.length;

    NSMutableData *out = [NSMutableData dataWithCapacity:len];
    NSUInteger i = 0;
    BOOL foundAny = NO;
    while (i + 3 < len) {
        // 找起始码（3 字节或 4 字节）
        NSUInteger scLen = 0;
        if (i + 4 <= len && bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 0 && bytes[i+3] == 1) {
            scLen = 4;
        } else if (bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 1) {
            scLen = 3;
        } else {
            i++;
            continue;
        }
        NSUInteger nalStart = i + scLen;
        NSUInteger nalEnd = nalStart;
        while (nalEnd + 3 < len) {
            if (bytes[nalEnd] == 0 && bytes[nalEnd+1] == 0 &&
                (bytes[nalEnd+2] == 1 ||
                 (nalEnd + 3 < len && bytes[nalEnd+2] == 0 && bytes[nalEnd+3] == 1))) {
                break;
            }
            nalEnd++;
        }
        if (nalEnd + 3 >= len) nalEnd = len;

        NSUInteger nalSize = nalEnd - nalStart;
        if (nalSize > 0) {
            uint8_t header[4] = {0};
            for (int b = 0; b < lengthSize; b++) {
                header[lengthSize - 1 - b] = (uint8_t)((nalSize >> (8 * b)) & 0xFF);
            }
            [out appendBytes:header length:lengthSize];
            [out appendBytes:bytes + nalStart length:nalSize];
            foundAny = YES;
        }
        i = nalEnd;
    }
    return foundAny ? out : nil;
}

/// 是否已经是长度前缀（AVCC）格式：前 4 字节的大端值合理
static BOOL VCamLooksLikeAVCC(NSData *data) {
    if (data.length < 8) return NO;
    const uint8_t *b = data.bytes;
    uint32_t n = (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
    return n > 0 && n < data.length;
}

/// 收集 Annex-B 流里的 SPS(7) / PPS(8) NAL
static void VCamCollectParameterSets(NSData *annexB,
                                     NSMutableArray<NSData *> *spsList,
                                     NSMutableArray<NSData *> *ppsList) {
    const uint8_t *bytes = annexB.bytes;
    NSUInteger len = annexB.length;
    NSUInteger i = 0;
    while (i + 3 < len) {
        NSUInteger scLen = 0;
        if (i + 4 <= len && bytes[i]==0 && bytes[i+1]==0 && bytes[i+2]==0 && bytes[i+3]==1) scLen = 4;
        else if (bytes[i]==0 && bytes[i+1]==0 && bytes[i+2]==1) scLen = 3;
        else { i++; continue; }
        NSUInteger start = i + scLen;
        NSUInteger end = start;
        while (end + 3 < len) {
            if (bytes[end]==0 && bytes[end+1]==0 &&
                (bytes[end+2]==1 ||
                 (end+3 < len && bytes[end+2]==0 && bytes[end+3]==1))) break;
            end++;
        }
        if (end + 3 >= len) end = len;
        if (end > start) {
            uint8_t nalType = bytes[start] & 0x1F;
            NSData *nal = [NSData dataWithBytes:bytes + start length:end - start];
            if (nalType == 7 && spsList.count == 0) [spsList addObject:nal];
            else if (nalType == 8 && ppsList.count == 0) [ppsList addObject:nal];
        }
        i = end;
    }
}

/// 从 AVCDecoderConfigurationRecord 里取 SPS/PPS
static BOOL VCamParseAVCDCR(NSData *record,
                            NSData **outSPS, NSData **outPPS, int *outLengthSize) {
    if (record.length < 7) return NO;
    const uint8_t *b = record.bytes;
    if (b[0] != 1) return NO;             // configurationVersion 必须为 1
    int lengthSize = (b[4] & 0x03) + 1;
    if (outLengthSize) *outLengthSize = lengthSize;
    int numSPS = b[5] & 0x1F;
    NSUInteger off = 6;
    if (numSPS > 0) {
        if (off + 2 > record.length) return NO;
        uint16_t sl = (b[off] << 8) | b[off+1];
        off += 2;
        if (off + sl > record.length) return NO;
        if (outSPS) *outSPS = [record subdataWithRange:NSMakeRange(off, sl)];
        off += sl;
    }
    if (off >= record.length) return NO;
    int numPPS = b[off]; off += 1;
    if (numPPS > 0) {
        if (off + 2 > record.length) return NO;
        uint16_t pl = (b[off] << 8) | b[off+1];
        off += 2;
        if (off + pl > record.length) return NO;
        if (outPPS) *outPPS = [record subdataWithRange:NSMakeRange(off, pl)];
    }
    return YES;
}

#pragma mark - 解码器

@implementation VCamVideoToolboxDecoder {
    VTDecompressionSessionRef _session;
    CMFormatDescriptionRef _formatDesc;
    os_unfair_lock _lock;
    BOOL _running;
    BOOL _needKeyframe;
    uint64_t _decoded;
    uint64_t _dropped;
    CGSize _streamSize;
    int _nalLengthSize;
    int64_t _firstPtsMs;
    CMTime _anchorHostTime;
    __weak id<VCamVideoToolboxDecoderDelegate> _delegate;
}

- (instancetype)initWithDelegate:(id<VCamVideoToolboxDecoderDelegate>)delegate {
    if ((self = [super init])) {
        _delegate = delegate;
        _lock = OS_UNFAIR_LOCK_INIT;
        _waitForKeyframe = YES;
        _needKeyframe = YES;
        _nalLengthSize = 4;
        _firstPtsMs = INT64_MIN;
        _streamSize = CGSizeZero;
    }
    return self;
}

- (void)dealloc { [self stop]; }

- (CGSize)streamSize {
    os_unfair_lock_lock(&_lock);
    CGSize s = _streamSize;
    os_unfair_lock_unlock(&_lock);
    return s;
}
- (uint64_t)decodedFrames { os_unfair_lock_lock(&_lock); uint64_t v = _decoded; os_unfair_lock_unlock(&_lock); return v; }
- (uint64_t)droppedFrames { os_unfair_lock_lock(&_lock); uint64_t v = _dropped; os_unfair_lock_unlock(&_lock); return v; }

#pragma mark 会话

- (BOOL)start {
    os_unfair_lock_lock(&_lock);
    _running = YES;
    _needKeyframe = self.waitForKeyframe;
    os_unfair_lock_unlock(&_lock);
    return YES;
}

- (void)stop {
    os_unfair_lock_lock(&_lock);
    _running = NO;
    VTDecompressionSessionRef s = _session;
    _session = NULL;
    CMFormatDescriptionRef f = _formatDesc;
    _formatDesc = NULL;
    os_unfair_lock_unlock(&_lock);
    if (s) {
        VTDecompressionSessionWaitForAsynchronousFrames(s);
        VTDecompressionSessionInvalidate(s);
        CFRelease(s);
    }
    if (f) CFRelease(f);
}

/// 解出帧后的回调
static void VCamDecoderOutputCallback(void *decompressionOutputRefCon,
                                      void *sourceFrameRefCon,
                                      OSStatus status,
                                      VTDecodeInfoFlags infoFlags,
                                      CVImageBufferRef imageBuffer,
                                      CMTime presentationTimeStamp,
                                      CMTime presentationDuration) {
    VCamVideoToolboxDecoder *decoder =
        (__bridge VCamVideoToolboxDecoder *)decompressionOutputRefCon;
    if (!decoder) return;
    if (status != noErr || !imageBuffer) {
        if (status != noErr) {
            VCamLog(@"[vt] 解码错误 status=%d", (int)status);
        }
        return;
    }

    // 把流时间轴映射到 host 时间轴。
    // sourceFrameRefCon 里塞的是 ptsMs（打包成 intptr_t）。
    int64_t ptsMs = (int64_t)(intptr_t)sourceFrameRefCon;
    CMTime ts = presentationTimeStamp;
    if (ptsMs != INT64_MIN) {
        os_unfair_lock_lock(&decoder->_lock);
        if (decoder->_firstPtsMs == INT64_MIN) {
            decoder->_firstPtsMs = ptsMs;
            decoder->_anchorHostTime = CMClockGetTime(CMClockGetHostTimeClock());
        }
        CMTime anchor = decoder->_anchorHostTime;
        int64_t base = decoder->_firstPtsMs;
        os_unfair_lock_unlock(&decoder->_lock);
        int64_t deltaMs = ptsMs - base;
        ts = CMTimeAdd(anchor, CMTimeMake(deltaMs, 1000));
        // 保证时间戳单调：绝不往回跳，否则预览层会丢帧
        CMTime now = CMClockGetTime(CMClockGetHostTimeClock());
        if (CMTIME_IS_NUMERIC(ts) && CMTimeCompare(ts, now) < 0) {
            // 流落后于实时（网络抖动），用当前时间兜住
            ts = now;
        }
    }
    if (!CMTIME_IS_NUMERIC(ts)) ts = CMClockGetTime(CMClockGetHostTimeClock());

    CVPixelBufferRef pb = (CVPixelBufferRef)imageBuffer;
    if (decoder.outputQueue) {
        [decoder.outputQueue enqueuePixelBuffer:pb atTime:ts];
    } else if (decoder->_delegate &&
               [decoder->_delegate respondsToSelector:@selector(videoDecoder:didDecodePixelBuffer:presentationTime:)]) {
        [decoder->_delegate videoDecoder:decoder didDecodePixelBuffer:pb presentationTime:ts];
    }

    os_unfair_lock_lock(&decoder->_lock);
    decoder->_decoded++;
    os_unfair_lock_unlock(&decoder->_lock);
}

- (BOOL)_createSessionWithSPS:(NSData *)sps pps:(NSData *)pps {
    const uint8_t *paramSetPtrs[2] = { sps.bytes, pps.bytes };
    const size_t paramSetSizes[2] = { sps.length, pps.length };
    CMFormatDescriptionRef fmt = NULL;
    OSStatus st = CMVideoFormatDescriptionCreateFromH264ParameterSets(
        kCFAllocatorDefault, 2, paramSetPtrs, paramSetSizes, _nalLengthSize, &fmt);
    if (st != noErr || !fmt) {
        VCamLog(@"[vt] 创建 H.264 formatDescription 失败 %d", (int)st);
        return NO;
    }

    // ATTRS = destinationImageBufferAttributes：决定输出像素缓冲的格式。
    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferMetalCompatibilityKey: @(YES),
        (id)kCVPixelBufferWidthKey: @(MAX(2.0, self.expectedSize.width)),
        (id)kCVPixelBufferHeightKey: @(MAX(2.0, self.expectedSize.height)),
    };

    // ⚠️ 修正：VTDecompressionSessionCreate 的第三个参数是
    //      videoDecoderSpecification，它接受的是 kVTVideoDecoderSpecification_* 系列的键，
    //      **不是** kVTDecompressionPropertyKey_*（那是给 VTSessionSetProperty 用的）。
    //      原来这里把 RealTime / ThreadCount / OutputPoolRequestedMinimumBufferCount
    //      塞进了 decoderSpecification，虽然能编译但语义错误（会被解码器忽略）。
    //      正确做法：
    //        · decoderSpecification 用 kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder
    //          明确要求硬件解码器（OBS 1080p30 软解顶不住）
    //        · RealTime / ThreadCount 等属性在会话创建后用 VTSessionSetProperty 设置
    NSDictionary *spec = @{
        (id)kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: @(YES),
    };

    VTDecompressionSessionRef session = NULL;
    VTDecompressionOutputCallbackRecord cb = {
        .decompressionOutputCallback = VCamDecoderOutputCallback,
        .decompressionOutputRefCon = (__bridge void *)self,
    };
    st = VTDecompressionSessionCreate(kCFAllocatorDefault,
                                      fmt,
                                      (__bridge CFDictionaryRef)spec,
                                      (__bridge CFDictionaryRef)attrs,
                                      &cb,
                                      &session);
    if (st != noErr || !session) {
        VCamLog(@"[vt] 创建解码会话失败 %d", (int)st);
        CFRelease(fmt);
        return NO;
    }
    // 低延迟调优：这些是"会话属性"，必须用 VTSessionSetProperty 设置，
    // 不能塞进 VTDecompressionSessionCreate 的 decoderSpecification。
    //
    // ⚠️ 头文件（VTDecompressionProperties.h）明确写着：
    //    "Setting both kVTDecompressionPropertyKey_MaximizePowerEfficiency and
    //     kVTDecompressionPropertyKey_RealTime is unsupported and results in
    //     undefined behavior."
    //   所以这里**只设 RealTime**，绝不两个都设。
    //
    // VTSessionSetProperty 带 warn_unused_result，返回值必须接住，
    // 否则 -Wunused-result 会在 -Werror 下失败。
    OSStatus rtErr = VTSessionSetProperty(session,
                                          kVTDecompressionPropertyKey_RealTime,
                                          kCFBooleanTrue);
    if (rtErr != noErr) {
        VCamLog(@"[vt] 设置 RealTime 失败 %d（继续，只是延迟略高）", (int)rtErr);
    }
    // 线程数：解码器可用线程上限。OBS 1080p30 用 2 条足够，多了反而抢 CPU。
    OSStatus thErr = VTSessionSetProperty(session,
                                          kVTDecompressionPropertyKey_ThreadCount,
                                          (__bridge CFTypeRef)@(2));
    if (thErr != noErr) {
        VCamLog(@"[vt] 设置 ThreadCount 失败 %d", (int)thErr);
    }

    // 拿到真实分辨率
    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(fmt);
    os_unfair_lock_lock(&_lock);
    _streamSize = CGSizeMake(dims.width, dims.height);
    if (_session) {
        VTDecompressionSessionInvalidate(_session);
        CFRelease(_session);
    }
    if (_formatDesc) CFRelease(_formatDesc);
    _session = session;
    _formatDesc = fmt;   // 持有
    os_unfair_lock_unlock(&_lock);

    VCamLog(@"[vt] 解码会话就绪 %dx%d nalLen=%d", dims.width, dims.height, _nalLengthSize);
    return YES;
}

#pragma mark 送包

- (void)feedAccessUnit:(NSData *)data
             extradata:(NSData *)extradata
            isKeyframe:(BOOL)isKeyframe
                 ptsMs:(int64_t)ptsMs {
    if (!data.length || !_running) return;

    BOOL isAnnexB = !VCamLooksLikeAVCC(data);
    NSMutableArray<NSData *> *spsList = [NSMutableArray array];
    NSMutableArray<NSData *> *ppsList = [NSMutableArray array];

    int nalLen = _nalLengthSize;
    NSData *spsFromExtra = nil, *ppsFromExtra = nil;
    if (extradata.length > 0) {
        if (VCamParseAVCDCR(extradata, &spsFromExtra, &ppsFromExtra, &nalLen)) {
            _nalLengthSize = nalLen;
        }
    }
    if (isAnnexB) {
        VCamCollectParameterSets(data, spsList, ppsList);
    }

    // 会话还没建：需要 SPS/PPS 才能建
    os_unfair_lock_lock(&_lock);
    BOOL needSession = (_session == NULL);
    BOOL needKey = _needKeyframe;
    os_unfair_lock_unlock(&_lock);

    if (needSession) {
        NSData *sps = spsList.count ? spsList[0] : spsFromExtra;
        NSData *pps = ppsList.count ? ppsList[0] : ppsFromExtra;
        if (!sps || !pps) {
            // 还没拿到参数集：静默丢包（这是正常启动流程，1 秒内会拿到）
            return;
        }
        if (![self _createSessionWithSPS:sps pps:pps]) {
            return;
        }
        needKey = YES;
    }

    if (needKey && !isKeyframe) {
        os_unfair_lock_lock(&_lock);
        _dropped++;
        os_unfair_lock_unlock(&_lock);
        return;   // 等下一个 IDR，避免花屏
    }
    if (isKeyframe) {
        os_unfair_lock_lock(&_lock);
        _needKeyframe = NO;
        os_unfair_lock_unlock(&_lock);
    }

    // 统一转成 AVCC（长度前缀）
    NSData *avcc = isAnnexB ? VCamConvertAnnexBToAVCC(data, _nalLengthSize) : data;
    if (!avcc.length) {
        os_unfair_lock_lock(&_lock);
        _dropped++;
        os_unfair_lock_unlock(&_lock);
        return;
    }

    os_unfair_lock_lock(&_lock);
    CMFormatDescriptionRef fmt = _formatDesc ? (CMFormatDescriptionRef)CFRetain(_formatDesc) : NULL;
    VTDecompressionSessionRef session = _session ? (VTDecompressionSessionRef)CFRetain(_session) : NULL;
    os_unfair_lock_unlock(&_lock);
    if (!fmt || !session) {
        if (fmt) CFRelease(fmt);
        if (session) CFRelease(session);
        return;
    }

    // ---- 组装 CMBlockBuffer + CMSampleBuffer ----
    CMBlockBufferRef bb = NULL;
    OSStatus st = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL,
                                                     avcc.length, kCFAllocatorDefault,
                                                     NULL, 0, avcc.length,
                                                     kCMBlockBufferAssureMemoryNowFlag, &bb);
    if (st != kCMBlockBufferNoErr || !bb) {
        CFRelease(fmt); CFRelease(session);
        return;
    }
    CMBlockBufferReplaceDataBytes(avcc.bytes, bb, 0, avcc.length);

    CMTime ts = CMTimeMake(ptsMs, 1000);
    if (ptsMs == INT64_MIN) ts = CMClockGetTime(CMClockGetHostTimeClock());
    CMSampleTimingInfo timing = {
        .duration = CMTimeMake(1, 30),
        .presentationTimeStamp = ts,
        .decodeTimeStamp = kCMTimeInvalid,
    };
    size_t sampleSize = avcc.length;
    CMSampleBufferRef sb = NULL;
    st = CMSampleBufferCreateReady(kCFAllocatorDefault, bb, fmt, 1, 1, &timing, 1, &sampleSize, &sb);
    CFRelease(bb);
    if (st != noErr || !sb) {
        CFRelease(fmt); CFRelease(session);
        os_unfair_lock_lock(&_lock);
        _dropped++;
        os_unfair_lock_unlock(&_lock);
        return;
    }

    VTDecodeInfoFlags flags = 0;
    VTDecodeFrameFlags decodeFlags = kVTDecodeFrame_EnableAsynchronousDecompression |
                                     kVTDecodeFrame_EnableTemporalProcessing;
    st = VTDecompressionSessionDecodeFrame(session, sb, decodeFlags, (void *)(intptr_t)ptsMs, &flags);
    if (st != noErr) {
        VCamLog(@"[vt] DecodeFrame 失败 %d", (int)st);
        os_unfair_lock_lock(&_lock);
        _dropped++;
        // 会话可能已损坏（例如流参数变了）：重建
        _needKeyframe = YES;
        os_unfair_lock_unlock(&_lock);
    }
    CFRelease(sb);
    CFRelease(fmt);
    CFRelease(session);
}

@end

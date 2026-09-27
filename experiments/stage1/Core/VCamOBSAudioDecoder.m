//
//  VCamOBSAudioDecoder.m
//  VCam
//

#import "VCamOBSAudioDecoder.h"
#import "VCamConfig.h"
#import <AudioToolbox/AudioToolbox.h>
#import <os/lock.h>

/// 从 AudioSpecificConfig (ASC) 里解析出 objectType / sampleRate / channels
static BOOL VCamParseAudioSpecificConfig(NSData *asc,
                                         UInt32 *outObjectType,
                                         UInt32 *outSampleRate,
                                         UInt32 *outChannels) {
    if (asc.length < 2) return NO;
    const uint8_t *b = asc.bytes;
    // 位读取（ASC 是紧凑位流）
    uint32_t bitPos = 0;
    #define READ_BITS(n) ({ uint32_t v = 0; for (uint32_t i = 0; i < (n); i++) { \
        uint32_t byteIdx = (bitPos) >> 3; uint32_t bitIdx = 7 - ((bitPos) & 7); \
        if (byteIdx < asc.length) v = (v << 1) | ((b[byteIdx] >> bitIdx) & 1); \
        else v = (v << 1); (bitPos)++; } v; })

    static const UInt32 kRates[16] = {
        96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
        16000, 12000, 11025, 8000, 7350, 0, 0, 0
    };

    UInt32 objType = READ_BITS(5);
    if (objType == 31) objType = 32 + READ_BITS(6);   // 扩展 object type
    UInt32 freqIdx = READ_BITS(4);
    UInt32 rate = (freqIdx == 15) ? READ_BITS(24) : (freqIdx < 16 ? kRates[freqIdx] : 0);
    UInt32 chCfg = READ_BITS(4);
    #undef READ_BITS

    if (outObjectType) *outObjectType = objType;
    if (outSampleRate) *outSampleRate = rate ?: 48000;
    if (outChannels) *outChannels = (chCfg > 0 && chCfg <= 7) ? chCfg : 2;
    return rate > 0;
}

@implementation VCamOBSAudioDecoder {
    AudioConverterRef _converter;
    AudioStreamBasicDescription _inASBD;
    AudioStreamBasicDescription _outASBD;
    os_unfair_lock _lock;
    NSData *_pendingFrame;      // 当前待解帧（AudioConverter 回调从这里取）
    UInt32 _pendingOffset;
    uint64_t _decoded;
    uint64_t _dropped;
    int64_t _firstPtsMs;
    CMTime _anchorHostTime;
    // 解码输出缓冲
    float *_outBuf;
    size_t _outBufFrames;
    UInt32 _inChannels;
    UInt32 _inSampleRate;
}

- (instancetype)init {
    if ((self = [super init])) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _outputSampleRate = 48000.0;
        _outputChannels = 2;
        _gain = 1.0f;
        _firstPtsMs = INT64_MIN;
        _outBufFrames = 8192;
        _outBuf = (float *)calloc(_outBufFrames * 2, sizeof(float));
    }
    return self;
}

- (void)dealloc {
    [self reset];
    if (_outBuf) free(_outBuf);
}

- (uint64_t)decodedFrames { os_unfair_lock_lock(&_lock); uint64_t v = _decoded; os_unfair_lock_unlock(&_lock); return v; }
- (uint64_t)droppedFrames { os_unfair_lock_lock(&_lock); uint64_t v = _dropped; os_unfair_lock_unlock(&_lock); return v; }

- (void)reset {
    os_unfair_lock_lock(&_lock);
    if (_converter) {
        AudioConverterDispose(_converter);
        _converter = NULL;
    }
    memset(&_inASBD, 0, sizeof(_inASBD));
    memset(&_outASBD, 0, sizeof(_outASBD));
    _pendingFrame = nil;
    _pendingOffset = 0;
    _firstPtsMs = INT64_MIN;
    os_unfair_lock_unlock(&_lock);
}

#pragma mark - AudioConverter 输入回调

typedef struct {
    const uint8_t *data;
    UInt32 size;
    UInt32 offset;
    UInt32 packetCount;    // 已经发出的包数
    UInt32 totalPackets;   // 本帧包含几个 AAC 包（TS 里通常就是 1）
} VCamAudioFeedCtx;

static OSStatus VCamAudioConverterInputProc(AudioConverterRef inConverter,
                                            UInt32 *ioNumberDataPackets,
                                            AudioBufferList *ioData,
                                            AudioStreamPacketDescription **outDataPacketDescription,
                                            void *inUserData) {
    VCamAudioFeedCtx *ctx = (VCamAudioFeedCtx *)inUserData;
    if (!ctx || *ioNumberDataPackets == 0) {
        *ioNumberDataPackets = 0;
        return noErr;
    }

    // 每次回调只提供一个 AAC 包。
    // 为什么：AudioConverter 的输入回调语义是"请给我 N 个 packet"，
    // 一次把整块数据给它会造成 VBR 包边界错乱。TS 里一个 PES 就是
    // 一个 AAC raw frame，所以按单包喂是最稳的。
    UInt32 packetsLeft = ctx->totalPackets > ctx->packetCount
                       ? (ctx->totalPackets - ctx->packetCount) : 0;
    if (packetsLeft == 0) {
        *ioNumberDataPackets = 0;
        return noErr;   // 没有更多数据
    }

    UInt32 remaining = ctx->size - ctx->offset;
    ioData->mNumberBuffers = 1;
    ioData->mBuffers[0].mNumberChannels = 0;
    ioData->mBuffers[0].mDataByteSize = remaining;
    ioData->mBuffers[0].mData = (void *)(ctx->data + ctx->offset);
    if (outDataPacketDescription) {
        // AAC 是 VBR，需要给包描述
        static AudioStreamPacketDescription desc;
        desc.mStartOffset = 0;
        desc.mVariableFramesInPacket = 0;   // 0 = 由解码器按 1024 处理
        desc.mDataByteSize = remaining;
        *outDataPacketDescription = &desc;
    }
    ctx->offset += remaining;
    ctx->packetCount++;
    *ioNumberDataPackets = 1;
    return noErr;
}

#pragma mark - 建立转换器

- (BOOL)_ensureConverterWithASC:(NSData *)asc
                     sampleRate:(int)sampleRate
                       channels:(int)channels {
    if (_converter) return YES;

    UInt32 objType = 2, rate = (UInt32)(sampleRate > 0 ? sampleRate : 48000), ch = (UInt32)(channels > 0 ? channels : 2);
    if (asc.length >= 2) {
        VCamParseAudioSpecificConfig(asc, &objType, &rate, &ch);
    }
    if (objType != 2 && objType != 5) {
        // HE-AAC(5) 在 iOS 上 AudioConverter 也支持；其它 object type 走软解兜底
        VCamLog(@"[obs][aac] objectType=%u 非 AAC-LC/HE，尝试按 LC 处理", (unsigned)objType);
        objType = 2;
    }

    AudioStreamBasicDescription in = {0};
    in.mSampleRate = rate;
    in.mFormatID = kAudioFormatMPEG4AAC;
    in.mFormatFlags = 0;
    in.mChannelsPerFrame = ch;
    in.mFramesPerPacket = 1024;
    in.mBytesPerPacket = 0;              // VBR
    in.mBytesPerFrame = 0;
    in.mBitsPerChannel = 0;

    AudioStreamBasicDescription out = {0};
    out.mSampleRate = self.outputSampleRate;
    out.mFormatID = kAudioFormatLinearPCM;
    out.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    out.mChannelsPerFrame = self.outputChannels;
    out.mFramesPerPacket = 1;
    out.mBytesPerFrame = sizeof(float) * out.mChannelsPerFrame;
    out.mBytesPerPacket = out.mBytesPerFrame;
    out.mBitsPerChannel = 32;

    AudioConverterRef conv = NULL;
    OSStatus st = AudioConverterNew(&in, &out, &conv);
    if (st != noErr || !conv) {
        VCamLog(@"[obs][aac] AudioConverterNew 失败 %d", (int)st);
        return NO;
    }
    // 让 AAC 解码器优先使用系统硬件解码
    UInt32 canHW = 0, size = sizeof(canHW);
    AudioConverterGetProperty(conv, kAudioConverterPropertyCanAccessRawHardware, &size, &canHW);

    if (asc.length > 0) {
        // 设置 magic cookie（ASC）
        UInt32 cookieSize = (UInt32)asc.length;
        st = AudioConverterSetProperty(conv, kAudioConverterDecompressionMagicCookie,
                                       cookieSize, asc.bytes);
        if (st != noErr) {
            VCamLog(@"[obs][aac] 设置 magic cookie 失败 %d（继续尝试）", (int)st);
        }
    }

    _converter = conv;
    _inASBD = in;
    _outASBD = out;
    _inChannels = ch;
    _inSampleRate = rate;
    VCamLog(@"[obs][aac] 解码器就绪 %uHz %uch -> %.0fHz %uch",
            (unsigned)rate, (unsigned)ch,
            self.outputSampleRate, (unsigned)self.outputChannels);
    return YES;
}

#pragma mark - 送帧

- (void)feedAACFrame:(NSData *)frame
           extradata:(NSData *)extradata
          sampleRate:(int)sampleRate
            channels:(int)channels
               ptsMs:(int64_t)ptsMs {
    if (!frame.length) return;

    os_unfair_lock_lock(&_lock);
    if (!_converter) {
        if (![self _ensureConverterWithASC:extradata sampleRate:sampleRate channels:channels]) {
            _dropped++;
            os_unfair_lock_unlock(&_lock);
            return;
        }
    }
    if (_firstPtsMs == INT64_MIN) {
        _firstPtsMs = ptsMs;
        _anchorHostTime = CMClockGetTime(CMClockGetHostTimeClock());
    }
    CMTime anchor = _anchorHostTime;
    int64_t base = _firstPtsMs;
    AudioConverterRef conv = _converter;
    Float64 outRate = _outASBD.mSampleRate;
    UInt32 outCh = _outASBD.mChannelsPerFrame;
    os_unfair_lock_unlock(&_lock);

    VCamAudioFeedCtx ctx = { .data = frame.bytes, .size = (UInt32)frame.length,
                             .offset = 0, .packetCount = 0, .totalPackets = 1 };

    size_t framesOut = _outBufFrames;
    while (ctx.offset < ctx.size && ctx.packetCount < ctx.totalPackets) {
        UInt32 outPackets = (UInt32)framesOut;
        AudioBufferList abl = {0};
        abl.mNumberBuffers = 1;
        abl.mBuffers[0].mNumberChannels = outCh;
        abl.mBuffers[0].mDataByteSize = (UInt32)(framesOut * sizeof(float) * outCh);
        abl.mBuffers[0].mData = _outBuf;

        OSStatus st = AudioConverterFillComplexBuffer(conv,
                                                      VCamAudioConverterInputProc,
                                                      &ctx,
                                                      &outPackets,
                                                      &abl,
                                                      NULL);
        if (st != noErr && st != kAudioConverterErr_NoMoreData) {
            VCamLog(@"[obs][aac] FillComplexBuffer 失败 %d", (int)st);
            break;
        }
        if (outPackets == 0) break;

        // 音量
        float gain = self.gain;
        if (gain != 1.0f) {
            size_t n = outPackets * outCh;
            for (size_t i = 0; i < n; i++) {
                float v = _outBuf[i] * gain;
                _outBuf[i] = MAX(-1.0f, MIN(1.0f, v));
            }
        }

        CMTime ts = CMTimeAdd(anchor, CMTimeMake(ptsMs - base, 1000));

        VCamPCMHandler h = self.pcmHandler;
        if (h) {
            @try { h(_outBuf, outPackets, outCh, outRate, ts); }
            @catch (NSException *e) { VCamLog(@"[obs][aac] pcm handler 异常 %@", e); }
        }
        os_unfair_lock_lock(&_lock);
        _decoded += outPackets;
        os_unfair_lock_unlock(&_lock);

        if (st == kAudioConverterErr_NoMoreData) break;
    }
    if (ctx.offset == 0) {
        os_unfair_lock_lock(&_lock);
        _dropped++;
        os_unfair_lock_unlock(&_lock);
    }
}

@end

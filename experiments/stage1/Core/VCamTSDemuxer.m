//
//  VCamTSDemuxer.m
//  VCam
//

#import "VCamTSDemuxer.h"
#import "VCamConfig.h"
#import <os/lock.h>
#import <pthread.h>

#if VCAM_ENABLE_OBS
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/imgutils.h>
#endif

@implementation VCamTSDemuxer {
    NSString *_urlString;
    NSString *_transport;
    pthread_t _thread;
    BOOL _running;
    os_unfair_lock _lock;
    uint64_t _videoCount, _audioCount, _errCount;
    double _bitrateKbps;
    NSTimeInterval _startTime;
    uint64_t _bytesSinceLastCalc;
    NSTimeInterval _lastCalcTime;
    BOOL _gotKeyframe;
}

- (instancetype)initWithURLString:(NSString *)urlString transport:(NSString *)transport {
    if ((self = [super init])) {
        _urlString = [urlString copy];
        _transport = [transport.lowercaseString isEqualToString:@"tcp"] ? @"tcp" : @"udp";
        _lock = OS_UNFAIR_LOCK_INIT;
    }
    return self;
}

- (uint64_t)videoPacketCount { os_unfair_lock_lock(&_lock); uint64_t v = _videoCount; os_unfair_lock_unlock(&_lock); return v; }
- (uint64_t)audioPacketCount { os_unfair_lock_lock(&_lock); uint64_t v = _audioCount; os_unfair_lock_unlock(&_lock); return v; }
- (uint64_t)errorCount { os_unfair_lock_lock(&_lock); uint64_t v = _errCount; os_unfair_lock_unlock(&_lock); return v; }
- (double)bitrateKbps { os_unfair_lock_lock(&_lock); double v = _bitrateKbps; os_unfair_lock_unlock(&_lock); return v; }
- (BOOL)gotKeyframe { os_unfair_lock_lock(&_lock); BOOL v = _gotKeyframe; os_unfair_lock_unlock(&_lock); return v; }

#pragma mark - 生命周期

#if VCAM_ENABLE_OBS

typedef struct {
    VCamTSDemuxer * __unsafe_unretained demuxer;
} VCamInterruptCookie;

static int vcam_interrupt_cb(void *opaque) {
    VCamInterruptCookie *cookie = (VCamInterruptCookie *)opaque;
    if (!cookie || !cookie->demuxer) return 0;
    return cookie->demuxer->_running ? 0 : 1;   // 返回 1 = 中断
}

static void *vcam_demux_thread(void *opaque) {
    VCamTSDemuxer *self = (__bridge VCamTSDemuxer *)opaque;
    [self _runReadLoop];
    return NULL;
}

- (BOOL)start {
    if (_running) return YES;
    if (_urlString.length == 0) {
        self.lastError = @"推流地址为空";
        return NO;
    }
    _running = YES;
    _startTime = NSDate.date.timeIntervalSince1970;
    _lastCalcTime = _startTime;

    int rc = pthread_create(&_thread, NULL, vcam_demux_thread, (__bridge void *)self);
    if (rc != 0) {
        _running = NO;
        self.lastError = [NSString stringWithFormat:@"无法创建接收线程 (%d)", rc];
        return NO;
    }
    return YES;
}

- (void)stop {
    if (!_running) return;
    _running = NO;
    // interrupt_callback 会打断阻塞中的 av_read_frame / recv，
    // 但为保险再 join 一次（最多等 2 秒，超时不 join 直接标记结束）
    pthread_join(_thread, NULL);
}

- (void)_runReadLoop {
    AVFormatContext *fmt = NULL;
    VCamInterruptCookie cookie = { .demuxer = self };
    AVDictionary *opts = NULL;

    // ---- 低延迟参数 ----
    // 关键：OBS 推来的 TS 是"实时流"，必须让 FFmpeg 不要缓冲。
    av_dict_set(&opts, "fflags", "nobuffer", 0);
    av_dict_set(&opts, "flags", "low_delay", 0);
    av_dict_set(&opts, "probesize", "32768", 0);
    av_dict_set(&opts, "analyzeduration", "500000", 0);
    av_dict_set(&opts, "max_delay", "500000", 0);
    if ([_transport isEqualToString:@"udp"]) {
        // 允许端口复用 + 加大接收缓冲，避免 Wi-Fi 抖动导致丢包黑屏
        av_dict_set(&opts, "reuse", "1", 0);
        av_dict_set(&opts, "buffer_size", "4194304", 0);
        av_dict_set(&opts, "fifo_size", "5000000", 0);
        av_dict_set(&opts, "overrun_nonfatal", "1", 0);
    } else {
        av_dict_set(&opts, "listen", "1", 0);       // TCP 服务端模式
        av_dict_set(&opts, "tcp_nodelay", "1", 0);
    }

    AVInputFormat *inFmt = av_find_input_format("mpegts");
    int rc = avformat_open_input(&fmt, _urlString.UTF8String, inFmt, &opts);
    av_dict_free(&opts);
    if (rc < 0 || !fmt) {
        char errbuf[128] = {0};
        av_strerror(rc, errbuf, sizeof(errbuf));
        self.lastError = [NSString stringWithFormat:@"打开流失败: %s。请确认 OBS 地址与手机显示的完全一致", errbuf];
        VCamLog(@"[obs] open_input 失败 %d (%s) url=%@", rc, errbuf, _urlString);
        _running = NO;
        return;
    }
    fmt->interrupt_callback.callback = vcam_interrupt_cb;
    fmt->interrupt_callback.opaque = &cookie;
    fmt->flags |= AVFMT_FLAG_NOBUFFER | AVFMT_FLAG_FLUSH_PACKETS;

    // 流信息（probe 阶段）不强求，mpegts 一般能直接识别
    if (avformat_find_stream_info(fmt, NULL) < 0) {
        VCamLog(@"[obs] find_stream_info 失败，继续尝试直接读包");
    }

    int videoIdx = -1, audioIdx = -1;
    for (unsigned i = 0; i < fmt->nb_streams; i++) {
        AVCodecParameters *par = fmt->streams[i]->codecpar;
        if (par->codec_type == AVMEDIA_TYPE_VIDEO && videoIdx < 0) {
            videoIdx = (int)i;
            VCamLog(@"[obs] 视频流 #%d codec=%s %dx%d", i,
                    avcodec_get_name(par->codec_id), par->width, par->height);
        } else if (par->codec_type == AVMEDIA_TYPE_AUDIO && audioIdx < 0) {
            audioIdx = (int)i;
            VCamLog(@"[obs] 音频流 #%d codec=%s %dHz %dch", i,
                    avcodec_get_name(par->codec_id), par->sample_rate, par->channels);
        }
    }
    if (videoIdx < 0) {
        self.lastError = @"流里没有视频轨。请检查 OBS 是否在推 H.264 视频";
        VCamLog(@"[obs] 没有视频轨");
        avformat_close_input(&fmt);
        _running = NO;
        return;
    }

    AVPacket *pkt = av_packet_alloc();
    self.lastError = nil;

    while (_running) {
        @autoreleasepool {
            int r = av_read_frame(fmt, pkt);
            if (r < 0) {
                if (r == AVERROR(EAGAIN)) { usleep(2000); continue; }
                if (r == AVERROR_EXIT) break;         // 我们自己中断的
                if (r == AVERROR_EOF) {
                    VCamLog(@"[obs] 流结束（OBS 可能停止了推流）");
                    self.lastError = @"OBS 已断开推流";
                    break;
                }
                os_unfair_lock_lock(&_lock);
                _errCount++;
                os_unfair_lock_unlock(&_lock);
                usleep(5000);
                continue;
            }

            AVCodecParameters *par = fmt->streams[pkt->stream_index]->codecpar;
            AVRational tb = fmt->streams[pkt->stream_index]->time_base;
            int64_t ptsMs = (pkt->pts == AV_NOPTS_VALUE)
                          ? (int64_t)((NSDate.date.timeIntervalSince1970 - _startTime) * 1000.0)
                          : av_rescale_q(pkt->pts, tb, (AVRational){1, 1000});

            // extradata（SPS/PPS 或 AudioSpecificConfig）
            NSData *extradata = nil;
            if (par->extradata && par->extradata_size > 0) {
                extradata = [NSData dataWithBytes:par->extradata length:par->extradata_size];
            }

            _bytesSinceLastCalc += (uint64_t)pkt->size;

            if (pkt->stream_index == videoIdx) {
                NSData *data = [NSData dataWithBytes:pkt->data length:pkt->size];
                BOOL key = (pkt->flags & AV_PKT_FLAG_KEY) != 0;
                if (key) {
                    os_unfair_lock_lock(&_lock);
                    _gotKeyframe = YES;
                    os_unfair_lock_unlock(&_lock);
                }
                os_unfair_lock_lock(&_lock);
                _videoCount++;
                os_unfair_lock_unlock(&_lock);

                VCamTSVideoPacketHandler h = self.videoHandler;
                if (h) { @try { h(data, extradata, key, ptsMs); }
                         @catch (NSException *e) { VCamLog(@"[obs] video handler 异常 %@", e); } }
            } else if (pkt->stream_index == audioIdx) {
                NSData *data = [NSData dataWithBytes:pkt->data length:pkt->size];
                os_unfair_lock_lock(&_lock);
                _audioCount++;
                os_unfair_lock_unlock(&_lock);

                VCamTSAudioPacketHandler h = self.audioHandler;
                if (h) { @try { h(data, extradata, par->sample_rate,
                                  MAX(1, par->channels), ptsMs); }
                         @catch (NSException *e) { VCamLog(@"[obs] audio handler 异常 %@", e); } }
            }
            av_packet_unref(pkt);

            // 每秒算一次码率，给 UI 显示
            NSTimeInterval now = NSDate.date.timeIntervalSince1970;
            if (now - _lastCalcTime >= 1.0) {
                os_unfair_lock_lock(&_lock);
                _bitrateKbps = (_bytesSinceLastCalc * 8.0 / 1000.0) / (now - _lastCalcTime);
                os_unfair_lock_unlock(&_lock);
                _bytesSinceLastCalc = 0;
                _lastCalcTime = now;
            }
        }
    }

    if (pkt) av_packet_free(&pkt);
    avformat_close_input(&fmt);
    _running = NO;
    VCamLog(@"[obs] 接收线程退出（视频包=%llu 音频包=%llu 错误=%llu）",
            (unsigned long long)_videoCount,
            (unsigned long long)_audioCount,
            (unsigned long long)_errCount);
}

#else  /* VCAM_ENABLE_OBS == 0 */

- (BOOL)start {
    self.lastError = @"本包未编译 OBS 支持（构建时 VCAM_ENABLE_OBS=0）";
    return NO;
}
- (void)stop {}

#endif

@end

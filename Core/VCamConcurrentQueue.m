//
//  VCamConcurrentQueue.m
//  VCam
//

#import "VCamConcurrentQueue.h"
#import <os/lock.h>

typedef struct {
    CVPixelBufferRef buffer;
    CMTime time;
} VCamQueueSlot;

@implementation VCamConcurrentQueue {
    VCamQueueSlot *_slots;
    NSUInteger _capacity;
    NSUInteger _count;
    NSUInteger _head;   // 出队位置
    NSUInteger _tail;   // 入队位置
    os_unfair_lock _lock;
}

- (instancetype)initWithCapacity:(NSUInteger)capacity {
    if ((self = [super init])) {
        _capacity = MAX(1, capacity);
        _slots = (VCamQueueSlot *)calloc(_capacity, sizeof(VCamQueueSlot));
        _count = 0;
        _head = 0;
        _tail = 0;
        _lock = OS_UNFAIR_LOCK_INIT;
        if (!_slots) return nil;
    }
    return self;
}

- (void)dealloc {
    [self flush];
    if (_slots) free(_slots);
}

- (NSUInteger)count {
    os_unfair_lock_lock(&_lock);
    NSUInteger c = _count;
    os_unfair_lock_unlock(&_lock);
    return c;
}

- (BOOL)enqueuePixelBuffer:(CVPixelBufferRef)pixelBuffer atTime:(CMTime)time {
    if (!pixelBuffer) return NO;
    CVPixelBufferRetain(pixelBuffer);
    os_unfair_lock_lock(&_lock);
    if (_count == _capacity) {
        // 丢最旧
        CVPixelBufferRef old = _slots[_head].buffer;
        _slots[_head].buffer = NULL;
        _head = (_head + 1) % _capacity;
        _count--;
        os_unfair_lock_unlock(&_lock);
        if (old) CVPixelBufferRelease(old);
        os_unfair_lock_lock(&_lock);
    }
    _slots[_tail].buffer = pixelBuffer;
    _slots[_tail].time = time;
    _tail = (_tail + 1) % _capacity;
    _count++;
    os_unfair_lock_unlock(&_lock);
    return YES;
}

- (CVPixelBufferRef)dequeuePixelBufferWithTime:(CMTime *)outTime {
    CVPixelBufferRef pb = NULL;
    CMTime t = kCMTimeInvalid;
    os_unfair_lock_lock(&_lock);
    if (_count > 0) {
        pb = _slots[_head].buffer;   // 引用转移给调用方，不再 +1
        t = _slots[_head].time;
        _slots[_head].buffer = NULL;
        _head = (_head + 1) % _capacity;
        _count--;
    }
    os_unfair_lock_unlock(&_lock);
    if (outTime) *outTime = t;
    return pb;
}

- (CVPixelBufferRef)dequeueLatestPixelBufferWithTime:(CMTime *)outTime {
    CVPixelBufferRef latest = NULL;
    CMTime t = kCMTimeInvalid;
    os_unfair_lock_lock(&_lock);
    while (_count > 0) {
        CVPixelBufferRef cur = _slots[_head].buffer;
        CMTime ct = _slots[_head].time;
        _slots[_head].buffer = NULL;
        _head = (_head + 1) % _capacity;
        _count--;
        if (latest) CVPixelBufferRelease(latest);
        latest = cur;
        t = ct;
    }
    os_unfair_lock_unlock(&_lock);
    if (outTime) *outTime = t;
    return latest;
}

- (void)flush {
    os_unfair_lock_lock(&_lock);
    for (NSUInteger i = 0; i < _count; i++) {
        NSUInteger idx = (_head + i) % _capacity;
        if (_slots[idx].buffer) {
            CVPixelBufferRelease(_slots[idx].buffer);
            _slots[idx].buffer = NULL;
        }
    }
    _count = 0;
    _head = 0;
    _tail = 0;
    os_unfair_lock_unlock(&_lock);
}

@end

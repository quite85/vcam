//
//  VCamStateStore.m
//  VCam
//

#import "VCamStateStore.h"
#import <notify.h>
#import <os/lock.h>
#import <sys/stat.h>

static const NSInteger kVCamSchemaVersion = 1;
static const uint16_t  kVCamDefaultPort    = 5600;  // OBS 推流默认端口

@implementation VCamStateStore {
    NSMutableDictionary *_dict;
    os_unfair_lock _lock;
    int _notifyToken;
    BOOL _observing;
    NSMutableArray<void (^)(void)> *_observers;
}

+ (instancetype)shared {
    static VCamStateStore *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [[VCamStateStore alloc] init];
    });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _observers = [NSMutableArray array];
        _notifyToken = 0;
        [self _loadFromDisk];
    }
    return self;
}

- (void)dealloc {
    if (_notifyToken) notify_cancel(_notifyToken);
}

#pragma mark - 默认值

- (NSDictionary *)_defaults {
    return @{
        kVCamStateKeyMode          : @(VCamModeDisabled),
        kVCamStateKeyAssetPath     : @"",
        kVCamStateKeyAssetIsVideo  : @(NO),
        kVCamStateKeyRotation      : @(0),
        kVCamStateKeyMirror        : @(NO),
        kVCamStateKeyMirrorBack    : @(YES),
        kVCamStateKeyLoop          : @(YES),
        kVCamStateKeyPort          : @(kVCamDefaultPort),
        kVCamStateKeyTransport     : @"udp",
        kVCamStateKeyLatencyMs     : @(120),
        kVCamStateKeyAudioKind     : @(VCamAudioSourceNone),
        kVCamStateKeyAudioVolume   : @(1.0f),
        kVCamStateKeyLipSyncMs     : @(0),
        kVCamStateKeyMSDDisabled   : @(NO),
        kVCamStateKeyAppLayerOnly  : @(NO),
        kVCamStateKeySessionActive : @(NO),
        kVCamStateKeyLastError     : @"",
        kVCamStateKeyVersion       : @(kVCamSchemaVersion),
    };
}

#pragma mark - 磁盘 IO

- (void)_loadFromDisk {
    NSMutableDictionary *d = [[self _defaults] mutableCopy];
    NSDictionary *onDisk = [NSDictionary dictionaryWithContentsOfFile:VCamStateFilePath()];
    if ([onDisk isKindOfClass:NSDictionary.class]) {
        [d addEntriesFromDictionary:onDisk];
    }
    os_unfair_lock_lock(&_lock);
    _dict = d;
    os_unfair_lock_unlock(&_lock);
}

- (void)_writeToDisk {
    NSDictionary *snapshot;
    os_unfair_lock_lock(&_lock);
    snapshot = [_dict copy];
    os_unfair_lock_unlock(&_lock);

    NSString *path = VCamStateFilePath();
    NSString *tmp = [path stringByAppendingString:@".tmp"];
    // 原子写：先写 .tmp 再 rename，避免 mediaserverd 读到半个文件
    if ([snapshot writeToFile:tmp atomically:YES]) {
        chmod(tmp.fileSystemRepresentation, 0644);
        rename(tmp.fileSystemRepresentation, path.fileSystemRepresentation);
        chmod(path.fileSystemRepresentation, 0644);
    } else {
        VCamLog(@"[state] 写入失败 %@", path);
    }
    uint32_t token = 0;
    notify_register_check(kVCamNotificationStateChanged.UTF8String, &token);
    if (token) {
        notify_set_state(token, (uint64_t)NSDate.date.timeIntervalSince1970);
        notify_post(kVCamNotificationStateChanged.UTF8String);
        notify_cancel(token);
    } else {
        notify_post(kVCamNotificationStateChanged.UTF8String);
    }
}

- (void)reload {
    [self _loadFromDisk];
    for (void (^b)(void) in [_observers copy]) {
        @try { b(); } @catch (NSException *e) { VCamLog(@"[state] observer 异常 %@", e); }
    }
}

#pragma mark - 读

- (id)_obj:(NSString *)key {
    os_unfair_lock_lock(&_lock);
    id v = _dict[key];
    os_unfair_lock_unlock(&_lock);
    return v;
}

- (NSDictionary *)raw {
    os_unfair_lock_lock(&_lock);
    NSDictionary *d = [_dict copy];
    os_unfair_lock_unlock(&_lock);
    return d;
}

- (VCamMode)mode {
    NSNumber *n = [self _obj:kVCamStateKeyMode];
    VCamMode m = (VCamMode)n.integerValue;
    if (m < VCamModeDisabled || m > VCamModeOBS) m = VCamModeDisabled;
    return m;
}
- (NSString *)assetPath {
    NSString *s = [self _obj:kVCamStateKeyAssetPath];
    return [s isKindOfClass:NSString.class] ? s : @"";
}
- (BOOL)assetIsVideo { return [[self _obj:kVCamStateKeyAssetIsVideo] boolValue]; }
- (NSInteger)rotation { return [[self _obj:kVCamStateKeyRotation] integerValue]; }
- (BOOL)mirror { return [[self _obj:kVCamStateKeyMirror] boolValue]; }
- (BOOL)mirrorBack { return [[self _obj:kVCamStateKeyMirrorBack] boolValue]; }
- (BOOL)loop { return [[self _obj:kVCamStateKeyLoop] boolValue]; }
- (uint16_t)port {
    NSInteger p = [[self _obj:kVCamStateKeyPort] integerValue];
    if (p <= 1024 || p > 65535) p = kVCamDefaultPort;
    return (uint16_t)p;
}
- (NSString *)transport {
    NSString *t = [self _obj:kVCamStateKeyTransport];
    if (![t isKindOfClass:NSString.class] || t.length == 0) return @"udp";
    return [t.lowercaseString isEqualToString:@"tcp"] ? @"tcp" : @"udp";
}
- (NSInteger)latencyMs { return MAX(0, [[self _obj:kVCamStateKeyLatencyMs] integerValue]); }
- (VCamAudioSourceKind)audioKind {
    return (VCamAudioSourceKind)[[self _obj:kVCamStateKeyAudioKind] integerValue];
}
- (float)audioVolume {
    float v = [[self _obj:kVCamStateKeyAudioVolume] floatValue];
    return MAX(0.0f, MIN(2.0f, v));
}
- (NSInteger)lipSyncMs { return [[self _obj:kVCamStateKeyLipSyncMs] integerValue]; }
- (BOOL)msdDisabled { return [[self _obj:kVCamStateKeyMSDDisabled] boolValue]; }
- (BOOL)appLayerOnly { return [[self _obj:kVCamStateKeyAppLayerOnly] boolValue]; }
- (NSString *)lastError {
    NSString *s = [self _obj:kVCamStateKeyLastError];
    return [s isKindOfClass:NSString.class] ? s : @"";
}

#pragma mark - 写

- (void)update:(void (^)(NSMutableDictionary *))block {
    if (!block) return;
    os_unfair_lock_lock(&_lock);
    if (!_dict) _dict = [[self _defaults] mutableCopy];
    block(_dict);
    os_unfair_lock_unlock(&_lock);
    [self _writeToDisk];
}

- (void)setMode:(VCamMode)mode {
    [self update:^(NSMutableDictionary *d) { d[kVCamStateKeyMode] = @(mode); }];
}
- (void)setAssetPath:(NSString *)path isVideo:(BOOL)isVideo {
    [self update:^(NSMutableDictionary *d) {
        d[kVCamStateKeyAssetPath] = path ?: @"";
        d[kVCamStateKeyAssetIsVideo] = @(isVideo);
    }];
}
- (void)setRotation:(NSInteger)rotation {
    NSInteger r = ((rotation % 360) + 360) % 360;
    [self update:^(NSMutableDictionary *d) { d[kVCamStateKeyRotation] = @(r); }];
}
- (void)setMirror:(BOOL)mirror {
    [self update:^(NSMutableDictionary *d) { d[kVCamStateKeyMirror] = @(mirror); }];
}
- (void)setMirrorBack:(BOOL)mirrorBack {
    [self update:^(NSMutableDictionary *d) { d[kVCamStateKeyMirrorBack] = @(mirrorBack); }];
}
- (void)setLoop:(BOOL)loop {
    [self update:^(NSMutableDictionary *d) { d[kVCamStateKeyLoop] = @(loop); }];
}
- (void)setPort:(uint16_t)port {
    [self update:^(NSMutableDictionary *d) { d[kVCamStateKeyPort] = @(port); }];
}
- (void)setTransport:(NSString *)transport {
    NSString *t = [transport.lowercaseString isEqualToString:@"tcp"] ? @"tcp" : @"udp";
    [self update:^(NSMutableDictionary *d) { d[kVCamStateKeyTransport] = t; }];
}
- (void)setLatencyMs:(NSInteger)ms {
    [self update:^(NSMutableDictionary *d) { d[kVCamStateKeyLatencyMs] = @(MAX(0, ms)); }];
}
- (void)setAudioKind:(VCamAudioSourceKind)kind {
    [self update:^(NSMutableDictionary *d) { d[kVCamStateKeyAudioKind] = @(kind); }];
}
- (void)setAudioVolume:(float)volume {
    [self update:^(NSMutableDictionary *d) {
        d[kVCamStateKeyAudioVolume] = @(MAX(0.0f, MIN(2.0f, volume)));
    }];
}
- (void)setLipSyncMs:(NSInteger)ms {
    [self update:^(NSMutableDictionary *d) { d[kVCamStateKeyLipSyncMs] = @(ms); }];
}
- (void)setMSDDisabled:(BOOL)disabled {
    [self update:^(NSMutableDictionary *d) { d[kVCamStateKeyMSDDisabled] = @(disabled); }];
}
- (void)setAppLayerOnly:(BOOL)only {
    [self update:^(NSMutableDictionary *d) { d[kVCamStateKeyAppLayerOnly] = @(only); }];
}
- (void)recordError:(NSString *)error {
    [self update:^(NSMutableDictionary *d) { d[kVCamStateKeyLastError] = error ?: @""; }];
    VCamLog(@"[state] error: %@", error);
}

#pragma mark - 监听

- (void)observeChanges:(void (^)(void))block {
    if (!block) return;
    [_observers addObject:[block copy]];
    if (_observing) return;
    _observing = YES;
    __weak typeof(self) weakSelf = self;
    notify_register_dispatch(kVCamNotificationStateChanged.UTF8String,
                             &_notifyToken,
                             dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
                             ^(int token) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self _loadFromDisk];
        for (void (^b)(void) in [self->_observers copy]) {
            @try { b(); } @catch (NSException *e) { VCamLog(@"[state] observer 异常 %@", e); }
        }
    });
}

@end

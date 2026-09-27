//
//  VCamPhotoOutputInjector.m
//  VCam
//

#import "VCamPhotoOutputInjector.h"
#import "VCamConfig.h"
#import "VCamCore.h"
#import "VCamPixelBufferUtils.h"
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <ImageIO/ImageIO.h>
#import <os/lock.h>

/// 每个 delegate 对象上挂的最新虚拟 JPEG
static const void *kVCamVirtualJPEGKey = &kVCamVirtualJPEGKey;
static const void *kVCamVirtualDimsKey = &kVCamVirtualDimsKey;
static const void *kVCamSwizzledKey  = &kVCamSwizzledKey;
static os_unfair_lock gInjectLock = OS_UNFAIR_LOCK_INIT;

// ---------------------------------------------------------------------------
// 前向声明（必须放在所有 @implementation 之前）
// ---------------------------------------------------------------------------
// 下面两个方法定义在文件后部的 @implementation NSObject (VCamPhotoDelegate) 分类里，
// 但本文件开头的两个 C 函数（vcam_photoDidFinish_2 / _4）会调用它们。
// Objective-C 的方法调用不需要声明，但如果**完全不声明**，
// clang 在 C 函数里遇到 [(id)self someMethod:] 会报：
//     error: no known instance method for selector 'vcam_makePhotoFromJPEG:settings:'
// 所以在最前面把「某个 NSObject 上有这些实例方法」告诉编译器。
@interface NSObject (VCamPhotoDelegateForward)
- (AVCapturePhoto *)vcam_makePhotoFromJPEG:(NSData *)jpeg
                                  settings:(AVCaptureResolvedPhotoSettings *)resolved;
- (BOOL)vcam_tryReplacePhoto:(AVCapturePhoto **)photoPtr;
@end

@implementation VCamPhotoOutputInjector
+ (void)install {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = NSClassFromString(@"AVCapturePhotoOutput");
        if (!cls) {
            VCamLog(@"[photo] 找不到 AVCapturePhotoOutput，跳过");
            return;
        }
        // 1) capturePhotoWithSettings:delegate: —— 记下"这次要注入"
        [self _swizzle:cls
          originalSel:@selector(capturePhotoWithSettings:delegate:)
        replacementSel:@selector(vcam_capturePhotoWithSettings:delegate:)];

        // 2) capturePhotoWithSettings:delegate:（无 error 版本，部分旧代码用）
        if (class_respondsToSelector(cls, @selector(capturePhotoBracketSettings:delegate:))) {
            [self _swizzle:cls
              originalSel:@selector(capturePhotoBracketSettings:delegate:)
            replacementSel:@selector(vcam_capturePhotoBracketSettings:delegate:)];
        }
        [self _installDelegateSwizzles];
        VCamLog(@"[photo] 拍照注入已安装");
    });
}

// ---- 照片替换的两个实现 ----
// 用 C 函数避免 objc_msgSend 强转警告；内部再调回原 IMP。
static void vcam_photoDidFinish_2(id self, SEL _cmd, AVCapturePhotoOutput *output,
                                  AVCapturePhoto *photo, NSError *error) {
    if (photo) {
        @try {
            NSData *jpeg = objc_getAssociatedObject(self, kVCamVirtualJPEGKey);
            if (jpeg) {
                AVCapturePhoto *fake = [(id)self vcam_makePhotoFromJPEG:jpeg
                                                               settings:photo.resolvedSettings];
                if (fake) photo = fake;
                objc_setAssociatedObject(self, kVCamVirtualJPEGKey, nil,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        } @catch (NSException *e) {
            VCamLog(@"[photo] 替换照片异常（透传真实照片）: %@", e);
        }
    }
    // 调用原 IMP
    SEL orig = NSSelectorFromString(@"VCamOriginal_photoOutput:didFinishProcessingPhoto:error:");
    if ([self respondsToSelector:orig]) {
        typedef void (*Fn)(id, SEL, id, id, id);
        Fn fn = (Fn)[self methodForSelector:orig];
        if (fn) fn(self, orig, output, photo, error);
    }
}

static void vcam_photoDidFinish_4(id self, SEL _cmd, AVCapturePhotoOutput *output,
                                  AVCapturePhoto *photo, AVCapturePhoto *preview,
                                  AVCaptureResolvedPhotoSettings *rs,
                                  AVCapturePhotoSettings *us, NSError *error) {
    NSError *err = error;
    if (photo) {
        @try {
            NSData *jpeg = objc_getAssociatedObject(self, kVCamVirtualJPEGKey);
            if (jpeg) {
                AVCapturePhoto *fake = [(id)self vcam_makePhotoFromJPEG:jpeg
                                                               settings:photo.resolvedSettings];
                if (fake) photo = fake;
                objc_setAssociatedObject(self, kVCamVirtualJPEGKey, nil,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        } @catch (NSException *e) {
            VCamLog(@"[photo] 替换照片异常（透传真实照片）: %@", e);
        }
    }
    SEL orig = NSSelectorFromString(
        @"VCamOriginal_photoOutput:didFinishProcessingPhoto:previewPhoto:resolvedSettings:unresolvedSettings:error:");
    if ([self respondsToSelector:orig]) {
        typedef void (*Fn)(id, SEL, id, id, id, id, id, id);
        Fn fn = (Fn)[self methodForSelector:orig];
        if (fn) fn(self, orig, output, photo, preview, rs, us, err);
    }
}

/// 给实现了 AVCapturePhotoCaptureDelegate 的类加上"换照片"的拦截。
///
/// 为什么要在运行时给 delegate 类动态加方法：
///  App 的 delegate 类名我们是不知道的（可能是匿名的 block 包装类），
///  但我们可以：
///    1) 从 AVCapturePhotoOutput 的 _photoCapturedDelegate（私有 ivar）
///       或者从我们 hook 到的 capturePhotoWithSettings:delegate: 拿到 delegate 对象；
///    2) 对这个对象所属的类做一次 method swizzle：
///       把原 IMP 改名为 VCamOriginal_xxx，然后挂上我们的实现；
///    3) 在这个类的父类链上也做同样的替换（有些 App 让父类实现 delegate）。
+ (void)vcam_instrumentDelegate:(id)delegate {
    if (!delegate) return;
    // 上面 -capturePhotoWithSettings: 里已经调过，这里是给外部调用留的入口
    [self _instrumentDelegateImpl:delegate];
}

+ (void)_instrumentDelegateImpl:(id)delegate {
    if (!delegate) return;
    os_unfair_lock_lock(&gInjectLock);
    BOOL already = (objc_getAssociatedObject(delegate, kVCamSwizzledKey) != nil);
    if (!already) {
        objc_setAssociatedObject(delegate, kVCamSwizzledKey, @(YES),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    os_unfair_lock_unlock(&gInjectLock);
    if (already) return;

    [self _instrumentClass:object_getClass(delegate)
                     sel:@selector(photoOutput:didFinishProcessingPhoto:error:)
                 mangled:@"VCamOriginal_photoOutput:didFinishProcessingPhoto:error:"
                   newIMP:(IMP)vcam_photoDidFinish_2];
    [self _instrumentClass:object_getClass(delegate)
                     sel:@selector(photoOutput:didFinishProcessingPhoto:previewPhoto:resolvedSettings:unresolvedSettings:error:)
                 mangled:@"VCamOriginal_photoOutput:didFinishProcessingPhoto:previewPhoto:resolvedSettings:unresolvedSettings:error:"
                   newIMP:(IMP)vcam_photoDidFinish_4];
    VCamLog(@"[photo] 已为 delegate %@ 安装照片替换", NSStringFromClass(object_getClass(delegate)));
}

+ (void)_instrumentClass:(Class)cls
                     sel:(SEL)sel
                 mangled:(NSString *)mangledName
                   newIMP:(IMP)newIMP {
    if (!cls || !sel) return;
    SEL mangled = NSSelectorFromString(mangledName);
    if (class_respondsToSelector(cls, mangled)) return;   // 已经处理过

    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        // 这类没实现，往父类找
        Class super = class_getSuperclass(cls);
        while (super && super != NSObject.class) {
            Method sm = class_getInstanceMethod(super, sel);
            if (sm) {
                [self _instrumentClass:super sel:sel mangled:mangledName newIMP:newIMP];
                return;
            }
            super = class_getSuperclass(super);
        }
        return;
    }
    IMP original = method_getImplementation(m);
    const char *types = method_getTypeEncoding(m);
    // ⚠️ 不要用 method_getClass(m)。
    //    它**不是**公开的 objc/runtime.h API（头文件里没有声明），
    //    clang 会隐式声明为返回 int，
    //    于是 `method_getClass(m) ?: cls` 报：
    //        error: incompatible operand types ('int' and 'Class')
    //    而 class_getInstanceMethod 的实现就在 cls 自身，
    //    直接对 cls 操作即可（class_addMethod/class_replaceMethod 作用于该类）。
    Class target = cls;

    // 把原实现挂到 VCamOriginal_xxx 上
    class_addMethod(target, mangled, original, types);
    // 把我们的实现顶上去
    class_replaceMethod(target, sel, newIMP, types);
}

+ (void)_installDelegateSwizzles {
    // 真正的工作在 vcam_instrumentDelegate: 里按需完成（需要拿到 delegate 对象）。
    // 这里只做一次静态检查，确认 AVCapturePhoto 的私有构造方法存在与否，
    // 结果写进日志，方便用户排查"拍照没替换成功"。
    BOOL hasSampleBufferInit =
        [AVCapturePhoto instancesRespondToSelector:NSSelectorFromString(@"initWithSampleBuffer:")];
    BOOL hasFullInit = [AVCapturePhoto instancesRespondToSelector:
        NSSelectorFromString(@"initWithSettings:previewPhoto:resolvedSettings:unresolvedSettings:")];
    VCamLog(@"[photo] initWithSampleBuffer: %@ / 完整构造 %@",
            hasSampleBufferInit ? @"可用" : @"不可用",
            hasFullInit ? @"可用" : @"不可用");
}

+ (void)_swizzle:(Class)cls originalSel:(SEL)orig replacementSel:(SEL)repl {
    Method m1 = class_getInstanceMethod(cls, orig);
    Method m2 = class_getInstanceMethod(cls, repl);
    if (!m1 || !m2) {
        VCamLog(@"[photo] swizzle 跳过 %@", NSStringFromSelector(orig));
        return;
    }
    if (class_addMethod(cls, orig, method_getImplementation(m2), method_getTypeEncoding(m2))) {
        class_replaceMethod(cls, repl, method_getImplementation(m1), method_getTypeEncoding(m1));
    } else {
        method_exchangeImplementations(m1, m2);
    }
}

@end

#pragma mark - AVCapturePhotoOutput 替换实现

@implementation AVCapturePhotoOutput (VCamInject)

/// 生成虚拟 JPEG 并挂到 delegate 上（不改动拍照流程本身）
- (void)vcam_capturePhotoWithSettings:(AVCapturePhotoSettings *)settings
                             delegate:(id<AVCapturePhotoCaptureDelegate>)delegate {
    @try {
        VCamCore *core = [VCamCore shared];
        if (core.active && delegate) {
            // 先给 delegate 的类装上"换照片"的拦截
            [VCamPhotoOutputInjector vcam_instrumentDelegate:delegate];
            CGSize dims = CGSizeZero;
            CVPixelBufferRef pb = [core copyPixelBufferForNow];
            if (pb) {
                dims = CGSizeMake(CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb));
                UIImage *img = [VCamPixelBufferUtils imageFromPixelBuffer:pb];
                if (img) {
                    NSData *jpeg = UIImageJPEGRepresentation(img, 0.95);
                    if (jpeg.length > 0) {
                        os_unfair_lock_lock(&gInjectLock);
                        objc_setAssociatedObject(delegate, kVCamVirtualJPEGKey, jpeg,
                                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                        objc_setAssociatedObject(delegate, kVCamVirtualDimsKey,
                                                 [NSValue valueWithCGSize:dims],
                                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                        os_unfair_lock_unlock(&gInjectLock);
                        VCamLog(@"[photo] 已为本次拍照准备虚拟 JPEG（%.0fx%.0f, %lu bytes）",
                                dims.width, dims.height, (unsigned long)jpeg.length);
                    }
                }
                CVPixelBufferRelease(pb);
            }
        }
    } @catch (NSException *e) {
        VCamLog(@"[photo] 准备虚拟 JPEG 异常（不影响真实拍照）: %@", e);
    }
    // 调用原实现（swizzle 后这个 selector 指向原始 IMP）
    [self vcam_capturePhotoWithSettings:settings delegate:delegate];
}

- (void)vcam_capturePhotoBracketSettings:(AVCapturePhotoBracketSettings *)settings
                                delegate:(id<AVCapturePhotoCaptureDelegate>)delegate {
    @try {
        if ([VCamCore shared].active && delegate) {
            [self vcam_capturePhotoWithSettings:(AVCapturePhotoSettings *)settings delegate:delegate];
            return;
        }
    } @catch (NSException *e) {
        VCamLog(@"[photo] bracket 异常 %@", e);
    }
    [self vcam_capturePhotoBracketSettings:settings delegate:delegate];
}

@end

#pragma mark - delegate 替换实现

@implementation NSObject (VCamPhotoDelegate)

/// 尝试把真实照片换成虚拟照片。返回 YES 表示替换成功。
/// 注意：目前在 vcam_photoDidFinish_2 / _4 里直接用 vcam_makePhotoFromJPEG:settings:
/// 完成替换，这个方法保留作为"带校验的封装"，供第三方模块或将来扩展使用。
- (BOOL)vcam_tryReplacePhoto:(AVCapturePhoto **)photoPtr {
    NSData *jpeg = objc_getAssociatedObject(self, kVCamVirtualJPEGKey);
    if (!jpeg || !photoPtr || !*photoPtr) return NO;

    AVCapturePhoto *real = *photoPtr;

    // 途径 a：用 JPEG 造一个 CMSampleBuffer 再试 initWithSampleBuffer:
    AVCapturePhoto *fake = [self vcam_makePhotoFromJPEG:jpeg settings:real.resolvedSettings];
    if (fake) {
        *photoPtr = fake;
        objc_setAssociatedObject(self, kVCamVirtualJPEGKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        VCamLog(@"[photo] 已用虚拟照片替换（%lu bytes）", (unsigned long)jpeg.length);
        return YES;
    }

    // 途径 c：换不了，就只把 JPEG 塞进 metadata 供调试，并退回真实照片
    VCamLog(@"[photo] 无法构造 AVCapturePhoto，本次退回真实照片。"
            @"（如果 mediaserverd 层注入生效，真实照片其实也是虚拟的）");
    objc_setAssociatedObject(self, kVCamVirtualJPEGKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return NO;
}

- (AVCapturePhoto *)vcam_makePhotoFromJPEG:(NSData *)jpeg
                                  settings:(AVCaptureResolvedPhotoSettings *)resolved {
    if (!jpeg) return nil;

    // 构造 CMSampleBuffer（图像格式描述用 JPEG 类型）
    CMBlockBufferRef bb = NULL;
    if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, jpeg.length,
                                           kCFAllocatorDefault, NULL, 0, jpeg.length,
                                           kCMBlockBufferAssureMemoryNowFlag, &bb) != kCMBlockBufferNoErr) {
        return nil;
    }
    CMBlockBufferReplaceDataBytes(jpeg.bytes, bb, 0, jpeg.length);

    CMFormatDescriptionRef fmt = NULL;
    OSStatus st = CMVideoFormatDescriptionCreate(kCFAllocatorDefault,
                                                 kCMVideoCodecType_JPEG,
                                                 0, 0, NULL, &fmt);
    if (st != noErr || !fmt) { CFRelease(bb); return nil; }

    CMSampleTimingInfo timing = {
        .duration = CMTimeMake(1, 30),
        .presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock()),
        .decodeTimeStamp = kCMTimeInvalid,
    };
    size_t sampleSize = jpeg.length;
    CMSampleBufferRef sb = NULL;
    st = CMSampleBufferCreateReady(kCFAllocatorDefault, bb, fmt, 1, 1, &timing, 1, &sampleSize, &sb);
    CFRelease(bb);
    CFRelease(fmt);
    if (st != noErr || !sb) return nil;

    AVCapturePhoto *photo = nil;
    @try {
        // 途径 a：initWithSampleBuffer:
        SEL sel = NSSelectorFromString(@"initWithSampleBuffer:");
        if ([AVCapturePhoto instancesRespondToSelector:sel]) {
            typedef id (*InitFn)(id, SEL, CMSampleBufferRef);
            InitFn fn = (InitFn)[AVCapturePhoto instanceMethodForSelector:sel];
            photo = fn([AVCapturePhoto alloc], sel, sb);
        }
        // 途径 b：完整指定构造
        if (!photo) {
            SEL sel2 = NSSelectorFromString(@"initWithSettings:previewPhoto:resolvedSettings:unresolvedSettings:");
            if ([AVCapturePhoto instancesRespondToSelector:sel2]) {
                typedef id (*InitFn2)(id, SEL, id, id, id, id);
                InitFn2 fn2 = (InitFn2)[AVCapturePhoto instanceMethodForSelector:sel2];
                photo = fn2([AVCapturePhoto alloc], sel2, nil, nil, resolved, nil);
            }
        }
    } @catch (NSException *e) {
        VCamLog(@"[photo] 构造 AVCapturePhoto 异常: %@", e);
        photo = nil;
    }
    CFRelease(sb);
    return photo;
}

@end

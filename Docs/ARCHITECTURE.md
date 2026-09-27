# VCam 架构与 Hook 点详解

这份文档写给要改代码的人。README 讲「怎么用」，这里讲「为什么这么写、
改哪里会崩」。

---

## 1. 进程与过滤

### 1.1 为什么要注入这么多进程

| 进程 | 用哪个 filter | 为什么需要 |
| --- | --- | --- |
| `mediaserverd` | `VCam-mediaserverd.plist`（Executables） | 相机与麦克风的真正采集在这里。注入这一层 = **系统级**，任何 App 都生效 |
| `SpringBoard` | `VCam.plist`（Bundles，`com.apple.springboard`） | 悬浮小窗 UI + 音量键拦截。放在 SpringBoard 里就不需要每个 App 都有一份 UI |
| 各相机类 App | `VCam.plist`（Bundles，长名单） | mediaserverd 层符号没匹配上时的兜底，保证预览/拍照/录像是虚拟的 |
| `mediaplaybackd` / `camerad` / `audioaccessoryd` | `VCam-mediaserverd.plist` | 部分 iOS 版本把这些职责拆到了别的 daemon |

**为什么 App 名单这么长而不是用 `CoreMedia` / `AVFoundation` 作为过滤器？**

用框架名过滤理论上更省事，但实践中会把 VCam 注入到所有链接了
AVFoundation 的进程（包括很多系统守护进程、小组件、XPC 服务），
风险远大于收益：那些进程里没有相机、也不需要虚拟帧，
却要额外加载一个 dylib 并 hook 一批类。

所以策略是：**系统层靠 mediaserverd 兜住，App 层只覆盖已知会用相机的名单**。

### 1.2 filter 文件放在哪

Theos 会把**与 tweak 同名**的 `VCam.plist` 自动装到
`$(THEOS_PACKAGE_INSTALL_PREFIX)/Library/MobileSubstrate/DynamicLibraries/`。

⚠️ **`VCam-mediaserverd.plist` 不同名，Theos 不会自动安装它。**
这会导致「medaserverd 层根本没加载」—— 系统级注入失效，只剩 App 层。

三种处理方式，任选一种：

**方式 A（最简单）：把 mediaserverd 也写进主 filter 的 Bundles 里**

```json
{
    Filter = { Bundles = ( "com.apple.springboard", "com.apple.camera", ... ) };
    /* 注意：mediaserverd 没有 bundle id，用 Bundles 匹配不到 */
}
```

不行 —— `mediaserverd` 是 daemon，没有 bundle id，必须用 `Executables`。
所以要用方式 B 或 C。

**方式 B（推荐）：拆成两个 tweak**

```
vcam/
├── Makefile            # TWEAK_NAME = VCam
├── VCam.x              # App 层 + SpringBoard 层 + 音量键
├── VCam.plist          # Bundles = ( springboard, camera, 各 App )
└── msd/
    ├── Makefile        # TWEAK_NAME = VCamMSD
    ├── VCamMSD.x       # FigImageQueue / AudioUnit 的 hook
    └── VCamMSD.plist   # Executables = ( mediaserverd, ... )
```

根 Makefile 里加 `SUBPROJECTS += msd`，并在 `msd/Makefile` 里指定
`VCamMSD_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries`。

**方式 C（本仓库当前做法）：在 Makefile 里打包后手动补装**

在根 `Makefile` 的 `after-install::` 里加：

```make
after-install::
	install.exec "cp $(THEOS_PROJECT_DIR)/VCam-mediaserverd.plist \
	  $(THEOS_PACKAGE_INSTALL_PREFIX)/Library/MobileSubstrate/DynamicLibraries/"
```

或者在 `layout/` 目录里直接摆好目标路径（Theos 会把 `layout/` 的内容
原样拷进 staging 目录，rootless 时自动加 `/var/jb` 前缀）：

```
vcam/layout/Library/MobileSubstrate/DynamicLibraries/VCam-mediaserverd.plist
```

> 本仓库为了保持源码目录清爽，把 filter 文件放在根目录并在 README 里
> 说明用方式 C 补装。如果你要长期维护，**建议改成方式 B**，
> 两个 tweak 各自带同名 plist，安装路径由 Theos 自动处理，最不容易出错。

---

## 2. mediaserverd 层 Hook

### 2.1 尝试的符号

`Tweak.x` 里的 `VCamHookMediaServerdSymbols()` 会按顺序尝试：

```c
FigImageQueueEnqueue          // 最外层：把帧塞进给客户端的队列
FigImageQueueEnqueueImage
FigCaptureImageQueueEnqueue
FigVideoQueueEnqueueFrame
RTImageQueueEnqueue          // 实时队列（预览/采集共用）
```

这些函数签名在不同 iOS 版本上略有差异，统一按
`OSStatus fn(void *queue, void *pixelBuffer, void *context)` 处理。
因为我们只在「替换 pixelBuffer 指针」这一件事上用它，
参数多一个少一个都不影响（多余的寄存器/栈参数会被忽略）。

### 2.2 替换逻辑

```c
static OSStatus vcam_FigImageQueueEnqueue(void *queue, void *pixelBuffer, void *context) {
    @autoreleasepool {
        @try {
            VCamCore *core = [VCamCore shared];
            if (core.active) {                          // 只在这一行判断是否接管
                CVPixelBufferRef pb = [core copyPixelBufferForNow];   // +1
                if (pb) {
                    OSStatus st = orig_...(queue, (void *)pb, context);
                    CVPixelBufferRelease(pb);
                    if (st == 0) return st;             // 成功就返回，真实帧被丢弃
                    // 失败 → 落到下面走真实帧，绝不堵死管线
                }
            }
        } @catch (NSException *e) { VCamLog(...); }
    }
    return orig_...(queue, pixelBuffer, context);
}
```

三个必须遵守的规矩：

1. **先问 `core.active`**，再决定是否替换。禁用状态下这个函数等于原函数。
2. **`copyPixelBufferForNow` 返回 `NULL` 必须 fallback**，不能把 `NULL` 传下去。
3. **失败也 fallback**，让相机至少能用。

### 2.3 麦克风：AURemoteIO

iOS 上麦克风采集最终都是 `AURemoteIO`（`kAudioUnitSubType_RemoteIO`）。
上层要拿到数据有两种方式：

- `kAudioOutputUnitProperty_SetInputCallback`（输入回调）— 我们 hook 这个
- `AudioUnitRender`（主动拉）— 部分 App 用这种

`AudioUnitSetProperty` 是 C 符号，用 `MSHookFunction` 替换：

```c
static OSStatus vcam_AudioUnitSetProperty(AudioUnit inUnit, AudioUnitPropertyID inID, ...) {
    if (inID == kAudioOutputUnitProperty_SetInputCallback && inData && inDataSize >= sizeof(AURenderCallbackStruct)) {
        AURenderCallbackStruct ours = *(const AURenderCallbackStruct *)inData;
        ours.inputProc = vcam_InputCallback;    // 换掉回调函数指针
        return gOrigAudioUnitSetProperty(inUnit, inID, inScope, inElement, &ours, sizeof(ours));
    }
    return gOrigAudioUnitSetProperty(...);
}
```

`vcam_InputCallback` 里直接覆盖 `ioData` 各个 `AudioBuffer` 的内容。
注意它**不调用原始回调**：原始回调是 mediaserverd 用来「把 A/D 数据
交给自己上层」的，我们要的就是它别送真实数据。

> 局限：如果某版本 iOS 的麦克风不走 `AudioUnitSetProperty`
> （例如走 `AVAudioEngine` 的独立 XPC），这一层会失效。
> App 层的 `AVCaptureAudioDataOutput` 代理仍然有效。

### 2.4 降级机制

```
mediaserverd 启动
   │
   ├─ 看到 /var/mobile/Library/VCam/msd_crash.flag 存在
   │     → 说明上次注入后 8 秒内 mediaserverd 挂了
   │     → setMSDDisabled:YES，删除 flag，本进程不注入
   │
   └─ 没看到 flag
         → 写 flag
         → 8 秒后（说明活着）删除 flag
         → 正常注入
```

实现见 `VCamMediaserverdWatchdog()`。`VCamCore.reloadFromState` 里
也会检查 `msdDisabled && VCamIsMediaServerProcess()` 直接 teardown。

---

## 3. App 层 Hook

### 3.1 `AVCaptureVideoDataOutput` —— 包 delegate

不去 hook `AVCaptureVideoDataOutput` 的
`-captureOutput:didOutputSampleBuffer:fromConnection:`，因为那个方法
定义在 **App 自己的类**上（类名未知）。

做法是 hook `-setSampleBufferDelegate:queue:`，把 delegate 换成
`VCamVideoDataOutputProxy`，代理里再转发给原 delegate：

```
App 的 Delegate  ←─转发─  VCamVideoDataOutputProxy  ←─系统─  AVCapture 管线
                                │
                                └─ 把 sampleBuffer 换成虚拟帧（用同尺寸 + 同 PTS）
```

关键细节：

- 用 `CMSampleBufferGetImageBuffer(sampleBuffer)` 取**真实帧的尺寸**，
  让 `copyPixelBufferForWidth:height:` 缩放到同样大小
  → 下游完全感知不到差别。
- 时间戳用真实 sampleBuffer 的 PTS，而不是我们自己造的
  → 录制时间轴与 App 的其它逻辑（例如录屏同步）保持一致。
- 实现 `-respondsToSelector:` 与 `-forwardingTargetForSelector:`
  → 未实现的 delegate 方法（例如 `didDropSampleBuffer:`）会自动转发。
- 装载标记用关联对象写在 output 上（`associatedProxy`），幂等。
- 卸载：`+uninstallAll` 把原 delegate 装回去。

### 3.2 `AVCaptureVideoPreviewLayer` —— 覆盖层

PreviewLayer 的画面来自内部私有 CALayer 的 `contents`，
由 mediaserverd 通过 IOSurface 直塞给 CoreAnimation，
**没有任何 ObjC 方法可以 hook**。

所以策略是「盖一层」：

```
AVCaptureVideoPreviewLayer
   ├── 内部私有 layer（真实画面，我们不动它）
   └── VCamOverlayHost.overlay   ← 我们加的，zPosition=10，contents = 虚拟帧 CGImage
       VCamOverlayHost.hint      ← "等待信号…" 提示
```

- `contentsGravity = kCAGravityResizeAspectFill`，与 previewLayer 默认一致，
  不会变形。
- `layoutSublayers` 里同步 `overlay.frame`，用 `CATransaction` 关闭隐式动画
  （否则每次 layout 画面会「抖」一下）。
- 30fps 定时器（不是 60），1080p 的 `CVPixelBuffer → CGImage` 约 2–4ms，
  够用且省电。
- 因为 mediaserverd 层生效时这是多余的转换，所以留了
  `+setPassthroughMode:`；检测到 msd 层可用就不要再做覆盖层转换。
- 卸载：`+detachAll` 遍历所有 window 的 layer 树，靠关联对象找回我们自己加的层。

### 3.3 `AVCapturePhotoOutput` —— 换照片

时序：

```
App:    [output capturePhotoWithSettings:settings delegate:delegate]
              │
              ├─ 我们的 swizzle：
              │    1) [VCamPhotoOutputInjector vcam_instrumentDelegate:delegate]
              │       → 给 delegate 的类动态加方法：
              │          VCamOriginal_photoOutput:didFinishProcessingPhoto:error:
              │          替换 photoOutput:didFinishProcessingPhoto:error:
              │    2) 用虚拟帧生成 JPEG，关联到 delegate 上
              │
              ▼  调用原实现（真实拍照照常进行，保证 App 时序正常）
系统:   真实拍照 → delegate 回调
              │
              ▼
delegate: photoOutput:didFinishProcessingPhoto:error:   ← 已被我们替换
              ├─ 从关联对象取出虚拟 JPEG
              ├─ 尝试构造 AVCapturePhoto：
              │    a) initWithSampleBuffer:              （部分版本有）
              │    b) initWithSettings:previewPhoto:resolvedSettings:unresolvedSettings:
              │    c) 都不行 → 保留真实照片 + 打日志
              └─ 调用 VCamOriginal_...（转发给 App）
```

为什么用「动态给 delegate 类加方法」而不是 `%hook`：
App 的 delegate 类名在编译期未知（可能是 block 包装类）。

### 3.4 `AVCaptureMovieFileOutput` —— 影子录制 + 替换

`AVCaptureMovieFileOutput` 没有「写入一帧」的公开接口，
所以采用并行录制：

```
App:  startRecordingToOutputFileURL:A
        │
        ├─ 我们额外启动 AVAssetWriter → 隐藏文件 shadow_xxx.mp4
        │    帧：VCamCore 拉（1080x1920，30fps）
        │    音：VCamCore pullPCMInto（48k 立体声 → AAC 128k）
        │
        ▼ 调用原实现（真实录制照常）
        ...
App:  stopRecording
        │
系统: delegate: captureOutput:didFinishRecordingToOutputFileAtURL:A ...  ← 已替换
        ├─ finishWriting 影子文件（最多等 3 秒）
        ├─ 备份 A → A.vcam_real
        ├─ shadow_xxx.mp4 → A
        │    失败则回滚 A.vcam_real → A
        └─ 转发给 App 的原实现
```

代价：录制期间多一路 H.264 编码。A 系列芯片能同时跑 2 路 1080p，
`expectsMediaDataInRealTime = YES` 让编码器走实时低延迟路径。

如果想在 mediaserverd 层已生效时省掉这份开销，
可以在 `vcam_startRecordingToOutputFileURL:` 里判断
`[[VCamStateStore shared] msdDisabled] == NO` 时跳过影子录制。

### 3.5 麦克风（App 层）

- `AVCaptureAudioDataOutput`：和视频一样包 delegate。
  从真实 buffer 的 `CMFormatDescription` 读出 ASBD，
  用同样的采样率/声道数构造虚拟 buffer，App 侧完全无感。
- `AVAudioRecorder`：`-record` / `-recordForDuration:` 只做
  「确保 AVAudioSession 是 active」，不做数据替换
  （真实数据替换由 AudioUnit 层完成）。
  这么做的原因是 `AVAudioRecorder` 的输入路径在进程内是一层
  `AudioQueue` 封装，从外部 hook 它的 buffer 非常脆弱。

---

## 4. 帧与时间戳

### 4.1 为什么坚持 NV12（420f / 420v）

| 格式 | 说明 |
| --- | --- |
| `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange` (420f) | 摄像头原生（full range），VideoToolbox 解码默认输出 |
| `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` (420v) | 视频范围，部分编码路径偏好 |

用 NV12 的好处：

1. 与 ISP / VideoToolbox / 预览层 / 编码器的原生路径一致，**少两次颜色转换**；
2. bi-planar 用 `CVPixelBufferGetBaseAddressOfPlane(0/1)` 直接拿到
   Y 与 UV 指针，`vImage` 可以直接处理；
3. 内存占用是 RGBA 的一半（1080p：3.1MB vs 8.3MB），
   30fps 下对内存带宽影响很大。

只有在「图片源」与「占位帧」两处需要 RGB→NV12 转换，
用 `CIContext render:toCVPixelBuffer:` 一次搞定（走 GPU）。

### 4.2 旋转/镜像为什么用 vImage 而不是 CIImage

`CIImage + CIContext` 每次都会创建新的 CVPixelBuffer 并且要走
Metal/CoreAnimation 的上下文，30fps 连续转换会造成
「GPU 上下文频繁切换」的开销，而且 daemon 进程里 Metal 设备
有时拿不到。

`vImage` 是纯 CPU 的 SIMD 实现：

- `vImageRotate90_Planar8`（0/90/180/270，角度是 90 的整数倍时这是最优路径）
- `vImageScale_Planar8`（带 `kvImageHighQualityResampling`）
- `vImageHorizontalReflect_Planar8`（镜像）

1080p 一帧旋转约 3–6ms（A12），加上缩放约 8–12ms，30fps 预算 33ms，
够用。而且这一步在 **独立串行队列** 上执行，不占采集实时线程。

⚠️ NV12 的 UV 平面：**宽高都是 Y 的一半，但每像素 2 字节**。
旋转时要先把 `vImage_Buffer.width` 乘 2（见
`transformPixelBuffer:rotation:mirror:` 里的 `suv2` / `duv2`），
否则会切掉一半的色度数据，表现为画面右半边偏色。

### 4.3 时间戳

```objc
CMClockGetTime(CMClockGetHostTimeClock())
```

与 `AVCaptureVideoDataOutput` 给出的 PTS **同源**（都由
`mach_absolute_time` 派生），所以：

- 预览层能立刻排程显示，不用等；
- 录制器的时间轴连续，不会出现「音频比视频快 200ms」；
- OBS 的流内 PTS 通过 `hostTimeForStreamTime:anchor:` 映射到 host 时间轴，
  以「收到第一个包的时刻」为锚点，之后按时差推进。
  落后于实时（网络抖动）时用当前时间兜住，**保证单调递增**
  （预览层对时间戳回退非常敏感，回退就会丢帧）。

音频时间戳由流 PTS 映射 + `lipSyncOffsetMs` 偏移构成，
默认 0；蓝牙耳机场景可手动微调。

---

## 5. 内存管理约定

这是最容易写出泄漏的地方，务必遵守。

### 5.1 `emitPixelBuffer:atStreamTime:` 的契约

```objc
// 生产者（FrameSource）
CVPixelBufferRetain(pb);                 // block 持有
dispatch_async(workQueue, ^{
    CVPixelBufferRef working = pb;       // 协议：进入时 +1
    ... 缩放/旋转，替换 working 时 release 旧的 ...
    handler(working, ts);                // 回调期间有效
    CVPixelBufferRelease(working);       // 退出时 -1
});
```

**回调方如果需要跨函数保留（例如丢进另一个 `dispatch_async`），
必须自己 `CVPixelBufferRetain`。**

### 5.2 返回 `+1` 的接口

| 接口 | 说明 |
| --- | --- |
| `VCamCore -copyPixelBufferForNow` | 名字里的 `copy` 表示调用方负责 release |
| `VCamCore -copyPixelBufferForWidth:height:` | 同上 |
| `AVPlayerItemVideoOutput -copyPixelBufferForItemTime:` | 系统接口，+1 |
| `VCamConcurrentQueue -dequeuePixelBufferWithTime:` | 引用转移给调用方 |

### 5.3 常见错误

| 错误 | 后果 |
| --- | --- |
| `emitPixelBuffer` 里忘记 `CVPixelBufferRetain` | 30fps 下必崩（EXC_BAD_ACCESS） |
| 把 `copyPixelBufferForNow` 的结果直接塞进 `dispatch_async` 不 retain | 同上 |
| 在 `FrameSource` 的 block 里用 `self` 强引用 | 源无法释放，禁用替换后仍在出帧 |
| 把整个视频文件读进内存 | 1080p 10 分钟约 1GB |
| 忘记 `flushPools` | 池里缓存的 buffer 在禁用后仍占几十 MB |

`VCamCore -teardown` 会依次：停源 → 清音频环形缓冲 → 释放最近一帧 →
`[VCamPixelBufferUtils flushPools]`。

---

## 6. 状态机

```
                  ┌──────────────┐
                  │  Disabled    │◄───────────────┐
                  │ （硬件相机）  │                │
                  └──────┬───────┘        点「禁用替换」
                         │                      │
      选图片 / 选视频 / OBS │                      │
                         ▼                      │
                  ┌──────────────┐              │
                  │  Image       │──────────────┤
                  │  Video       │              │
                  │  OBS         │──────────────┘
                  └──────┬───────┘
                         │ 源启动失败
                         ▼
                  ┌──────────────┐
                  │ 未就绪        │  statusText = "失败：<原因>"
                  │ （回退硬件）   │  lastError 写进 state.plist
                  └──────────────┘
```

- `VCamCore.active` = `source != nil && 源 start 成功`
- 注入层只看 `active`；不活跃就完全不介入
- 状态变化通过 `notify_post` 广播，所有进程 `reloadFromState`
- **不需要杀进程或 respring**

---

## 7. 想改代码的话，从哪下手

| 想做什么 | 改哪里 |
| --- | --- |
| 加一种新的虚拟源（例如网络摄像头 / 屏幕共享） | 新建 `Core/VCamXxxSource.m` 继承 `VCamFrameSourceBase`，在 `VCamCore reloadFromState` 的 `switch` 里加一个分支，在 `VCamMode` 里加枚举 |
| 改输出分辨率 / 帧率 | `VCamCore reloadFromState` 里的 `src.targetSize` / `src.targetFPS`；小窗的「横屏/竖屏」按钮走 `vcam_landscape` 偏好 |
| 加 hook 的 App | `VCam.plist` 的 `Bundles` 数组 |
| 改 mediaserverd 的候选符号 | `Tweak.x` 的 `VCamHookMediaServerdSymbols()` 里 `candidates[]` 数组 |
| 让 OBS 支持更多容器 | `Core/VCamTSDemuxer.m` 里 `av_find_input_format("mpegts")`，改成按 URL 后缀/参数选择 |
| 加 RTMP/RTSP 拉流 | 同上，把 `av_find_input_format` 换成 `NULL` 让 FFmpeg 自动探测 |
| 降低录像码率 | `Media/VCamMovieFileInjector.m` 的 `AVVideoAverageBitRateKey` |
| 关闭影子录制（msd 层已生效时） | `vcam_startRecordingToOutputFileURL:` 里判断 `msdDisabled` |
| 换音量键触发方式 | `UI/VCamVolumeHook.m` 的 `_handleVolumeStepFrom:to:explicit:` |
| 改小窗 UI | `UI/VCamPanel.m` 的 `_rebuildButtons` 和 `_makeButton:action:style:` |
| 加设置项 | `prefs/Resources/Root.plist` + `Core/VCamStateStore` 里加读写方法 |

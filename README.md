# VCam —— iOS 系统级虚拟摄像头 + 虚拟麦克风

> 把整机的**摄像头画面**与**麦克风音频**替换成虚拟源。
> 任意调用系统相机管线的 App（系统相机、FaceTime、微信、QQ、Zoom、
> Snapchat、Instagram、TikTok）看到的都是虚拟内容，而不是物理传感器。
>
> 支持 **iOS 15.0 – 16.6.1**，同时支持 **rootful / rootless（Dopamine、palera1n）**。
> 无卡密、无联网授权、无 UDID 上传，全部离线本地运行。
>
> 参考了 VCam-iOS-16 的**能力范围**（<https://github.com/notaudren/VCam-iOS-16>），
> 但代码是从零实现的，没有使用任何反编译产物。
>
> **⚠️ 使用前请先读文末的「免责声明」。**

---

## 目录

1. [先改这两个占位符](#0-先改这两个占位符)
2. [总体架构](#1-总体架构)
3. [文件树](#2-文件树)
4. [编译](#3-编译)
5. [安装](#4-安装)
6. [使用（音量减悬浮窗）](#5-使用音量减悬浮窗)
7. [OBS / 电脑推流 逐步设置](#6-obs--电脑推流-逐步设置)
8. [把自己域名做成 Sileo 源](#7-把自己域名做成-sileo-源)
9. [常见故障排查](#8-常见故障排查)
10. [已知限制](#9-已知限制)
11. [免责声明](#10-免责声明)

---

## 0. 包名与域名（已为你配置好）

本工程**已经按你的 GitHub 用户名配好了**，不需要再改任何占位符：

| 项目 | 当前值 |
| --- | --- |
| 插件包名（Package id） | `com.quite85.vcam` |
| 软件源地址 | `https://quite85.github.io/vcam` |
| deb 文件名 | `com.quite85.vcam_1.0.0_iphoneos-arm64-rootless.deb` |

如果你以后想换成自己的域名（例如 `repo.quite85.com`），一次性替换即可：

```bash
cd vcam
# macOS
grep -rl 'quite85.github.io/vcam' . | xargs sed -i '' 's|quite85\.github\.io/vcam|repo.quite85.com|g'
# Linux / WSL
grep -rl 'quite85.github.io/vcam' . | xargs sed -i  's|quite85\.github\.io/vcam|repo.quite85.com|g'
# 然后再改 scripts/make-repo.sh 里的 DOMAIN / REPO_PATH 默认值
```

> `VCAM_PKG_ID` 在 `Makefile` 里也有默认值，如果要改包名，记得同时改
> `control-rootful`、`control-rootless`、`Makefile` 三处，否则 deb 文件名会不一致。

---

## 0.5 GitHub Pages 源地址是怎么拼出来的

`repo/` 目录会被整目录部署到 Pages，所以：

```
仓库名        : vcam
Pages 基地址  : https://quite85.github.io/vcam
源里各文件的真实 URL ：
  Release          → https://quite85.github.io/vcam/Release
  Packages.gz      → https://quite85.github.io/vcam/Packages.gz
  depiction/vcam.html → https://quite85.github.io/vcam/depiction/vcam.html
  debs/xxx.deb     → https://quite85.github.io/vcam/debs/xxx.deb

★ 用户在 Sileo 里填的源地址 = https://quite85.github.io/vcam
```

对应到构建脚本的环境变量：

```bash
DOMAIN=quite85.github.io REPO_PATH=/vcam ./scripts/make-repo.sh
```

⚠️ **不要**把源地址填成 `https://quite85.github.io/vcam/repo`（多一层 repo）——
那是最常见的 404 原因。`REPO_PATH` 指的是「repo/ 这个目录部署到了网站的哪个路径」，
不是目录名本身。

---

## 1. 总体架构

### 1.1 关键认知：App 里的 AVCaptureSession 只是「遥控器」

```
   硬件 ISP / 麦克风 ADC
            │
            ▼
   ┌─────────────────────────────────────────┐
   │            mediaserverd                 │  ← 真正的采集发生在这里
   │  FigCaptureSourceBackend                │
   │    → FigCaptureSourceVideoStream        │
   │    → FigCaptureImageQueue (IOSurface)   │
   │  AURemoteIO / AudioUnit (麦克风)         │
   └─────────────────────────────────────────┘
            │  XPC (FigCaptureSessionRemote)
            ▼
   ┌─────────────────────────────────────────┐
   │        目标 App 进程                     │
   │  AVCaptureSession（配置+遥控）           │
   │  AVCaptureVideoDataOutput（收帧）        │
   │  AVCaptureVideoPreviewLayer（显示）      │
   │  AVCapturePhotoOutput（拍照）            │
   │  AVCaptureMovieFileOutput（录像）        │
   └─────────────────────────────────────────┘
```

因此 VCam 做了**两层注入**，互相兜底：

| 层 | 注入进程 | 插入点 | 作用 |
| --- | --- | --- | --- |
| **A. 系统层（主）** | `mediaserverd` | `FigImageQueue*Enqueue`、`AudioUnitSetProperty` 的输入回调 | 在公共管线里换数据源 → **任何 App 都生效，不依赖 App 里有没有 tweak** |
| **B. App 层（兜底）** | 各相机类 App、SpringBoard | `AVCaptureVideoDataOutput` delegate 代理、`AVCaptureVideoPreviewLayer` 覆盖层、`AVCapturePhotoOutput`、`AVCaptureMovieFileOutput`、`AVCaptureAudioDataOutput` | A 层某版 iOS 符号变了也能保证预览/拍照/录像是虚拟的 |

> **为什么两层都要**：`Fig*` 是私有 C++/C 符号，iOS 15 与 16.4+ 之间名字和结构
> 有变化。A 层保证「App 里没有 tweak 也生效」这个系统级目标；B 层保证
> 「预览是虚拟的，拍下来是真的」这种最糟糕的结果不会发生。
>
> **为什么不做「每个 App 单独注入 UI」**：那是把相机界面换成自己的界面，
> 只在特定 App 有效，且一眼就能看出被改过。VCam 在数据层替换，
> App 自己完全不知道，它拿到的仍是「一个普通的 AVCaptureDevice」。

### 1.2 数据流（三个虚拟源 → 统一 CVPixelBuffer → 注入）

```
  ┌───────────────┐
  │ 相册视频       │  AVPlayer + AVPlayerItemVideoOutput
  │ VCamVideoSource│  → copyPixelBufferForItemTime（硬件解码，天然支持循环）
  │               │  AVAssetReader（另一条线程）→ 交错 float32 PCM
  └───────┬───────┘
          │
  ┌───────┴───────┐
  │ 相册图片       │  UIImage → CIContext 渲染成 420f NV12 基准帧
  │ VCamImageSource│  → dispatch timer 按 30fps 重复送同一帧
  └───────┬───────┘
          │
  ┌───────┴───────┐
  │ OBS 推流       │  FFmpeg libavformat(mpegts, udp/tcp)
  │ VCamOBSSource  │   ├─ H.264 → VideoToolbox 硬解 → CVPixelBuffer(420f)
  │                │   └─ AAC   → AudioConverter → 交错 float32 PCM
  └───────┬───────┘
          │
          ▼
  ┌──────────────────────────────────────────┐
  │  VCamFrameSourceBase.emitPixelBuffer:    │
  │    aspect-fill 缩放 → vImage 旋转/镜像    │
  │    时间戳 = CMClockGetHostTimeClock()     │  ← 与 AVCapture 同源，唇形/时间轴才对
  └───────────────┬──────────────────────────┘
                  ▼
  ┌──────────────────────────────────────────┐
  │  VCamCore（单例，两个进程各一份）          │
  │   · 最近一帧 CVPixelBuffer（+1 引用）      │
  │   · 音频环形缓冲（48k 立体声 float32）      │
  │   · copyPixelBufferForNow / pullPCMInto:  │
  └───────────────┬──────────────────────────┘
                  ▼
        ┌─────────┴──────────┐
        ▼                    ▼
  视频注入层            音频注入层
  · mediaserverd        · mediaserverd
    FigImageQueueEnqueue   AudioUnit 输入回调
  · VideoDataOutput      · AudioDataOutput 代理
    delegate 代理        · AVAudioRecorder 保护
  · PreviewLayer 覆盖层
  · PhotoOutput 换照片
  · MovieFileOutput 影子录制+替换
```

**关键设计：`copyPixelBufferForNow` 返回 `NULL` 就代表「请用真实硬件」。**
所有注入点的第一行代码都是调用它；拿到 `NULL` 就原样走系统实现。
这样「禁用替换」「源没准备好」「解码失败」三种情况天然 fallback，
不需要在任何地方写 IF 分支去区分硬件/虚拟。

### 1.3 状态同步（跨进程）

SpringBoard（UI）与 mediaserverd（采集）是两个进程，不能共享内存单例：

```
  SpringBoard                       mediaserverd / 目标 App
  ┌──────────────┐                  ┌──────────────┐
  │ VCamPanel UI │                  │  VCamCore    │
  └──────┬───────┘                  └──────▲───────┘
         │ 写                               │ 读
         ▼                                  │
  /var/mobile/Library/VCam/state.plist ─────┘
         │  原子写（.tmp + rename，0644）
         ▼
  notify_post("com.quite85.vcam/stateChanged")
         │
         ▼  notify_register_dispatch
    各进程 reloadFromState → 重建虚拟源 → 立刻生效（无需杀进程 / respring）
```

### 1.4 稳定性设计（不打崩 mediaserverd）

| 措施 | 说明 |
| --- | --- |
| 全部 hook 包 `@try/@catch` | 异常一律回退原始实现 |
| 空指针/尺寸校验 | 任何一步失败都 `return %orig`，绝不把 `NULL` 交给相机管线 |
| Watchdog 自动降级 | 注入后 8 秒内 mediaserverd 异常退出 → 写 `msd_crash.flag`；下次启动自动切「仅 App 层注入」并记日志 |
| 手动降级开关 | 设置 → VCam → 「仅 App 层注入（跳过 mediaserverd）」 |
| 独立串行队列 | 缩放/旋转/解码都不在采集实时线程上做 |
| 有界队列 + 丢帧 | OBS 解码队列只留 3 帧，满了丢最旧，延迟不累积 |
| 影子录制可回滚 | 替换录像文件前先备份原文件，替换失败回滚 |

### 1.5 iOS 15 / 16 差异处理

| 差异点 | 处理方式 |
| --- | --- |
| `Fig*` 私有符号名不同 | 用候选名字数组逐个 `dlsym` 尝试，命中哪个用哪个；全部失败就记录日志并降级（不 abort） |
| `AVCapturePhoto` 私有构造不同 | 依次尝试 `initWithSampleBuffer:` → 完整指定构造 → 失败退回真实照片 |
| Prefences 面板 API | 只用 `PSListController` + `PSLinkCell`，15/16 通用 |
| `PHPickerFilter` | 用 `@available(iOS 14.0, *)` 分支 |
| `AVAudioSession` 类别枚举 | 只用 15.0 就存在的常量 |
| 时间戳 | 统一 `CMClockGetTime(CMClockGetHostTimeClock())`，两个版本行为一致 |
| 编译期最低版本 | `TARGET = iphone:clang:latest:15.0`，运行时不做 `kCFCoreFoundationVersionNumber` 硬判断，改为「能力探测」（`respondsToSelector` / `dlsym`）——比版本号判断更耐升级 |

---

## 2. 文件树

```
vcam/
├── Makefile                        # 主构建文件（rootful + rootless）
├── control                         # rootful 包描述
├── control-rootless                # rootless 包描述（Theos 按 scheme 自动挑选）
├── entitlements.plist              # rootful entitlements
├── entitlements-rootless.plist     # rootless entitlements
├── VCam.plist                      # filter：SpringBoard + 相机类 App（Bundles 名单）
├── VCam-mediaserverd.plist         # filter：mediaserverd 等（Executables）
├── Tweak.x                         # Logos 主入口，按进程分流 + 核心 hook
│
├── Core/                           # 编译成静态库 VCamCore，被 tweak 复用
│   ├── VCamConfig.h/.m             # 路径、日志、进程判断（兼容 rootful/rootless）
│   ├── VCamStateStore.h/.m         # 跨进程配置（原子写 + notify 广播）
│   ├── VCamCore.h/.m               # 单例：当前源、最近一帧、音频环形缓冲
│   ├── VCamFrameSource.h/.m        # 帧源抽象 + 统一输出管线（缩放/旋转/镜像）
│   ├── VCamImageSource.h/.m        # 相册图片（30fps 重复帧）
│   ├── VCamVideoSource.h/.m        # 相册视频（AVPlayer 出帧 + AVAssetReader 出音）
│   ├── VCamOBSSource.h/.m          # OBS 推流源（拉帧 + 断流占位）
│   ├── VCamOBSSource_stub.m        # VCAM_ENABLE_OBS=0 时的降级实现
│   ├── VCamOBSAddress.m            # 本机 IP / 推流地址生成（不依赖 FFmpeg）
│   ├── VCamTSDemuxer.h/.m          # MPEG-TS 接收与解复用（FFmpeg）
│   ├── VCamVideoToolboxDecoder.h/.m# H.264 硬解 → CVPixelBuffer
│   ├── VCamOBSAudioDecoder.h/.m    # AAC → PCM（AudioConverter）
│   ├── VCamPixelBufferUtils.h/.m   # NV12 工具、CMSampleBuffer 组装、时钟
│   └── VCamConcurrentQueue.h/.m    # 有界帧队列（低延迟、丢最旧）
│
├── UI/
│   ├── VCamPanel.h/.m              # 音量减弹出的悬浮小窗（可拖动、贴边、穿透）
│   ├── VCamVolumeHook.h/.m         # 音量减拦截（短按弹窗 / 长按调音量 / 通话放行）
│   ├── VCamPickerController.h/.m   # PHPicker 选相册 + 导出到本地文件
│   ├── VCamHUD.h/.m                # 轻量吐司（不抢 keyWindow，避免打断推流）
│   ├── VCamVideoDataOutputProxy.h/.m # AVCaptureVideoDataOutput delegate 代理
│   └── VCamPreviewOverlay.h/.m     # PreviewLayer 覆盖层（无 data output 的 App）
│
├── Media/
│   ├── VCamPhotoOutputInjector.h/.m   # 拍照结果替换成虚拟画面
│   └── VCamMovieFileInjector.h/.m     # 录像影子录制 + 文件替换
│
├── Mic/
│   └── VCamMicInjector.h/.m        # 麦克风替换（AURemoteIO / AudioDataOutput / Recorder）
│
├── prefs/                          # 可选 PreferenceLoader 面板（VCAM_BUILD_PREFS=1）
│   ├── Makefile
│   ├── VCamPrefsRootListController.m
│   ├── Resources/Root.plist
│   └── layout/Library/PreferenceLoader/Preferences/VCam.plist
│
├── scripts/
│   ├── build.sh                    # 一次打 rootful + rootless 两个 deb
│   ├── make-repo.sh                # 生成 Packages / Packages.gz / Release（含校验）
│   ├── make-icon.sh                # 生成 CydiaIcon.png 与横幅
│   ├── ffmpeg-deps.sh              # 把 FFmpeg 静态库装进 Theos vendor
│   └── nginx-vcam-repo.conf        # Nginx 部署示例（HTTPS + 正确 MIME + 缓存策略）
│
├── repo/                           # 直接上传到网站目录的内容
│   ├── Release.template            # Release 模板（改域名即可用）
│   ├── Packages.example            # Packages 格式示例（真实文件由脚本生成）
│   ├── sileo-featured.json         # Sileo 精选横幅
│   ├── depiction/vcam.html         # 普通 HTML depiction
│   ├── depiction/vcam.json         # Sileo native depiction
│   ├── icons/                      # 图标（用 make-icon.sh 生成）
│   └── debs/                       # 放 .deb（由 make-repo.sh 填充）
│
├── .github/workflows/build.yml     # push tag → 编译 + 生成源 + 发布 Pages
├── Docs/ARCHITECTURE.md            # 架构与 hook 点细节
└── README.md                       # 本文件
```

---

## 3. 编译

### 3.1 依赖

| 需要 | 说明 |
| --- | --- |
| **macOS** | Theos 需要 Xcode 的 iOS SDK 来交叉编译 arm64e。WSL/Linux 上可以构建，但需要额外装工具链，本文以 macOS 为准 |
| **Theos** | <https://theos.dev/docs/installation> |
| **ldid** | `brew install ldid`（签名 iOS 二进制） |
| **dpkg** | `brew install dpkg`（打包 deb）；Debian/Ubuntu 用 `apt install dpkg-dev` |
| **FFmpeg 静态库** | 只有 OBS 模式需要，见 `scripts/ffmpeg-deps.sh` |

```bash
export THEOS=/opt/theos
export PATH=$THEOS/bin:$PATH
```

### 3.2 编译

```bash
cd vcam

# 方式一：一次打出两个包（推荐；会自动切换 control 文件）
chmod +x scripts/*.sh
./scripts/build.sh
# → packages/com.quite85.vcam_1.0.0_iphoneos-arm64-rootful.deb
# → packages/com.quite85.vcam_1.0.0_iphoneos-arm64-rootless.deb

# 方式二：单独打一个（注意先切换 control，Theos 只读根目录的 ./control）
cp control-rootful control && make package FINALPACKAGE=1
cp control-rootless control && make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless

# 不要 FFmpeg（体积从 ~15MB 降到 ~200KB，OBS 菜单会提示未编译）
VCAM_ENABLE_OBS=0 ./scripts/build.sh

# 附带设置面板
cp control-rootful control && make package VCAM_BUILD_PREFS=1

# Debug 版（带更多日志）
cp control-rootful control && make package DEBUG=1
```

> **版本号改哪里**：`control-rootful` 与 `control-rootless` **两个文件都要改**
> （`build.sh` 会按变体把它们拷成 `./control`）。

### 3.3 架构说明

- `ARCHS = arm64 arm64e`：一个 deb 里同时含两个切片。
  - **arm64e** 给 A12 及以上的新设备（Dopamine / palera1n rootless 走这条）
  - **arm64** 给旧设备与 rootful
- 包名统一是 `iphoneos-arm64`，`Packages` 里按 `-rootful` / `-rootless`
  分成两条记录，Sileo 会按你的越狱类型自动选。

---

## 4. 安装

### 4.1 rootless（Dopamine / palera1n rootless / XinaA15）

```
安装路径（Theos 自动加 /var/jb 前缀）：
  /var/jb/Library/MobileSubstrate/DynamicLibraries/VCam.dylib
  /var/jb/Library/MobileSubstrate/DynamicLibraries/VCam.plist
  /var/jb/Library/MobileSubstrate/DynamicLibraries/VCam-mediaserverd.plist
  /var/jb/Library/PreferenceBundles/VCamPrefs.bundle      （可选）
  /var/jb/Library/PreferenceLoader/Preferences/VCam.plist （可选）
运行时数据（不属于包，插件自己创建）：
  /var/mobile/Library/VCam/
```

```bash
# Sileo 里安装（推荐）
# 或 ad-hoc：
dpkg -i com.quite85.vcam_1.0.0_iphoneos-arm64-rootless.deb
killall -9 SpringBoard    # UI 生效需要重启 SpringBoard
```

### 4.2 rootful（unc0ver / checkra1n / palera1n rootful）

```
安装路径：
  /Library/MobileSubstrate/DynamicLibraries/VCam.dylib
  /Library/MobileSubstrate/DynamicLibraries/VCam.plist
  /Library/MobileSubstrate/DynamicLibraries/VCam-mediaserverd.plist
  /Library/PreferenceBundles/VCamPrefs.bundle
  /Library/PreferenceLoader/Preferences/VCam.plist
```

```bash
dpkg -i com.quite85.vcam_1.0.0_iphoneos-arm64-rootful.deb
killall -9 SpringBoard
```

### 4.3 roothide

用 roothide 的 Theos 分支构建，或对已编译的 dylib 跑一遍
`roothide Patcher`。装了之后状态文件仍在
`/var/mobile/Library/VCam/`（roothide 会做路径重定向）。

### 4.4 安装后自检

```bash
# 1) 依赖注入是否加载
tail -f /var/mobile/Library/VCam/vcam.log

# 期望看到的行：
#   =========== VCam 加载到 SpringBoard (pid ...) ===========
#   [vol] 音量键监听已安装
#   =========== VCam 加载到 mediaserverd (pid ...) ===========
#   [hook][msd] 已 hook FigImageQueueEnqueue @ 0x...
#   [mic][msd] 已 hook AudioUnitSetProperty @ 0x...
#   =========== VCam 加载到 <某个App> (pid ...) ===========
#   [app] 已为 AVCaptureVideoDataOutput 安装虚拟帧代理

# 2) 确认 dylib 与 filter 都在
ls -l /var/jb/Library/MobileSubstrate/DynamicLibraries/VCam*     # rootless
ls -l /Library/MobileSubstrate/DynamicLibraries/VCam*            # rootful
```

如果 `mediaserverd` 里**没有任何** `[hook][msd]` 行，说明这版 iOS 的私有符号
没匹配上 —— 功能仍然可用（App 层接管），但极少数未注入的 App 可能拿到真实画面。

### 4.5 ⚠️ 重要：mediaserverd 的 filter 需要补装

Theos 只会自动安装**与 tweak 同名**的 `VCam.plist`。
`VCam-mediaserverd.plist` 名字不同，**不会被自动安装** —— 不处理的话
系统级注入（mediaserverd 层）根本不会加载。

最省事的做法：在仓库里建好 `layout/` 目录，让 Theos 直接拷进去
（rootless 会自动加 `/var/jb` 前缀）：

```bash
mkdir -p layout/Library/MobileSubstrate/DynamicLibraries
cp VCam-mediaserverd.plist layout/Library/MobileSubstrate/DynamicLibraries/
```

或者用 Theos 的过滤条件（`vcam-msd/` 子工程）：

```make
# vcam/msd/Makefile
TWEAK_NAME = VCamMSD
VCamMSD_FILES = VCamMSD.x
include $(THEOS_MAKE_PATH)/tweak.mk
# 根 Makefile 里加： SUBPROJECTS += msd
```

更完整的三种方案见 [Docs/ARCHITECTURE.md 第 1.2 节](Docs/ARCHITECTURE.md)。

---

## 5. 使用（音量减悬浮窗）

### 5.1 基本操作

| 操作 | 结果 |
| --- | --- |
| **短按「音量减」** | 弹出 / 收起悬浮小窗（音量会被还原，不误调音量） |
| **长按「音量减」** | 交给系统调音量（约 0.28 秒判定） |
| 通话中按音量键 | 不拦截，完全交给系统 |
| 拖动小窗 | 移动位置，松手自动贴左边或右边 |
| 点 `✕` | 收起 |
| 点 `⋯` | 展开高级选项 |

### 5.2 小窗选项

**基本四项（永远显示）**

- 🎬 **选择视频** —— 相册选视频，循环播放作为相机画面；有音轨则同步替换麦克风
- 🖼 **选择图片** —— 相册选图片，作为静止画面（约 30fps 重复同一帧）
- 📡 **电脑推流 / OBS** —— 显示并复制本机推流地址，开始监听
- ⛔️ **禁用替换** —— 立刻恢复真实摄像头与真实麦克风（无残帧、无残音）

**高级选项（点 `⋯` 展开）**

- ↻ 旋转 90°（0/90/180/270 循环）
- ⇋ 镜像开关
- 🔁 视频循环开关
- 🔊 唇形同步微调（0 / +40 / −40 ms 循环）
- 📐 横屏 / 竖屏切换（1920x1080 ↔ 1080x1920）
- 📋 复制推流地址
- 🔄 重载虚拟源

### 5.3 为什么是音量减，不是长按 Home

- iPhone X 之后没有 Home 键；
- 长按 Home 会触发 AssistiveTouch / Siri，且在全屏相机 App 里常被拦截；
- 音量键是所有 App（含全屏游戏、FaceTime）都能稳定收到的硬件事件；
- 音量减还有一个额外好处：用户普遍不用它（更常用音量加），误触概率低。

### 5.4 相册权限

第一次选择相册资源时会弹权限申请。**必须允许**，因为：

PHPicker 提供的临时授权只对调用进程（SpringBoard）在当前会话内有效，
而真正读文件的 `mediaserverd` 没有这个授权。所以 VCam 的流程是：

```
PHPicker 选择 → SpringBoard 进程内导出到
  /var/mobile/Library/VCam/assets/video_xxxx.mp4（H.264+AAC）
  /var/mobile/Library/VCam/assets/image_xxxx.jpg（EXIF 方向已烘焙）
→ mediaserverd 直接读本地文件（不需要任何相册权限）
```

导出时会自动处理：

- 视频若是 HEVC/ProRes 等 → 转成 H.264 + AAC 的 mp4（保证 AVPlayer 一定解得动）
- 图片若是 HEIC → 转成 JPEG 并把方向烘焙进像素（避免旋转两次）
- 最长边限制 2560、视频上限 10 分钟
- 只保留最近 4 个资源文件，自动清理旧的

---

## 6. OBS / 电脑推流 逐步设置

### 6.1 手机端

1. 打开任意相机 App，**按一次音量减**。
2. 点「📡 电脑推流 / OBS」。
3. 小窗会显示类似 `udp://192.168.1.20:5600` 的地址，**并且已经复制到剪贴板**。
   小窗同时会列出其它可用的网卡地址（USB 网络共享的会排在最前面）。

> 默认端口 **5600**，可以在「设置 → VCam → 监听端口」里改。
> 想换成 TCP：设置 → VCam → 传输协议 → TCP。

### 6.2 电脑端 OBS

**OBS → 设置 → 输出**

1. 「输出模式」选 **高级**
2. 切到 **流** 标签页
3. 按下面填：

```
编码器          : FFmpeg 自定义输出  (Custom Output (FFmpeg))
FFmpeg 输出类型  : 输出到 URL
容器格式         : mpegts
视频编码器       : libx264
音频编码器       : aac
输出 / 目标      : udp://192.168.1.20:5600      ← 填手机显示的那个地址
```

4. 点「开始推流」。

> ⚠️ **别填 `127.0.0.1`**！那推给你自己电脑了。
> 必须是手机小窗里显示的那个 IP。

### 6.3 推荐编码参数

| 参数 | 建议值 | 理由 |
| --- | --- | --- |
| 分辨率 | `1080x1920`（竖屏）/ `1280x720`（省流量） | 竖屏和社交 App 的预览比例一致，不用裁切 |
| 帧率 | **30 fps** | 60fps 会让手机解码负载翻倍，收益极小（社交 App 也多为 30fps） |
| 编码预设 | `veryfast` | 延迟/画质平衡点 |
| Profile | `baseline` 或 `main` | `high 10` 手机会解不了 |
| x264 参数 | `tune=zerolatency` | 关掉前瞻缓冲，延迟能降 100ms+ |
| 关键帧间隔 | **1 秒**（`keyint=30`，`min-keyint=30`） | 丢包后 1 秒内就能恢复画面，不然会花屏很久 |
| B 帧 | `0`（`bframes=0`） | 省掉重排序缓冲 |
| 码率 | Wi-Fi `4–8 Mbps`；USB 网络共享 `10–15 Mbps` | 超过 15Mbps 手机会开始丢包 |
| 音频 | AAC-LC，48000 Hz，立体声，128 kbps | 与插件内部处理格式一致，避免重采样 |

OBS 自定义 FFmpeg 输出里，这些可以直接写在「视频编码器」后面的参数栏：

```
libx264 -preset veryfast -tune zerolatency -profile:v baseline \
        -b:v 6000k -maxrate 8000k -bufsize 8000k \
        -g 30 -keyint_min 30 -bframes 0 -pix_fmt yuv420p
```

音频栏：

```
aac -b:a 128k -ar 48000 -ac 2
```

### 6.4 更稳的连接方式（强烈推荐）

**USB 网络共享**：iPhone 打开「个人热点」，用数据线连电脑，
然后在电脑上确认多出一个网卡（通常是 `172.20.10.x` 网段）。

| | Wi-Fi | USB 网络共享 |
| --- | --- | --- |
| 延迟 | ~250–400 ms | ~90–150 ms |
| 丢包 | 偶发 | 几乎为零 |
| 稳定性 | 受路由器/邻居干扰 | 有线，稳定 |

插件会把 `172.20.10.x` / `192.168.42.x` 这类共享网段的地址**排在最前面**，
直接用小窗显示的地址推流即可。

### 6.5 断流行为

- 断流后默认**保持最后一帧**（画面不闪黑）；
- 如果需要明确的提示，把 `VCamOBSSource.holdLastFrame` 设为 `NO`，
  会显示「等待 OBS 推流…」占位图（最多 2fps 生成，避免浪费 CPU）；
- 小窗状态区会显示当前码率与丢帧数。

### 6.6 音频

OBS 里必须**同时有音频轨**（桌面音频或麦克风都可以），
插件的 `AudioConverter` 会解 AAC 并灌进虚拟麦克风。
如果 OBS 只推视频，VCam 会输出**静音占位**而不是放行真实麦克风
（避免「画面是虚拟的、声音是真的」这种穿帮）。

---

## 7. 把自己域名做成 Sileo 源

Sileo 里「添加软件源」填的是**一个 APT 仓库地址**，不是上传到什么官网。
只要你的域名上放着 `Release` + `Packages.gz` + `debs/`，并且是 **HTTPS**，
就能被订阅。

### 7.1 生成源文件

```bash
cd vcam

# 1) 改域名
export DOMAIN=repo.example.com     # 你的域名
export REPO_PATH=""                # 放在网站根目录就留空；放在 /repo 子目录就写 /repo

# 2) 编译 + 生成
./scripts/build.sh
./scripts/build.sh                 # 确保两个 deb 都在 packages/
./scripts/make-repo.sh             # → repo/{Release,Packages,Packages.gz,debs/...}
./scripts/make-icon.sh 256         # 生成 CydiaIcon.png 与图标（需 ImageMagick 或 python3）

# 3) 本地预览
cd repo && python3 -m http.server 8000
# iPhone 上把源地址填 http://<电脑IP>:8000/ 先验证，正式使用务必换 HTTPS
```

### 7.2 目录结构

```
/repo/                          ← 上传到网站目录（若希望用户只输域名，就放在根目录）
  Release                       ← 源信息（含 Packages 的校验和）
  Packages                      ← 明文包列表
  Packages.gz                   ← 压缩版（Sileo 优先读这个）
  Packages.bz2                  ← 可选
  CydiaIcon.png                 ← 源列表里的小图标
  sileo-featured.json           ← Sileo 精选横幅（可选）
  depiction/
    vcam.html                   ← 普通 depiction
    vcam.json                   ← Sileo native depiction
  icons/
    vcam.png
    vcam_banner.png
  debs/
    com.quite85.vcam_1.0.0_iphoneos-arm64-rootful.deb
    com.quite85.vcam_1.0.0_iphoneos-arm64-rootless.deb
```

### 7.3 Release 内容

`repo/Release.template` 是可改域名的模板，`make-repo.sh` 会自动生成真实的
`Release`（含 `Date`、`MD5Sum`、`SHA256` 三段校验）。关键字段：

```
Origin: VCam Repo
Label: VCam Repo
Suite: stable
Version: 1.0
Codename: ios
Architectures: iphoneos-arm iphoneos-arm64 iphoneos-arm64e
Components: main
Description: iOS 15.0-16.6.1 系统级虚拟相机 + 虚拟麦克风
```

### 7.4 Packages 条目

每个 `.deb` 一条记录。`make-repo.sh` 用
`dpkg-scanpackages -m debs /dev/null > Packages` 生成，
然后**再用 python3 兜底重算** `Size` / `MD5sum` / `SHA256`
（有些 dpkg 版本不写这些字段，缺了 Sileo 会直接报校验失败）。

真实条目长这样：

```
Package: com.quite85.vcam
Name: VCam
Version: 1.0.0
Architecture: iphoneos-arm64
Description: 系统级虚拟摄像头 + 虚拟麦克风（相册图片 / 相册视频 / OBS MPEG-TS 推流）
Depends: firmware (>= 15.0), firmware (<< 16.7), mobilesubstrate | ellekit
Recommends: preferenceloader
Conflicts: com.notaudren.vcam, com.audren.vcam
Installed-Size: 512
Section: Tweaks
Depiction: https://quite85.github.io/vcam/depiction/vcam.html
SileoDepiction: https://quite85.github.io/vcam/depiction/vcam.json
Icon: https://quite85.github.io/vcam/icons/vcam.png
Author: yourname <you@quite85.github.io>
Maintainer: yourname <you@quite85.github.io>
Filename: debs/com.quite85.vcam_1.0.0_iphoneos-arm64-rootful.deb
Size: 184320
MD5sum: 9c1f...（32 位）
SHA256: 3f2a...（64 位）
```

> `repo/Packages.example` 是格式示例，里面的 `Size/MD5sum/SHA256` 是**占位零值**，
> 只用来对照字段名。**发包前必须跑 `make-repo.sh` 生成真实值。**

### 7.5 部署方式（三选一）

#### A. Cloudflare Pages / GitHub Pages + 自定义域名

```bash
# GitHub Pages
git add repo && git commit -m "repo: 1.0.0" && git push
# 然后 Settings → Pages → Source 选 "GitHub Actions"
# 仓库里的 .github/workflows/build.yml 已经配好了整个流水线：
#   push tag v1.0.0 → 编译 → 生成源 → 发 Release → 部署 Pages
```

然后加 `CNAME` 记录把 `repo.example.com` 指向 `yourname.github.io`。
Cloudflare 用户**必须**对 `/Packages*` 和 `/Release` 设置
Cache Rule = **Bypass**，否则用户刷不到更新。

#### B. VPS + Nginx（最可控，推荐）

```bash
sudo mkdir -p /var/www/vcam-repo
sudo cp -r vcam/repo/* /var/www/vcam-repo/
sudo cp vcam/scripts/nginx-vcam-repo.conf /etc/nginx/sites-available/vcam-repo
sudo ln -s /etc/nginx/sites-available/vcam-repo /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx

# 免费证书（不要自签！Sileo 会失败）
sudo apt install certbot python3-certbot-nginx
sudo certbot --nginx -d repo.example.com
```

`scripts/nginx-vcam-repo.conf` 里已经处理好了三个关键点：

1. **必须 HTTPS**，HTTP 301 跳过去
2. `.deb` 的 MIME 用 `application/vnd.debian.binary-package`
3. `Release` / `Packages*` 的缓存设为 `no-cache`，并且**关闭 gzip**
   （不能把 `Packages.gz` 再压一次）

#### C. 对象存储 + CDN（S3 / R2 / OSS + CloudFront / Cloudflare）

```bash
aws s3 sync repo/ s3://my-vcam-repo/ \
  --exclude "*.deb" --cache-control "no-cache"
aws s3 sync repo/debs/ s3://my-vcam-repo/debs/ \
  --cache-control "public, max-age=3600"
# 关键：Release / Packages* 必须 no-cache 或极短 TTL
aws s3 cp repo/Packages.gz s3://my-vcam-repo/Packages.gz \
  --content-type application/gzip --cache-control "no-cache"
```

### 7.6 DNS

| 方式 | 记录类型 | 主机记录 | 值 |
| --- | --- | --- | --- |
| 独立子域名 | A | `repo` | 你的服务器 IP |
| 独立子域名（Cloudflare） | CNAME | `repo` | `yourname.github.io`（或 Pages 项目域名） |
| 子目录 | A | `@` | 你的服务器 IP，`REPO_PATH=/repo` |

### 7.7 域名与更新流程

**用户添加源**：Sileo → 软件源 → `+` → 输入

```
https://repo.example.com          （放在根目录时）
https://example.com/repo          （放在子目录时）
```

**发新版流程**

```
1. 改 control / control-rootless 里的 Version（例如 1.0.0 → 1.0.1）
2. ./scripts/build.sh                       # 编译新 deb
3. 旧 deb 可以留在 repo/debs/ 做历史版本（Packages 支持多版本）
4. DOMAIN=repo.example.com ./scripts/make-repo.sh   # 重算 Size/SHA256 并重建索引
5. 上传覆盖 Release / Packages / Packages.gz / debs/
6. 用户在 Sileo 里下拉刷新 → 看到「更新」按钮 → 升级
```

> **铁律：每次换 deb 都必须重新跑 `make-repo.sh`。**
> `Packages` 里的 `Size` / `SHA256` 与实际文件不符时，
> Sileo 会报 `Hash Sum mismatch` 或 `Size mismatch`，用户根本装不上。
>
> 如果用户已经装了旧版且你想替换同版本号的包（不推荐）：
> 改了内容必须改 `Version`，否则 APT 认为「已经是最新」不会重新下载。
> 万不得已时清一下：`apt-get clean && rm -rf /var/mobile/Library/Caches/com.saurik.Cydia`

---

## 8. 常见故障排查

日志永远在 `/var/mobile/Library/VCam/vcam.log`（滚动，最大 256KB），
也可以在「设置 → VCam → 查看日志」里直接看和复制。

### 8.1 Sileo 添加源失败

| 现象 | 原因 | 解决 |
| --- | --- | --- |
| 「无法连接到服务器」 | 用了 HTTP 或自签证书 | 必须 HTTPS + 受信任证书（Let's Encrypt） |
| 「Release 文件未找到」 | `Release` 没上传，或路径不对 | 确认 `https://域名/repo/Release` 能直接在浏览器打开 |
| 「Hash Sum mismatch」 | `Packages` 里的 SHA256 与 deb 不符 | 重跑 `make-repo.sh`，确认上传了新版 `Packages` **和** `Packages.gz` |
| 「Size mismatch」 | 同上，或者 CDN 缓存了旧的 `Packages.gz` | 清 CDN 缓存；把 `Packages*` 设为 no-cache |
| 「File has unexpected size」 | `Packages.gz` 被又压了一层（`.gz.gz`） | Nginx 里对 `Packages.gz` 关闭 gzip（配置里已处理） |
| 刷新后看不到新版本 | `Release` 的 `Date` 没变 / APT 缓存 | 重跑 `make-repo.sh`（会自动更新 `Date`）；用户在 Sileo 里下拉刷新 |
| 装上去但插件不加载 | rootless 包装到了 rootful 设备（或反之） | 确认 `Packages` 里两个架构各有一条；或手动 `dpkg -i` 对应包 |

### 8.2 插件不生效

```
1) SpringBoard 里没有 [vol] 音量键监听已安装
   → filter plist 没装到正确路径
   → rootless:  ls -l /var/jb/Library/MobileSubstrate/DynamicLibraries/VCam*
   → rootful:   ls -l /Library/MobileSubstrate/DynamicLibraries/VCam*
   → 检查依赖是否满足：dpkg -l | grep -E 'ellekit|mobilesubstrate'

2) 按音量减有弹窗，但预览还是真实画面
   → 先看 mediaserverd 有没有加载 VCam（看日志）
   → 如果 mediaserverd 没加载：确认 VCam-mediaserverd.plist 存在
   → 如果加载了但没 [hook][msd]：这版 iOS 私有符号没匹配上，
     换到「设置 → VCam」打开「仅 App 层注入」并 killall 相机 App 重试
   → 如果 App 里也没有 [app] 已为 AVCaptureVideoDataOutput 安装虚拟帧代理：
     说明该 App 用的是 previewLayer + 自己录制的路径（见 9. 已知限制）

3) 预览是虚拟的，但拍下来是真的
   → 「设置 → VCam → 查看日志」搜 [photo]
   → 如果看到「无法构造 AVCapturePhoto」：这版 iOS 的私有构造方法变了，
     请联系作者提供日志；临时方案是改用录像模式

4) 装了之后相机完全不可用 / 黑屏
   → 「设置 → VCam」打开「仅 App 层注入」
   → killall -9 mediaserverd   或重启设备
   → 如果反复如此，说明 mediaserverd 层的某个 hook 在你这版 iOS 上有问题，
     自动降级机制会在下次启动时接管（日志里有「已自动降级为 App 层注入」）
```

### 8.3 音频

| 现象 | 原因 | 解决 |
| --- | --- | --- |
| 画面虚拟了但声音还是真的 | 选的视频没有音轨 | 换带音轨的视频；或用 OBS 模式（OBS 里要有音频轨） |
| 完全没声音 | 视频音轨是 5.1/非常见格式 | 插件统一转 48k 立体声；日志里搜 `[vid][audio]` |
| 音画不同步 | 蓝牙耳机延迟 / OBS 缓冲 | 小窗 → `⋯` → 唇形同步微调（每次 ±40ms） |
| 声音断断续续 | OBS 码率过高 / Wi-Fi 抖动 | 降码率到 4–6 Mbps；换 USB 网络共享；设置里加大「抖动缓冲」 |

### 8.4 OBS

| 现象 | 原因 | 解决 |
| --- | --- | --- |
| 手机一直「等待 OBS」 | 地址填成 `127.0.0.1` 了 | 用手机小窗显示的 IP |
| 同上 | 电脑与手机不在同一网段 | 连同一个 Wi-Fi；或开 USB 网络共享 |
| 同上 | 端口不一致 | 手机设置里的端口与 OBS 输出目标必须一致 |
| 有画面但花屏很久 | 关键帧间隔太大 | OBS 里设 `keyint=30`（1 秒） |
| 延迟很高（>1s） | 有 B 帧 / 没开 zerolatency | `-tune zerolatency -bframes 0` |
| UDP 一直收不到 | 电脑防火墙拦了 | 放行 OBS 或改用 `tcp://` |
| 日志里 `打开流失败` | FFmpeg 未编译进包 | 这个包是 `VCAM_ENABLE_OBS=0` 构建的 |

### 8.5 音量键

| 现象 | 原因 | 解决 |
| --- | --- | --- |
| 按音量减只调音量不弹窗 | 判定成长按了 | 更干脆地短按（< 0.25 秒松开） |
| 完全不响应 | 正在通话中 | 设计如此（通话中不拦截音量键） |
| 弹窗同时音量被调了 | 极少数 App 抢了音量事件 | 小窗里操作完成后音量会被还原；可到设置里关掉音量键功能 |
| 弹窗挡住了相机界面 | 位置不好 | 拖动小窗，会自动贴边 |

### 8.6 性能 / 发热

| 现象 | 原因 | 解决 |
| --- | --- | --- |
| 相机预览掉帧 | 图片源每帧都在做旋转 | 尽量用「0° + 不镜像」；或降低图片分辨率 |
| 手机很热 | 视频源 + 「拍照/录像」同时在解码 | 关闭不需要的功能；OBS 分辨率降到 720p |
| 录像文件很大 | 影子录制用了 6Mbps 固定码率 | 改 `VCamMovieFileInjector.m` 里的 `AVVideoAverageBitRateKey` |

---

## 9. 已知限制

### 9.1 可能仍然检测到虚拟相机的 App

VCam 不做对抗检测（这是设计选择，也符合需求里「不做针对特定 App 的
恶意检测对抗样本」）。以下情况可能被 App 自己发现：

| 检测手段 | 说明 |
| --- | --- |
| 时延指纹 | App 测量「请求 → 首帧」的时间，虚拟源通常比硬件快很多 |
| 传感器一致性 | App 同时读 `CMMotionManager` 与画面运动，静帧/循环视频会对不上 |
| 画面内容分析 | 服务端做人脸活体检测、屏幕翻拍检测（如某些银行/政务 App） |
| 相机参数 | App 读 `AVCaptureDevice.activeFormat`、镜头畸变系数等，虚拟源下这些仍是真实值，反而可能暴露 |
| 帧间隔统计 | 图片源的帧间隔过于规律（dispatch timer 抖动 < 1ms），硬件会有 ±2ms 抖动 |
| 专属 SDK | 某些 App 用自研采集（不用 AVFoundation），或走 ReplayKit / 屏幕录制路径 |

**已知比较难搞的场景**：

- 微信/QQ 的**视频通话**：它同时用摄像头 + 麦克风 + 自己的编解码，
  部分版本会读取 `AVCaptureDevice` 的 `deviceType` 列表来判断是不是真机摄像头。
- **FaceTime**：走 `AVConference` 框架，采集由独立 XPC 服务负责。
  VCam 的 mediaserverd 层 hook 通常能覆盖，但如果 iOS 版本把采集挪到
  `AVConference` 自己的进程里，就需要额外注入该进程。
- **Snapchat / Instagram 的相机**：它们大量使用 `AVCapturePhotoOutput`
  与自定义 Metal 渲染管线。VCam 的照片替换 + 视频帧替换一般有效，
  但 Snapchat 的部分滤镜会直接把 `CVPixelBuffer` 送进自家 GPU 管线，
  这时虚拟帧仍是虚拟帧（对我们有利）。
- **扫码 / 二维码**：会拿到虚拟画面，扫到的是视频里的码，属正常行为。

### 9.2 iOS 16.6.1 边界

- **16.6.1 是本项目明确测试范围的上界**。16.7 及以上（含 17.x）：
  `mediaserverd` 的 `Fig*` 符号有较大改动，`Packages` 里的
  `firmware (<< 16.7)` 会阻止安装 —— 这是**故意**的，避免装上去相机全黑。
- **iOS 17+** 引入了新的相机扩展机制（`CMIOExtension` 风格），
  真要做系统级虚拟相机需要走完全不同的路线（Camera Extension Provider），
  本项目不覆盖。
- **16.0–16.3** 上 `FigImageQueueEnqueue` 的名字与 16.4+ 不同，
  候选符号数组里都列了，命中哪个用哪个；命中不到就靠 App 层。
- **15.x** 上 `AVCapturePhoto` 的 `initWithSampleBuffer:` 通常可用，
  拍照替换成功率比 16.x 高。

### 9.3 音量键冲突

| 冲突场景 | 现状 |
| --- | --- |
| 相机 App 内录像时按音量减 | 会弹窗（设计如此），但不会打断录像 |
| 系统相机「音量键快门」 | 与 VCam 冲突。开启替换后，按音量减弹 VCam 小窗，不会拍照。可以先禁用替换再拍 |
| 音乐 / 播客 App | 会被拦截弹出小窗（短按）。长按仍能调音量 |
| 通话中 | 完全不拦截（检测到 `AVAudioSessionCategoryPlayAndRecord` + 其它音频播放时放行） |
| 精确的「按下/松开」判定 | 用的是「0.28 秒内音量是否继续下降」启发式判断。极快速连按可能偶尔被判定为长按，或反之 |
| 音量已到 0 或 1 | 公开 API 通道 A 不再产生变化事件；通道 B（私有通知）仍会触发，所以顶到底时依然能弹窗 |

### 9.4 相机功能降级

虚拟源生效时，以下操作会做「假成功」（避免 App 崩溃），但**不会真的生效**：

- 闪光灯 / 手电筒开关 → 返回成功，不点亮
- 对焦 / 曝光点设置 → 吞掉
- 白平衡模式切换 → 吞掉
- `lockForConfiguration` → 直接返回 `YES`（不会真的获取硬件锁）

前后摄切换**是**生效的：切换后虚拟源继续工作，
前摄默认会应用镜像（符合自拍习惯，可在小窗里关掉）。

### 9.5 其他

- **OBS 的 `holdLastFrame`**：断流时保留最后一帧是默认行为，
  这让「是不是断了」不那么直观。想看明确的「等待 OBS」提示，
  把 `VCamOBSSource.holdLastFrame` 设为 `NO`。
- **录像文件替换**：影子录制与原始录制是并行的两个文件，
  App 的 delegate 回调会被延迟到替换完成后（最多 3 秒）。
  极个别 App 会检查「录制时长与文件时长是否一致」，可能察觉差异。
- **mediaserverd 层音频替换**依赖 `AudioUnitSetProperty` 这个
  CoreAudio C 符号。如果某个 iOS 版本把麦克风采集移到别的路径
  （例如 `AVAudioEngine` 的独立 XPC），这一层会失效，
  但 App 层的 `AVCaptureAudioDataOutput` 代理仍有效。
- **内存**：循环视频不会把整个文件读进内存（AVPlayer 流式解码 +
  有界队列）；图片只保留一张基准帧；OBS 解码队列上限 3 帧。
  禁用替换时会 `flushPools` 释放所有 CVPixelBufferPool。
- **不支持**：iPad 台前调度多窗口下的多路同时采集、
  `AVCaptureMultiCamSession`（多个摄像头同时采集）场景未做特殊处理。

---

## 10. 免责声明

本插件用于：

- 个人内容创作 / 直播的画面替代；
- 物理摄像头或麦克风损坏时的应急替代方案；
- 开发调试与自动化测试。

**使用者需自行遵守所使用 App 的服务条款与当地法律法规。**
作者不对因使用本插件导致的账号处罚、内容纠纷、数据损失承担任何责任。

本插件**不含**卡密、**不联网**授权、**不上传**任何用户信息
（UDID / 设备标识 / 相册内容都不会离开设备）。
所有数据处理都在本机完成。

---

## 附录：参考与致谢

- 能力范围参考：[VCam-iOS-16](https://github.com/notaudren/VCam-iOS-16)（未使用其任何代码或二进制）
- [Theos](https://theos.dev/) · [Logos](https://theos.dev/docs/logos)
- [ElleKit](https://github.com/evelyneee/ellekit) · [Dopamine](https://github.com/opa334/Dopamine)
- [FFmpeg](https://ffmpeg.org/)（仅 mpegts demux 与 h264/aac parser）
- Apple 文档：AVFoundation、CoreMedia、VideoToolbox、AudioToolbox

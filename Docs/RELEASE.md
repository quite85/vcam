# 发布信息（Release Notes）

> 本文档记录**当前已发布**的产物与地址，方便随时查。
> 最后更新：v1.0.0 发布完成时。

---

## 1. 已发布的地址

| 用途 | 地址 |
| --- | --- |
| **Sileo 软件源**（在 Sileo 里添加这个） | `https://quite85.github.io/vcam` |
| GitHub Release（直接下载 deb） | <https://github.com/quite85/vcam/releases/tag/v1.0.0> |
| 源码仓库 | <https://github.com/quite85/vcam> |
| 源码里的 depiction 预览 | <https://quite85.github.io/vcam/depiction/vcam.html> |

---

## 2. 已发布的包

| 文件名 | 大小 | 适用 |
| --- | --- | --- |
| `com.quite85.virtualcamera_1.0.0_iphoneos-arm64-rootless.deb` | 94.3 KB | **Dopamine / palera1n rootless**（iOS 15.0–16.6.1） |
| `com.quite85.virtualcamera_1.0.0_iphoneos-arm64-rootful.deb` | 95 KB | unc0ver / checkra1n / palera1n rootful |
| 包名（Package id） | — | `com.quite85.virtualcamera` |
| 显示名 | — | 虚拟摄像头 |
| 版本 | — | 1.0.0 |

### 安装后在设备上的位置（rootless）

```
/var/jb/Library/MobileSubstrate/DynamicLibraries/VCam.dylib               主注入库
/var/jb/Library/MobileSubstrate/DynamicLibraries/VCam.plist               App 层 filter
/var/jb/Library/MobileSubstrate/DynamicLibraries/VCam-mediaserverd.plist  系统级 filter
/var/mobile/Library/VirtualCamera/                                        运行时数据（日志等）
```

---

## 3. 本次构建包含的功能

- **mediaserverd 层注入**：`FigImageQueue*` 出帧点 + `AudioUnitSetProperty` 输入回调
- **AVFoundation 层注入**：`AVCaptureVideoDataOutput` delegate 代理、预览层覆盖、
  拍照换帧、录像影子录制、`AVCaptureAudioDataOutput` 代理
- **相册视频**：AVPlayer 循环播放出帧 + AVAssetReader 出音轨（可作虚拟麦）
- **相册图片**：静帧按 30fps 重复送帧
- **音量减悬浮小窗**：短按弹窗 / 长按调音量 / 通话中不拦截，可拖动贴边
- **禁用恢复**：一键完整回到硬件相机与麦克风

### 本次**未**包含（构建选项关闭）

| 功能 | 状态 | 如何开启 |
| --- | --- | --- |
| OBS / 电脑推流（MPEG-TS + VideoToolbox 硬解） | 源码已完整实现，但构建时 `VCAM_ENABLE_OBS=0` | 准备 FFmpeg 依赖后设 `VCAM_ENABLE_OBS=1` 重新构建 |
| 设置面板（PreferenceLoader） | 源码已完整实现 | 设 `VCAM_BUILD_PREFS=1` 重新构建 |
| 源列表图标 `CydiaIcon.png` | 生成脚本已就绪，但 CI 未成功产出 | 见下方"待办" |

---

## 4. 安装步骤（Dopamine / rootless）

### 方式 A：通过 Sileo 源（推荐，以后能收到更新）

1. Sileo → **软件源** → 右上角 `+`
2. 输入 `https://quite85.github.io/vcam`
3. 刷新后找到「**虚拟摄像头**」→ 安装
4. 装完 **Respring**

### 方式 B：直接装 deb

1. 从 Release 页面下载 `..._iphoneos-arm64-rootless.deb`
2. 用 Filza 打开 → 安装；或者在电脑上：

```bash
scp com.quite85.virtualcamera_1.0.0_iphoneos-arm64-rootless.deb root@手机IP:/var/mobile/
ssh root@手机IP
dpkg -i /var/mobile/com.quite85.virtualcamera_1.0.0_iphoneos-arm64-rootless.deb
```

3. 重启 SpringBoard：

```bash
killall -9 SpringBoard
```

---

## 5. 装完怎么用

1. 打开**系统相机**
2. **短按一下「音量减」** → 弹出悬浮小窗
3. 点 **🎬 选择视频** → 允许相册权限 → 选一个视频
4. 相机画面立刻变成你的视频（无需杀进程、无需 respring）
5. 点 **⋯** 展开可调：旋转 / 镜像 / 循环 / 横竖屏 / 唇形同步
6. 想恢复真实相机 → 点 **⛔️ 禁用替换**

**音量键**：短按弹窗（音量会自动还原）· 长按才真正调音量 · 通话中不拦截。

---

## 6. 装完怎么确认注入成功

```bash
tail -f /var/mobile/Library/VirtualCamera/virtualcamera.log
```

**期望看到**：

```
=========== 虚拟摄像头 加载到 SpringBoard (pid ...) ===========
[vol] 音量键监听已安装
=========== 虚拟摄像头 加载到 mediaserverd (pid ...) ===========
[hook][msd] 已 hook FigImageQueueEnqueue @ 0x...
[mic][msd] 已 hook AudioUnitSetProperty @ 0x...
```

同时确认文件都在：

```bash
ls -l /var/jb/Library/MobileSubstrate/DynamicLibraries/VCam*
```

若 `mediaserverd` 里**没有** `[hook][msd]` 行，说明这版 iOS 的私有符号名没匹配上 ——
功能仍可用（App 层接管），但极少数未注入的 App 可能拿到真实画面。
详见 [BUILD_TROUBLESHOOTING.md](BUILD_TROUBLESHOOTING.md) 与 README 第 9 节。

---

## 7. 目前**尚未在真机验证**

⚠️ **重要**：v1.0.0 的 deb 已经**编译并通过打包验证**（哈希一致、路径正确），
但**还没有在真实 iPhone 上安装运行过**。

代码层面已完成的部分：编译、链接、打包、源索引、哈希校验、filter 落盘路径。
运行时行为（音量键是否弹出、预览是否变虚拟、相机是否稳定）需要你装上去验证。

如果装上后有问题，请把日志（`/var/mobile/Library/VirtualCamera/virtualcamera.log`）发出来。

---

## 8. 待办 / 已知小问题

1. **`CydiaIcon.png` 未产出** —— `scripts/make-icon.sh` 在 CI 上没成功生成图标，
   导致 `https://quite85.github.io/vcam/CydiaIcon.png` 返回 404。
   不影响安装，只是 Sileo 源列表里没有自定义图标。
   修法：在 CI 里改用它依赖的 python3 分支，或直接放一张 256x256 PNG 进 `repo/`。

2. **OBS 推流未编译进本包** —— 需要 FFmpeg 静态库（见 `scripts/ffmpeg-deps.sh`）。
   源码（`VCamTSDemuxer` / `VCamVideoToolboxDecoder` / `VCamOBSAudioDecoder`）已完整实现，
   开启 `VCAM_ENABLE_OBS=1` 即可。

3. **设置面板未编译** —— `VCAM_BUILD_PREFS=1` 即可，源码在 `prefs/`。

---

## 9. 如何发新版本

1. 改 `control-rootful` 与 `control-rootless` 里的 `Version`（**两个文件都要改**）
2. 提交并推送：

```bash
git add -A
git commit -m "v1.0.1"
git push origin main
git tag -f -a v1.0.1 -m "虚拟摄像头 1.0.1"
git push origin v1.0.1 --force
```

3. GitHub Actions 会自动：编译两个 deb → 生成 APT 源 → 创建 Release → 部署 Pages
4. 用户在 Sileo 里**下拉刷新**即可看到更新

> ⚠️ 换 deb 后必须重新生成 `Packages`（CI 已自动做），
> 否则 `Size`/`SHA256` 不符，Sileo 会报校验失败。

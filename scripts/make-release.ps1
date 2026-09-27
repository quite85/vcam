$token = [System.IO.File]::ReadAllText("$env:TEMP\ghtoken.txt")
$hdr = @{ 'User-Agent'='vcam-check'; 'Accept'='application/vnd.github+json'; 'Authorization'="Bearer $token" }

Write-Output "=== 创建 GitHub Release v2.0.0 ==="
$notes = @'
# 虚拟摄像头 v2.0.0

把相机画面替换为相册里的视频。**这一版是基于开源项目重写的。**

## 装哪个

| 你的越狱类型 | 装这个文件 |
| --- | --- |
| **Dopamine / palera1n rootless / XinaA15** | `..._iphoneos-arm64-rootless.deb` |
| unc0ver / checkra1n / palera1n rootful | `..._iphoneos-arm64-rootful.deb` |

## 用法

1. 装好，**重启手机**
2. **短按「音量减」** → 弹出悬浮小窗
3. 点「选择相册视频」 → 选一个视频
4. 打开相机 / Safari 网页 → 画面就是那个视频了

悬浮小窗可以拖动，松手自动贴边。再按一次音量减可随时唤出。

## 这一版改了什么

骨架来自开源项目 [lxxsoufahk/VCam](https://github.com/lxxsoufahk/VCam)，
但修掉了它一个**致命缺陷**。

### 修掉的缺陷

它的 `%ctor` 是：

```objc
NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
if (![bundleID isEqualToString:@"com.apple.springboard"]) {
    %init(VCamHooks);
}
```

而它的 filter **只注入 SpringBoard**。

→ 结果 hook 从未被安装，相机替换从未生效，只剩下一个点了没反应的按钮。

本工程改为**在所有进程都安装帧替换**，SpringBoard 里额外装 UI 与音量监听。

### 帧替换改用代理模式

开源项目用 `%hook NSObject` 实现 `captureOutput:didOutputSampleBuffer:fromConnection:`。
但 `%hook NSObject` 只把方法加到 NSObject 上，各 delegate 子类会命中自己的实现，
那份永远不会被调用。

本工程把 `AVCaptureVideoDataOutput` 的 delegate 包一层 proxy，
**无论真实 delegate 用什么类、是否靠消息转发，都能覆盖**。

### 新增开源项目没有的功能

1. **短按音量减唤出面板**（它只能点屏幕上的按钮）
2. **载入失败时弹窗告知具体原因**（比如"这个文件里没有视频轨"）
3. **运行日志写文件 + NSLog**，出问题能查

## 设计约束

- filter 只列 22 个 Bundle，**不注入 mediaserverd 等系统守护进程**
- 所有 install 与 hook 都包在 `@try/@catch`，构造阶段绝不抛异常
  （此前四次黑屏最可能就是构造异常导致 SpringBoard 崩溃重启循环）

## 已知限制

- **只替换视频，不替换麦克风**
- 部分 App 用 `AVCapturePhotoOutput` 拍照或 `AVCaptureMovieFileOutput` 录像，
  这些路径暂未覆盖
- 竖屏视频的旋转方向处理还不够完善

## 卸载

```
dpkg -r com.quite85.virtualcamera
killall -9 SpringBoard
```
'@

$body = @{
  tag_name = 'v2.0.0'
  target_commitish = 'main'
  name = 'v2.0.0 —— 基于开源项目重写'
  body = $notes
  draft = $false
  prerelease = $false
} | ConvertTo-Json -Depth 3

try {
    $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/quite85/vcam/releases' `
        -Method POST -Body $body -ContentType 'application/json; charset=utf-8' -Headers $hdr -TimeoutSec 60
    Write-Output "  创建成功: $($rel.html_url)"
    $relId = $rel.id
} catch {
    Write-Output "  创建失败（可能已存在）: $($_.Exception.Message)"
    $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/quite85/vcam/releases/tags/v2.0.0' -Headers $hdr -TimeoutSec 30
    $relId = $rel.id
    Write-Output "  使用已存在的 Release: $($rel.html_url)"
}

Write-Output ""
Write-Output "=== 上传两个 deb ==="
foreach ($deb in (Get-ChildItem 'C:\日常使用\vcam\packages\*.deb' -File)) {
    try {
        $up = Invoke-RestMethod -Uri "https://uploads.github.com/repos/quite85/vcam/releases/$relId/assets?name=$($deb.Name)" `
            -Method POST -InFile $deb.FullName -ContentType 'application/vnd.debian.binary-package' -Headers $hdr -TimeoutSec 180
        Write-Output "  OK  $($deb.Name)  ($([math]::Round($deb.Length/1KB,1)) KB)"
    } catch {
        Write-Output "  FAIL $($deb.Name): $($_.Exception.Message)"
    }
}

Write-Output ""
$rel = Invoke-RestMethod -Uri "https://api.github.com/repos/quite85/vcam/releases/$relId" -Headers $hdr -TimeoutSec 30
Write-Output "=== Release 资产 ==="
$rel.assets | ForEach-Object { Write-Output ("   - " + $_.name + "  " + [math]::Round($_.size/1KB,1) + " KB") }
Write-Output ""
Write-Output "下载地址:"
$rel.assets | ForEach-Object { Write-Output ("   " + $_.browser_download_url) }

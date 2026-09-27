$token = [System.IO.File]::ReadAllText("$env:TEMP\ghtoken.txt")
$hdr = @{ 'User-Agent'='vcam-check'; 'Accept'='application/vnd.github+json'; 'Authorization'="Bearer $token" }
$runId = '36358130616'

Write-Output "=== 下载 CI 产物 ==="
$arts = Invoke-RestMethod -Uri "https://api.github.com/repos/quite85/vcam/actions/runs/$runId/artifacts" -Headers $hdr -TimeoutSec 30
$arts.artifacts | ForEach-Object { Write-Output "  制品: $($_.name)  $([math]::Round($_.size_in_bytes/1KB,1)) KB" }
$a = $arts.artifacts | Where-Object { $_.name -eq 'vcam-debs' } | Select-Object -First 1
$zip = Join-Path $env:TEMP 'staged.zip'
Invoke-WebRequest -Uri $a.archive_download_url -OutFile $zip -Headers $hdr -TimeoutSec 120 -UseBasicParsing -MaximumRedirection 10
$d = Join-Path $env:TEMP 'stageddebs'
if (Test-Path $d) { Remove-Item $d -Recurse -Force }
Expand-Archive -Path $zip -DestinationPath $d -Force
New-Item -ItemType Directory -Force -Path 'C:\日常使用\vcam\packages' | Out-Null
Get-ChildItem $d -Recurse -File -Filter '*.deb' | ForEach-Object {
    Copy-Item $_.FullName 'C:\日常使用\vcam\packages\' -Force
    Write-Output "  ✅ $($_.Name)  ($([math]::Round($_.Length/1KB,1)) KB)"
}

Write-Output ""
Write-Output "=== 创建 Release v2.1.0-staged ==="
$notes = @'
# 虚拟摄像头 —— 阶梯测试包

**v2.0.0 装完重启后直接黑屏（看不到桌面）。已定位到 3 个高风险点并修掉了前两个。**

这一版给你 **3 个阶梯包**，从最安全到完整。请**按顺序**测试，每次只装一个。

---

## 测试顺序

### 第 1 步：装 stageA（最安全）

`com.quite85.virtualcamera_2.1.0_iphoneos-arm64-stageA.deb`

- **只注入 SpringBoard**，完全不参与相机
- 目的：验证「UI + 构造阶段」是否安全

| 结果 | 说明 | 下一步 |
| --- | --- | --- |
| **不黑屏** | UI 与构造阶段没问题 | 装 stageB |
| **黑屏** | 问题在 UI 或构造阶段 | 告诉我，我继续修这一层 |

### 第 2 步：装 stageB

`com.quite85.virtualcamera_2.2.0_iphoneos-arm64-stageB.deb`

- 注入 SpringBoard + 相机 + Safari
- 目的：验证「帧替换（相机 hook）」是否安全

| 结果 | 说明 |
| --- | --- |
| **不黑屏** | 帧替换没问题，黑屏另有原因 |
| **黑屏** | 黑屏来自帧替换，我去修那一层 |

### 第 3 步：装 stageC（完整）

`com.quite85.virtualcamera_2.3.0_iphoneos-arm64-stageC.deb`

- 完整 filter，22 个 Bundle
- 如果 stageA、stageB 都不黑屏而这个黑屏，说明问题在某个第三方 App 进程

---

## 装完怎么用

1. **重启手机**
2. **短按「音量减」** → 弹出悬浮小窗
3. 点「选择相册视频」→ 选一个视频
4. 打开相机 → 画面就是那个视频了

---

## v2.0.0 黑屏的原因

### 1. 致命：`makeKeyAndVisible`

```objc
gOverlayWindow.hidden = NO;
[gOverlayWindow makeKeyAndVisible];   // ← 抢走了 SpringBoard 的 key window
```

我们的透明悬浮窗成了 key window，SpringBoard 的窗口/场景系统被打乱，
表现为**桌面完全不出画面**。

改成只让它 visible，**绝不 makeKey**。
另外加了守卫：窗口没有 `windowScene` 时直接跳过 ——
在无 scene 的窗口上 present 弹窗是崩溃的常见来源。

### 2. 悬浮窗在 SpringBoard 未就绪时创建

原来在 `%ctor` 里延迟 1.5 秒就建 `UIWindow`，此时 `UIScene` 可能还没就绪。

现在改成：
- 构造阶段**只装音量监听**（很轻，不碰 UI）
- 窗口与按钮**推迟到用户第一次按音量减时才创建**（惰性）
- 改用 `initWithWindowScene:`，`windowLevel` 从 `Alert+100` 降到 `Alert+1`

### 3. 代理的无条件消息转发

`forwardingTargetForSelector:` 无条件转发，会把 AVFoundation 内部
对 delegate 的私有方法调用也转发走。
改为白名单：只转发 `AVCaptureVideoDataOutputSampleBufferDelegate`
协议里声明的方法。

---

## 安全开关

如果插件再次导致黑屏，可以这样彻底关掉它：

1. 进安全模式（强制重启时按音量加进入）
2. 用 Filza 新建一个**空文件**：`/var/mobile/Library/VirtualCamera/off`
3. 重启

插件检测到这个文件就完全不动手。

---

## 卸载

```
dpkg -r com.quite85.virtualcamera
killall -9 SpringBoard
```
'@
$body = @{
  tag_name = 'v2.1.0-staged'
  target_commitish = 'main'
  name = 'v2.1.0 阶梯测试包（修复黑屏）'
  body = $notes
  draft = $false
  prerelease = $true
} | ConvertTo-Json -Depth 3

try {
    $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/quite85/vcam/releases' -Method POST -Body $body -ContentType 'application/json; charset=utf-8' -Headers $hdr -TimeoutSec 60
    Write-Output "  OK: $($rel.html_url)"
    $relId = $rel.id
} catch {
    Write-Output "  已存在，改用现有: $($_.Exception.Message)"
    $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/quite85/vcam/releases/tags/v2.1.0-staged' -Headers $hdr -TimeoutSec 30
    $relId = $rel.id
}

Write-Output ""
Write-Output "=== 上传阶梯包 ==="
foreach ($deb in (Get-ChildItem 'C:\日常使用\vcam\packages\*.deb' -File | Where-Object { $_.Name -match '2\.[123]\.0' })) {
    try {
        $up = Invoke-RestMethod -Uri "https://uploads.github.com/repos/quite85/vcam/releases/$relId/assets?name=$($deb.Name)" `
            -Method POST -InFile $deb.FullName -ContentType 'application/vnd.debian.binary-package' -Headers $hdr -TimeoutSec 180
        Write-Output "  OK  $($deb.Name)  ($([math]::Round($deb.Length/1KB,1)) KB)"
    } catch { Write-Output "  FAIL $($deb.Name): $($_.Exception.Message)" }
}

Write-Output ""
$rel = Invoke-RestMethod -Uri "https://api.github.com/repos/quite85/vcam/releases/$relId" -Headers $hdr -TimeoutSec 30
Write-Output "=== 下载地址 ==="
$rel.assets | Sort-Object name | ForEach-Object { Write-Output ("   " + $_.name); Write-Output ("     " + $_.browser_download_url) }

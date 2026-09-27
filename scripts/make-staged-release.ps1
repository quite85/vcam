$token = [System.IO.File]::ReadAllText("$env:TEMP\ghtoken.txt")
$hdr = @{ 'User-Agent'='vcam-check'; 'Accept'='application/vnd.github+json'; 'Authorization'="Bearer $token" }

Write-Output "=== 创建 / 获取 Release v2.1.0-staged ==="
$notes = @'
# 虚拟摄像头 —— 阶梯测试包

**v2.0.0 装完重启后直接黑屏（看不到桌面）。已定位到 3 个高风险点并修掉了前两个。**

这里给你 3 个阶梯包，从最安全到完整。请按顺序测试，每次只装一个。

---

# 测试顺序

## 第 1 步：stageA（最安全）

com.quite85.virtualcamera_2.1.0_iphoneos-arm64-stageA.deb

只注入 SpringBoard，完全不参与相机。目的：验证 UI + 构造阶段是否安全。

- 不黑屏 -> UI 与构造阶段没问题，装 stageB
- 黑屏   -> 问题在 UI 或构造阶段，告诉我

## 第 2 步：stageB

com.quite85.virtualcamera_2.2.0_iphoneos-arm64-stageB.deb

注入 SpringBoard + 相机 + Safari。目的：验证帧替换（相机 hook）是否安全。

- 不黑屏 -> 帧替换没问题
- 黑屏   -> 黑屏来自帧替换

## 第 3 步：stageC（完整）

com.quite85.virtualcamera_2.3.0_iphoneos-arm64-stageC.deb

完整 filter，22 个 Bundle。

---

# 装完怎么用

1. 重启手机
2. 短按「音量减」-> 弹出悬浮小窗
3. 点「选择相册视频」-> 选一个视频
4. 打开相机 -> 画面就是那个视频了

---

# v2.0.0 黑屏的三个原因

## 1. 致命：makeKeyAndVisible

    gOverlayWindow.hidden = NO;
    [gOverlayWindow makeKeyAndVisible];   // 抢走了 SpringBoard 的 key window

透明悬浮窗成了 key window，SpringBoard 的窗口/场景系统被打乱，桌面完全不出画面。

改成只让它 visible，绝不 makeKey。
另加守卫：窗口没有 windowScene 时直接跳过 ——
在无 scene 的窗口上 present 弹窗是崩溃的常见来源。

## 2. 悬浮窗在 SpringBoard 未就绪时创建

原来在 %ctor 里延迟 1.5 秒就建 UIWindow，此时 UIScene 可能还没就绪。

现在：
- 构造阶段只装音量监听（很轻，不碰 UI）
- 窗口与按钮推迟到第一次按音量减时才创建（惰性）
- 改用 initWithWindowScene:，windowLevel 从 Alert+100 降到 Alert+1

## 3. 代理的无条件消息转发

forwardingTargetForSelector: 无条件转发，会把 AVFoundation 内部
对 delegate 的私有方法调用也转发走。
改为白名单：只转发 AVCaptureVideoDataOutputSampleBufferDelegate
协议里声明的方法。

---

# 安全开关

若插件再次导致黑屏，可以彻底关掉它：

1. 进安全模式
2. 用 Filza 新建一个空文件：/var/mobile/Library/VirtualCamera/off
3. 重启

插件检测到这个文件就完全不动手。

---

# 卸载

    dpkg -r com.quite85.virtualcamera
    killall -9 SpringBoard
'@

$relId = $null
$relUrl = ''
try {
    $body = @{
        tag_name = 'v2.1.0-staged'
        target_commitish = 'main'
        name = 'v2.1.0 阶梯测试包（修复黑屏）'
        body = $notes
        draft = $false
        prerelease = $true
    } | ConvertTo-Json -Depth 3
    $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/quite85/vcam/releases' -Method POST -Body $body -ContentType 'application/json; charset=utf-8' -Headers $hdr -TimeoutSec 60
    Write-Output "  创建成功: $($rel.html_url)"
    $relId = $rel.id
    $relUrl = $rel.html_url
} catch {
    Write-Output "  创建失败（可能已存在）: $($_.Exception.Message)"
    try {
        $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/quite85/vcam/releases/tags/v2.1.0-staged' -Headers $hdr -TimeoutSec 30
        $relId = $rel.id
        $relUrl = $rel.html_url
        Write-Output "  使用现有 Release: $relUrl"
    } catch { Write-Output "  也取不到: $($_.Exception.Message)" }
}

if (-not $relId) { Write-Output "无法取得 Release，退出"; exit 1 }

Write-Output ""
Write-Output "=== 上传阶梯包 ==="
$existing = @()
try { $existing = (Invoke-RestMethod -Uri "https://api.github.com/repos/quite85/vcam/releases/$relId/assets" -Headers $hdr -TimeoutSec 30).name } catch {}
foreach ($deb in (Get-ChildItem 'C:\日常使用\vcam\packages\*.deb' -File | Where-Object { $_.Name -match 'stage[ABC]' } | Sort-Object Name)) {
    if ($existing -contains $deb.Name) { Write-Output "  已存在，跳过 $($deb.Name)"; continue }
    try {
        $up = Invoke-RestMethod -Uri "https://uploads.github.com/repos/quite85/vcam/releases/$relId/assets?name=$($deb.Name)" `
            -Method POST -InFile $deb.FullName -ContentType 'application/vnd.debian.binary-package' -Headers $hdr -TimeoutSec 180
        Write-Output "  OK  $($deb.Name)"
    } catch { Write-Output "  FAIL $($deb.Name): $($_.Exception.Message)" }
}

Write-Output ""
Write-Output "=== 最终下载地址 ==="
$rel = Invoke-RestMethod -Uri "https://api.github.com/repos/quite85/vcam/releases/$relId" -Headers $hdr -TimeoutSec 30
$rel.assets | Sort-Object name | ForEach-Object { Write-Output ("   " + $_.browser_download_url) }
Write-Output ""
Write-Output "Release 页面: $relUrl"

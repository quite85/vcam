$token = [System.IO.File]::ReadAllText("$env:TEMP\ghtoken.txt")
$hdr = @{ 'User-Agent'='vcam-check'; 'Accept'='application/vnd.github+json'; 'Authorization'="Bearer $token" }
$deb = 'C:\日常使用\vcam\experiments\stage2\com.quite85.vcamstage2_2.0.0_iphoneos-arm64.deb'
$name = [System.IO.Path]::GetFileName($deb)

Write-Output "=== 上传 Stage2 ==="
try {
    $up = Invoke-RestMethod -Uri "https://uploads.github.com/repos/quite85/vcam/releases/397830037/assets?name=$name" `
        -Method POST -InFile $deb -ContentType 'application/vnd.debian.binary-package' -Headers $hdr -TimeoutSec 180
    Write-Output "  OK: $($up.browser_download_url)"
} catch {
    Write-Output "  FAIL: $($_.Exception.Message)"
}

# Release 说明（用单引号 here-string，避免 $ 与反引号被解释）
$body = @'
# VCam 测试包

## Stage2 — 最小可用版（先试这个）

下载：com.quite85.vcamstage2_2.0.0_iphoneos-arm64.deb

装完按一下音量键，看手机右上角有没有出现一个相机图标按钮。

- 点按钮 -> 选相册里的视频 -> 视频循环播放，作为虚拟相机画面
- 按钮可拖动，松手贴边

### 设计说明

基于两个开源 iOS 虚拟摄像头项目验证过的做法：
- lxxsoufahk/VCam
- MurkAskA01/ios-vcam

| 做法 | 原因 |
| --- | --- |
| filter 只列 3 个 Bundle | 开源项目的 filter 只注入 SpringBoard 一个进程。本工程之前列了 111 项 + 7 个系统守护进程，注入面过大 |
| 不注入 mediaserverd 等系统守护进程 | 它是 iOS 显示与媒体管线的上游，崩溃会导致整机黑屏 |
| 每个 install 都包 @try/@catch | 构造阶段抛异常会让宿主进程崩溃重启循环 |
| 每一步都 NSLog | 电脑上能实时看到走到哪一步 |

---

## Stage1 — 注入验证包（备用）

零 hook：不含任何 %hook，只写一行日志。用来验证注入是否生效。

---

## 卸载

dpkg -r com.quite85.vcamstage2
killall -9 SpringBoard
'@

Write-Output ""
Write-Output "=== 更新 Release 说明 ==="
try {
    $rb = @{ body = $body } | ConvertTo-Json -Depth 3
    Invoke-RestMethod -Uri 'https://api.github.com/repos/quite85/vcam/releases/397830037' -Method PATCH -Body $rb -ContentType 'application/json; charset=utf-8' -Headers $hdr -TimeoutSec 30 | Out-Null
    Write-Output "  OK"
} catch { Write-Output "  FAIL: $($_.Exception.Message)" }

Write-Output ""
$rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/quite85/vcam/releases/397830037' -Headers $hdr -TimeoutSec 30
Write-Output "=== Release 资产 ==="
$rel.assets | Sort-Object name | ForEach-Object { Write-Output ("   - " + $_.name + "  " + [math]::Round($_.size/1KB,1) + " KB") }

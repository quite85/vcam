# vcam-usbmux-proxy.ps1
#
# 把 Windows 本机 127.0.0.1:27015 上的 Apple usbmuxd 暴露成 0.0.0.0:27016，
# 让 WSL 里的 libimobiledevice（idevicesyslog 等）能连上 iPhone。
#
# ============================================================================
# 关键设计：**必须用阻塞读 + 客户端断开时关闭上游**。
#
# 前一版用"轮询 DataAvailable + sleep"，有两个致命缺陷：
#
#   1) **无法检测客户端断开**
#      .NET 的 TcpClient.Connected 只在发生过 I/O 错误后才变 false。
#      轮询 DataAvailable 时若客户端（idevicesyslog）被杀掉，
#      我们既不读也不写，Connected 一直是 true，于是循环永不退出，
#      **上游到设备 usbmuxd 的连接永远不关**。
#      而 iOS 的 syslog relay 通常只允许一个客户端 ——
#      于是后续所有 idevicesyslog 都拿到 0 字节，
#      表现为"日志通道时好时坏"，我不得不反复重启转发才能抓到一次日志。
#
#   2) 15ms 轮询在高流量下会丢数据
#
# 现在改成阻塞读：客户端方向的 Read 返回 0（EOF）即代表 idevicesyslog 退出，
# 此时立刻关闭两端连接，从而释放设备侧的 syslog relay。
# ============================================================================
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File vcam-usbmux-proxy.ps1
#   WSL 里：
#     export USBMUXD_SOCKET_ADDRESS=172.25.32.1:27016
#     idevicesyslog

param(
    [int]$ListenPort = 27016,
    [string]$TargetHost = '127.0.0.1',
    [int]$TargetPort = 27015
)

$ErrorActionPreference = 'Stop'

function Write-Log([string]$msg) {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $msg"
}

Write-Host "=== VCam usbmux 转发（阻塞读版）===" -ForegroundColor Cyan
Write-Host "  监听  : 0.0.0.0:$ListenPort"
Write-Host "  转发到: ${TargetHost}:${TargetPort}  (Apple usbmuxd)"
Write-Host ""

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $ListenPort)
$listener.Start()
Write-Host "已启动，等待 WSL 连接…（Ctrl+C 停止）" -ForegroundColor Green
Write-Host ""

# 每个连接的处理体：阻塞读 + 断开时关闭两端
$handlerSrc = @'
param($client, $targetHost, $targetPort, $connId)

function Log([string]$m) {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] [$connId] $m"
}

$upstream = $null
try {
    $upstream = New-Object System.Net.Sockets.TcpClient
    $upstream.Connect($targetHost, $targetPort)
} catch {
    Log "连不上 usbmuxd: $($_.Exception.Message)"
    try { $client.Close() } catch { }
    return
}

$cStream = $client.GetStream()
$uStream = $upstream.GetStream()
$cStream.ReadTimeout = -1
$uStream.ReadTimeout = -1

$buf = New-Object byte[] 65536
$up = 0

try {
    while ($true) {
        $n = $cStream.Read($buf, 0, $buf.Length)
        if ($n -le 0) { break }
        $uStream.Write($buf, 0, $n)
        $uStream.Flush()
        $up += $n
    }
} catch {
    # 客户端断开或读错误，正常收尾
}

# 关键：客户端一走就关闭上游，
# 否则设备侧的 syslog relay 会被这条连接一直占着，
# 后续 idevicesyslog 全部拿不到数据。
try { $client.Client.Shutdown([System.Net.Sockets.SocketShutdown]::Both) } catch { }
try { $upstream.Client.Shutdown([System.Net.Sockets.SocketShutdown]::Both) } catch { }
try { $cStream.Close() } catch { }
try { $uStream.Close() } catch { }
try { $client.Close() } catch { }
try { $upstream.Close() } catch { }

Log "结束  上行 $up 字节"
'@

$connId = 0
while ($true) {
    $client = $null
    try { $client = $listener.AcceptTcpClient() } catch { Start-Sleep -Milliseconds 100; continue }

    $connId++
    $remote = $client.Client.RemoteEndPoint
    Write-Log "#$connId 连接来自 $remote"

    $ps = [PowerShell]::Create()
    $null = $ps.AddScript($handlerSrc).
                AddArgument($client).
                AddArgument($TargetHost).
                AddArgument($TargetPort).
                AddArgument("#$connId")
    $null = $ps.BeginInvoke()
}

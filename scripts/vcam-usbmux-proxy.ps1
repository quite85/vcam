# vcam-usbmux-proxy.ps1
#
# 作用：把 Windows 本机 127.0.0.1:27015 上的 Apple usbmuxd
#       暴露成监听 0.0.0.0:27016 的 TCP 服务，让 WSL 能连进来。
#
# 为什么要这样：
#   · iPhone 连在 **Windows** 上，Apple Mobile Device Service
#     （Windows 版 usbmuxd）在 127.0.0.1:27015 提供服务。
#   · WSL 里的 libimobiledevice 看不到设备（设备被 Windows 占着，
#     usbipd 转发会报 Device busy）。
#   · libimobiledevice 支持 USBMUXD_SOCKET_ADDRESS=host:port 指向
#     一个 TCP 端点，所以只要能连通 usbmuxd 就行。
#   · usbmuxd 只监听 127.0.0.1，因此需要本转发。
#
# 关键设计：必须**并发**处理每个连接。
#   第一版是单连接串行（accept → 一直 pump 到该连接结束 → 再 accept），
#   结果 idevice_id 那条连接被 libimobiledevice 保持不断开，
#   后续所有请求都排在 backlog 里永远不被接受，
#   表现为"第一次成功、之后一直 No device found"。
#   现在每个连接交给独立 runspace 处理，主循环立刻回去 accept。
#
# 另一个坑：.NET 的 ReadTimeout 只接受 -1（Infinite）或 >0，
#   设 0 会抛异常并把进程搞崩。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File vcam-usbmux-proxy.ps1
#   WSL 里：
#     export USBMUXD_SOCKET_ADDRESS=172.25.32.1:27016
#     idevice_id -l

param(
    [int]$ListenPort = 27016,
    [string]$TargetHost = '127.0.0.1',
    [int]$TargetPort = 27015
)

$ErrorActionPreference = 'Stop'

function Write-Log([string]$msg) {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $msg"
}

Write-Host "=== VCam usbmux 转发（并发版）===" -ForegroundColor Cyan
Write-Host "  监听  : 0.0.0.0:$ListenPort"
Write-Host "  转发到: ${TargetHost}:${TargetPort}  (Apple usbmuxd)"
Write-Host ""

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $ListenPort)
$listener.Start()
Write-Host "已启动，等待 WSL 连接…（Ctrl+C 停止）" -ForegroundColor Green
Write-Host ""

# 连接处理体：在每个连接的独立 runspace 里执行
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
$down = 0

try {
    while ($true) {
        $did = $false

        if ($cStream.DataAvailable) {
            while ($cStream.DataAvailable) {
                $n = $cStream.Read($buf, 0, $buf.Length)
                if ($n -le 0) { throw "client closed" }
                $uStream.Write($buf, 0, $n)
                $uStream.Flush()
                $up += $n
            }
            $did = $true
        }

        if ($uStream.DataAvailable) {
            while ($uStream.DataAvailable) {
                $n = $uStream.Read($buf, 0, $buf.Length)
                if ($n -le 0) { throw "usbmuxd closed" }
                $cStream.Write($buf, 0, $n)
                $cStream.Flush()
                $down += $n
            }
            $did = $true
        }

        if (-not $client.Connected -or -not $upstream.Connected) { break }
        if (-not $did) { Start-Sleep -Milliseconds 5 }
    }
} catch {
    # 正常收尾（任一端关闭）或单连接错误，忽略
}

Log "结束  上行 $up 字节 / 下行 $down 字节"
try { $cStream.Close() } catch { }
try { $uStream.Close() } catch { }
try { $client.Close() } catch { }
try { $upstream.Close() } catch { }
'@

$connId = 0
while ($true) {
    $client = $null
    try { $client = $listener.AcceptTcpClient() } catch { Start-Sleep -Milliseconds 100; continue }

    $connId++
    $remote = $client.Client.RemoteEndPoint
    Write-Log "#$connId 连接来自 $remote"

    # 丢到独立 runspace 处理，主循环立刻回去 accept 下一个连接
    $ps = [PowerShell]::Create()
    $null = $ps.AddScript($handlerSrc).
                AddArgument($client).
                AddArgument($TargetHost).
                AddArgument($TargetPort).
                AddArgument("#$connId")
    $null = $ps.BeginInvoke()
}

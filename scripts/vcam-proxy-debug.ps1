# vcam-proxy-debug.ps1 —— 最小化 usbmux 转发，带详细日志
#
# 目的：定位为什么"本机直连 27015 正常，经转发 27016 无响应"。
# 与前一个版本的关键区别：**用 Start-ThreadJob 而不是 PowerShell runspace**。
#
# 之前用 [PowerShell]::Create().AddScript($handlerSrc).BeginInvoke()，
# 但 handler 里用 Write-Host 的日志一条都没输出（只看到 accept 的日志），
# 说明 handler 可能根本没跑起来（BeginInvoke 的 runspace 环境里
# $ErrorActionPreference='Stop' + 各种因素都可能让它静默失败）。
# 这里改用 Start-ThreadJob：它是官方支持的轻量并发方式，错误可见。

param(
    [int]$ListenPort = 27017,
    [string]$TargetHost = '127.0.0.1',
    [int]$TargetPort = 27015
)

$ErrorActionPreference = 'Continue'

function Log([string]$m) {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss.fff')] $m"
}

Log "=== usbmux 转发调试版 ==="
Log "  监听 0.0.0.0:$ListenPort -> ${TargetHost}:${TargetPort}"

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $ListenPort)
$listener.Start()
Log "listener 已启动"

$connId = 0
while ($true) {
    $client = $null
    try { $client = $listener.AcceptTcpClient() } catch { Start-Sleep -Milliseconds 200; continue }

    $connId++
    $id = $connId
    Log "#$id 接受连接，来自 $($client.Client.RemoteEndPoint)"

    # 用 Start-ThreadJob 起独立作业处理（每个连接一个）
    $null = Start-ThreadJob -ScriptBlock {
        param($client, $targetHost, $targetPort, $id)

        $tag = "#$id"
        function L([string]$m) { Write-Host "[$(Get-Date -Format 'HH:mm:ss.fff')] $tag $m" }

        $upstream = $null
        try {
            $upstream = New-Object System.Net.Sockets.TcpClient
            $upstream.Connect($targetHost, $targetPort)
            L "上游已连上 ${targetHost}:${targetPort}"
        } catch {
            L "上游连接失败: $($_.Exception.Message)"
            try { $client.Close() } catch { }
            return
        }

        $cStream = $client.GetStream()
        $uStream = $upstream.GetStream()
        $cStream.ReadTimeout = -1
        $uStream.ReadTimeout = -1

        # --- 两个方向：客户端->上游（本线程） ---
        $buf = New-Object byte[] 65536
        $up = 0
        $down = 0

        # 先起一个后台线程处理 上游->客户端
        $downJob = Start-ThreadJob -ScriptBlock {
            param($uStream, $cStream, $tag)
            function L2([string]$m) { Write-Host "[$(Get-Date -Format 'HH:mm:ss.fff')] $tag(down) $m" }
            $b = New-Object byte[] 65536
            $total = 0
            try {
                while ($true) {
                    $n = $uStream.Read($b, 0, $b.Length)
                    if ($n -le 0) { break }
                    $cStream.Write($b, 0, $n)
                    $cStream.Flush()
                    $total += $n
                    L2 "转发 $n 字节（累计 $total）"
                }
            } catch { L2 "结束: $($_.Exception.Message)" }
            L2 "总计 $total 字节"
        } -ArgumentList $uStream, $cStream, $tag

        try {
            while ($true) {
                $n = $cStream.Read($buf, 0, $buf.Length)
                if ($n -le 0) { L "客户端读结束(EOF)"; break }
                $uStream.Write($buf, 0, $n)
                $uStream.Flush()
                $up += $n
                L "上行 $n 字节（累计 $up）"
            }
        } catch { L "上行异常: $($_.Exception.Message)" }

        # 客户端走了：关闭两端，让 downJob 也结束
        try { $client.Close() } catch { }
        try { $upstream.Close() } catch { }
        L "连接结束（上行 $up 字节）"

    } -ArgumentList $client, $TargetHost, $TargetPort, $id | Out-Null
}

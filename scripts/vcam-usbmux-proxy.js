// vcam-usbmux-proxy.js
//
// 把 Windows 本机 127.0.0.1:27015 上的 Apple usbmuxd 暴露成 0.0.0.0:27016，
// 让 WSL 里的 libimobiledevice（idevicesyslog 等）能连上 iPhone。
//
// ============================================================================
// 为什么改用 Node 而不是 PowerShell
//
// 之前用 PowerShell 写了两版转发，都不稳定：
//
//   第 1 版：轮询 DataAvailable + sleep
//     · 无法检测客户端断开 —— .NET 的 TcpClient.Connected 只在发生过
//       I/O 错误后才变 false，轮询时不读不写它就永远是 true，
//       于是上游一直连着设备，把 iOS 的 syslog relay 占死
//       （relay 通常只允许一个客户端），后续抓取全部拿到 0 字节。
//     · 15ms 轮询在高流量下丢数据。
//
//   第 2 版：阻塞读 + 显式 Shutdown
//     · 反而更糟：对 Windows 上 Apple 的 usbmuxd 调用
//       Socket.Shutdown(Both) 之后，它进入不可用状态，
//       连 idevice_id 都报 "Unable to retrieve device list"。
//
//   第 3 版：[PowerShell]::Create().BeginInvoke() 起 runspace 处理连接
//     · handler 里一条日志都没输出，说明它根本没跑起来，
//       客户端连上但永远拿不到数据。
//
// Node 的 net 模块处理这类"双向管道 + 断开清理"是原生强项：
//   · 'close'/'error'/'end' 事件可靠，断开即清理，不会泄漏上游连接
//   · 用 pipe() 由内核转发，天然双向、无轮询、无丢数据
// ============================================================================
//
// 用法：
//   node vcam-usbmux-proxy.js
//   WSL 里：
//     export USBMUXD_SOCKET_ADDRESS=172.25.32.1:27016
//     idevicesyslog

const net = require('net');

const LISTEN_PORT = parseInt(process.env.VCAM_LISTEN_PORT || '27016', 10);
const TARGET_HOST = process.env.VCAM_TARGET_HOST || '127.0.0.1';
const TARGET_PORT = parseInt(process.env.VCAM_TARGET_PORT || '27015', 10);

function ts() {
  const d = new Date();
  const p = (n, w = 2) => String(n).padStart(w, '0');
  return `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}.${p(d.getMilliseconds(), 3)}`;
}

function log(msg) {
  console.log(`[${ts()}] ${msg}`);
}

let connId = 0;

const server = net.createServer((client) => {
  const id = ++connId;
  const tag = `#${id}`;
  log(`${tag} 连接来自 ${client.remoteAddress}:${client.remotePort}`);

  let up = 0;
  let down = 0;
  let closed = false;

  const upstream = net.connect({ host: TARGET_HOST, port: TARGET_PORT });

  // 任一端出错或关闭，就把两端都关掉 —— 这是不泄漏上游连接的关键
  const shutdown = (why) => {
    if (closed) return;
    closed = true;
    log(`${tag} 结束（${why}）上行 ${up} 字节 / 下行 ${down} 字节`);
    try { client.destroy(); } catch (_) {}
    try { upstream.destroy(); } catch (_) {}
  };

  client.on('error', (e) => shutdown(`客户端错误 ${e.code || e.message}`));
  upstream.on('error', (e) => shutdown(`上游错误 ${e.code || e.message}`));
  client.on('close', () => shutdown('客户端关闭'));
  upstream.on('close', () => shutdown('上游关闭'));

  upstream.on('connect', () => {
    log(`${tag} 上游已连上 ${TARGET_HOST}:${TARGET_PORT}`);

    // 双向管道：内核级转发，无轮询
    client.on('data', (d) => { up += d.length; });
    upstream.on('data', (d) => { down += d.length; });

    client.pipe(upstream);
    upstream.pipe(client);

    // 半关闭透传：一端 EOF 时把另一端也结束写，让对端有机会回完剩余数据
    client.on('end', () => { try { upstream.end(); } catch (_) {} });
    upstream.on('end', () => { try { client.end(); } catch (_) {} });
  });
});

server.on('error', (e) => {
  console.error(`[${ts()}] 监听失败: ${e.code || e.message}`);
  process.exit(1);
});

server.listen(LISTEN_PORT, '0.0.0.0', () => {
  console.log('=== VCam usbmux 转发（Node）===');
  console.log(`  监听  : 0.0.0.0:${LISTEN_PORT}`);
  console.log(`  转发到: ${TARGET_HOST}:${TARGET_PORT}  (Apple usbmuxd)`);
  console.log('');
  console.log('已启动，等待 WSL 连接…（Ctrl+C 停止）');
  console.log('');
});

process.on('SIGINT', () => {
  log('收到中断，退出');
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 500);
});

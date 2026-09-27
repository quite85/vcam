# 实时日志抓取（iPhone → WSL）

> **目的**：装上插件后如果黑屏/崩溃，能立即看到现场日志，而不是靠猜。
> 这是定位 VCam 黑屏问题最关键的工具。

---

## 为什么需要它

VCam 在用户设备上**四次黑屏**，但我一次都没拿到崩溃日志 ——
所有排查都只能靠推测，这是找不到 bug 的根本原因。

这个工具把 iPhone 的系统日志**实时**流到电脑上。
**即使手机黑屏，日志照样在传** —— 因为日志走 USB，不依赖屏幕。

---

## 架构

```
iPhone
  │ USB 数据线
  ▼
Windows: Apple Mobile Device Service（Windows 版 usbmuxd）
  │ 127.0.0.1:27015
  ▼
vcam-usbmux-proxy.ps1（本机 TCP 转发，监听 0.0.0.0:27016）
  │ TCP 172.25.32.1:27016
  ▼
WSL Ubuntu: libimobiledevice（idevicesyslog / ideviceinfo / idevicepair）
```

### 为什么不直接把 USB 转发进 WSL

试过 `usbipd attach --wsl`，失败：

```
WSL usbip: error: Attach Request for 1-1 failed - Device busy (exported)
usbipd: warning: The device appears to be used by Windows; stop the software
         using the device, or bind the device using the '--force' option.
```

设备被 Apple 服务占着，而 usbipd 5.3.0 的 `attach` 已经没有 `--force`
（只有 `bind` 有，且是授权用途）。

**更好的思路：不搬 USB，而是让 WSL 复用 Windows 上已经跑着的 usbmuxd。**
libimobiledevice 支持用 `USBMUXD_SOCKET_ADDRESS=host:port` 指向一个
TCP 端点，所以只需要让 WSL 能连通 usbmuxd 即可。
唯一障碍是 usbmuxd 只监听 `127.0.0.1`，于是加一层转发。

---

## 一次性搭建（已完成，此处仅作记录）

### 1. Windows 侧

```powershell
# 安装 usbipd 只为了拿不到（当时的目标），实际不需要了；
# 真正需要的是：Apple Mobile Device Support（已随 Apple 支持软件安装）
winget install --id dorssel.usbipd-win    # 可选，本项目最终没用到

# 防火墙放行转发端口（需管理员）
New-NetFirewallRule -DisplayName "VCam usbmux proxy 27016" `
  -Direction Inbound -Protocol TCP -LocalPort 27016 -Action Allow -Profile Any

# 启动转发
powershell -NoProfile -ExecutionPolicy Bypass `
  -File scripts\vcam-usbmux-proxy.ps1
```

### 2. WSL 侧

```bash
apt-get install -y libimobiledevice-utils
```

### 3. 复制配对记录（关键！）

`idevice_id -l` 不需要配对就能列出设备，但 `idevicesyslog` / `ideviceinfo`
需要**配对信任**。Windows 上早已配对过，把记录复制给 WSL 即可：

```bash
# 在 Windows 上把 C:\ProgramData\Apple\Lockdown\*.plist
# 复制到 WSL 的 /var/lib/lockdown/
```

复制后 `idevicepair validate` 就会返回成功。

---

## 日常使用

### 前提检查

```bash
# Windows 侧转发要在跑
Get-NetTCPConnection -LocalPort 27016 -State Listen

# WSL 侧验证
export USBMUXD_SOCKET_ADDRESS=172.25.32.1:27016
idevice_id -l                # 应输出设备 UDID
idevicepair validate         # 应输出 SUCCESS
```

### 抓日志

```bash
# 全部日志（最详细，但量很大）
bash scripts/vcam-monitor.sh

# 只看崩溃/异常/看门狗/substrate —— **排黑屏问题用这个**
bash scripts/vcam-monitor.sh crash

# 只看我们插件的日志
bash scripts/vcam-monitor.sh vcam
```

日志同时写入 `/root/vcam-logs/<时间戳>-<模式>.log`，方便事后回看。

### 设备信息

```bash
ideviceinfo | grep -iE 'ProductType|ProductVersion|BuildVersion|DeviceName'
```

---

## 踩过的坑（都已在脚本里修好）

| # | 现象 | 原因 | 修法 |
|---|---|---|---|
| 1 | `ReadTimeout = 0` 抛异常、转发进程崩 | .NET 只接受 -1（Infinite）或 >0 | 改成 -1 |
| 2 | **第一次能列设备，之后一直 `No device found`** | 转发是**单连接串行**：`idevice_id` 的连接被库保持不断开，后续请求全排在 backlog 里 | 每个连接交给独立 runspace 并发处理 |
| 3 | 脚本报"字符串缺少终止符" | PowerShell 5.1 无 BOM 时按 ANSI 读 .ps1，中文注释乱码 | 保存为**带 BOM 的 UTF-8** |
| 4 | WSL 连不上 27016 | Windows 防火墙挡入站 | 加放行规则 |
| 5 | `ldid: command not found`（本地构建） | Ubuntu 源没有 ldid | 用包装脚本代替（越狱不校验签名） |
| 6 | 转发进程随终端退出 | 后台 Job 不跨会话保留 | 用 `Start-Process` 起独立进程 |

---

## 已知限制

- **必须 USB 连电脑**。手机上 OpenSSH 的替代方案（直接 SSH 看日志）需要先能 SSH。
- 手机锁屏时部分日志会被 `<private>` 屏蔽，这是 iOS 的隐私保护。
- `idevicesyslog` 需要设备已解锁并信任过电脑。

---

## 崩溃日志的另一种取法

如果日志来不及看，可以直接导出完整 logarchive：

```bash
export USBMUXD_SOCKET_ADDRESS=172.25.32.1:27016
idevicesyslog archive /root/vcam-logs/archive
```

（会在手机上打包完整系统日志，可能需要较长时间）

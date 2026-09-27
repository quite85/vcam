#!/usr/bin/env bash
# 持续监控 iPhone 日志，只保留**崩溃与生命周期事件**。
#
# 三轮迭代的原因（记录教训）：
#   第 1 版：全量落盘            → 9.5 MB/分钟，噪声淹没一切
#   第 2 版：加包含规则          → backboardd(CoreBrightness) 背光调试刷屏
#   第 3 版：加排除规则          → backboardd(ColourSensor) / HID 事件刷屏
#   第 4 版（本版）：**不再按进程名匹配**，只按"事件关键词"匹配。
#       因为按进程名匹配必然把该进程的所有调试日志一起捞进来，
#       而我们要的是"这个进程崩了/被杀了/重启了"这类事件。
set -u
export USBMUXD_SOCKET_ADDRESS=172.25.32.1:27016

OUT=/root/vcam-logs/live-key.log
mkdir -p /root/vcam-logs

{
    echo "=== 监控开始 $(date '+%F %T') ==="
    echo "=== 设备: $(idevice_id -l 2>/dev/null | head -1) ==="
} > "$OUT"

# ---- 只保留这些"事件"关键词 ----
PAT='VCam|vcam|VirtualCamera|virtualcamera|虚拟摄像头|VCamPing|vcamping'
PAT+='|crash|Crash|CRASH|panic|Panic'
PAT+='|EXC_BAD|EXC_CRASH|EXC_GUARD|EXC_BREAKPOINT|EXC_RESOURCE'
PAT+='|SIGSEGV|SIGABRT|SIGBUS|SIGKILL|SIGTRAP|SIGILL'
PAT+='|watchdog|Watchdog|jetsam|Jetsam|memorystatus'
PAT+='|has died|exited abnormally|terminating|Terminating|killed by|Killed by'
PAT+='|substrate|Substrate|ElleKit|ellekit|MobileLoader|mobileloader'
PAT+='|dyld|Library not loaded|Symbol not found|image not found'
PAT+='|assertion failed|Assertion failed|fatal error|Fatal error'
PAT+='|deny file|Sandbox.*deny|deny\(1\)'
PAT+='|Failed to launch|failed to launch|launch failed|unable to launch'
PAT+='|inject|Inject|loading dylib|Loading dylib'

# ---- 排除：即使命中上面的词但属于噪声的 ----
EX='CoreBrightness|ColourSensor|xpc_|nits|SLBI|backlight|Backlight'
EX+='|Accelerometer|HIDEvent|Motion event|usagePage'
EX+='|Ping timer|resetting watchdog'
EX+='|JetSamPolicy|JetsamPolicy|jetsam.*limit'

exec idevicesyslog --no-colors 2>&1 \
  | grep --line-buffered -E "$PAT" \
  | grep --line-buffered -E -v "$EX" \
  | tee -a "$OUT"

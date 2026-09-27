#!/usr/bin/env bash
# ============================================================================
#  vcam-monitor.sh —— 实时抓取 iPhone 系统日志，重点标记崩溃与关键进程
#
#  用途：VCam 装上后如果黑屏/崩溃，用这个脚本抓现场。
#
#  用法（WSL 里）：
#      bash /root/vcam-monitor.sh              # 全部日志 + 高亮
#      bash /root/vcam-monitor.sh crash        # 只看崩溃/异常相关
#      bash /root/vcam-monitor.sh vcam         # 只看我们插件的日志
#
#  输出同时写入 /root/vcam-logs/<时间戳>.log，方便事后回看。
#
#  前置条件：
#    · Windows 侧 usbmux 转发在跑（vcam-usbmux-proxy.ps1）
#    · 已配对（配对记录从 Windows 复制到 /var/lib/lockdown）
# ============================================================================
set -u

export USBMUXD_SOCKET_ADDRESS="${USBMUXD_SOCKET_ADDRESS:-172.25.32.1:27016}"
MODE="${1:-all}"

LOGDIR=/root/vcam-logs
mkdir -p "$LOGDIR"
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$LOGDIR/$STAMP-$MODE.log"

echo "==============================================================="
echo " VCam 日志监控   模式=$MODE"
echo " 输出文件: $OUT"
echo " 停止: Ctrl+C"
echo "==============================================================="
echo ""

# 检查设备
if ! timeout 8 idevice_id -l >/dev/null 2>&1; then
    echo "❌ 看不到设备。请确认："
    echo "   1) iPhone 用数据线连着 Windows，且已「信任此电脑」"
    echo "   2) Windows 侧转发在跑（vcam-usbmux-proxy.ps1）"
    echo "   3) 局域网可达 $USBMUXD_SOCKET_ADDRESS"
    exit 1
fi
echo "✅ 设备已连接，开始抓取…"
echo ""

case "$MODE" in
    crash)
        # 只看崩溃、异常、看门狗、重启相关
        PATTERN='crash|Crash|panic|Panic|EXC_|signal|SIGSEGV|SIGABRT|SIGBUS|'
        PATTERN+='watchdog|Watchdog|jetsam|Jetsam|memorystatus|'
        PATTERN+='terminating|Terminating|killed|Killed|'
        PATTERN+='failed to launch|Failed to launch|'
        PATTERN+='BUG|assertion|Assertion|'
        PATTERN+='substrate|Substrate|ElleKit|ellekit|MobileSubstrate|'
        PATTERN+='dyld|Dyld|Library not loaded|Symbol not found'
        ;;
    vcam)
        PATTERN='VCam|vcam|VirtualCamera|虚拟摄像头'
        ;;
    *)
        PATTERN='.'
        ;;
esac

# 用 grep --line-buffered 保证实时输出（不加的话会攒一大块才显示）
timeout 0 idevicesyslog --no-colors 2>&1 \
  | grep --line-buffered -E "$PATTERN" \
  | tee -a "$OUT"

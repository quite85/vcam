#!/usr/bin/env bash
# 综合诊断：确认插件的注入是否真的发生
set -u
export USBMUXD_SOCKET_ADDRESS=172.25.32.1:27016
LOGDIR=/root/vcam-logs

echo "==============================================================="
echo " 1) 设备信息"
echo "==============================================================="
timeout 20 ideviceinfo 2>/dev/null | grep -iE 'ProductType|ProductVersion|BuildVersion|DeviceName' | sed 's/^/  /'

echo ""
echo "==============================================================="
echo " 2) 已安装的插件包（含 vcam / substrate / ellekit）"
echo "==============================================================="
timeout 30 ideviceinfo -q com.apple.mobile.installation_proxy 2>/dev/null | head -5 | sed 's/^/  /' || true
echo "  （lockdown 不提供插件包列表，改用崩溃报告时间判断）"

echo ""
echo "==============================================================="
echo " 3) 崩溃报告里最近的时间戳（判断今天有没有新崩溃）"
echo "==============================================================="
find "$LOGDIR/crashreports" -maxdepth 1 -type f -name '*.ips' -printf '%TY-%Tm-%Td %p\n' 2>/dev/null \
  | sort -r | head -12 | sed 's/^/  /'
echo ""
TODAY=$(date +%Y-%m-%d)
N=$(find "$LOGDIR/crashreports" -maxdepth 1 -type f -name "*${TODAY}*" 2>/dev/null | wc -l)
echo "  今天（$TODAY）的崩溃报告数: $N"

echo ""
echo "==============================================================="
echo " 4) 实时抓 15 秒，找任何 tweak 注入痕迹"
echo "==============================================================="
echo "  正在监听（请现在打开「设置」App）…"
timeout 15 idevicesyslog --no-colors 2>/dev/null \
  | grep -iE 'substrate|ellekit|mobileloader|tweakinject|dynamiclibraries|VirtualCamera|VCamStage1|dylib' \
  | head -25 | cut -c1-175 | sed 's/^/  /'
echo "  （空 = 15 秒内没有任何注入痕迹）"

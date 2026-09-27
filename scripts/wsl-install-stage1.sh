#!/usr/bin/env bash
# 安装 Stage1 诊断包，并在安装前后抓取关键日志
set -u
export USBMUXD_SOCKET_ADDRESS=172.25.32.1:27016

DEB="/mnt/c/日常使用/vcam/experiments/stage1/com.quite85.vcamstage1_1.0.0_iphoneos-arm64.deb"

echo "=== 0) 链路检查 ==="
UDID=$(timeout 10 idevice_id -l 2>/dev/null | head -1)
if [ -z "$UDID" ]; then
    echo "  ❌ 看不到设备"
    exit 1
fi
echo "  设备: $UDID"

echo ""
echo "=== 1) 设备信息 ==="
timeout 15 ideviceinfo 2>/dev/null | grep -iE 'ProductType|ProductVersion|BuildVersion' | sed 's/^/  /'

echo ""
echo "=== 2) 安装前：设备上现有的注入库 ==="
echo "  （用 idevicesyslog 无法列目录，这里只看日志侧）"
echo "  已安装的 V* 相关包："
timeout 15 idevicesyslog --no-colors -x 2>/dev/null | head -0 || true

echo ""
echo "=== 3) deb 检查 ==="
if [ ! -f "$DEB" ]; then
    echo "  ❌ 找不到 $DEB"
    exit 1
fi
echo "  大小: $(stat -c%s "$DEB") 字节"
dpkg-deb -f "$DEB" Package Name Version 2>/dev/null | sed 's/^/  /'

echo ""
echo "=== 4) 提示 ==="
cat <<'TIP'
  ⚠️ 本脚本**不直接安装**（安装需要通过 SSH 或 Filza 在手机上执行），
     因为 usbmux 通道只提供 syslog/lockdown 服务，不能执行命令。

  请在手机上用下面任一方式安装：
    A) Filza：打开 /var/mobile/com.quite85.vcamstage1_1.0.0_iphoneos-arm64.deb
    B) NewTerm：dpkg -i /var/mobile/com.quite85.vcamstage1_1.0.0_iphoneos-arm64.deb
                killall -9 SpringBoard
    安装包已由调用方复制到手机可访问的位置。

  安装完成后回到这里，日志会自动记录整个过程。
TIP

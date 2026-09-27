#!/usr/bin/env bash
# 检查生成的 deb 包内容（在 WSL 里跑，用 dpkg-deb）
DEBDIR="/mnt/c/Users/27992/AppData/Local/Temp/vcam-debs"

echo "=== deb 目录 ==="
ls -la "$DEBDIR" 2>/dev/null | sed 's/^/  /'

ROOTLESS="$DEBDIR/com.quite85.virtualcamera_1.0.0_iphoneos-arm64-rootless.deb"
ROOTFUL="$DEBDIR/com.quite85.virtualcamera_1.0.0_iphoneos-arm64-rootful.deb"

for d in "$ROOTLESS" "$ROOTFUL"; do
    echo ""
    echo "=============================================="
    echo " $(basename "$d")"
    echo "=============================================="
    if [ ! -f "$d" ]; then echo "  文件不存在"; continue; fi
    echo "--- control ---"
    dpkg-deb -f "$d" Package Name Version Architecture Depends 2>&1 | sed 's/^/  /'
    echo ""
    echo "--- 安装的文件（路径是否符合 rootless/rootful 规范）---"
    dpkg-deb -c "$d" 2>&1 | awk '{print "  " $1, $6, $7}' | sed 's|\./||'
done

echo ""
echo "=== 关键检查 ==="
for d in "$ROOTLESS" "$ROOTFUL"; do
    n=$(basename "$d")
    if dpkg-deb -c "$d" 2>/dev/null | grep -q 'MobileSubstrate/DynamicLibraries/VCam\.dylib'; then
        echo "  ✅ $n 含 VCam.dylib"
    else
        echo "  ❌ $n 缺 VCam.dylib"
    fi
    if dpkg-deb -c "$d" 2>/dev/null | grep -q 'VCam-mediaserverd\.plist'; then
        echo "  ✅ $n 含 VCam-mediaserverd.plist（系统级 filter）"
    else
        echo "  ❌ $n 缺 VCam-mediaserverd.plist"
    fi
    if echo "$n" | grep -q rootless; then
        dpkg-deb -c "$d" 2>/dev/null | grep -q '/var/jb/' \
            && echo "  ✅ $n 路径含 /var/jb（rootless 规范）" \
            || echo "  ❌ $n 路径不含 /var/jb"
    fi
done

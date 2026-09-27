#!/usr/bin/env bash
# 校验 v1.0.1 的「安全版」与「系统注入版」deb 内容差异
D=/mnt/c/Users/27992/AppData/Local/Temp/v101
cd "$D" || exit 1

echo "=== 目录内容 ==="
ls -1 *.deb | sed 's/^/  /'
echo ""

for f in *.deb; do
    echo "=============================================================="
    echo " $f"
    echo "=============================================================="

    echo "  [control 摘要]"
    dpkg-deb -f "$f" Package Name Version Architecture 2>/dev/null | sed 's/^/    /'

    T=$(mktemp -d)
    dpkg-deb -x "$f" "$T" 2>/dev/null

    P=$(find "$T" -name 'VCam-mediaserverd.plist' 2>/dev/null | head -1)
    echo "  [VCam-mediaserverd.plist 的 Executables]"
    if [ -n "$P" ]; then
        sed -n '/Executables/,/)/p' "$P" | sed 's/^/    /'
    else
        echo "    (缺此文件)"
    fi

    echo "  [安装的文件清单]"
    dpkg-deb -c "$f" 2>/dev/null | awk '{print $6}' | grep -v '/$' | sed 's/^/    /'

    rm -rf "$T"
    echo ""
done

echo "=============================================================="
echo " 结论检查"
echo "=============================================================="
for f in *rootless*.deb; do
    T=$(mktemp -d); dpkg-deb -x "$f" "$T" 2>/dev/null
    P=$(find "$T" -name 'VCam-mediaserverd.plist' 2>/dev/null | head -1)
    if [ -n "$P" ]; then
        if grep -q 'mediaserverd' "$P"; then
            echo "  ⚠️  $f  →  filter 指向 mediaserverd（系统注入）"
        elif grep -q '__layout' "$P"; then
            echo "  ✅ $f  →  空 filter（安全版，不注入系统守护进程）"
        else
            echo "  ?  $f  →  filter 内容无法判定"
        fi
    else
        echo "  ❌ $f  →  没有 filter 文件"
    fi
    rm -rf "$T"
done

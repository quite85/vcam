#!/usr/bin/env bash
# 检查 VCam 本地编译环境就绪状态
echo "=== 关键工具 ==="
for c in git make clang ldid dpkg-deb perl curl tar xz; do
    p="$(command -v "$c" 2>/dev/null || true)"
    if [ -n "$p" ]; then printf '  OK   %-9s %s\n' "$c" "$p"
    else printf '  MISS %-9s\n' "$c"; fi
done

echo ""
echo "=== Theos ==="
if [ -d "$HOME/theos/makefiles" ]; then
    echo "  Theos 已存在: $HOME/theos"
    ls "$HOME/theos" | head -8 | sed 's/^/    /'
else
    echo "  Theos 不存在"
fi

echo ""
echo "=== iOS SDK ==="
if [ -d "$HOME/theos/sdks" ]; then
    ls "$HOME/theos/sdks" | sed 's/^/    /'
else
    echo "  sdks 目录不存在"
fi

echo ""
echo "=== 残留日志 ==="
ls -la /tmp/apt-update.log /tmp/apt-install.log /tmp/theos-clone.log /root/setup.log 2>/dev/null | sed 's/^/  /'

echo ""
echo "=== apt-install 末尾 ==="
tail -6 /tmp/apt-install.log 2>/dev/null | sed 's/^/  /'

echo ""
echo "=== update 末尾 ==="
tail -3 /tmp/apt-update.log 2>/dev/null | sed 's/^/  /'

echo ""
echo "=== 磁盘 ==="
df -h / | tail -1 | sed 's/^/  /'

#!/usr/bin/env bash
# VCam 本地编译环境搭建（在 WSL Ubuntu 里运行）
set -uo pipefail

echo "=============================================="
echo " 1/4 安装 apt 依赖"
echo "=============================================="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/tmp/apt-update.log 2>&1
apt-get install -y -qq \
    git make clang lld ldid fakeroot dpkg-dev \
    curl wget xz-utils bzip2 ca-certificates \
    libssl-dev libxml2-dev libz3-dev pkg-config zlib1g-dev \
    build-essential rsync unzip zip perl \
    >/tmp/apt-install.log 2>&1
APT_RC=$?
echo "apt 退出码: $APT_RC"
if [ $APT_RC -ne 0 ]; then
    echo "--- apt 日志末尾 ---"
    tail -25 /tmp/apt-install.log
fi

echo ""
echo "--- 关键工具是否就位 ---"
for c in git make clang ldid dpkg-deb perl; do
    p="$(command -v "$c" 2>/dev/null || true)"
    if [ -n "$p" ]; then printf '  %-10s %s\n' "$c" "$p"
    else printf '  %-10s ❌ 未装\n' "$c"; fi
done

echo ""
echo "=============================================="
echo " 2/4 安装 Theos"
echo "=============================================="
export THEOS="$HOME/theos"
if [ ! -d "$THEOS/makefiles" ]; then
    rm -rf "$THEOS"
    git clone --recursive --depth 1 https://github.com/theos/theos.git "$THEOS" >/tmp/theos-clone.log 2>&1
    echo "git clone 退出码: $?"
else
    echo "Theos 已存在，跳过 clone"
fi
ls "$THEOS" | head -10

echo ""
echo "=============================================="
echo " 3/4 安装 iOS SDK 到 \$THEOS/sdks"
echo "=============================================="
mkdir -p "$THEOS/sdks"
SDK_NAME="iPhoneOS16.5.sdk"
if [ ! -d "$THEOS/sdks/$SDK_NAME" ]; then
    URL="https://github.com/theos/sdks/releases/download/master-146e41f/${SDK_NAME}.tar.xz"
    echo "下载 $URL"
    curl -fL --retry 3 -o "/tmp/${SDK_NAME}.tar.xz" "$URL" >/tmp/sdk-dl.log 2>&1
    echo "curl 退出码: $?"
    tar -xJf "/tmp/${SDK_NAME}.tar.xz" -C "$THEOS/sdks"
    echo "解压退出码: $?"
fi
if [ -d "$THEOS/sdks/$SDK_NAME" ]; then
    echo "✅ SDK 就位: $THEOS/sdks/$SDK_NAME"
else
    echo "❌ SDK 缺失"; ls -la "$THEOS/sdks"
fi

echo ""
echo "=============================================="
echo " 4/4 环境信息"
echo "=============================================="
echo "THEOS=$THEOS"
echo "clang: $(clang --version | head -1)"
echo "make : $(make --version | head -1)"
echo "ldid : $(ldid -v 2>&1 | head -1)"
echo ""
echo "=== 搭建脚本结束 ==="

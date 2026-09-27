#!/usr/bin/env bash
# 第 1 步（修正版）：装 apt 依赖，不包含 Ubuntu 源里没有的 ldid
export DEBIAN_FRONTEND=noninteractive
echo "--- apt-get install ---"
apt-get install -y \
    git make clang lld fakeroot dpkg-dev \
    curl wget xz-utils bzip2 ca-certificates \
    libssl-dev libxml2-dev libz3-dev pkg-config zlib1g-dev \
    build-essential rsync unzip zip perl 2>&1 | tail -8
echo "apt 退出码: ${PIPESTATUS[0]}"

echo ""
echo "--- 工具检查 ---"
for c in git make clang lld dpkg-deb perl curl; do
    p="$(command -v "$c" 2>/dev/null || true)"
    if [ -n "$p" ]; then printf '  OK   %-9s %s\n' "$c" "$p"
    else printf '  MISS %-9s\n' "$c"; fi
done

echo ""
echo "--- clang 版本 ---"
clang --version 2>/dev/null | head -2 || echo "  clang 不可用"

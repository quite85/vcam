#!/usr/bin/env bash
# 第 1 步：只装 apt 依赖（幂等，可重复执行）
export DEBIAN_FRONTEND=noninteractive
echo "--- apt-get update ---"
apt-get update -qq 2>&1 | tail -3
echo "退出码: $?"

echo ""
echo "--- apt-get install（这一步最慢）---"
apt-get install -y -qq \
    git make clang lld ldid fakeroot dpkg-dev \
    curl wget xz-utils bzip2 ca-certificates \
    libssl-dev libxml2-dev libz3-dev pkg-config zlib1g-dev \
    build-essential rsync unzip zip perl 2>&1 | tail -15
RC=$?
echo "apt install 退出码: $RC"

echo ""
echo "--- 工具检查 ---"
for c in git make clang ldid dpkg-deb; do
    p="$(command -v "$c" 2>/dev/null || true)"
    if [ -n "$p" ]; then printf '  OK   %-9s %s\n' "$c" "$p"
    else printf '  MISS %-9s\n' "$c"; fi
done

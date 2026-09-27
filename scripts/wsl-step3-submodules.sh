#!/usr/bin/env bash
# 补拉 Theos 的 submodule（vendor/dm.pl、vendor/logos、vendor/include 等）
set -uo pipefail
export THEOS="$HOME/theos"
cd "$THEOS" || exit 1

echo "=== .gitmodules ==="
cat .gitmodules 2>/dev/null | head -30

echo ""
echo "=== 当前 vendor 内容 ==="
ls -la vendor 2>/dev/null | head

echo ""
echo "=== 初始化 submodule ==="
git submodule update --init --recursive 2>&1 | tail -25
echo "退出码: $?"

echo ""
echo "=== 结果 ==="
ls vendor 2>/dev/null | sed 's/^/  /'
echo ""
echo "--- 关键文件 ---"
for f in vendor/dm.pl/dm.pl vendor/logos/bin/logos.pl vendor/include/substrate.h; do
    if [ -e "$THEOS/$f" ]; then printf '  OK   %s\n' "$f"
    else printf '  MISS %s\n' "$f"; fi
done

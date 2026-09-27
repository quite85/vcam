#!/usr/bin/env bash
# 分小步补 Theos submodule —— 每步只处理一个，避免超时
set -uo pipefail
export THEOS="$HOME/theos"
cd "$THEOS" || exit 1

STEP="${1:-list}"

case "$STEP" in
  list)
    echo "=== .gitmodules 里声明的 submodule ==="
    grep -E '^\s*(path|url)' .gitmodules 2>/dev/null | sed 's/^/  /'
    echo ""
    echo "=== 当前状态 ==="
    git submodule status 2>&1 | head -20
    ;;

  dm)
    echo ">>> 拉 dm.pl（打包脚本，必需）"
    timeout 100 git submodule update --init --depth 1 vendor/dm.pl 2>&1 | tail -5
    echo "RC=$?"
    ls -la vendor/dm.pl/ 2>/dev/null | head
    ;;

  logos)
    echo ">>> 拉 logos（预处理器，必需）"
    timeout 100 git submodule update --init --depth 1 vendor/logos 2>&1 | tail -5
    echo "RC=$?"
    ls vendor/logos/bin/ 2>/dev/null | head
    ;;

  headers)
    echo ">>> 拉 include（私有头文件）"
    timeout 150 git submodule update --init --depth 1 vendor/include 2>&1 | tail -5
    echo "RC=$?"
    ls vendor/include/ 2>/dev/null | head
    ;;

  lib)
    echo ">>> 拉 lib（CydiaSubstrate 等）"
    timeout 150 git submodule update --init --depth 1 vendor/lib 2>&1 | tail -5
    echo "RC=$?"
    ls vendor/lib/ 2>/dev/null | head
    ;;

  rest)
    echo ">>> 拉其余 submodule"
    timeout 200 git submodule update --init --depth 1 vendor/nic vendor/templates 2>&1 | tail -5
    echo "RC=$?"
    ;;

  verify)
    echo "=== 验证关键文件 ==="
    for f in vendor/dm.pl/dm.pl vendor/logos/bin/logos.pl vendor/include/substrate.h vendor/lib; do
      if [ -e "$THEOS/$f" ]; then printf '  OK   %s\n' "$f"
      else printf '  MISS %s\n' "$f"; fi
    done
    echo ""
    echo "=== libtool（静态归档需要）==="
    command -v libtool || command -v glibtool || echo "  未找到 libtool"
    ;;

  *) echo "用法: $0 {list|dm|logos|headers|lib|rest|verify}"; exit 1 ;;
esac

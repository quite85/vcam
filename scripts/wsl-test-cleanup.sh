#!/usr/bin/env bash
# 在 WSL 里实测 make-repo.sh 第 6 步的清理逻辑修复
echo "=== 模拟：把 4 个 deb 放进一个 debs/ 目录，再跑修复后的清理逻辑 ==="

W=$(mktemp -d)
DEBS="$W/debs"
mkdir -p "$DEBS"

# 复制真实的 4 个 deb
cp /mnt/c/Users/27992/AppData/Local/Temp/v101/*.deb "$DEBS/" 2>/dev/null

# 再加一个"命名不规范"的假 deb，用来验证它**应该**被删掉
touch "$DEBS/com.quite85.virtualcamera_1.0.1_iphoneos-arm64.deb"
touch "$DEBS/com.quite85.virtualcamera_1.0.1_iphoneos-arm.deb"

echo "清理前（$(ls -1 "$DEBS"/*.deb 2>/dev/null | wc -l | tr -d ' ') 个）："
ls -1 "$DEBS"/*.deb | xargs -n1 basename | sed 's/^/  /'

echo ""
echo "执行修复后的清理逻辑…"
DELETED=0
while IFS= read -r -d '' f; do
    echo "  - 移除命名不规范的重复包: $(basename "$f")"
    rm -f "$f"
    DELETED=$((DELETED + 1))
done < <(find "$DEBS" -maxdepth 1 -name '*.deb' \
            ! -name '*-rootful.deb'   ! -name '*-rootless.deb' \
            ! -name '*-rootful-safe.deb'  ! -name '*-rootful-full.deb' \
            ! -name '*-rootless-safe.deb' ! -name '*-rootless-full.deb' \
            -print0 2>/dev/null || true)
[ "$DELETED" -eq 0 ] && echo "  （无需清理）"

echo ""
echo "清理后（$(ls -1 "$DEBS"/*.deb 2>/dev/null | wc -l | tr -d ' ') 个）："
ls -1 "$DEBS"/*.deb 2>/dev/null | xargs -n1 basename | sed 's/^/  /'

echo ""
echo "=== 对照：旧的错误逻辑会怎样 ==="
B=$(mktemp -d)
cp /mnt/c/Users/27992/AppData/Local/Temp/v101/*.deb "$B/" 2>/dev/null
echo "旧逻辑清理后（$(find "$B" -maxdepth 1 -name '*.deb' ! -name '*-rootful.deb' ! -name '*-rootless.deb' | wc -l | tr -d ' ') 个剩余）："
find "$B" -maxdepth 1 -name '*.deb' ! -name '*-rootful.deb' ! -name '*-rootless.deb' 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/^/  /'
echo "  （这样就是空的了 —— 正是线上 repo/debs 为空的原因）"

rm -rf "$W" "$B"

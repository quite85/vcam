#!/usr/bin/env bash
# 在 WSL 里实测 make-repo.sh 的完整流程（用真实的 4 个 v1.0.1 deb）
set -u

SRC=/mnt/c/日常使用/vcam
WORK=/root/vcam-repotest

echo "=== 准备测试工作区 ==="
rm -rf "$WORK"
mkdir -p "$WORK"
# 只复制 make-repo.sh 需要的部分
cp -r "$SRC/scripts" "$WORK/scripts"
cp -r "$SRC/repo" "$WORK/repo"
find "$WORK" -name '*.sh' -exec sed -i 's/\r$//' {} \;
chmod +x "$WORK/scripts/"*.sh 2>/dev/null

# 清掉 repo/debs 与索引，模拟干净状态
rm -f "$WORK/repo/debs"/*.deb "$WORK/repo/Packages"* "$WORK/repo/Release" 2>/dev/null

mkdir -p "$WORK/packages"
cp /mnt/c/Users/27992/AppData/Local/Temp/v101/*.deb "$WORK/packages/" 2>/dev/null

echo "packages/ 里的 deb："
ls -1 "$WORK/packages"/*.deb 2>/dev/null | xargs -n1 basename | sed 's/^/  /'
echo ""

cd "$WORK"
echo "=== 运行 make-repo.sh（第 6 步会清理，重点看它是否误删）==="
DOMAIN=quite85.github.io REPO_PATH=/vcam bash ./scripts/make-repo.sh 2>&1 | tail -40

echo ""
echo "=== 结果检查 ==="
echo "repo/debs 内容："
ls -lh "$WORK/repo/debs" 2>/dev/null | tail -n +2 | sed 's/^/  /'
CNT=$(ls -1 "$WORK/repo/debs"/*.deb 2>/dev/null | wc -l | tr -d ' ')
echo "  deb 个数: $CNT （期望 4）"

echo ""
echo "Packages 里的 Filename 与文件是否都存在："
while IFS= read -r fn; do
    fn_clean="${fn#./}"
    if [ -f "$WORK/repo/$fn_clean" ]; then
        echo "  ✅ $fn_clean"
    else
        echo "  ❌ 不存在: $fn_clean"
    fi
done < <(grep '^Filename:' "$WORK/repo/Packages" 2>/dev/null | sed 's/^Filename: *//')

echo ""
echo "Packages 条目数: $(grep -c '^Package:' "$WORK/repo/Packages" 2>/dev/null || echo 0)"
echo "Release 是否生成: $([ -f "$WORK/repo/Release" ] && echo 是 || echo 否)"
echo "Packages.gz: $([ -f "$WORK/repo/Packages.gz" ] && echo 是 || echo 否)"

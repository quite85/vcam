#!/usr/bin/env bash
# ============================================================================
#  scripts/check-conflicts.sh
#
#  在 **iPhone 上**运行（SSH 进去后执行），检查"之前装的虚拟摄像头插件"
#  有没有留下会和我们冲突的东西。
#
#  用法（电脑上）：
#      scp scripts/check-conflicts.sh root@手机IP:/var/mobile/
#      ssh root@手机IP
#      bash /var/mobile/check-conflicts.sh
#
#  或者直接在手机上用 NewTerm / Filza 的终端跑。
#
#  它只做"查看"，不修改任何东西 —— 可以放心运行。
# ============================================================================

echo "==============================================================="
echo " 虚拟摄像头 冲突检查"
echo "==============================================================="

# ---- 自动判断 rootless / rootful ----
if [ -d /var/jb/Library/MobileSubstrate ]; then
    JB=/var/jb
    echo "检测到：rootless 越狱（安装前缀 /var/jb）"
elif [ -d /Library/MobileSubstrate ]; then
    JB=""
    echo "检测到：rootful 越狱（无前缀）"
else
    JB=/var/jb
    echo "⚠️  未检测到 MobileSubstrate 目录，两种前缀都试着查一下"
fi

echo ""
echo "=============== 1) 已安装的、名字里带 vcam/camera 的包 ==============="
dpkg -l 2>/dev/null | grep -iE 'vcam|camera|虚拟' || echo "  （没有匹配的已安装包）"

echo ""
echo "=============== 2) 所有已安装的越狱插件（便于人工找漏网的） ==============="
dpkg -l 2>/dev/null | awk '$1=="ii" {print "  " $2, $3}' | head -60

echo ""
echo "=============== 3) DynamicLibraries 里的 filter（同名会互相覆盖） ==============="
for d in "$JB/Library/MobileSubstrate/DynamicLibraries" /Library/MobileSubstrate/DynamicLibraries; do
    [ -d "$d" ] || continue
    echo "--- $d ---"
    ls -la "$d" 2>/dev/null | grep -viE '^total|^d' | awk '{print "  " $NF, "(" $5 " 字节)"}'
done

echo ""
echo "=============== 4) 全盘搜索 vcam 相关残留 ==============="
# 只搜可能相关的位置，避免全盘扫描太慢
for base in "$JB/Library" /Library /var/mobile/Library; do
    [ -d "$base" ] || continue
    hits=$(find "$base" -maxdepth 3 -iname '*vcam*' 2>/dev/null)
    if [ -n "$hits" ]; then
        echo "--- 在 $base 下发现 ---"
        echo "$hits" | sed 's/^/  /'
    fi
done

echo ""
echo "=============== 5) 有没有别的虚拟摄像头类插件 ==============="
echo "  搜索常见的虚拟摄像头包名/文件名关键词："
find "$JB/Library/MobileSubstrate/DynamicLibraries" /Library/MobileSubstrate/DynamicLibraries \
     -maxdepth 1 -type f 2>/dev/null | grep -iE 'cam|fake|virtual|obs' | sed 's/^/  /' \
     || echo "  （无）"

echo ""
echo "=============== 6) 我们的插件是否已安装 ==============="
if dpkg -l 2>/dev/null | grep -q 'com.quite85.virtualcamera'; then
    echo "  ✅ com.quite85.virtualcamera 已安装"
    dpkg -l 2>/dev/null | grep 'com.quite85.virtualcamera' | sed 's/^/     /'
else
    echo "  ⬜ com.quite85.virtualcamera 未安装"
fi

echo ""
echo "=============== 7) 关键依赖是否就位 ==============="
for p in ellekit mobilesubstrate preferenceloader; do
    if dpkg -l 2>/dev/null | grep -qE "^ii\s+$p"; then
        echo "  ✅ $p"
    else
        echo "  ⬜ $p（未装，但可能被别的包以 Provides 形式满足）"
    fi
done

echo ""
echo "=============== 8) 我们的运行时日志 ==============="
LOG=/var/mobile/Library/VirtualCamera/virtualcamera.log
if [ -f "$LOG" ]; then
    echo "  日志存在，最后 15 行："
    tail -15 "$LOG" | sed 's/^/    /'
else
    echo "  日志不存在（说明我们的插件还没运行过）"
fi

echo ""
echo "==============================================================="
echo " 检查完成。把上面全部输出发给我即可。"
echo "==============================================================="

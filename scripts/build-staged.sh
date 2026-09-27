#!/usr/bin/env bash
# ============================================================================
#  scripts/build-staged.sh —— 打出"阶梯测试包"
#
#  为什么要阶梯测试：
#    v2.0.0 装上去后"重启完直接黑屏、没看到桌面"，
#    即 SpringBoard 在启动阶段就崩溃重启循环。
#    而 v2.0.0 同时做了两件事：
#      (1) SpringBoard UI（悬浮窗 + 音量键监听）
#      (2) 在所有进程安装帧替换 swizzle
#    无法判断是哪一件造成的。用户每测一次成本很高，
#    所以一次给出多个包，逐个排除。
#
#  三个阶梯（版本号递增，便于在 Sileo 里连续安装升级）：
#
#    A  2.1.0  只注入 SpringBoard
#              完全不参与相机 → 验证 UI 与构造阶段是否安全
#
#    B  2.2.0  注入 SpringBoard + 相机 + Safari
#              验证帧替换在不含第三方 App 时是否安全
#
#    C  2.3.0  完整 filter（22 个 Bundle）
#
#  判断方法：
#    A 不黑屏、B 黑屏   → 帧替换（相机 hook）有问题
#    A 黑屏             → UI 或构造阶段有问题
#    A、B 都不黑屏      → v2.0.0 的黑屏来自某个第三方 App 进程
#
#  ⚠️ 状态管理要点：
#    本脚本会改写仓库根目录的 VCam.plist 与 control*，
#    必须先把原件备份到临时目录，结束时还原，否则会把仓库弄脏。
# ============================================================================
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PKG_ID="${VCAM_PKG_ID:-com.quite85.virtualcamera}"
SDK_VERSION="${VCAM_SDK_VERSION:-}"
OUT_DIR="$ROOT_DIR/packages"
mkdir -p "$OUT_DIR"

if [ -z "${THEOS:-}" ]; then
    for guess in /opt/theos "$HOME/theos" /var/theos; do
        [ -d "$guess/makefiles" ] && { export THEOS="$guess"; break; }
    done
fi
[ -n "${THEOS:-}" ] && [ -d "$THEOS/makefiles" ] || { echo "找不到 Theos" >&2; exit 1; }
[ -n "$SDK_VERSION" ] && export VCAM_SDK_VERSION="$SDK_VERSION"
echo "THEOS = $THEOS"

# ---- 备份会被改写的文件 ----
BK="$(mktemp -d)"
cp -f VCam.plist       "$BK/VCam.plist"
cp -f control-rootful  "$BK/control-rootful"
cp -f control-rootless "$BK/control-rootless"

restore() {
    cp -f "$BK/VCam.plist"       VCam.plist       2>/dev/null || true
    cp -f "$BK/control-rootful"  control-rootful  2>/dev/null || true
    cp -f "$BK/control-rootless" control-rootless 2>/dev/null || true
    cp -f "$BK/control-rootful"  control          2>/dev/null || true
    rm -rf "$BK"
}
trap restore EXIT INT TERM

FAILED=0

# ---------------------------------------------------------------------------
#  $1 = 版本号   $2 = filter 文件   $3 = 标记（进文件名）
# ---------------------------------------------------------------------------
build_stage() {
    local version="$1" filter="$2" tag="$3"

    echo ""
    echo "=============================================================="
    echo " 阶梯 $tag   版本 $version   filter=$(basename "$filter")"
    echo "=============================================================="

    cp -f "$filter" VCam.plist
    sed "s/^Version: .*/Version: $version/" "$BK/control-rootless" > control-rootless
    sed "s/^Version: .*/Version: $version/" "$BK/control-rootful"  > control-rootful
    cp -f control-rootful control

    local nb
    nb=$(grep -c '<string>' VCam.plist 2>/dev/null || echo 0)
    echo "  filter 中 <string> 行数: $nb"

    make clean >/dev/null 2>&1 || true
    # 两个位置都要清：
    #   $THEOS/packages     Theos 默认产物目录
    #   $ROOT_DIR/packages  某些 Theos 版本/配置会输出到这里
    # 不清的话，下面的"找产物"逻辑会捡到上一轮的 deb。
    # ⚠️ 只清 $THEOS/packages，**不要**清 $ROOT_DIR/packages。
    #    后者是我们自己放阶梯产物的目录，清掉会把前面几个阶梯包一起删了
    #    （踩过：三个阶梯跑完只剩最后一个）。
    rm -f "$THEOS"/packages/*.deb 2>/dev/null || true

    local log="/tmp/vcam-stage-$tag.log"
    # MAKEFLAGS=-k：继续编译其余文件，一次报出全部错误
    # ⚠️ 必须显式传 VERSION=：Theos 的 `internal-package` 会用 VERSION 变量
    #    覆盖 control 里的 Version 字段。只改 control 文件是没用的
    #    （第一次写这个脚本时就踩了：三个阶梯包出来全是 2.0.0，
    #      而且互相覆盖，因为包名相同、只有 control 里的版本不同）。
    if ! MAKEFLAGS=-k make package FINALPACKAGE=1 ARCHS=arm64 \
              THEOS_PACKAGE_SCHEME=rootless \
              VERSION="$version" > "$log" 2>&1; then
        echo "  ❌ 编译失败，详见 $log"
        grep -E 'error:|Error ' "$log" | head -8 | sed 's/^/      /'
        FAILED=$((FAILED + 1))
        return 1
    fi

    # 产物收集：Theos 有时输出到 $THEOS/packages，有时输出到项目 packages/。
    # 两个位置都找，但**必须按本轮版本号过滤** ——
    # 否则会捡到前面阶梯留在项目 packages/ 里的包（踩过这个坑）。
    local src=""
    for dir in "$THEOS/packages" "$OUT_DIR"; do
        [ -d "$dir" ] || continue
        for cand in "$dir/${PKG_ID}_${version}_"*.deb; do
            [ -e "$cand" ] || continue
            src="$cand"
            break
        done
        [ -n "$src" ] && break
    done
    if [ -z "$src" ]; then
        echo "  ❌ 编译成功但找不到版本 $version 的 deb"
        echo "     搜过的目录: $THEOS/packages  $OUT_DIR"
        ls "$THEOS/packages" 2>/dev/null | sed "s/^/       theos: /"
        ls "$OUT_DIR" 2>/dev/null | sed "s/^/       proj : /"
        FAILED=$((FAILED + 1))
        return 1
    fi

    local dest="$OUT_DIR/${PKG_ID}_${version}_iphoneos-arm64-${tag}.deb"
    cp -f "$src" "$dest"
    echo "  ✅ 产出: $(basename "$dest")  ($(wc -c < "$dest" | tr -d ' ') 字节)"

    # 把 Theos 原始命名的那份删掉（与 dest 同名则跳过），
    # 避免 packages/ 里出现两份内容相同、名字不同的 deb。
    if [ "$src" != "$dest" ]; then
        rm -f "$src" 2>/dev/null || true
    fi
}

build_stage "2.1.0" "filters/VCam-stageA.plist" "stageA"
build_stage "2.2.0" "filters/VCam-stageB.plist" "stageB"
build_stage "2.3.0" "filters/VCam-stageC.plist" "stageC"

echo ""
echo "=============================================================="
if [ "$FAILED" -eq 0 ]; then
    echo " 三个阶梯包全部完成"
else
    echo " 有 $FAILED 个阶梯编译失败"
fi
echo "=============================================================="
ls -lh "$OUT_DIR"/*.deb 2>/dev/null | awk '{print "  " $9, "(" $5 ")"}'
exit "$FAILED"

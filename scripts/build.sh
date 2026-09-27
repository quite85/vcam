#!/usr/bin/env bash
# ============================================================================
#  scripts/build.sh —— 一次打出「安全版」+「系统注入版」的 rootful/rootless deb
#
#  用法：
#    ./scripts/build.sh                     # 打全部 4 个包（安全版 + 系统注入版 × rootful/rootless）
#    VCAM_ENABLE_OBS=0 ./scripts/build.sh   # 不带 FFmpeg 的轻量包
#    ONLY=rootless ./scripts/build.sh       # 只打 rootless（两种变体都打）
#    VARIANTS=safe ./scripts/build.sh       # 只打安全版
#    VARIANTS=full ./scripts/build.sh       # 只打系统注入版
#
#  产物（packages/）：
#    <pkgid>_<版本>_iphoneos-arm64-rootful-safe.deb      安全版（默认推荐）
#    <pkgid>_<版本>_iphoneos-arm64-rootless-safe.deb
#    <pkgid>_<版本>_iphoneos-arm64-rootful-full.deb      系统注入版（含 mediaserverd）
#    <pkgid>_<版本>_iphoneos-arm64-rootless-full.deb
#
#  两个变体的区别（详见 Makefile 的 VCAM_SYSTEM_HOOK 注释）：
#    safe = VCAM_SYSTEM_HOOK=0，只注入 App 层，**不会黑屏**
#    full = VCAM_SYSTEM_HOOK=1，额外注入 mediaserverd 等系统守护进程
#
#  前置条件：
#    - 已安装 Theos 并 export THEOS=/opt/theos
#    - 如果 VCAM_ENABLE_OBS=1，需要 FFmpeg 依赖（见 scripts/ffmpeg-deps.sh）
# ============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PKG_ID="${VCAM_PKG_ID:-com.quite85.virtualcamera}"
ENABLE_OBS="${VCAM_ENABLE_OBS:-1}"
ONLY="${ONLY:-all}"
VARIANTS="${VARIANTS:-all}"
# 编译用 SDK 版本。留空 = 让 Theos 用 Xcode 自带的 SDK（macOS 本机开发）。
# CI 上必须显式指定，因为运行器上没有 iPhoneOS SDK。
SDK_VERSION="${VCAM_SDK_VERSION:-}"

# ---- 环境检查 ----
if [ -z "${THEOS:-}" ]; then
    for guess in /opt/theos "$HOME/theos" /var/theos; do
        if [ -d "$guess/makefiles" ]; then
            export THEOS="$guess"
            break
        fi
    done
fi
if [ -z "${THEOS:-}" ] || [ ! -d "$THEOS/makefiles" ]; then
    echo "❌ 找不到 Theos。请先安装并 export THEOS=/opt/theos" >&2
    exit 1
fi
echo "✅ THEOS = $THEOS"

# ---- SDK 检查（CI 上最容易踩的坑）----
if [ -n "$SDK_VERSION" ]; then
    export VCAM_SDK_VERSION="$SDK_VERSION"
    if [ ! -d "$THEOS/sdks/iPhoneOS${SDK_VERSION}.sdk" ]; then
        echo "❌ 找不到 SDK: $THEOS/sdks/iPhoneOS${SDK_VERSION}.sdk" >&2
        echo "   请下载并解压：" >&2
        echo "     curl -L -o /tmp/sdk.tar.xz https://github.com/theos/sdks/releases/download/master-146e41f/iPhoneOS${SDK_VERSION}.sdk.tar.xz" >&2
        echo "     mkdir -p \"\$THEOS/sdks\" && tar -xJf /tmp/sdk.tar.xz -C \"\$THEOS/sdks\"" >&2
        exit 1
    fi
    echo "✅ SDK = $THEOS/sdks/iPhoneOS${SDK_VERSION}.sdk  (SDKVERSION=$SDK_VERSION)"
else
    echo "ℹ️  未指定 VCAM_SDK_VERSION，将由 Theos 自行选择 SDK（需要 Xcode 自带 iOS SDK）"
fi

if ! command -v dpkg-deb >/dev/null 2>&1; then
    echo "⚠️  未找到 dpkg-deb；Debian/Ubuntu 上装 dpkg-dev，macOS 上装 dpkg（brew install dpkg）" >&2
fi

if [ "$ENABLE_OBS" = "1" ] && [ ! -d "$THEOS/vendor/include/ffmpeg" ]; then
    echo "⚠️  未找到 FFmpeg 依赖 ($THEOS/vendor/include/ffmpeg)。"
    echo "    见 scripts/ffmpeg-deps.sh，或用 VCAM_ENABLE_OBS=0 只打轻量包。"
fi

VERSION="$(grep -m1 '^Version:' control-rootful | awk '{print $2}')"
[ -n "$VERSION" ] || { echo "❌ 无法从 control-rootful 读取 Version" >&2; exit 1; }
echo "📦 版本：$VERSION  包名：$PKG_ID  OBS=$ENABLE_OBS  变体=$VARIANTS"

OUT_DIR="$ROOT_DIR/packages"
mkdir -p "$OUT_DIR"

# Theos 只读根目录的 ./control，所以打包不同变体前要先把对应的 control 拷过去。
# 退出时（包括失败/中断）恢复成默认的 control-rootful，保持仓库干净。
restore_control() {
    cp -f "$ROOT_DIR/control-rootful" "$ROOT_DIR/control" 2>/dev/null || true
}
trap restore_control EXIT INT TERM

# ---------------------------------------------------------------------------
# 打包一个变体
#   $1 = scheme（空 = rootful，或 rootless / roothide）
#   $2 = 文件名标记（rootful / rootless / roothide）
#   $3 = 变体名（safe / full）
# ---------------------------------------------------------------------------
build_one() {
    local scheme="$1"
    local tag="$2"
    local variant="$3"

    echo ""
    echo "=============================================================="
    echo " 打包：$tag / $variant"
    echo "=============================================================="

    # ---- 按变体选择 control 与系统注入开关 ----
    local ctl
    local syshook
    if [ "$variant" = "safe" ]; then
        syshook=0
        if [ "$tag" = "rootful" ]; then ctl="control-safe-rootful"; else ctl="control-safe-rootless"; fi
    else
        syshook=1
        if [ "$tag" = "rootful" ]; then ctl="control-rootful"; else ctl="control-rootless"; fi
    fi
    if [ ! -f "$ROOT_DIR/$ctl" ]; then
        echo "❌ 找不到 control 文件：$ctl" >&2
        exit 1
    fi
    cp -f "$ROOT_DIR/$ctl" "$ROOT_DIR/control"
    echo "  control = $ctl   VCAM_SYSTEM_HOOK = $syshook"

    # ---- 按变体准备 layout/ 里的 mediaserverd filter ----
    # layout/ 下的文件会被原样打进 deb 并安装到设备。
    #
    # 为什么要放两套模板：
    #   · safe   装 filters/...disabled（空 filter，永不匹配）——
    #            不只是"不注入"，更要**覆盖掉**之前系统注入版留下的那份 plist，
    #            否则换装安全版后旧 filter 还在，系统注入依然生效。
    #   · full   装 filters/...enabled（Executables = mediaserverd 等）
    #
    # 注意这里每次都 rm -rf layout 再重建：layout/ 里只允许有
    # "必须安装到设备的东西"，不留任何辅助文件（曾把 README.txt 打进 deb）。
    rm -rf "$ROOT_DIR/layout"
    mkdir -p "$ROOT_DIR/layout/Library/MobileSubstrate/DynamicLibraries"
    local filter_src
    if [ "$variant" = "safe" ]; then
        filter_src="$ROOT_DIR/filters/VCam-mediaserverd.plist.disabled"
    else
        filter_src="$ROOT_DIR/filters/VCam-mediaserverd.plist.enabled"
    fi
    if [ ! -f "$filter_src" ]; then
        echo "❌ 找不到 filter 模板：$filter_src" >&2
        exit 1
    fi
    cp -f "$filter_src" "$ROOT_DIR/layout/Library/MobileSubstrate/DynamicLibraries/VCam-mediaserverd.plist"
    echo "  layout filter = $(basename "$filter_src")"

    make clean >/dev/null 2>&1 || true

    # 清掉 **Theos 的** packages 目录里上一轮遗留的 deb。
    #
    # ⚠️ 注意只清 $THEOS/packages，**不要**清 $ROOT_DIR/packages。
    #    这正是上一版 build.sh 的 bug 所在：
    #      原来写的是 rm -f $THEOS/packages/*.deb $ROOT_DIR/packages/*.deb，
    #      第二轮（rootless）开始时把第一轮（rootful）的产物一并删了，
    #      于是 make-repo.sh 只扫到一个 deb，
    #      Packages 里两条记录指向同一个文件（Size/SHA256 相同），
    #      仓库里只有 rootless 那份，rootful 那条 Filename 直接 404。
    #    现在每轮只清理 Theos 的输出，我们自己的产物完整保留。
    rm -f "$THEOS"/packages/*.deb 2>/dev/null || true

    # 每次切换 scheme 都要重新编译：rootless 会改变安装路径前缀
    #
    # ⚠️ 这里刻意不用数组传 THEOS_PACKAGE_SCHEME。
    #    原因：新版 bash（4.4+ / macOS 上 brew 装的）在 `set -u` 下
    #    安全展开空数组 `"${arr[@]}"`，但 **macOS 自带的 bash 3.2**
    #    会把空数组当成未定义变量，直接报
    #        line 110: scheme_arg[@]: unbound variable
    #    并 exit 1。GitHub 的 macos-latest 运行器用的正是 bash 3.2，
    #    所以这里改成条件拼接参数，兼容所有 bash 版本。
    #
    # MAKEFLAGS=-k（keep going）：
    #    默认 make 在第一个编译错误上就停下，一次只暴露一个文件的错误，
    #    排查要来回跑很多轮。加 -k 后它会继续编译其余文件，
    #    把所有错误一次性报出来。退出码仍然非 0，所以不影响失败判定。
    if [ -n "$scheme" ]; then
        MAKEFLAGS=-k make package FINALPACKAGE=1 \
             VCAM_ENABLE_OBS="$ENABLE_OBS" \
             VCAM_SYSTEM_HOOK="$syshook" \
             THEOS_PACKAGE_SCHEME="$scheme" \
             2>&1 | tee "/tmp/vcam-build-$tag-$variant.log"
        local make_rc=${PIPESTATUS[0]}
    else
        MAKEFLAGS=-k make package FINALPACKAGE=1 \
             VCAM_ENABLE_OBS="$ENABLE_OBS" \
             VCAM_SYSTEM_HOOK="$syshook" \
             2>&1 | tee "/tmp/vcam-build-$tag-$variant.log"
        local make_rc=${PIPESTATUS[0]}
    fi
    if [ "$make_rc" -ne 0 ]; then
        echo "❌ make package 失败（退出码 ${make_rc}），详见 /tmp/vcam-build-${tag}-${variant}.log"
        # 把错误条数统计出来，方便一眼看出还剩几个问题
        local errcount
        errcount=$(grep -c 'error:' "/tmp/vcam-build-$tag-$variant.log" 2>/dev/null || echo 0)
        echo "   本次编译共出现 $errcount 条 error（-k 模式，已尽量全部报告）"
        return "$make_rc"
    fi

    # 取本轮生成的 deb：优先从 Theos 的输出目录找（保留原始文件名做判定），
    # 找不到再退回到我们自己的 packages/。
    local src
    src="$(ls -t "$THEOS"/packages/*.deb 2>/dev/null | head -n 1 || true)"
    if [ -z "$src" ]; then
        src="$(ls -t "$ROOT_DIR"/packages/*.deb 2>/dev/null | head -n 1 || true)"
    fi
    if [ -z "$src" ]; then
        echo "❌ $tag/$variant 打包失败，请查看 /tmp/vcam-build-$tag-$variant.log" >&2
        exit 1
    fi

    # 文件名同时带 tag（rootful/rootless）与变体（safe/full），便于区分
    local arch_name="iphoneos-arm64"
    local dest="$OUT_DIR/${PKG_ID}_${VERSION}_${arch_name}-${tag}-${variant}.deb"
    cp -f "$src" "$dest"

    # ⚠️ 把 Theos 命名的原始 deb 删掉，只保留上面这份规范命名的。
    #    Theos 产出的名字是 com.<pkg>_<ver>_iphoneos-arm.deb 或 [...]_iphoneos-arm64.deb
    #    （取决于 control 里的 Architecture），既不带后缀，也和我们的命名重复。
    #    不删的话 packages/ 里会同时存在两份内容相同、名字不同的 deb，
    #    make-repo.sh 把它们都拷进 debs/ 并各写一条 Packages 记录，
    #    于是源里出现重复条目，用户不知道该装哪个。
    if [ "$src" != "$dest" ]; then
        rm -f "$src" 2>/dev/null || true
        echo "   （已移除 Theos 原始命名产物：$(basename "$src")）"
    fi
    echo "✅ 产出：$(basename "$dest")"
}

# ---------------------------------------------------------------------------
# 按 ONLY（架构）× VARIANTS（变体）组合打包
# ---------------------------------------------------------------------------
run_one() {
    local arch="$1" variant="$2"
    local scheme tag
    if [ "$arch" = "rootful" ]; then scheme=""; tag="rootful"; else scheme="$arch"; tag="$arch"; fi
    build_one "$scheme" "$tag" "$variant"
}

ARCH_LIST=()
case "$ONLY" in
    rootful)  ARCH_LIST=(rootful) ;;
    rootless) ARCH_LIST=(rootless) ;;
    all)      ARCH_LIST=(rootful rootless) ;;
    *) echo "❌ ONLY 只能是 rootful / rootless / all" >&2; exit 1 ;;
esac

VARIANT_LIST=()
case "$VARIANTS" in
    safe) VARIANT_LIST=(safe) ;;
    full) VARIANT_LIST=(full) ;;
    all)  VARIANT_LIST=(safe full) ;;
    *) echo "❌ VARIANTS 只能是 safe / full / all" >&2; exit 1 ;;
esac

for v in "${VARIANT_LIST[@]}"; do
    for a in "${ARCH_LIST[@]}"; do
        run_one "$a" "$v"
    done
done

echo ""
echo "=============================================================="
echo " 全部完成。下一步："
echo "   ./scripts/make-repo.sh          # 生成 APT 源文件"
echo "   ./scripts/make-repo.sh --serve  # 顺便起个本地 http 预览"
echo "=============================================================="
ls -lh "$OUT_DIR"

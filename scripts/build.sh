#!/usr/bin/env bash
# ============================================================================
#  scripts/build.sh —— 一次打出 rootful + rootless 两个 .deb
#
#  用法：
#    ./scripts/build.sh                     # 打两个包（默认，含 OBS 支持）
#    VCAM_ENABLE_OBS=0 ./scripts/build.sh   # 不带 FFmpeg 的轻量包
#    ONLY=rootless ./scripts/build.sh       # 只打 rootless
#
#  产物：
#    packages/com.quite85.vcam_<版本>_iphoneos-arm64-rootful.deb
#    packages/com.quite85.vcam_<版本>_iphoneos-arm64-rootless.deb
#
#  前置条件：
#    - 已安装 Theos 并 export THEOS=/opt/theos
#    - 如果 VCAM_ENABLE_OBS=1，需要 FFmpeg 依赖（见 scripts/ffmpeg-deps.sh）
# ============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PKG_ID="${VCAM_PKG_ID:-com.quite85.vcam}"
ENABLE_OBS="${VCAM_ENABLE_OBS:-1}"
ONLY="${ONLY:-all}"
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
echo "📦 版本：$VERSION  包名：$PKG_ID  OBS=$ENABLE_OBS"

OUT_DIR="$ROOT_DIR/packages"
mkdir -p "$OUT_DIR"

# Theos 只读根目录的 ./control，所以打包不同变体前要先把对应的 control 拷过去。
# 退出时（包括失败/中断）恢复成 rootful 的版本，保持仓库干净。
restore_control() {
    cp -f "$ROOT_DIR/control-rootful" "$ROOT_DIR/control" 2>/dev/null || true
}
trap restore_control EXIT INT TERM

# ---------------------------------------------------------------------------
# 打包一个变体
#   $1 = scheme（空 = rootful，或 rootless / roothide）
#   $2 = 文件名标记（rootful / rootless / roothide）
# ---------------------------------------------------------------------------
build_one() {
    local scheme="$1"
    local tag="$2"

    echo ""
    echo "=============================================================="
    echo " 打包：$tag"
    echo "=============================================================="

    # 切换到对应的 control
    if [ "$tag" = "rootful" ]; then
        cp -f "$ROOT_DIR/control-rootful" "$ROOT_DIR/control"
    else
        cp -f "$ROOT_DIR/control-rootless" "$ROOT_DIR/control"
    fi

    make clean >/dev/null 2>&1 || true

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
             THEOS_PACKAGE_SCHEME="$scheme" \
             2>&1 | tee "/tmp/vcam-build-$tag.log"
        local make_rc=${PIPESTATUS[0]}
    else
        MAKEFLAGS=-k make package FINALPACKAGE=1 \
             VCAM_ENABLE_OBS="$ENABLE_OBS" \
             2>&1 | tee "/tmp/vcam-build-$tag.log"
        local make_rc=${PIPESTATUS[0]}
    fi
    if [ "$make_rc" -ne 0 ]; then
        echo "❌ make package 失败（退出码 $make_rc），详见 /tmp/vcam-build-$tag.log"
        # 把错误条数统计出来，方便一眼看出还剩几个问题
        local errcount
        errcount=$(grep -c 'error:' "/tmp/vcam-build-$tag.log" 2>/dev/null || echo 0)
        echo "   本次编译共出现 $errcount 条 error（-k 模式，已尽量全部报告）"
        return "$make_rc"
    fi

    # 取最新生成的 deb
    local src
    src="$(ls -t "$THEOS"/packages/*.deb "$ROOT_DIR"/packages/*.deb 2>/dev/null | head -n 1 || true)"
    if [ -z "$src" ]; then
        echo "❌ $tag 打包失败，请查看 /tmp/vcam-build-$tag.log" >&2
        exit 1
    fi

    local arch_name="iphoneos-arm64"
    local dest="$OUT_DIR/${PKG_ID}_${VERSION}_${arch_name}-${tag}.deb"
    cp -f "$src" "$dest"
    echo "✅ 产出：$dest"

    # 再留一份不带架构标记的副本，方便本地 ad-hoc 安装
    cp -f "$src" "$OUT_DIR/${PKG_ID}_${VERSION}_${arch_name}.deb" 2>/dev/null || true
}

case "$ONLY" in
    rootful)  build_one "" rootful ;;
    rootless) build_one rootless rootless ;;
    all)
        build_one "" rootful
        build_one rootless rootless
        ;;
    *) echo "❌ ONLY 只能是 rootful / rootless / all" >&2; exit 1 ;;
esac

echo ""
echo "=============================================================="
echo " 全部完成。下一步："
echo "   ./scripts/make-repo.sh          # 生成 APT 源文件"
echo "   ./scripts/make-repo.sh --serve  # 顺便起个本地 http 预览"
echo "=============================================================="
ls -lh "$OUT_DIR"

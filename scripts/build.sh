#!/usr/bin/env bash
# ============================================================================
#  scripts/build.sh —— 一次打出 rootful + rootless 两个 deb
#
#  用法：
#    ./scripts/build.sh                     # 打两个包
#    ONLY=rootless ./scripts/build.sh       # 只打 rootless
#    ONLY=rootful  ./scripts/build.sh       # 只打 rootful
#
#  产物（packages/）：
#    com.quite85.virtualcamera_<版本>_iphoneos-arm64-rootful.deb
#    com.quite85.virtualcamera_<版本>_iphoneos-arm64-rootless.deb
#
#  前置条件：
#    - 已安装 Theos 并 export THEOS=/opt/theos
#    - 已把 iOS SDK 放到 $THEOS/sdks/（CI 上必须；macOS 本机可用 Xcode 自带）
# ============================================================================
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PKG_ID="${VCAM_PKG_ID:-com.quite85.virtualcamera}"
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
    echo "错误：找不到 Theos。请先安装并 export THEOS=/opt/theos" >&2
    exit 1
fi
echo "THEOS = $THEOS"

# ---- SDK 检查（CI 上最容易踩的坑）----
if [ -n "$SDK_VERSION" ]; then
    export VCAM_SDK_VERSION="$SDK_VERSION"
    if [ ! -d "$THEOS/sdks/iPhoneOS${SDK_VERSION}.sdk" ]; then
        echo "错误：找不到 SDK $THEOS/sdks/iPhoneOS${SDK_VERSION}.sdk" >&2
        echo "  下载方式：" >&2
        echo "    curl -L -o /tmp/sdk.tar.xz https://github.com/theos/sdks/releases/download/master-146e41f/iPhoneOS${SDK_VERSION}.sdk.tar.xz" >&2
        echo "    mkdir -p \"\$THEOS/sdks\" && tar -xJf /tmp/sdk.tar.xz -C \"\$THEOS/sdks\"" >&2
        exit 1
    fi
    echo "SDK  = $THEOS/sdks/iPhoneOS${SDK_VERSION}.sdk"
else
    echo "未指定 VCAM_SDK_VERSION，将由 Theos 自行选择 SDK"
fi

if ! command -v dpkg-deb >/dev/null 2>&1; then
    echo "提示：未找到 dpkg-deb（Debian/Ubuntu 装 dpkg-dev，macOS 装 brew install dpkg）"
fi

VERSION="$(grep -m1 '^Version:' control-rootful | awk '{print $2}')"
[ -n "$VERSION" ] || { echo "错误：无法从 control-rootful 读取 Version" >&2; exit 1; }
echo "版本 = $VERSION   包名 = $PKG_ID"

OUT_DIR="$ROOT_DIR/packages"
mkdir -p "$OUT_DIR"

# Theos 只读仓库根目录的 ./control，所以打包不同 scheme 前要先把对应的拷过去。
# 退出时恢复成默认（rootful），保持仓库干净。
restore_control() {
    cp -f "$ROOT_DIR/control-rootful" "$ROOT_DIR/control" 2>/dev/null || true
}
trap restore_control EXIT INT TERM

# ---------------------------------------------------------------------------
# 打包一个变体
#   $1 = scheme（空 = rootful，或 rootless）
#   $2 = 文件名标记（rootful / rootless）
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

    # 清掉 **Theos 的** packages 目录里上一轮遗留的 deb。
    # ⚠️ 只清 $THEOS/packages，**不要**清 $ROOT_DIR/packages ——
    #    否则第二轮会把第一轮的产物一起删掉，导致只发布出一个包。
    rm -f "$THEOS"/packages/*.deb 2>/dev/null || true

    # MAKEFLAGS=-k（keep going）：
    #    默认 make 在第一个编译错误上就停下，一次只暴露一个文件的错误。
    #    加 -k 后它会继续编译其余文件，把所有错误一次性报出来。
    #    退出码仍然非 0，不影响失败判定。
    if [ -n "$scheme" ]; then
        MAKEFLAGS=-k make package FINALPACKAGE=1 \
             THEOS_PACKAGE_SCHEME="$scheme" \
             2>&1 | tee "/tmp/vcam-build-$tag.log"
        local make_rc=${PIPESTATUS[0]}
    else
        MAKEFLAGS=-k make package FINALPACKAGE=1 \
             2>&1 | tee "/tmp/vcam-build-$tag.log"
        local make_rc=${PIPESTATUS[0]}
    fi

    if [ "$make_rc" -ne 0 ]; then
        echo "make package 失败（退出码 ${make_rc}），详见 /tmp/vcam-build-${tag}.log"
        local errcount
        errcount=$(grep -c 'error:' "/tmp/vcam-build-$tag.log" 2>/dev/null || echo 0)
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
        echo "错误：$tag 打包失败，请查看 /tmp/vcam-build-$tag.log" >&2
        exit 1
    fi

    local arch_name="iphoneos-arm64"
    local dest="$OUT_DIR/${PKG_ID}_${VERSION}_${arch_name}-${tag}.deb"
    cp -f "$src" "$dest"

    # 把 Theos 命名的原始 deb 删掉，只保留上面这份规范命名的。
    # 否则 packages/ 里会同时存在两份内容相同、名字不同的 deb，
    # make-repo.sh 会把它们都扫进 Packages，源里出现重复条目。
    if [ "$src" != "$dest" ]; then
        rm -f "$src" 2>/dev/null || true
    fi
    echo "产出：$(basename "$dest")"
}

case "$ONLY" in
    rootful)  build_one "" rootful ;;
    rootless) build_one rootless rootless ;;
    all)
        build_one "" rootful
        build_one rootless rootless
        ;;
    *) echo "错误：ONLY 只能是 rootful / rootless / all" >&2; exit 1 ;;
esac

echo ""
echo "=============================================================="
echo " 全部完成。下一步："
echo "   ./scripts/make-repo.sh          # 生成 APT 源文件"
echo "=============================================================="
ls -lh "$OUT_DIR"

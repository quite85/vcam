#!/usr/bin/env bash
# ============================================================================
#  scripts/collect-compile-errors.sh —— 一次收集全部编译错误
#
#  背景（为什么要这个脚本）：
#    Theos 生成 .mi 中间文件时用的是「占位源文件」，clang 的症状是：
#      · 报错文件名显示成 "virtual"，行号与真实文件对不上
#      · make 默认在第一个出错文件就停，一次只暴露一个文件
#      · 同一条错误被 arm64 / arm64e 各报一遍
#    结果就是排错要来回很多轮，每轮只修掉一个文件。
#
#  本脚本的做法：
#    1) 先用 Logos 把 Tweak.x 预处理成 .m（放在仓库根的 .theos-pre/ 下）
#    2) 直接把**全部**主 tweak 源文件（含预处理后的 Tweak.m）一次性喂给
#       clang -fsyntax-only，而不是让 Theos 逐个目标去 make
#    3) 收集所有 file:line:col: error 行，去重、排序后汇总输出
#    4) 同时输出"通过/失败"文件清单，一眼看出还剩哪些
#
#  用法：
#    THEOS=/opt/theos ./scripts/collect-compile-errors.sh
#    # 只看汇总不看详细输出：
#    QUIET=1 THEOS=/opt/theos ./scripts/collect-compile-errors.sh
#
#  依赖：perl、Theos（提供 logos.pl 与 iOS SDK）、xcrun 或 clang 在 PATH 里
# ============================================================================
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

THEOS="${THEOS:-/opt/theos}"
SDK_VERSION="${VCAM_SDK_VERSION:-16.5}"
SDK="$THEOS/sdks/iPhoneOS${SDK_VERSION}.sdk"
[ -d "$SDK" ] || SDK="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || echo "")"
if [ -z "$SDK" ] || [ ! -d "$SDK" ]; then
    echo "❌ 找不到 iOS SDK（试过 $THEOS/sdks/iPhoneOS${SDK_VERSION}.sdk 与 xcrun）" >&2
    exit 1
fi
echo "使用 SDK : $SDK"

LOGOS="$THEOS/vendor/logos/bin/logos.pl"
[ -f "$LOGOS" ] || { echo "❌ 找不到 $LOGOS" >&2; exit 1; }

PRE_DIR="$ROOT_DIR/.theos-pre"
mkdir -p "$PRE_DIR"

# ---- 1) 预处理 Tweak.x ----
echo "预处理 Tweak.x …"
if ! perl "$LOGOS" Tweak.x > "$PRE_DIR/Tweak.m" 2> "$PRE_DIR/logos.err"; then
    echo "❌ logos.pl 失败：" >&2
    cat "$PRE_DIR/logos.err" >&2
    exit 1
fi
if [ -s "$PRE_DIR/logos.err" ]; then
    echo "⚠️  logos.pl 有警告（Theos 用 -c warnings=error，视为失败）：" >&2
    cat "$PRE_DIR/logos.err" >&2
    exit 1
fi

# ---- 2) 收集要编译的源文件 ----
#   Tweak.x 用预处理产物；其余用真实源文件（也就是错误位置精确的关键）
SRCS=(
    "$PRE_DIR/Tweak.m"
    "UI/VCamPanel.m"
    "UI/VCamPickerController.m"
    "UI/VCamHUD.m"
    "UI/VCamVolumeHook.m"
    "UI/VCamVideoDataOutputProxy.m"
    "UI/VCamPreviewOverlay.m"
    "Media/VCamPhotoOutputInjector.m"
    "Media/VCamMovieFileInjector.m"
    "Mic/VCamMicInjector.m"
)

CLANG="${CLANG:-xcrun -sdk iphoneos clang}"
COMMON=(-fsyntax-only -fobjc-arc -x objective-c
        -isysroot "$SDK" -miphoneos-version-min=15.0
        -I. -ICore -IUI -IMedia -IMic
        -I"$THEOS/vendor/include"
        -I"$THEOS/vendor/lib"
        -F"$SDK/System/Library/Frameworks"
        -F"$SDK/System/Library/PrivateFrameworks"
        -fmodules -fobjc-weak)
FRAMEWORKS=()
for f in Foundation UIKit AVFoundation CoreMedia CoreVideo AudioToolbox \
         VideoToolbox CoreImage ImageIO Photos PhotosUI QuartzCore \
         MediaPlayer Accelerate UniformTypeIdentifiers; do
    FRAMEWORKS+=(-framework "$f")
done

# ---- 3) 逐个文件跑 clang，收集全部错误 ----
ERRFILE="$PRE_DIR/all-errors.txt"
rm -f "$ERRFILE"
PASS=0
FAIL=0
FAILED_FILES=""

for src in "${SRCS[@]}"; do
    # shellcheck disable=SC2086
    if $CLANG "${COMMON[@]}" "${FRAMEWORKS[@]}" "$src" 2> "$PRE_DIR/err.txt"; then
        rc=0
    else
        rc=$?
    fi
    if [ -s "$PRE_DIR/err.txt" ] || [ "$rc" -ne 0 ]; then
        FAIL=$((FAIL + 1))
        FAILED_FILES="$FAILED_FILES\n  ✗ $src"
        # 只保留诊断行（error/warning/note），去掉列出的源码行与空行
        grep -E ':[0-9]+:[0-9]+: (error|warning|note):' "$PRE_DIR/err.txt" >> "$ERRFILE" 2>/dev/null || true
        [ "$rc" -ne 0 ] && echo "$src: clang exit $rc" >> "$ERRFILE"
    else
        PASS=$((PASS + 1))
    fi
done

# ---- 4) 汇总 ----
echo ""
echo "==============================================================="
echo " 通过 $PASS 个文件，失败 $FAIL 个"
if [ -n "$FAILED_FILES" ]; then
    echo -e " 失败清单:$FAILED_FILES"
fi
echo "==============================================================="

if [ -s "$ERRFILE" ]; then
    COUNT=$(grep -c ': error:' "$ERRFILE" 2>/dev/null || echo 0)
    echo ""
    echo "共 $COUNT 条 error（已去重）。按文件分组："
    echo ""
    awk -F: '/: error:/ {print $1}' "$ERRFILE" | sort | uniq -c | sort -rn | while read -r n f; do
        printf "  %3s 条  %s\n" "$n" "$f"
    done
    echo ""
    echo "--- 全部错误行（唯一）---"
    grep ': error:' "$ERRFILE" | sort -u | sed 's/^/  /'
    echo ""
    echo "--- 错误位置片段（含 note，便于定位）---"
    sort -u "$ERRFILE" | sed 's/^/  /'
    echo ""
    echo "完整原始输出：$ERRFILE"
    echo "（若需要，可逐文件查看：$PRE_DIR/err.txt 只保留最后一个文件）"
    exit 1
else
    echo "✅ 全部源文件通过语法检查"
    exit 0
fi

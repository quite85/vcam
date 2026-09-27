#!/usr/bin/env bash
# ============================================================================
#  scripts/precheck-logos.sh —— Logos 语法与生成代码预检
#
#  为什么需要这个脚本：
#    Tweak.x 先经过 Logos 预处理器，再交给 clang。Logos 的某些错误
#    **不会**让 logos.pl 报错 —— 它会生成"语法合法但语义错误"的代码，
#    直到 clang 编译时才炸，而且报错位置非常难懂。
#
#    本项目真实踩过一次：
#      在 %hook 块之后、%ctor 之前写了一行 #import。
#      Logos 把"不在 %hook 里的代码"统一塞进它生成的构造函数，
#      于是那行 #import 落进了某个方法体内，clang 报：
#        Tweak.x:337:164: error: function definition is not allowed here
#        VCamVolumeHook.h:29:1: error: redundant #include of module
#          'Foundation' appears within function '...$hasFlash'
#        VCamVolumeHook.h:33:1: error: unexpected '@' in program
#      而 logos.pl 自己的退出码是 0、stderr 是空的 —— 只看退出码根本发现不了。
#
#  本脚本检查 6 项：
#    1) logos.pl 退出码与 stderr
#    2) 生成代码里是否还有未展开的 Logos 指令（^\s*%）
#    3) 生成代码里是否有**缩进的** #import（= 落在了函数体内）★核心检查
#    4) 花括号平衡
#    5) %ctor 是否生成了 __attribute__((constructor))
#    6) 所有 #import 是否都在文件前 1/4 处
#
#  用法：
#    THEOS=/opt/theos ./scripts/precheck-logos.sh
#    LOGOS=/path/to/logos.pl ./scripts/precheck-logos.sh
#
#  依赖：perl、以及 Theos 的 vendor/logos（$THEOS/vendor/logos/bin/logos.pl）
# ============================================================================
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

TARGET_X="${1:-Tweak.x}"

# ---- 找 logos.pl ----
LOGOS="${LOGOS:-}"
if [ -z "$LOGOS" ]; then
    if [ -n "${THEOS:-}" ] && [ -f "$THEOS/vendor/logos/bin/logos.pl" ]; then
        LOGOS="$THEOS/vendor/logos/bin/logos.pl"
    elif [ -f "$ROOT_DIR/vendor/logos/bin/logos.pl" ]; then
        LOGOS="$ROOT_DIR/vendor/logos/bin/logos.pl"
    fi
fi
if [ -z "$LOGOS" ] || [ ! -f "$LOGOS" ]; then
    echo "❌ 找不到 logos.pl。请设置 THEOS 或 LOGOS 环境变量。" >&2
    echo "   例如： THEOS=/opt/theos $0" >&2
    exit 1
fi
echo "使用 logos.pl: $LOGOS"

OUT="$(mktemp -t vcam-logos-XXXXXX.m)"
ERR="$(mktemp -t vcam-logos-XXXXXX.err)"
trap 'rm -f "$OUT" "$ERR"' EXIT

# ---- 1) 跑 logos.pl ----
if ! perl "$LOGOS" "$TARGET_X" > "$OUT" 2> "$ERR"; then
    echo "❌ logos.pl 退出码非 0："
    cat "$ERR" >&2
    exit 1
fi
if [ -s "$ERR" ]; then
    echo "⚠️  logos.pl 有输出（警告/错误）："
    cat "$ERR" >&2
    # Logos 在 Theos 里是带 -c warnings=error 调用的，警告也会变成失败
    echo "❌ 视为失败（Theos 用 -c warnings=error）"
    exit 1
fi
echo "✅ [1/6] logos.pl 成功，无 stderr 输出（生成 $(wc -c < "$OUT" | tr -d ' ') 字节）"

FAIL=0

# ---- 2) 未展开的 Logos 指令 ----
if grep -nE '^[[:space:]]*%' "$OUT" > /dev/null 2>&1; then
    echo "❌ [2/6] 生成代码里仍有未展开的 Logos 指令："
    grep -nE '^[[:space:]]*%' "$OUT" | head -20
    FAIL=1
else
    echo "✅ [2/6] 无残留 Logos 指令"
fi

# ---- 3) 缩进的 #import（★ 最关键的一项）----
# 顶层 #import 顶格写；一旦有缩进，说明它被塞进了函数体/方法体。
if grep -nE '^[[:space:]]+#[[:space:]]*(import|include)' "$OUT" > /dev/null 2>&1; then
    echo "❌ [3/6] 发现缩进的 #import —— 说明它落在了函数体内！"
    grep -nE '^[[:space:]]+#[[:space:]]*(import|include)' "$OUT" | head -20
    echo "   常见原因：把 #import 写在了 %hook 块之后。"
    echo "   Logos 会把「不在 %hook 里的代码」放进生成的构造函数，"
    echo "   所以所有 #import 必须集中在文件顶部、任何 %hook 之前。"
    FAIL=1
else
    echo "✅ [3/6] 无缩进 #import（全部位于文件顶层）"
fi

# ---- 4) 花括号平衡 ----
# 用 perl 精确统计（跳过字符串与注释，避免把 log 文本里的花括号算进去）
BAL=$(perl -0777 -ne '
    my $s = $_;
    # 去掉块注释
    $s =~ s{/\*.*?\*/}{}gs;
    # 去掉行注释
    $s =~ s{//[^\n]*}{}g;
    # 去掉字符串与字符字面量
    $s =~ s{"(?:\\.|[^"\\])*"}{""}gs;
    $s =~ s{\x27(?:\\.|[^\x27\\])*\x27}{""}gs;
    my $o = () = $s =~ /\{/g;
    my $c = () = $s =~ /\}/g;
    print "$o $c";
' "$OUT")
set -- $BAL
if [ "${1:-0}" = "${2:-0}" ]; then
    echo "✅ [4/6] 花括号平衡（$1 对）"
else
    echo "❌ [4/6] 花括号不平衡：{ = $1, } = $2"
    FAIL=1
fi

# ---- 5) %ctor 生成检查 ----
if grep -q '__attribute__((constructor))' "$OUT"; then
    echo "✅ [5/6] %ctor 已生成 __attribute__((constructor))"
else
    echo "❌ [5/6] 没找到生成的构造函数 —— %ctor 可能没被识别"
    FAIL=1
fi

# ---- 6) #import 位置 ----
TOTAL=$(wc -l < "$OUT" | tr -d ' ')
LIMIT=$(( TOTAL / 4 ))
LATE=$(grep -nE '^#import' "$OUT" | awk -F: -v lim="$LIMIT" '$1 > lim {print $1}' | tr '\n' ' ')
if [ -z "$LATE" ]; then
    echo "✅ [6/6] 所有 #import 都在前 $LIMIT 行内"
else
    echo "❌ [6/6] 有 #import 出现在文件后 3/4 处（行号：${LATE}）"
    grep -nE '^#import' "$OUT" | awk -F: -v lim="$LIMIT" '$1 > lim'
    FAIL=1
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "==============================================================="
    # ⚠️ 变量必须写成 ${TARGET_X} 花括号形式。
    #    之前写成 "…（$TARGET_X）" 这种形式（未加花括号），中文字符「（」紧贴变量，
    #    bash 3.2 会把该多字节字符的首字节并进变量名，
    #    在 set -u 下报：TARGET_X<字节>: unbound variable
    echo " ✅ 预检全部通过：${TARGET_X}"
    echo "==============================================================="
    exit 0
else
    echo "==============================================================="
    echo " ❌ 预检失败，请按上面的提示修改：${TARGET_X}"
    echo "==============================================================="
    exit 1
fi

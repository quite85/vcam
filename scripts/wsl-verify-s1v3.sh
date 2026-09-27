#!/usr/bin/env bash
set -u
D="/mnt/c/日常使用/vcam/experiments/stage1/com.quite85.vcamstage1_1.0.2_iphoneos-arm64.deb"
echo "=== Stage1 v3 deb ==="
echo "  大小: $(stat -c%s "$D") 字节"
dpkg-deb -f "$D" Package Name Version 2>/dev/null | sed 's/^/  /'
echo ""
echo "=== 安装的文件 ==="
dpkg-deb -c "$D" 2>/dev/null | awk '{print "  " $6}' | grep -v '/$'
echo ""
T=$(mktemp -d); dpkg-deb -x "$D" "$T" 2>/dev/null

echo "=== ★ 关键：filter plist 的格式与内容 ==="
F=$(find "$T" -name '*.plist' | head -1)
echo "  文件: $F"
echo "  前 4 字节（XML 应是 <?xm）:"
head -c 4 "$F" | xxd | sed 's/^/    /'
echo "  完整内容:"
cat "$F" | sed 's/^/    /'
echo ""
echo "  用 plutil 解析验证（若可用）:"
if command -v plutil >/dev/null 2>&1; then
    plutil -p "$F" 2>&1 | sed 's/^/    /'
else
    echo "    （无 plutil，用 python 解析）"
    python3 -c "
import plistlib,sys
try:
    with open('$F','rb') as fh:
        d = plistlib.load(fh)
    print('    ✅ 解析成功:', d)
except Exception as e:
    print('    ❌ 解析失败:', e)
"
fi
echo ""
echo "=== ★ 关键：是否包含 springboard ==="
if grep -q 'com.apple.springboard' "$F"; then echo "  ✅ 含 com.apple.springboard"; else echo "  ❌ 不含 springboard"; fi
if grep -q 'com.apple.Preferences' "$F"; then echo "  ✅ 含 com.apple.Preferences"; else echo "  ❌ 不含 Preferences"; fi
echo ""
echo "=== dylib ==="
DL=$(find "$T" -name '*.dylib' | head -1)
file "$DL" | sed 's/^/  /'
echo "  依赖:"
llvm-objdump -p "$DL" 2>/dev/null | grep -E 'name /' | sed 's/^/    /'
echo ""
echo "=== 关键字符串 ==="
for s in VCamStage1 outputVolume springboard; do
  if strings "$DL" | grep -q "$s"; then echo "  ✅ 含 \"$s\""; else echo "  ⬜ 不含 \"$s\""; fi
done
rm -rf "$T"

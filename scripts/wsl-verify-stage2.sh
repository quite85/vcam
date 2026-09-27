#!/usr/bin/env bash
set -u
D="/mnt/c/日常使用/vcam/experiments/stage2/com.quite85.vcamstage2_2.0.0_iphoneos-arm64.deb"
echo "=== Stage2 deb ==="
echo "  大小: $(stat -c%s "$D") 字节"
dpkg-deb -f "$D" Package Name Version Architecture 2>/dev/null | sed 's/^/  /'
echo ""
echo "=== 安装的文件 ==="
dpkg-deb -c "$D" 2>/dev/null | awk '{print "  " $6}' | grep -v '/$'
echo ""
T=$(mktemp -d); dpkg-deb -x "$D" "$T" 2>/dev/null

echo "=== ★ filter 内容（应只有 3 个 Bundle）==="
F=$(find "$T" -name '*.plist' | head -1)
python3 -c "
import plistlib
with open('$F','rb') as fh: d = plistlib.load(fh)
print('   ', d)
b = d.get('Filter',{}).get('Bundles',[])
print('    Bundle 数:', len(b))
for x in b: print('     -', x)
" 2>&1 | sed 's/^/  /'
echo ""
echo "=== ★ 关键检查 ==="
if grep -qa 'mediaserverd' "$F"; then echo "  ❌ filter 含 mediaserverd（不该有）"; else echo "  ✅ filter 不含 mediaserverd"; fi
if grep -qa 'springboard' "$F"; then echo "  ✅ filter 含 springboard"; else echo "  ❌ 缺 springboard"; fi
if grep -qa 'mobilesafari' "$F"; then echo "  ✅ filter 含 mobilesafari"; else echo "  ⬜ 不含 mobilesafari"; fi
echo ""
echo "=== dylib ==="
DL=$(find "$T" -name '*.dylib' | head -1)
echo "  大小: $(stat -c%s "$DL") 字节"
file "$DL" | sed 's/^/  /'
echo "  依赖:"
llvm-objdump -p "$DL" 2>/dev/null | grep -E 'name /' | sed 's/^/    /'
echo ""
echo "=== 关键字符串（确认代码真的进去了）==="
for s in VCamStage2 悬浮 音量 springboard outputVolume 已注入; do
  if strings "$DL" | grep -q "$s"; then echo "  ✅ 含 \"$s\""; else echo "  ⬜ 不含 \"$s\""; fi
done
rm -rf "$T"

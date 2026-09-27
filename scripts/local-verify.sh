#!/usr/bin/env bash
# 本地验证新实现：Logos 预处理 + clang 语法检查 + 完整编译
set -u
THEOS=/root/theos
export THEOS
export PATH="$THEOS/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
SDK=$THEOS/sdks/iPhoneOS16.5.sdk

W=/root/vcam-new
SRC=/mnt/c/日常使用/vcam
rm -rf "$W"; mkdir -p "$W"
cp -r "$SRC/." "$W/" 2>/dev/null
rm -rf "$W/.git" "$W/.theos" "$W/packages"
find "$W" -name '*.sh' -exec sed -i 's/\r$//' {} \; 2>/dev/null
chmod +x "$W/scripts/"*.sh 2>/dev/null
cd "$W"

echo "=== 1) Logos 预处理 Tweak.xm ==="
if ! perl "$THEOS/vendor/logos/bin/logos.pl" Tweak.xm > /tmp/new_tweak.m 2>/tmp/new_logos.err; then
    echo "  ❌ logos.pl 失败:"; cat /tmp/new_logos.err | head -20 | sed 's/^/    /'
    exit 1
fi
if [ -s /tmp/new_logos.err ]; then
    echo "  ⚠️ logos.pl 有输出（Theos 视为错误）:"
    cat /tmp/new_logos.err | head -20 | sed 's/^/    /'
    exit 1
fi
echo "  ✅ 预处理成功（$(wc -l < /tmp/new_tweak.m) 行）"

echo ""
echo "=== 2) 关键符号检查 ==="
for pat in 'VCamFrameInjector' 'VCamMediaManager' 'VCamFloatButton' 'VCamVolumeWatcher' \
           'VCamVideoDelegateProxy' 'setSampleBufferDelegate' 'applicationDidFinishLaunching' \
           'class_addMethod'; do
    n=$(grep -c "$pat" /tmp/new_tweak.m 2>/dev/null)
    printf '  %-30s %s\n' "$pat" "$n"
done

echo ""
echo "=== 3) clang 语法检查（各源文件）==="
FLAGS="-fsyntax-only -fobjc-arc -x objective-c
       -target arm64-apple-ios15.0
       -isysroot $SDK
       -I. -Isrc -I$THEOS/vendor/include
       -F$SDK/System/Library/Frameworks
       -F$SDK/System/Library/PrivateFrameworks
       -Wno-everything -fmodules -fobjc-weak"
for f in Foundation UIKit AVFoundation CoreMedia CoreVideo CoreImage QuartzCore Photos; do
    FLAGS="$FLAGS -framework $f"
done

FAIL=0
for src in /tmp/new_tweak.m src/VCamMediaManager.m src/VCamFrameInjector.m; do
    if clang $FLAGS "$src" 2>/tmp/new_clang.err; then
        echo "  ✅ $src"
    else
        echo "  ❌ $src"
        head -20 /tmp/new_clang.err | sed 's/^/      /'
        FAIL=1
    fi
done
[ "$FAIL" -eq 0 ] || exit 1

echo ""
echo "=== 4) 完整编译（arm64，rootless）==="
rm -rf .theos packages
make package FINALPACKAGE=1 ARCHS=arm64 THEOS_PACKAGE_SCHEME=rootless > /tmp/new_build.log 2>&1
RC=$?
echo "  make 退出码 = $RC"
if [ "$RC" -ne 0 ]; then
    echo "  错误摘要:"
    grep -E 'error:|Error ' /tmp/new_build.log | head -12 | sed 's/^/    /'
    echo "  末尾:"
    tail -12 /tmp/new_build.log | sed 's/^/    /'
    exit 1
fi

echo ""
echo "=== 5) 产物 ==="
D=$(ls -t "$W"/packages/*.deb "$THEOS"/packages/*.deb 2>/dev/null | head -1)
if [ -n "$D" ]; then
    echo "  ✅ $D  ($(stat -c%s "$D") 字节)"
    cp -f "$D" /mnt/c/日常使用/vcam/packages/ 2>/dev/null || {
        mkdir -p /mnt/c/日常使用/vcam/packages
        cp -f "$D" /mnt/c/日常使用/vcam/packages/
    }
    echo "  已复制到 packages/"
    echo ""
    echo "  === 安装的文件 ==="
    dpkg-deb -c "$D" 2>/dev/null | awk '{print "    " $6}' | grep -v '/$'
    T=$(mktemp -d); dpkg-deb -x "$D" "$T" 2>/dev/null
    echo "  === dylib ==="
    find "$T" -name '*.dylib' -exec file {} \; | sed 's/^/    /'
    echo "  === filter ==="
    find "$T" -name '*.plist' -exec sh -c 'python3 -c "
import plistlib,sys
with open(sys.argv[1],\"rb\") as f: d=plistlib.load(f)
b=d.get(\"Filter\",{}).get(\"Bundles\",[])
print(\"    Bundle 数:\", len(b))
for x in b[:6]: print(\"      -\", x)
print(\"      ...\")
" "$1"' _ {} \;
    rm -rf "$T"
else
    echo "  ❌ 无产物"
    tail -15 /tmp/new_build.log | sed 's/^/    /'
    exit 1
fi

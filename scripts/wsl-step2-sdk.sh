#!/usr/bin/env bash
# 第 2 步：下载 iOS SDK 到 $THEOS/sdks
set -uo pipefail
export THEOS="$HOME/theos"
SDK_NAME="iPhoneOS16.5.sdk"
DEST="$THEOS/sdks/$SDK_NAME"

mkdir -p "$THEOS/sdks"
if [ -d "$DEST" ]; then
    echo "SDK 已存在: $DEST"
else
    URL="https://github.com/theos/sdks/releases/download/master-146e41f/${SDK_NAME}.tar.xz"
    echo "下载: $URL"
    if curl -fL --retry 3 --progress-bar -o "/tmp/${SDK_NAME}.tar.xz" "$URL"; then
        echo "下载完成，大小: $(du -h /tmp/${SDK_NAME}.tar.xz | cut -f1)"
        tar -xJf "/tmp/${SDK_NAME}.tar.xz" -C "$THEOS/sdks"
        echo "解压退出码: $?"
    else
        echo "❌ 下载失败"
        exit 1
    fi
fi

echo ""
echo "--- \$THEOS/sdks 内容 ---"
ls "$THEOS/sdks" | sed 's/^/  /'
if [ -d "$DEST" ]; then
    echo "✅ SDK 就位"
    echo "  大小: $(du -sh "$DEST" | cut -f1)"
    echo "  usr/include 存在: $([ -d "$DEST/usr/include" ] && echo yes || echo no)"
    echo "  System/Library/Frameworks 存在: $([ -d "$DEST/System/Library/Frameworks" ] && echo yes || echo no)"
    echo "  框架数量: $(ls "$DEST/System/Library/Frameworks" 2>/dev/null | wc -l)"
else
    echo "❌ SDK 缺失"; exit 1
fi

#!/usr/bin/env bash
# ============================================================================
#  scripts/ffmpeg-deps.sh —— 为 OBS(MPEG-TS) 支持准备 FFmpeg 静态库
#
#  我们只需要 demux 与解码辅助，不需要编码器。
#  这样能把静态库从 ~40MB 压到 ~4-6MB（arm64+arm64e 各一份）。
#
#  前提：
#    - macOS + Xcode 命令行工具
#    - 已安装 Theos，$THEOS/vendor/{include,lib} 存在
#    - 已经用 theos-ffmpeg 或自建方式得到 iOS 版 libav*
#
#  推荐做法（最省事）：
#    1) 安装 theos-ffmpeg（社区维护的 iOS FFmpeg 构建脚本）
#         git clone https://github.com/kirbylover4000/theos-ffmpeg /opt/theos-ffmpeg
#         cd /opt/theos-ffmpeg && ./build.sh --arch=arm64,arm64e \
#             --disable-everything \
#             --enable-demuxer=mpegts --enable-decoder=h264,aac \
#             --enable-parser=h264,aac --enable-protocol=udp,tcp,file \
#             --enable-swresample --enable-static --disable-shared
#    2) 把产物拷到 Theos 的 vendor 目录：
#         cp -r ffmpeg/include/* $THEOS/vendor/include/
#         cp -r ffmpeg/lib/*     $THEOS/vendor/lib/
#    3) 重新编译插件
#
#  这个脚本负责第 2 步，并做基本的完整性校验。
# ============================================================================
set -euo pipefail

THEOS="${THEOS:-/opt/theos}"
SRC="${1:-}"

if [ -z "$SRC" ]; then
    cat <<EOF
用法： $0 <ffmpeg 构建产物目录>
  该目录应包含 include/ 和 lib/ 两个子目录。
例如： $0 /opt/theos-ffmpeg/ffmpeg
EOF
    exit 1
fi

if [ ! -d "$SRC/include" ] || [ ! -d "$SRC/lib" ]; then
    echo "❌ $SRC 下没有 include/ 或 lib/" >&2
    exit 1
fi
if [ ! -d "$THEOS/vendor" ]; then
    echo "❌ $THEOS/vendor 不存在，THEOS 设置是否正确？当前 = $THEOS" >&2
    exit 1
fi

echo "➡️  拷贝头文件到 $THEOS/vendor/include/ffmpeg"
mkdir -p "$THEOS/vendor/include/ffmpeg"
cp -R "$SRC/include/." "$THEOS/vendor/include/ffmpeg/"

echo "➡️  拷贝静态库到 $THEOS/vendor/lib"
mkdir -p "$THEOS/vendor/lib"
for f in "$SRC"/lib/*.a; do
    [ -f "$f" ] || continue
    cp -f "$f" "$THEOS/vendor/lib/"
    echo "   + $(basename "$f")"
done

echo ""
echo "➡️  检查关键库是否齐备"
MISSING=0
for lib in libavformat.a libavcodec.a libavutil.a libswresample.a; do
    if [ -f "$THEOS/vendor/lib/$lib" ]; then
        echo "   ✅ $lib"
    else
        echo "   ❌ 缺少 $lib"
        MISSING=1
    fi
done

echo ""
if [ "$MISSING" = "1" ]; then
    echo "⚠️  有缺失，请检查 your ffmpeg 构建设置是否包含了 swresample。" >&2
else
    echo "✅ 完成。现在可以运行： VCAM_ENABLE_OBS=1 ./scripts/build.sh"
fi

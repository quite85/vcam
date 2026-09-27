#!/usr/bin/env bash
# ============================================================================
#  scripts/make-icon.sh —— 生成 CydiaIcon.png 与 depiction 用的图标
#
#  需要 ImageMagick（convert / magick）或 macOS 自带的 sips。
#  没有工具时会创建一个纯色 PNG 占位（Sileo 能正常显示，只是不好看）。
# ============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT_DIR/repo/icons"
mkdir -p "$OUT_DIR"

SIZE="${1:-256}"
TARGET="$OUT_DIR/vcam.png"

if command -v magick >/dev/null 2>&1; then
    magick -size ${SIZE}x${SIZE} xc:'#101418' \
        -fill '#4da3ff' -draw "roundrectangle 12,12 $((SIZE-12)),$((SIZE-12)) 28,28" \
        -fill white -pointsize $((SIZE/4)) -gravity center -annotate +0+0 'VCam' \
        "$TARGET"
elif command -v convert >/dev/null 2>&1; then
    convert -size ${SIZE}x${SIZE} xc:'#101418' \
        -fill '#4da3ff' -draw "roundrectangle 12,12 $((SIZE-12)),$((SIZE-12)) 28,28" \
        -fill white -pointsize $((SIZE/4)) -gravity center -annotate +0+0 'VCam' \
        "$TARGET"
elif command -v python3 >/dev/null 2>&1; then
    python3 - "$TARGET" "$SIZE" <<'PY'
import struct, sys, zlib
path, size = sys.argv[1], int(sys.argv[2])
w = h = size
# 生成一个深色底 + 中间浅蓝方块的简单 PNG
rows = bytearray()
for y in range(h):
    rows.append(0)
    for x in range(w):
        if size*0.15 < x < size*0.85 and size*0.15 < y < size*0.85:
            rows += bytes((0x4d, 0xa3, 0xff))
        else:
            rows += bytes((0x10, 0x14, 0x18))
def chunk(t, d):
    c = t + d
    return struct.pack('>I', len(d)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
png = b'\x89PNG\r\n\x1a\n'
png += chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
png += chunk(b'IDAT', zlib.compress(bytes(rows), 9))
png += chunk(b'IEND', b'')
open(path, 'wb').write(png)
print(f"✅ 已生成 {path} ({w}x{h})")
PY
    exit 0
else
    echo "⚠️  没有 ImageMagick / python3，无法生成图标。" >&2
    echo "    请手工放一张 256x256 PNG 到 $TARGET" >&2
    exit 1
fi

# Cydia / Sileo 源列表图标（放在源根目录）
cp -f "$TARGET" "$ROOT_DIR/repo/CydiaIcon.png"
# 精选横幅（1600x600 比较合适）
if command -v magick >/dev/null 2>&1; then
    magick -size 1600x600 xc:'#0b1220' \
        -fill '#4da3ff' -pointsize 160 -gravity center -annotate +0-40 'VCam' \
        -fill '#9ecbff' -pointsize 56 -gravity center -annotate +0+90 \
        'iOS 15 - 16.6.1 · 系统级虚拟相机' \
        "$OUT_DIR/vcam_banner.png"
elif command -v convert >/dev/null 2>&1; then
    convert -size 1600x600 xc:'#0b1220' \
        -fill '#4da3ff' -pointsize 160 -gravity center -annotate +0-40 'VCam' \
        -fill '#9ecbff' -pointsize 56 -gravity center -annotate +0+90 \
        'iOS 15 - 16.6.1 · 系统级虚拟相机' \
        "$OUT_DIR/vcam_banner.png"
fi

echo "✅ 图标完成："
ls -lh "$OUT_DIR" "$ROOT_DIR/repo/CydiaIcon.png"

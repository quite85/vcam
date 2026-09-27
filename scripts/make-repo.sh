#!/usr/bin/env bash
# ============================================================================
#  scripts/make-repo.sh —— 生成可直接被 Sileo 订阅的 APT 源
#
#  做的事：
#    1) 把 packages/*.deb 拷到 repo/debs/
#    2) dpkg-scanpackages -m debs /dev/null > Packages
#       （-m = multi-version，允许多个架构/版本的 deb 同时存在）
#    3) 为每个条目计算并写入 Size / MD5sum / SHA256
#       —— 注意：dpkg-scanpackages 在 Debian 系上会自动加这些字段，
#          但如果用 macOS 的 dpkg（brew 版）可能不加，所以脚本会兜底补算。
#    4) gzip -kc → Packages.gz，可选 bzip2 → Packages.bz2
#    5) 生成/更新 Release 文件（含原文的 MD5Sum / SHA256 校验段）
#
#  用法：
#    ./scripts/make-repo.sh
#    ./scripts/make-repo.sh --serve        # 额外用 python3 -m http.server 预览
#    DOMAIN=repo.example.com ./scripts/make-repo.sh
# ============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$ROOT_DIR/repo"
DEBS_DIR="$REPO_DIR/debs"
PKG_DIR="$ROOT_DIR/packages"

# ---- 域名与源信息（改这里，或通过环境变量传入）----
# GitHub Pages 部署时：仓库名 vcam → 基地址 https://<用户名>.github.io/vcam
# 所以 DOMAIN=<用户名>.github.io、REPO_PATH=/vcam
DOMAIN="${DOMAIN:-quite85.github.io}"       # 换成自己的域名时改这里，例如 repo.quite85.com
REPO_PATH="${REPO_PATH:-/vcam}"             # 若放在网站根目录，改成 ""
ORIGIN="${ORIGIN:-VCam Repo}"
LABEL="${LABEL:-VCam Repo}"
DESCRIPTION="${DESCRIPTION:-iOS 15.0-16.6.1 系统级虚拟相机 + 虚拟麦克风}"
SUITE="${SUITE:-stable}"
CODENAME="${CODENAME:-ios}"
REPO_VERSION="${REPO_VERSION:-1.0}"
ARCHS="${ARCHS:-iphoneos-arm iphoneos-arm64 iphoneos-arm64e}"

BASE_URL="https://${DOMAIN}${REPO_PATH}"
# 处理 REPO_PATH 为空的情况
BASE_URL="${BASE_URL%/}"

echo "=============================================================="
echo " 生成 APT 源"
echo "   源地址   : $BASE_URL"
echo "   本地目录 : $REPO_DIR"
echo "=============================================================="

# ---- 依赖检查 ----
SCANPACKAGES=""
for cand in dpkg-scanpackages /usr/bin/dpkg-scanpackages /usr/local/bin/dpkg-scanpackages; do
    if command -v "$cand" >/dev/null 2>&1; then SCANPACKAGES="$cand"; break; fi
done
if [ -z "$SCANPACKAGES" ]; then
    cat >&2 <<'EOF'
❌ 找不到 dpkg-scanpackages。
   安装方式：
     Debian/Ubuntu : sudo apt install dpkg-dev
     macOS (brew)  : brew install dpkg
     Windows       : 用 WSL，或 Docker：
                     docker run --rm -v "$PWD:/w" -w /w debian:bookworm \
                       bash -c "apt update && apt install -y dpkg-dev && ./scripts/make-repo.sh"
   也可以用 dpkg-deb 手动生成（脚本已内置 fallback，见下）。
EOF
    if command -v dpkg-deb >/dev/null 2>&1; then
        echo "➡️  检测到 dpkg-deb，使用内置 fallback 生成 Packages。"
        SCANPACKAGES="__fallback__"
    else
        exit 1
    fi
fi

mkdir -p "$DEBS_DIR" "$REPO_DIR/depiction" "$REPO_DIR/icons"

# ---- 0) 软件源图标 ----
# Sileo 会请求源根目录下的 CydiaIcon.png 作为源列表图标；
# 缺失只会让图标不显示（不影响安装），但补齐体验更好。
# 仓库里已提交一份（由 scripts/make-icon.ps1 生成），
# 若不存在则尝试用 make-icon.sh 现场生成。
if [ ! -f "$REPO_DIR/CydiaIcon.png" ]; then
    echo "CydiaIcon.png 缺失，尝试生成…"
    bash "$(dirname "${BASH_SOURCE[0]}")/make-icon.sh" 256 >/dev/null 2>&1 || true
fi
if [ -f "$REPO_DIR/CydiaIcon.png" ]; then
    echo "源图标: CydiaIcon.png（$(wc -c < "$REPO_DIR/CydiaIcon.png" | tr -d ' ') 字节）"
else
    echo "⚠️  源图标缺失（不影响安装，只是 Sileo 源列表没有自定义图标）"
fi

# ---- 1) 拷贝 deb ----
# ⚠️ 先把 debs/ 清空再拷贝。
#    不清的话，上一次构建留下的、本轮已不再生成的 deb 会一直躺在 debs/ 里；
#    虽然不会进 Packages（scanpackages 只扫存在的文件），
#    但会让 debs/ 越堆越多、也容易在排查时看错"到底发布了哪些包"。
rm -f "$DEBS_DIR"/*.deb 2>/dev/null || true

shopt -s nullglob
DEBS=("$PKG_DIR"/*.deb)
if [ ${#DEBS[@]} -eq 0 ]; then
    echo "❌ $PKG_DIR 里没有 .deb。请先运行 ./scripts/build.sh" >&2
    exit 1
fi
for d in "${DEBS[@]}"; do
    cp -f "$d" "$DEBS_DIR/"
    echo "  + $(basename "$d")"
done
echo "  （debs/ 共 $(ls -1 "$DEBS_DIR"/*.deb 2>/dev/null | wc -l | tr -d ' ') 个 deb）"

cd "$REPO_DIR"

# ---- 2) 生成 Packages ----
echo ""
echo "➡️  生成 Packages …"
if [ "$SCANPACKAGES" = "__fallback__" ]; then
    : > Packages
    for deb in debs/*.deb; do
        dpkg-deb -f "$deb" >> Packages
        # dpkg-deb -f 输出 Package/Version/Architecture/... 但不含 Filename/Size/校验
        printf 'Filename: %s\n' "$deb" >> Packages
        printf 'Size: %s\n' "$(stat -c%s "$deb" 2>/dev/null || stat -f%z "$deb")" >> Packages
        printf 'SHA256: %s\n' "$(sha256sum "$deb" 2>/dev/null | awk '{print $1}' \
            || shasum -a 256 "$deb" | awk '{print $1}')" >> Packages
        printf 'MD5sum: %s\n' "$(md5sum "$deb" 2>/dev/null | awk '{print $1}' \
            || md5 -q "$deb")" >> Packages
        printf '\n' >> Packages
    done
else
    "$SCANPACKAGES" -m debs /dev/null > Packages
fi

# ---- 3) 兜底补算 Size / MD5sum / SHA256 ----
# 为什么必须补：某些 dpkg 版本 / 手工维护的 Packages 会缺这些字段，
# Sileo 会直接报"哈希校验失败"或"文件大小不匹配"。
if command -v python3 >/dev/null 2>&1; then
python3 - <<'PY'
import hashlib, os, re, sys

path = "Packages"
with open(path, "r", encoding="utf-8", errors="replace") as f:
    blocks = f.read().split("\n\n")

out = []
for blk in blocks:
    if not blk.strip():
        continue
    lines = [l for l in blk.split("\n") if l.strip()]
    fields = {}
    order = []
    for l in lines:
        if ":" not in l:
            order.append((l, None))
            continue
        k, v = l.split(":", 1)
        fields[k.strip()] = v.strip()
        order.append((k.strip(), v.strip()))

    fn = fields.get("Filename", "")
    if not fn:
        # 没有 Filename 就原样输出
        out.append("\n".join(l for l, _ in order))
        continue
    local = fn.lstrip("./")
    if not os.path.exists(local):
        # 也试试 repo 相对路径
        alt = os.path.join(os.path.dirname(path), local)
        if os.path.exists(alt):
            local = alt
        else:
            sys.stderr.write(f"⚠️  Packages 里引用了不存在的文件: {fn}\n")
            out.append("\n".join(l for l, _ in order))
            continue

    size = os.path.getsize(local)
    sha = hashlib.sha256()
    md5 = hashlib.md5()
    with open(local, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            sha.update(chunk)
            md5.update(chunk)

    fields["Filename"] = fn
    fields["Size"] = str(size)
    fields["SHA256"] = sha.hexdigest()
    fields["MD5sum"] = md5.hexdigest()

    # 输出顺序：先保留原有键顺序，再补齐缺失的键
    seen = set()
    final = []
    for k, _ in order:
        if k is None:
            final.append("")
            continue
        if k in seen:
            continue
        seen.add(k)
        if k in fields:
            final.append(f"{k}: {fields[k]}")
    for k in ("Filename", "Size", "MD5sum", "SHA256"):
        if k not in seen and k in fields:
            final.append(f"{k}: {fields[k]}")
    out.append("\n".join(final))

with open(path, "w", encoding="utf-8") as f:
    f.write("\n\n".join(out) + "\n")
print(f"✅ 已为 {len([b for b in out if b.strip()])} 个条目校验 Size/MD5sum/SHA256")
PY
else
    echo "⚠️  没有 python3，跳过校验字段补算（如果 dpkg-scanpackages 已生成则可忽略）"
fi

# ---- 4) 压缩 ----
echo "➡️  压缩 Packages …"
gzip -9 -kc Packages > Packages.gz
if command -v bzip2 >/dev/null 2>&1; then
    bzip2 -9 -kc Packages > Packages.bz2
    echo "  + Packages.bz2"
fi
# 如果系统有 xz 也可以加一份（新版 APT 会优先用 xz）
if command -v xz >/dev/null 2>&1; then
    xz -9 -kc Packages > Packages.xz
    echo "  + Packages.xz"
fi

# ---- 5) 生成 Release ----
echo "➡️  生成 Release …"
{
    echo "Origin: $ORIGIN"
    echo "Label: $LABEL"
    echo "Suite: $SUITE"
    echo "Version: $REPO_VERSION"
    echo "Codename: $CODENAME"
    echo "Architectures: $ARCHS"
    echo "Components: main"
    echo "Description: $DESCRIPTION"
    echo "Support: ${SUPPORT_URL:-https://${DOMAIN}}"
    echo "Depiction: ${BASE_URL}/depiction/vcam.html"
    echo "SileoDepiction: ${BASE_URL}/depiction/vcam.json"
    echo "Date: $(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S UTC')"
    echo "MD5Sum:"
    for f in Packages Packages.gz Packages.bz2 Packages.xz; do
        [ -f "$f" ] || continue
        sz=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f")
        if command -v md5sum >/dev/null 2>&1; then
            h=$(md5sum "$f" | awk '{print $1}')
        else
            h=$(md5 -q "$f")
        fi
        printf " %s %16s %s\n" "$h" "$sz" "$f"
    done
    echo "SHA256:"
    for f in Packages Packages.gz Packages.bz2 Packages.xz; do
        [ -f "$f" ] || continue
        sz=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f")
        if command -v sha256sum >/dev/null 2>&1; then
            h=$(sha256sum "$f" | awk '{print $1}')
        else
            h=$(shasum -a 256 "$f" | awk '{print $1}')
        fi
        printf " %s %16s %s\n" "$h" "$sz" "$f"
    done
} > Release

# ---- 6) 清理 Theos 原始名字的重复 deb（避免用户装到没有架构标记的包）----
# 只保留带 -rootful / -rootless 后缀的
find "$REPO_DIR/debs" -maxdepth 1 -name '*.deb' ! -name '*-rootful.deb' ! -name '*-rootless.deb' -print0 2>/dev/null |
while IFS= read -r -d '' f; do
    echo "  - 移除无架构标记的重复包: $(basename "$f")"
    rm -f "$f"
done || true

echo ""
echo "=============================================================="
echo " ✅ 源已生成"
echo "    本地预览: cd repo && python3 -m http.server 8000"
echo "    用户添加: $BASE_URL"
echo ""
echo " 目录内容："
ls -lh "$REPO_DIR" | sed 's/^/   /'
echo "=============================================================="

# ---- 可选：本地预览 ----
if [ "${1:-}" = "--serve" ]; then
    PORT="${PORT:-8000}"
    echo ""
    echo "🌐 本地预览： http://127.0.0.1:${PORT}/"
    echo "   iPhone 上把源地址填成 http://<你的电脑IP>:${PORT}/ 即可测试"
    echo "   （正式使用请务必用 HTTPS，Sileo 对自签/自建 HTTP 源会报错）"
    cd "$REPO_DIR" && python3 -m http.server "$PORT"
fi

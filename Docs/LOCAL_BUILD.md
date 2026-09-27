# 本地 iOS 交叉编译环境（WSL）

> 目的：在 Windows 上验证 Theos 工程能否编译通过，不必每次都推 CI。
> 位置：WSL Ubuntu 26.04，root 用户，Theos 在 `/root/theos`。

## 已完成的搭建

```bash
# 1) 依赖
apt-get install -y git make clang lld llvm fakeroot dpkg-dev \
    libssl-dev libxml2-dev libz3-dev pkg-config zlib1g-dev \
    build-essential perl curl xz-utils

# 2) Theos
git clone --recursive --depth 1 https://github.com/theos/theos.git /root/theos

# 3) iOS SDK
curl -L -o /tmp/sdk.tar.xz \
  https://github.com/theos/sdks/releases/download/master-146e41f/iPhoneOS16.5.sdk.tar.xz
tar -xJf /tmp/sdk.tar.xz -C /root/theos/sdks

# 4) 补 vendor（submodule 在 WSL 里拉不下来，用 tarball 代替）
curl -sL https://codeload.github.com/theos/headers/tar.gz/refs/heads/master \
  | tar -xz -C /root/theos/vendor/include --strip-components=1
curl -sL https://codeload.github.com/theos/lib/tar.gz/refs/heads/master \
  | tar -xz -C /root/theos/vendor/lib --strip-components=1
# Theos 的规则要求这两个 .git 存在，否则 before-all 直接报错
mkdir -p /root/theos/vendor/include/.git /root/theos/vendor/lib/.git
```

## 关键坑（一共 6 个，全部踩过）

| # | 现象 | 原因 | 修法 |
|---|---|---|---|
| 1 | `make package requires dm.pl` | Theos 用 `dm.pl` 打包，Ubuntu 源里没有 | 从 theos/dm.pl 下载放到 `/usr/local/bin` |
| 2 | `toolchain/linux/iphone/bin/clang: No such file` | Linux 上 Theos 不自带工具链 | 建目录，把系统的 clang/ld/ar/nm/strip 软链进去 |
| 3 | `unrecognised emulation mode: llvm` | clang 在 Apple 目标下默认 `-fuse-ld=llvm`，找不到就回退 GNU ld | 用包装脚本作 `TARGET_LD`：`exec clang -fuse-ld=lld "$@"` |
| 4 | `vendor/include and/or vendor/lib directories are missing` | rules.mk 第 84 行要求两个目录下都有 `.git` | `mkdir -p vendor/{include,lib}/.git` |
| 5 | `library not found for -lroot_oldabi` | rootless 构建需要 theos/lib 里的库 | 把 theos/lib 全部内容复制进 `vendor/lib` |
| 6 | `strip: file format not recognized` | GNU strip 不认 Mach-O | `apt install llvm`，把 strip/ar/nm 等链到 llvm-* 版本 |

## 已知限制

- **arm64e 无法链接**：Ubuntu clang 21 生成的 arm64e 目标文件与 `ld64.lld` 不兼容，
  报 `INVALID relocation has width 8 bytes, but must be 0 bytes at __DATA,__cfstring`。
  用 `ARCHS=arm64` 单架构可以完整编过，产物是合法 Mach-O arm64 dylib。
  这只是**本地验证**的限制 —— CI 用 Apple clang，arm64e 一直正常。
- `ldid` 在 Ubuntu 源里不存在。用包装脚本代替（越狱设备不校验签名）。
- `VCam.plist` / filter 名字必须与 `TWEAK_NAME` 一致，否则 stage 阶段报
  `You are missing a filter property list`。

## 标准构建命令

```bash
export THEOS=/root/theos
export PATH="$THEOS/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
cd <工程目录>
make package FINALPACKAGE=1 ARCHS=arm64 THEOS_PACKAGE_SCHEME=rootless \
     TARGET_LD=/usr/local/bin/vcam-link
```

## 验证脚本

```bash
# Logos 预处理 + clang 语法检查（不依赖工具链完整性）
perl $THEOS/vendor/logos/bin/logos.pl Tweak.x > /tmp/Tweak.m && \
clang -fsyntax-only -target arm64-apple-ios15.0 -isysroot $THEOS/sdks/iPhoneOS16.5.sdk \
      -fobjc-arc -I. -ICore -IUI -IMedia -IMic /tmp/Tweak.m
```
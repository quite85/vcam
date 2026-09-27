---
title: 编译期踩坑记录（CI 实战）
---
# 编译期踩坑记录

这份文档记录 VCam 在 GitHub Actions（macos-latest）上首次编译时
实际遇到的每一个坑、根因、以及修法，避免以后重复踩。

每一条都附了**原始错误信息**和**定位方法**，可以直接照着排查。

---

## 坑 1：Theos 不自带 iOS SDK

### 现象

```
编译两个 deb  →  exit code 1
```

日志里只有：

```
> Making all for library VCamCore…
```

然后就没有了，或者直接报：

```
"You do not have any SDKs in /Users/runner/theos/sdks."
```

### 根因

Theos 的 SDK 查找逻辑（`makefiles/targets/_common/darwin_head.mk` 第 107-121 行）：

```make
_UNSORTED_SDKS := $(patsubst $(THEOS_SDKS_PATH)/iphoneos%.sdk,%,$(wildcard $(THEOS_SDKS_PATH)/iphoneos*.sdk))
ifneq ($(THEOS_PLATFORM_SDK_ROOT),)
    _UNSORTED_SDKS += ... Xcode 内部 SDK 目录 ...
endif

ifeq ($(words $(_UNSORTED_SDKS)),0)
before-all::
    $(ERROR_BEGIN)"You do not have any SDKs in $(THEOS_SDKS_PATH)."$(ERROR_END)
endif
```

它只查两个地方：

1. `$THEOS/sdks/`（Theos 自带 SDK，**但仓库里没有，需要单独装**）
2. Xcode 内部的 `Platforms/iPhoneOS.platform/Developer/SDKs/`

**GitHub 的 `macos-latest` 运行器两处都没有 iPhoneOS SDK** ——
Xcode 只带 macOS SDK 和 iOS **模拟器** SDK，真机 SDK 不安装。

### 修法

在编译前从官方 `theos/sdks` release 下载 SDK 到 `$THEOS/sdks/`：

```yaml
- name: 下载 iOS SDK 到 $THEOS/sdks
  run: |
    set -e
    export THEOS="$HOME/theos"
    mkdir -p "$THEOS/sdks"
    SDK="iPhoneOS${VCAM_SDK_VERSION}.sdk"
    URL="https://github.com/theos/sdks/releases/download/${THEOS_SDKS_TAG}/${SDK}.tar.xz"
    curl -fL --retry 3 -o /tmp/${SDK}.tar.xz "$URL"
    tar -xJf /tmp/${SDK}.tar.xz -C "$THEOS/sdks"
    [ -d "$THEOS/sdks/${SDK}" ] || { echo "::error::SDK 解压失败"; exit 1; }
```

可用的 SDK 版本（`theos/sdks` release `master-146e41f`）：

| SDK | 大小 |
| --- | --- |
| iPhoneOS16.5 | 16.6 MB ← 本项目使用 |
| iPhoneOS15.6 | 15.2 MB |
| iPhoneOS14.5 | 12.2 MB |
| iPhoneOS13.7 | 8.2 MB |

然后在 Makefile 里让 Theos 精确定位到它：

```make
ifneq ($(VCAM_SDK_VERSION),)
  export SDKVERSION = $(VCAM_SDK_VERSION)
endif
```

**注意**：本机（macOS + Xcode）开发时**不要**设这个变量，
Theos 会自动 fallback 到 Xcode 里的 SDK。

---

## 坑 2：macOS 自带 bash 3.2 把空数组当未定义变量

### 现象

```
./scripts/build.sh: line 110: scheme_arg[@]: unbound variable
❌ rootful 打包失败
build.sh 退出码 = 1
```

**`make` 完全没有输出** —— 因为脚本在调用 make 之前就退出了。

### 根因

脚本用数组传可选的 make 参数：

```bash
set -euo pipefail
local -a scheme_arg=()
if [ -n "$scheme" ]; then scheme_arg=(THEOS_PACKAGE_SCHEME="$scheme"); fi
make package ... "${scheme_arg[@]}"
```

在 `set -u`（nounset）下：

| bash 版本 | `"${empty[@]}"` 的行为 |
| --- | --- |
| 4.4+（Linux、brew 装的 bash） | 安全展开为空，什么都不传 ✅ |
| **3.2（macOS 自带）** | 视为「未定义变量」，报 `unbound variable` 并退出 ❌ |

GitHub 的 `macos-latest` 运行器用的正是 **bash 3.2**。

### 修法

改成条件分支，不用数组：

```bash
if [ -n "$scheme" ]; then
    make package FINALPACKAGE=1 VCAM_ENABLE_OBS="$ENABLE_OBS" \
         THEOS_PACKAGE_SCHEME="$scheme" 2>&1 | tee "/tmp/vcam-build-$tag.log"
    local make_rc=${PIPESTATUS[0]}
else
    make package FINALPACKAGE=1 VCAM_ENABLE_OBS="$ENABLE_OBS" \
         2>&1 | tee "/tmp/vcam-build-$tag.log"
    local make_rc=${PIPESTATUS[0]}
fi
```

**教训**：写 CI 脚本时假设 bash 3.2。避免
`"${arr[@]}"`、`${var,,}`（小写转换）、`mapfile`、关联数组。

---

## 坑 3：`notify_register_check` 的 out_token 必须是 `int`

### 现象

```
Core/VCamStateStore.m:100:69: error: passing 'uint32_t *' (aka 'unsigned int *')
  to parameter of type 'int *' converts between pointers to integer types
  with different sign [-Werror,-Wpointer-sign]
    notify_register_check(kVCamNotificationStateChanged.UTF8String, &token);
```

### 根因

`notify.h` 的签名特别注意这一点：

```c
OS_EXPORT uint32_t notify_register_check(const char *name, int *out_token);
//       ^^^^^^^^ 返回值是 uint32_t          ^^^^^ 但参数是 int *
```

**返回值和参数的类型不一致**，很容易看错。我按返回值把局部变量
声明成了 `uint32_t`，于是 `-Wpointer-sign` 触发。

Theos 默认带 `-Werror`，警告直接升级为错误。

### 修法

```objc
int token = 0;   // 必须 int，不是 uint32_t
notify_register_check(kVCamNotificationStateChanged.UTF8String, &token);
```

**同类注意点**：Apple 有几个 API 存在「返回值类型 ≠ 出参类型」的情况，
写的时候要看头文件别靠猜。其它常见的是
`notify_register_dispatch`（同样是 `int *`）。

### 排查手法

这类错误只需要看编译日志的第一条 error，它会直接给出
「你的类型」和「头文件期望的类型」两行对照 —— 非常明确。

---

## 排查基础设施：失败时自动上传日志

为了不用靠截图/复制粘贴定位问题，`build.yml` 里加了两件事：

```yaml
- name: 编译两个 deb
  id: builddeb
  run: |
    set +e
    ./scripts/build.sh 2>&1 | tee /tmp/vcam-full-build.log
    RC=${PIPESTATUS[0]}
    echo "build.sh 退出码 = $RC" | tee -a /tmp/vcam-full-build.log
    for f in /tmp/vcam-build-rootful.log /tmp/vcam-build-rootless.log; do
      [ -f "$f" ] && { echo "" >> /tmp/vcam-full-build.log; cat "$f" >> /tmp/vcam-full-build.log; }
    done
    [ $RC -eq 0 ] || exit $RC

- name: 上传编译日志（仅失败时）
  if: failure()
  uses: actions/upload-artifact@v4
  with:
    name: vcam-build-logs
    path: /tmp/vcam-full-build.log
```

这样每次失败都会有一个 `vcam-build-logs` 制品，里面是**合并后的完整日志**
（build.sh 输出 + 两次变体的 make 输出）。

### 日志大小是个有用的信号

| 日志大小 | 含义 |
| --- | --- |
| ~450 字节 | `make` 根本没跑起来 → 检查 build.sh 自身（参数、环境检查） |
| ~1 KB | `make` 跑了但立刻失败 → 缺 SDK、缺少工具链 |
| > 4 KB | 进入真正的编译，看第一条 `error:` 即可 |

这个规律在本项目实际排查中三次都命中了。

---

## Logos 语法的本地预检（不需要 iOS SDK）

`Tweak.x` 经过 Logos 预处理器，它有自己的语法。好消息是
**Logos 是纯 perl 脚本，可以在 Windows 上本地跑**，不用装 SDK。

Windows 上跑通需要两个额外步骤：

1. **需要一个 perl** —— Git for Windows 自带（`C:\Program Files\Git\usr\bin\perl.exe`）
2. **缺 `Locale::Maketext::Simple` 模块** —— Git 的 perl 没带，
   而 `Getopt::Long` 依赖的 `Params::Check` 会 `use` 它。
   写一个最小 stub 即可（只用于本地预检，不进工程）。

然后：

```bash
# 把 Windows 路径转成 cygwin POSIX 路径（cygpath -u）
perl -I/tmp/perlstub /tmp/theos-logos/vendor/logos/bin/logos.pl Tweak.x > /tmp/out.m
```

本项目实测结果：

```
退出码: 0
stderr: （无输出 = 无警告无错误）
生成代码长度: 28915 字符
```

### Logos 生成器：MobileSubstrate vs internal

Logos 有两种生成器，**影响链接依赖**：

| 生成器 | 产物 | 链接依赖 |
| --- | --- | --- |
| `MobileSubstrate`（默认） | `MSHookMessageEx` | 会写入 `.linker_option "-framework CydiaSubstrate"` |
| `internal` | 纯 ObjC runtime（`class_replaceMethod` / `method_setImplementation`） | **无外部依赖** |

Theos 的选择逻辑（`makefiles/instance/tweak.mk` 第 12 行）：

```make
_LOCAL_LOGOS_DEFAULT_GENERATOR = $(or $($(THEOS_CURRENT_INSTANCE)_LOGOS_DEFAULT_GENERATOR),$(LOGOS_DEFAULT_GENERATOR),$(_THEOS_TARGET_LOGOS_DEFAULT_GENERATOR),MobileSubstrate)
```

注意 `darwin_head.mk` 第 23-24 行：`internal` **只在模拟器目标下是默认值**，
真机目标默认走 `MobileSubstrate`。

想切换成不依赖 substrate 的版本，在 Makefile 里加一行：

```make
LOGOS_DEFAULT_GENERATOR = internal
```

VCam 默认**不切换**，原因：Dopamine 的 ElleKit 自带 CydiaSubstrate
兼容层（`/var/jb/usr/lib/libsubstrate.dylib`），默认路径经过最多验证。
如果你的环境没有该兼容层、链接时报找不到 CydiaSubstrate，
打开这个开关即可。

---

## 总结：CI 首次编译的检查清单

按顺序排查，能覆盖 95% 的失败：

1. **`$THEOS/sdks/` 里有 iPhoneOS SDK 吗？** 没有 → 坑 1
2. **build.sh 用数组传参了吗？** 用了 → 坑 2（bash 3.2）
3. **有 `-Wpointer-sign` 报错吗？** 有 → 坑 3（检查 `notify_*` 出参类型）
4. **日志多大？** <1KB 说明没进编译，先查脚本本身
5. **`Tweak.x` 本地 Logos 预检过吗？** 没过 → 先跑上面的 perl 命令

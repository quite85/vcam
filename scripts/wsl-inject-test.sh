#!/usr/bin/env bash
# 针对性测试：监听 25 秒，看「设置」App 启动时是否被注入
set -u
export USBMUXD_SOCKET_ADDRESS=172.25.32.1:27016

echo "==============================================================="
echo " 监听 25 秒 —— 请现在打开「设置」App"
echo "==============================================================="
echo ""

TMP=/tmp/inject-test.log
rm -f "$TMP"

# 全量抓取（不过滤），事后本地分析，避免漏掉任何线索
timeout 25 idevicesyslog --no-colors > "$TMP" 2>&1

echo "抓取完成，原始 $(( $(stat -c%s "$TMP") / 1024 )) KB"
echo ""

echo "=== 1) 设置 App 是否启动 / 退出 ==="
grep -iE 'Preferences' "$TMP" | grep -iE 'launch|Launch|start|Start|exit|Exit|died|terminat|kill|suspend|resume|foreground' \
  | head -15 | cut -c1-180 | sed 's/^/  /'
echo "  （空 = 25 秒内设置 App 没被启动）"
echo ""

echo "=== 2) 任何 tweak 注入相关 ==="
grep -iE 'substrate|ellekit|mobileloader|tweakinject|dynamiclibrar|inject|dylib|MobileSubstrate' "$TMP" \
  | grep -viE 'injecting inherited' \
  | head -20 | cut -c1-180 | sed 's/^/  /'
echo "  （空 = 无注入痕迹）"
echo ""

echo "=== 3) 我们插件 ==="
R=$(grep -iE 'VirtualCamera|VCamStage1|vcamstage1' "$TMP" | head -10)
if [ -n "$R" ]; then echo "$R" | cut -c1-180 | sed 's/^/  /'; else echo "  （无）"; fi
echo ""

echo "=== 4) 崩溃 / 异常 ==="
R=$(grep -iE 'EXC_|SIGSEGV|SIGABRT|SIGKILL|SIGBUS|panic|has died|crash' "$TMP" | head -12)
if [ -n "$R" ]; then echo "$R" | cut -c1-180 | sed 's/^/  /'; else echo "  （无）"; fi
echo ""

echo "=== 5) 沙盒 / 权限拒绝 ==="
R=$(grep -iE 'deny|Sandbox|Operation not permitted|Permission denied' "$TMP" | head -12)
if [ -n "$R" ]; then echo "$R" | cut -c1-180 | sed 's/^/  /'; else echo "  （无）"; fi
echo ""

echo "=== 6) 本次出现的进程（前 25 个）==="
awk '{for(i=1;i<=NF;i++) if ($i ~ /\[[0-9]+\]:?$/) {gsub(/\[[0-9]+\]:?/,"",$i); print $i; break}}' "$TMP" \
  | sort -u | head -25 | sed 's/^/  /'

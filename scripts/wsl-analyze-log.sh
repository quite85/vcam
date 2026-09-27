#!/usr/bin/env bash
# 分析捕获到的日志，定位 Stage1 插件是否被注入
set -u
F=/root/vcam-logs/stage1-verify.log

if [ ! -f "$F" ]; then echo "日志文件不存在"; exit 1; fi

echo "=== 文件信息 ==="
echo "  大小: $(stat -c%s "$F") 字节"
echo "  行数: $(wc -l < "$F")"
echo "  范围:"
head -3 "$F" | sed 's/^/    /'
tail -2 "$F" | cut -c1-140 | sed 's/^/    /'

echo ""
echo "=== 1) 我们插件相关（VCamStage1 / VirtualCamera）==="
R=$(grep -iE 'VCamStage1|VirtualCamera|vcamstage1' "$F" | head -20)
if [ -n "$R" ]; then echo "$R" | cut -c1-175 | sed 's/^/  /'; else echo "  ❌ 无"; fi

echo ""
echo "=== 2) 注入框架相关（substrate / ellekit / dyld）==="
R=$(grep -iE 'substrate|ellekit|mobileloader|tweakinject|dyld|Library not loaded|image not found' "$F" | head -20)
if [ -n "$R" ]; then echo "$R" | cut -c1-175 | sed 's/^/  /'; else echo "  ❌ 无"; fi

echo ""
echo "=== 3) 含 Preferences 的行 ==="
R=$(grep -i 'Preferences' "$F" | head -15)
if [ -n "$R" ]; then echo "$R" | cut -c1-175 | sed 's/^/  /'; else echo "  ❌ 无"; fi

echo ""
echo "=== 4) 崩溃与异常 ==="
R=$(grep -iE 'crash|EXC_|SIGSEGV|SIGABRT|SIGKILL|SIGBUS|has died|terminating' "$F" | head -15)
if [ -n "$R" ]; then echo "$R" | cut -c1-175 | sed 's/^/  /'; else echo "  ❌ 无"; fi

echo ""
echo "=== 5) 沙盒拒绝 ==="
R=$(grep -iE 'deny|Sandbox' "$F" | head -12)
if [ -n "$R" ]; then echo "$R" | cut -c1-175 | sed 's/^/  /'; else echo "  ❌ 无"; fi

echo ""
echo "=== 6) 所有不同的进程名（看日志覆盖了哪些进程）==="
awk '{for(i=1;i<=NF;i++) if ($i ~ /^[a-zA-Z_][a-zA-Z0-9_]*\(/ || $i ~ /^[a-zA-Z_][a-zA-Z0-9_]*\[/) {print $i; break}}' "$F" \
  | sed 's/[\(\[]//' | sort -u | head -30 | sed 's/^/  /'

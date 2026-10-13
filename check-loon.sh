#!/bin/bash
# Loon 兼容性闸门：断言 7 张 AI-*.list 只含 Loon 支持的规则类型。
#
# 为什么 Loon 不另生成一套表：Loon 的规则语法与 Surge **同构** —— 实测 blackmatrix7
# 的 rule/Loon/<表>.list 与 rule/Surge/<表>.list 字节级一致（仅个别表因 Loon 不支持
# PROCESS-NAME 而少那几行）。所以 Loon **直接引用现有 AI-*.list 即可**，无需转换/副本。
# 本脚本守的是「以后别往表里加 Loon 不认的类型」——那会让 Loon 用户静默漏规则。
#
# Loon 支持的类型（依据：Loon 官方文档 nsloon.app/docs/Rule/* 全部 9 页 + Loon.app 自带
# example.conf + Loon 版真实规则集实测）：
#   域名：DOMAIN / DOMAIN-SUFFIX / DOMAIN-KEYWORD
#   HTTP：USER-AGENT / URL-REGEX
#   IP：IP-CIDR / IP-CIDR6 / IP-ASN / GEOIP
#   端口：SRC-PORT / DEST-PORT
#   协议：PROTOCOL
#   逻辑：AND / OR / NOT
# 不支持（Surge 有、Loon 没有）：PROCESS-NAME / PROCESS-PATH / SUB-RULE / RULE-SET（在文件里）
set -u
cd "$(dirname "$0")" || exit 1
fail=0

# Loon 支持的规则类型白名单（须列全 —— 漏一个合法类型会把正常规则误判为非法）
LOON_OK='DOMAIN|DOMAIN-SUFFIX|DOMAIN-KEYWORD|USER-AGENT|URL-REGEX|IP-CIDR|IP-CIDR6|IP-ASN|GEOIP|SRC-PORT|DEST-PORT|PROTOCOL|AND|OR|NOT'

TABLES="AI-CN AI-OpenAI AI-Claude AI-Gemini AI-Copilot AI-Jetbrains AI-Overseas-Others"
SRCDIR="surge"   # Surge 生成表所在目录（Loon 直接引用这批表，无副本）

for t in $TABLES; do
  f="$SRCDIR/$t.list"
  [ -f "$f" ] || { echo "✗ $f 不存在"; fail=1; continue; }
  # 取所有非注释、非空行的规则类型（逗号前那段）
  bad=$(grep -vE '^[[:space:]]*(#|$)' "$f" \
        | sed -E 's/^([A-Z][A-Z0-9-]*),.*/\1/' \
        | grep -vE "^($LOON_OK)$" | sort -u)
  if [ -n "$bad" ]; then
    echo "✗ $f: 含 Loon 不支持的类型："; echo "$bad" | sed 's/^/    /'; fail=1
  else
    n=$(grep -cvE '^[[:space:]]*(#|$)' "$f")
    echo "✓ $f: $n 条，类型全部 Loon 兼容"
  fi
done

# 反向确认：Loon 支持列表里，URL-REGEX（Surge 独有、Clash 丢弃的那条）Loon 是认的，
# 所以 Loon 端不像 Clash 要丢规则 —— 这里点名，免得有人「对齐 Clash」把它删了。
if grep -qE '^[[:space:]]*URL-REGEX,' "$SRCDIR"/AI-*.list 2>/dev/null; then
  echo "ℹ 含 URL-REGEX（Loon 支持、需配 MITM；Clash 端会丢弃）—— Loon 无损失。"
fi

if [ "$fail" = 0 ]; then
  echo "✓ Loon 兼容性校验通过（7 张表均可被 Loon 直接引用）"
else
  echo "✗ Loon 兼容性校验失败"
fi
exit $fail

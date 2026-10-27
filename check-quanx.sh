#!/bin/bash
# 校验 to-quanx.sh 的产物：quanx/*.list 必须是合法、非空、且与源表逐条对得上的 QX 远程过滤表。
#
# 依赖：无（纯 grep/awk —— 故意不用 python，让这道闸比 check-clash.sh 更轻）。
#
# 守的四件事：
#   1) 类型白名单：类型 ∈ QX filter 支持集（host/host-suffix/host-keyword/ip-cidr/
#      ip6-cidr/ip-asn，大小写均可）；值非空；三段式（type, value, policy）。
#      「类型拼错」很危险：QX 对远程表里的坏行会告警甚至拒载。
#   2) 数量对账：QX 表规则行数 == 源表规则数 − 被丢弃的不支持类型条数。
#      「静默丢行」比「格式错」更危险 —— 覆盖面悄悄缩水。
#   3) IP 规则对账：源表里的 IP-CIDR/IP-CIDR6/IP-ASN 值必须逐条出现在 QX 表
#      （值不变，仅类型改名 + 剥 no-resolve）—— 防 IP 网段被转换器悄悄丢掉
#      （Anthropic/OpenAI 自有网段就这几条，丢了没感知）。
#   4) 策略段：AI-CN 全部 direct、海外表全部 proxy —— 行内策略写错会让用户流量
#      在不配 force-policy 时走错方向（国内 AI 被代理、海外 AI 被直连）。
set -u
cd "$(dirname "$0")" || exit 1
fail=0

# 源表里被 to-quanx.sh 丢弃的类型（QX filter 不支持）。对账时按「源行数 − 丢弃数」。
# URL-REGEX 目前仅 Gemini 1 条；其余是 Surge 独有、QX filter 无对应物的类型（备用）。
# 注意 USER-AGENT/GEOIP 不在丢弃集 —— QX filter 认它们（官方 sample.conf [filter_local]
# 有 user-agent/geoip），转换器会映射值并替换 policy 段（见 to-quanx.sh）。
DROP_TYPES='URL-REGEX|PROCESS-NAME|PROCESS-PATH|RULE-SET|SUB-RULE|SRC-IP|SUBNET|DEST-PORT|PROTOCOL|DOMAIN-SET|DOMAIN-WILDCARD|IP6-CIDR-SOURCE|AND|OR|NOT'

TABLES="AI-CN AI-OpenAI AI-Claude AI-Gemini AI-Copilot AI-Jetbrains AI-Overseas-Others Google-Supplement"

for t in $TABLES; do
  case "$t" in
    Google-Supplement) src="$t.list" ;;
    *)                 src="surge/$t.list" ;;
  esac
  dst="quanx/$t.list"
  [ -f "$src" ] || { echo "✗ 源表 $src 不存在"; fail=1; continue; }
  [ -f "$dst" ] || { echo "✗ $dst 不存在（to-quanx.sh 是否跑过？）"; fail=1; continue; }

  # ── 1) 类型白名单 + 三段式 + 值非空 ──────────────────────
  # 值段要求：逗号后至少 1 个非空白字符（UA 值可含空格，故只约束首字符），再跟 policy 段。
  bad=$(grep -vE '^[[:space:]]*(#|$)' "$dst" \
        | grep -viE '^[[:space:]]*(host|host-suffix|host-keyword|user-agent|geoip|ip-cidr|ip6-cidr|ip-asn)[[:space:]]*,[[:space:]]*[^,[:space:]][^,]*,' \
        | grep -vE '^[[:space:]]*$' || true)
  # 上面那条正则允许「type」后跟可选空格再逗号（转换器产出 "type, value, policy"）；
  # 这里再兜一层：任何含 no-resolve 残留的行也算坏（转换器应已剥掉）。
  bad4=$(grep -vE '^[[:space:]]*(#|$)' "$dst" | grep -iE 'no-resolve' || true)
  if [ -n "$bad" ] || [ -n "$bad4" ]; then
    echo "✗ $dst: 含非法规则行（类型不在 QX filter 支持集 / 缺 policy 段 / no-resolve 残留）："
    { [ -n "$bad" ] && printf '%s\n' "$bad"; [ -n "$bad4" ] && printf '%s\n' "$bad4"; } | head -5 | sed 's/^/    /'
    fail=1
  fi

  # ── 2) 数量对账 ─────────────────────────────────────────
  src_n=$(grep -cvE '^[[:space:]]*(#|$)' "$src")
  drop_n=$(grep -vE '^[[:space:]]*(#|$)' "$src" | grep -cE "^($DROP_TYPES)," || true)
  qx_n=$(grep -cvE '^[[:space:]]*(#|$)' "$dst")
  if [ "$qx_n" -ne $((src_n - drop_n)) ]; then
    echo "✗ $dst: 对账失败 QX=$qx_n 源=$src_n 丢弃=$drop_n"
    fail=1
  fi

  # ── 3) IP 规则逐条对账（值必须原样保留）──────────────────
  # 源：IP-CIDR,x/no-resolve → QX: ip-cidr, x。取 QX 表的 (类型, 值) 集合比对。
  # 值含 . / : 等正则元字符 → 用 awk 全等比对而非 grep -E（避免 . 被当通配符假阳性）。
  miss=$(awk -F, '
    function norm(v){ gsub(/[ \t]/,"",v); return tolower(v) }
    /^IP-(CIDR|CIDR6|ASN),/ && !/^#/ {
      t=$1; v=$2; sub(/[ \t]+$/,"",v)
      if (t=="IP-CIDR") q="ip-cidr"
      else if (t=="IP-CIDR6") q="ip6-cidr"
      else q="ip-asn"
      print q " " norm(v)
    }' "$src" | sort -u)
  have=$(awk -F, '
    function norm(v){ gsub(/[ \t]/,"",v); return tolower(v) }
    !/^#/ && /^[[:space:]]*(ip-cidr|ip6-cidr|ip-asn)[[:space:]]*,/ {
      # 先取 q 再动 $0 —— 对 $0 的 sub() 会触发字段重新切分，$1 随即变成值
      q=$1; sub(/[ \t]/,"",q)
      print q " " norm($2)
    }' "$dst" | sort -u)
  while IFS= read -r want; do
    [ -z "$want" ] && continue
    printf '%s\n' "$have" | grep -qxF "$want" || { echo "✗ $dst: 源表的 IP 规则丢了: $want"; fail=1; }
  done <<< "$miss"

  # ── 4) 行内策略方向 ─────────────────────────────────────
  if [ "$t" = "AI-CN" ]; then
    wrong=$(grep -vE '^[[:space:]]*(#|$)' "$dst" | grep -viE ', *direct[[:space:]]*$' || true)
  else
    wrong=$(grep -vE '^[[:space:]]*(#|$)' "$dst" | grep -viE ', *proxy[[:space:]]*$' || true)
  fi
  if [ -n "$wrong" ]; then
    echo "✗ $dst: 行内策略方向错误（应为 $([ "$t" = "AI-CN" ] && echo direct || echo proxy)）："
    printf '%s\n' "$wrong" | head -3 | sed 's/^/    /'
    fail=1
  fi

  [ "$fail" = 0 ] && echo "✓ quanx/$t.list: $qx_n 条（源 $src_n，丢弃 $drop_n）"
done

if [ "$fail" = 0 ]; then
  echo "✓ QX 规则集校验通过（8 张表）"
else
  echo "✗ QX 规则集校验失败"
fi
exit $fail

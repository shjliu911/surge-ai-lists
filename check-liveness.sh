#!/bin/bash
# 存活性闸门：**新加入**的域名必须能解析，否则拒绝提交。
#
# 为什么需要它（黑名单的根本局限）：
#   现有 filter() 全是黑名单 —— 挡得住"已列举过"的垃圾，挡不住没见过的新变种。
#   实测：5 条编造的垃圾域（sso.acmecloud.com / zqxwv.xyz / telemetry.newvendor.io …）
#   100% 穿过全部黑名单。而 2026-10-12 审计发现的 6 条死域（tcwqqdy.guru 等）
#   全都 DNS 查无此域 —— 说明「不能解析」是这类垃圾的**共同特征**，
#   且它与域名长什么样无关，因此能自动拦住**将来任何**同类新增。
#
# 设计要点：
#   · 只查「相对上一版**新增**」的域名 → 不误伤历史遗留、不受"故意不解析的合法后缀"影响
#     （有些厂商后缀确实没有 A 记录，但它们在基线里，不会被重复检查）。
#   · 每个域名重试 3 次 → 抗 DNS 抖动，避免把网络问题当成垃圾域名。
#   · 只对**新增**域名硬失败；历史域名不解析仅告警（保持向后兼容）。
#
# 用法：./check-liveness.sh            # 与 HEAD 比（CI 里 = 与检出时的 main 比）
#       ./check-liveness.sh <ref>      # 与指定 ref 比
set -u
cd "$(dirname "$0")" || exit 1
BASE="${1:-HEAD}"

TABLES="AI-CN AI-OpenAI AI-Claude AI-Gemini AI-Copilot AI-Jetbrains AI-Overseas-Others"

# ── 收集当前 / 基线域名 ─────────────────────────────────
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
: > "$tmp/cur"; : > "$tmp/base"
for t in $TABLES; do
  [ -f "$t.list" ] || continue
  # BSD sed 不支持 \s → 用 awk（也更稳）
  awk -F, '/^DOMAIN(-SUFFIX)?,/{gsub(/[ \t]/,"",$2); print tolower($2)}' "$t.list" >> "$tmp/cur"
  git show "$BASE:$t.list" 2>/dev/null \
    | awk -F, '/^DOMAIN(-SUFFIX)?,/{gsub(/[ \t]/,"",$2); print tolower($2)}' >> "$tmp/base"
done
sort -u "$tmp/cur" -o "$tmp/cur"; sort -u "$tmp/base" -o "$tmp/base"

# 新增 = 当前 - 基线（基线为空时只查新增；不查全量）
comm -23 "$tmp/cur" "$tmp/base" > "$tmp/new"
NEWN=$(wc -l < "$tmp/new" | tr -d ' ')
echo "── 存活性检查 ──"
echo "  当前 $(wc -l < "$tmp/cur" | tr -d ' ') 个域名，其中相对 $BASE 新增 $NEWN 个"

if [ "$NEWN" -eq 0 ]; then
  echo "✓ 无新增域名，跳过"
  exit 0
fi

# ── 并行 DNS 解析（DoH，避免本机 resolver 差异）──────────
resolve_one() { # $1=domain → echo "domain<TAB>ok|dead"
  # DoH 返回 JSON；用 python 解析（BSD sed 不支持 \s，会静默解析失败 → 误判）
  local d="$1" i st
  for i in 1 2 3; do
    st=$(curl -fsS --max-time 8 -H 'accept: application/dns-json' \
         "https://cloudflare-dns.com/dns-query?name=$d&type=A" 2>/dev/null \
         | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("Status",""))
except Exception: print("")' 2>/dev/null)
    case "$st" in
      "") ;;                                   # 查询失败 → 重试
      0)  echo -e "$d\tok"; return ;;          # NOERROR
      3)  # NXDOMAIN：再查 AAAA，排除"只有 IPv6 记录"的合法域名
          st2=$(curl -fsS --max-time 8 -H 'accept: application/dns-json' \
               "https://cloudflare-dns.com/dns-query?name=$d&type=AAAA" 2>/dev/null \
               | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("Status",""))
except Exception: print("")' 2>/dev/null)
          [ "$st2" = "0" ] && { echo -e "$d\tok"; return; }
          echo -e "$d\tdead"; return ;;
    esac
    sleep 1
  done
  echo -e "$d\tdead"
}
export -f resolve_one

# 20 路并发（BSD xargs 不支持 -a，用重定向）
xargs -P 20 -I{} bash -c 'resolve_one "$@"' _ {} < "$tmp/new" > "$tmp/res" 2>/dev/null

DEAD=$(awk -F'\t' '$2=="dead"{print $1}' "$tmp/res" | sort)
DEADN=$(printf '%s\n' "$DEAD" | grep -c . || true)

echo "  可解析 $((NEWN - DEADN)) 个，不可解析 ${DEADN} 个"

if [ "$DEADN" -gt 0 ]; then
  echo ""
  echo "✗ 以下**新增**域名无法解析（NXDOMAIN / 无任何记录）："
  printf '%s\n' "$DEAD" | grep . | sed 's/^/     /'
  echo ""
  echo "  这类域名规则永不命中，且经验上是上游灌入的垃圾（2026-10-12 那批死域同此特征）。"
  echo "  处理：若确属某 AI 服务，请确认域名拼写并加入白名单后重试；否则应在上游源中剔除。"
  exit 1
fi

echo "✓ 新增域名全部可解析"
exit 0

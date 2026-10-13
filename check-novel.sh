#!/bin/bash
# 增量审查闸门：**新加入**的域名若命中「通用基础设施/遥测/账号」语义模式，拒绝提交。
#
# 为什么需要它（存活性闸门的边界）：
#   check-liveness.sh 只拦「DNS 查无此域」的垃圾。但像 login.live.com 这种
#   **真实存在、却与 AI 无关**的域名会通过 —— 它属于「通用账号/基础设施」。
#   靠黑名单列举挡不住没见过的变种（如 sso.some-new-idp.com），
#   所以这里按**语义模式**拦：这些词几乎不可能出现在真正的 AI 服务域名里。
#
# 设计要点：
#   · 只查「相对基线**新增**」的域名 → 不误伤历史遗留。
#   · 命中模式 ≠ 直接失败：先列出让人/CI 看见。命中即失败，除非在 ALLOW 白名单里。
#   · ALLOW 是给「确实是 AI 的、但名字不幸撞模式」的域名留的逃生口（附理由）。
#
# 用法：./check-novel.sh            # 与 HEAD 比
#       ./check-novel.sh <ref>
set -u
cd "$(dirname "$0")" || exit 1
BASE="${1:-HEAD}"
TABLES="AI-CN AI-OpenAI AI-Claude AI-Gemini AI-Copilot AI-Jetbrains AI-Overseas-Others"

# 通用基础设施 / 账号 / 遥测 / 追踪 —— 与「某个具体 AI 产品」无关
# 注意：模式要**贴着标签**（如 ^sso\. 或 \.sso\.），不要把 ai 产品名里偶然含这些字串的误伤
SUSPECT=(
  '^(sso|signin|login|signup|account|accounts|auth|oauth|idp|ldap|directory)\.'  # 通用账号/单点登录入口
  '\.(sso|signin|login|auth|oauth|idp)\.'                                        # 同上（子域形式）
  '^(telemetry|metrics|analytics|tracking|tracker|beacon|rum)\.'                 # 遥测
  '\.(telemetry|metrics|analytics|tracking|tracker|beacon)\.'
  '^(status|support|help|docs|blog|news|careers|jobs|billing|invoice)\.'         # 非服务性站点
  '^(cdn|static|assets|img|images|fonts|media)\.'                                # 泛 CDN（各家共用式命名）
  '(^|\.)(doubleclick|googletagmanager|google-analytics|adservice|adsystem)\.'   # 广告
)
# 「确实是 AI，但名字撞了模式」的逃生口（域名:理由）
ALLOW=""

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
: > "$tmp/cur"; : > "$tmp/base"
for t in $TABLES; do
  [ -f "surge/$t.list" ] || continue
  awk -F, '/^DOMAIN(-SUFFIX)?,/{gsub(/[ \t]/,"",$2); print tolower($2)}' "surge/$t.list" >> "$tmp/cur"
  git show "$BASE:surge/$t.list" 2>/dev/null \
    | awk -F, '/^DOMAIN(-SUFFIX)?,/{gsub(/[ \t]/,"",$2); print tolower($2)}' >> "$tmp/base"
done
sort -u "$tmp/cur" -o "$tmp/cur"; sort -u "$tmp/base" -o "$tmp/base"
comm -23 "$tmp/cur" "$tmp/base" > "$tmp/new"
NEWN=$(wc -l < "$tmp/new" | tr -d ' ')

echo "── 增量语义审查 ──"
echo "  相对 $BASE 新增 $NEWN 个域名"
[ "$NEWN" -eq 0 ] && { echo "✓ 无新增域名，跳过"; exit 0; }

HITS=""
while IFS= read -r d; do
  [ -z "$d" ] && continue
  case "$ALLOW" in *"$d:"*) continue;; esac
  for pat in "${SUSPECT[@]}"; do
    if printf '%s\n' "$d" | grep -qE "$pat"; then
      HITS="$HITS$d  ← 命中 /$pat/\n"
      break
    fi
  done
done < "$tmp/new"

if [ -n "$HITS" ]; then
  echo ""
  echo "✗ 新增域名命中「通用基础设施/账号/遥测」模式 —— 需人工确认后才可入库："
  printf "$HITS" | sed 's/^/     /'
  echo ""
  echo "  真正的 AI 服务极少使用 sso./login./telemetry./status. 这类前缀。"
  echo "  若确属某 AI 服务（如厂商自己的登录页），请在 check-novel.sh 的 ALLOW 里"
  echo "  加 '<域名>:<理由>' 放行；否则应在上游源剔除。"
  exit 1
fi

echo "✓ 新增域名未命中可疑模式"
exit 0

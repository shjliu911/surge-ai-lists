#!/bin/bash
# 把 Surge 格式的 AI-*.list 转成 mihomo / Clash.Meta 的 rule-provider YAML。
#
# 为什么单独一步、而不是在 refresh-ai-lists.sh 里直接产出：
#   两套格式的规则集要能**各自独立**校验（Surge 侧 check-ai-lists.sh / Clash 侧
#   check-clash.sh），转换器保持「纯函数」——只读 AI-*.list、写 clash/*.yaml，不碰网络、
#   不依赖上游。refresh 生成完 7 张表后调用本脚本，CI 与 sync.sh 都这么串。
#
# 规则类型映射（mihomo 官方文档 https://wiki.metacubex.one/config/rules/ 已核对）：
#   DOMAIN / DOMAIN-SUFFIX / DOMAIN-KEYWORD / IP-CIDR / IP-CIDR6 / IP-ASN  →  原样保留
#     classical provider 里写法与 Surge 完全一致（含 `,no-resolve` 后缀）。
#   URL-REGEX  →  mihomo **没有**等价类型（它只有 DOMAIN-REGEX，匹配域名而非 URL 路径），
#     丢弃，并在产物头部注明。当前仅 AI-Gemini 有一条。
#
# 幂等：只在内容真变化时重写（比较时忽略 `# GEN:` 行），避免每天空提交——
#   与 refresh-ai-lists.sh 的 gen() 同一套纪律。
set -u
cd "$(dirname "$0")" || exit 1

OUTDIR="clash"
mkdir -p "$OUTDIR"

# 表 → 建议策略组（对应 Surge 侧 RULE-SET 的第三个参数；Clash 无内建策略组名，
# 这里只作为注释提示，用户接自己命名的代理组）。
# 用 case 而非 declare -A —— macOS 自带 bash 3.2 不支持关联数组。
group_of() {
  case "$1" in
    AI-CN)              echo "DIRECT" ;;
    AI-OpenAI)          echo "🧠 ChatGPT" ;;
    AI-Claude)          echo "🎭 Claude" ;;
    AI-Gemini)          echo "💎 Gemini" ;;
    AI-Copilot|AI-Jetbrains|AI-Overseas-Others) echo "🤖 AI 服务" ;;
    *)                  echo "" ;;
  esac
}

# 表 → rule-provider 名（Clash 侧 `rule-providers` 的 key，也是 rules 里 `RULE-SET,<名>` 用的名）。
# 必须与 README「Clash / mihomo 如何引用」一致；AI-Overseas-Others 特意缩成 ai-others（简短好记）。
provider_name_of() {
  case "$1" in
    AI-Overseas-Others) echo "ai-others" ;;
    *)                  echo "$1" | tr 'A-Z' 'a-z' ;;
  esac
}

TABLES="AI-CN AI-OpenAI AI-Claude AI-Gemini AI-Copilot AI-Jetbrains AI-Overseas-Others"

for t in $TABLES; do
  src="$t.list"
  [ -f "$src" ] || { printf 'SKIP %s（源不存在）\n' "$src" >&2; continue; }
  dst="$OUTDIR/$t.yaml"
  opt=$(mktemp)

  # 提取规则行（去注释/空行），按类型分流；统计被丢弃的 URL-REGEX。
  # 注意：`grep -c` 无匹配时退出码为 1、但**仍输出 "0"**；再加 `|| echo 0` 会得到 "0\n0"。
  # 故用 `|| true` 抑制退出码，让 grep 自己那行 "0" 作为唯一输出。
  dropped=$(grep -cE '^[[:space:]]*URL-REGEX,' "$src" 2>/dev/null || true)
  payload=$(grep -vE '^[[:space:]]*(#|$)' "$src" \
            | grep -vE '^[[:space:]]*URL-REGEX,' \
            | sed -E 's/[[:space:]]+$//')

  {
    printf '# NAME: %s\n' "$t"
    printf '# SRC:  %s（由 to-clash.sh 自动生成，勿手改）\n' "$src"
    printf '# TYPE: mihomo rule-provider / behavior: classical / format: yaml\n'
    printf '# USE:  Clash: RULE-SET,%s,%s   (Surge: RULE-SET,%s.list,%s)\n' \
      "$(provider_name_of "$t")" "$(group_of "$t")" "$t" "$(group_of "$t")"
    printf '# GEN:  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    if [ "$dropped" -gt 0 ]; then
      printf '# NOTE: 已丢弃 %s 条 mihomo 不支持的规则类型（URL-REGEX）\n' "$dropped"
    fi
    printf 'payload:\n'
    # 每个规则行前加 "  - "。用 sed 而非逐行 echo，避免 subshell 开销。
    printf '%s\n' "$payload" | sed -E 's/^(.*)$/  - \1/'
  } > "$opt"

  # 幂等：忽略 # GEN: 行后比较。
  norm() { grep -vE '^# GEN:' "$1"; }
  if [ -f "$dst" ] && diff -q <(norm "$dst") <(norm "$opt") >/dev/null 2>&1; then
    rm -f "$opt"
    printf '%s   %-28s %s 条（无变化）\n' '--' "$dst" "$(grep -cE '^[[:space:]]*  - ' "$dst")"
  else
    mv "$opt" "$dst"
    printf 'OK   %-28s %s 条\n' "$dst" "$(grep -cE '^[[:space:]]*  - ' "$dst")"
  fi
done

echo "完成。mihomo 用 rule-provider 引用 clash/*.yaml（见 README）。"

#!/bin/bash
# 把 surge/AI-*.list（Surge 格式）转成 Quantumult X [filter_remote] 远程过滤表（quanx/*.list）。
#
# 为什么单独一步、而不是在 refresh-ai-lists.sh 里直接产出：
#   各客户端格式要能**各自独立**校验（Surge 侧 check-ai-lists.sh / Clash 侧 check-clash.sh /
#   QX 侧 check-quanx.sh），转换器保持「纯函数」——只读 surge/AI-*.list、写 quanx/*.list，
#   不碰网络、不依赖上游。refresh 生成完 7 张表后调用本脚本，CI 与 sync.sh 都这么串。
#
# 规则类型映射（依据三方交叉实证，2026-10-27）：
#   ① 官方 sample.conf（crossutility/Quantumult-X，2019→2026 全历史）：
#      远程过滤行是三段式 `type, value, policy`；[filter_local] 展示的 filter 类型全集为
#      user-agent / host / host-keyword / host-wildcard / host-suffix / ip6-cidr / ip-cidr /
#      geoip / ip-asn / final；force-policy 注释原文
#      "the policy in filter of remote resource will be ignored and the force-policy
#       will be used" —— 即行内 policy 会被引用处的 force-policy **覆盖**，
#      所以行内写内建策略（direct/proxy）是安全默认值。
#   ② blackmatrix7 的 QuantumultX/ 与 Surge/ 目录 A/B 对照（同源数据双格式，全球最大消费量）：
#      DOMAIN→HOST、DOMAIN-SUFFIX→HOST-SUFFIX（连根域一起命中，语义等同，无需补 host 行）、
#      DOMAIN-KEYWORD→HOST-KEYWORD、IP-CIDR→IP-CIDR、IP-CIDR6→IP6-CIDR、IP-ASN→IP-ASN；
#      Surge 的 `,no-resolve` 在 QX 产物里被剥掉（Loon 版保留 → 剥离是 QX 特有要求）。
#   ③ URL-REGEX：QX filter 全历史 0 支持（仅 [rewrite] 段有 reject 类 URL 正则），
#      丢弃并在产物头部注明（当前仅 AI-Gemini 有 1 条）。
#   其余 Surge 独有类型（DOMAIN-SET / PROCESS-* / RULE-SET / SRC-IP / SUBNET /
#   DEST-PORT / PROTOCOL / AND|OR|NOT）QX filter 无对应物，保守丢弃并计数。
#
# 行内策略选择「内建策略」（AI-CN → direct，其余 → proxy）：QX 配置里
# 不一定存在 Surge 那套 emoji 组名，内建策略任何配置都认；要接自己的策略组，
# 在 [filter_remote] 引用行上写 force-policy=<你的组名> 即可（官方语义保证覆盖）。
#
# 幂等：只在内容真变化时重写（比较时忽略 `# GEN:` 行），避免每天空提交——
#   与 to-clash.sh / refresh-ai-lists.sh 的 gen() 同一套纪律。
set -u
cd "$(dirname "$0")" || exit 1

SRCDIR="surge"    # Surge 生成表所在目录（由 refresh-ai-lists.sh 产出）
OUTDIR="quanx"
mkdir -p "$OUTDIR"

# 表 → 行内策略（QX 内建策略；引用处用 force-policy 覆盖成自己的策略组）
policy_of() {
  case "$1" in
    AI-CN) echo "direct" ;;
    *)     echo "proxy" ;;
  esac
}

# 表 → Surge 侧建议策略组（注释提示用，与 to-clash.sh 的 group_of 同口径）
surge_group_of() {
  case "$1" in
    AI-CN)              echo "DIRECT" ;;
    AI-OpenAI)          echo "🧠 ChatGPT" ;;
    AI-Claude)          echo "🎭 Claude" ;;
    AI-Gemini)          echo "💎 Gemini" ;;
    AI-Copilot|AI-Jetbrains|AI-Overseas-Others) echo "🤖 AI 服务" ;;
    Google-Supplement)  echo "🐱哈基米" ;;
    *)                  echo "" ;;
  esac
}

TABLES="AI-CN AI-OpenAI AI-Claude AI-Gemini AI-Copilot AI-Jetbrains AI-Overseas-Others Google-Supplement"

for t in $TABLES; do
  # Google-Supplement 是根目录手写表（非 refresh 产物），其余在 surge/
  case "$t" in
    Google-Supplement) src="$t.list" ;;
    *)                 src="$SRCDIR/$t.list" ;;
  esac
  [ -f "$src" ] || { printf 'SKIP %s（源不存在）\n' "$src" >&2; continue; }
  dst="$OUTDIR/$t.list"
  opt=$(mktemp)
  pol=$(policy_of "$t")

  # 转换规则行（去注释/空行；域名/IP 类型逐条映射；URL-REGEX 等不支持类型丢弃并计数）
  #   DOMAIN→host  DOMAIN-SUFFIX→host-suffix  DOMAIN-KEYWORD→host-keyword
  #   IP-CIDR→ip-cidr  IP-CIDR6→ip6-cidr  IP-ASN→ip-asn   （取官方 sample 小写风格）
  #   USER-AGENT→user-agent（官方 [filter_local] 有此类型）；本仓库表当前不含它，映射备用。
  #   `,no-resolve` 剥离（BM7 QX 产物实证：Loon 版保留、QX 版剥掉）
  dropped=0
  : > "$opt.rules"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    type=${line%%,*}
    rest=${line#*,}
    value=${rest%%,*}
    case "$type" in
      DOMAIN)         qtype="host" ;;
      DOMAIN-SUFFIX)  qtype="host-suffix" ;;
      DOMAIN-KEYWORD) qtype="host-keyword" ;;
      IP-CIDR)        qtype="ip-cidr" ;;
      IP-CIDR6)       qtype="ip6-cidr" ;;
      IP-ASN)         qtype="ip-asn" ;;
      USER-AGENT|GEOIP)
        # 这两类在 Surge 源里第三段是 policy（或无第三段），不是 no-resolve：
        #   Surge: USER-AGENT,<pattern>,<policy> / GEOIP,<cc>[,<policy>]
        # QX filter 同样支持（官方 sample.conf [filter_local] 有 user-agent/geoip）。
        # 取第 2 段为值、丢掉源 policy、换上本表内建策略。
        printf '%s, %s, %s\n' "$([ "$type" = "USER-AGENT" ] && echo user-agent || echo geoip)" "$value" "$pol" >> "$opt.rules"
        continue
        ;;
      *)
        dropped=$((dropped + 1))
        continue
        ;;
    esac
    # 值后面可能跟 no-resolve：rest = "value,no-resolve" → value 已取到；确认多余字段只是 no-resolve
    extra=${rest#*,}
    [ "$extra" = "$rest" ] && extra=""
    case "$extra" in
      no-resolve|' no-resolve'|'no-resolve '|' no-resolve ') ;;   # 合法后缀，剥掉
      '') ;;
      *)  # 未知后缀（将来可能出现新 flag）→ 保守丢弃该行，不产出半懂不懂的规则
        dropped=$((dropped + 1))
        continue
        ;;
    esac
    printf '%s, %s, %s\n' "$qtype" "$value" "$pol" >> "$opt.rules"
  done < "$src"

  {
    printf '# NAME: %s\n' "$t"
    printf '# SRC:  %s（由 to-quanx.sh 自动生成，勿手改）\n' "$src"
    printf '# TYPE: Quantumult X [filter_remote] 远程过滤（host/host-suffix/host-keyword/ip-cidr/ip6-cidr/ip-asn；UA/GEOIP 备用）\n'
    printf '# USE:  QX: <本文件raw URL>, tag=%s, force-policy=<你的策略组或direct/proxy>, enabled=true   (Surge: RULE-SET,%s,%s)\n' \
      "$t" "$src" "$(surge_group_of "$t")"
    printf '# NOTE: 行内策略为 QX 内建 "%s"（AI-CN 直连、其余代理）；引用时 force-policy= 会覆盖它\n' "$pol"
    printf '# GEN:  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    if [ "$dropped" -gt 0 ]; then
      printf '# NOTE: 已丢弃 %s 条 QX filter 不支持的规则（URL-REGEX 等）\n' "$dropped"
    fi
    printf '\n'
    cat "$opt.rules"
  } > "$opt"
  rm -f "$opt.rules"

  # 幂等：忽略 # GEN: 行后比较。
  norm() { grep -vE '^# GEN:' "$1"; }
  if [ -f "$dst" ] && diff -q <(norm "$dst") <(norm "$opt") >/dev/null 2>&1; then
    rm -f "$opt"
    printf '%s   %-28s %s 条（无变化）\n' '--' "$dst" "$(grep -cvE '^#|^$' "$dst")"
  else
    mv "$opt" "$dst"
    printf 'OK   %-28s %s 条\n' "$dst" "$(grep -cvE '^#|^$' "$dst")"
  fi
done

echo "完成。Quantumult X 在 [filter_remote] 里引用 quanx/*.list（见 README）。"

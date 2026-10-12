#!/bin/bash
# 刷新 AI 规则 list：合并 blackmatrix7 + VPSDance 两源，剔除宽泛规则，写入本机 list。
#
# 为什么用本地文件而不是直接 RULE-SET 远程 URL：
#   上游 list 带宽泛的 IP-ASN（14061 DigitalOcean / 20473 Vultr）和通用
#   DOMAIN-KEYWORD（sift / datadog / sentry），会按 ASN/关键字命中大量非 AI 站点，
#   把它们一起拉进 AI 策略组。Surge 无法对远程 list 做过滤，只能在本地预先生成。
#
# 过滤规则：剔除所有 IP-ASN（宽泛托管商网段）+ 通用关键词；
#           保留 IP-CIDR（是服务商自有、较精确的网段）。
#
# 用法：./refresh-ai-lists.sh       （Surge 会自动重载本机 list，无需手动 reload）
set -u
cd "$(dirname "$0")" || exit 1

BM7="https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/refs/heads/master/rule/Surge"
VPS="https://raw.githubusercontent.com/VPSDance/ai-proxy-rules/main/rules/surge"

# 需要剔除的通用 DOMAIN-KEYWORD（太宽，会误抓）
BAD_KW="sift|datadog|sentry"

# 需要剔除的通用第三方域名（上游从 AI 登录页的 SDK 引用误收，会误抓一堆非 AI 站点）
BAD_DOMAIN="algolia.net|auth0.com|stripe.com|sentry.io|intercom.io|intercomcdn.com|segment.io|launchdarkly.com|featuregates.org|identrust.com|observeit.net|statsig.com|statsigapi.net|datadoghq.com|cloudflareinsights.com|growthbook.io|challenges.cloudflare.com|cloudflare.net|azurefd.net|imgix.net"

fetch() { # $1=url  → stdout
  curl -fsS --max-time 40 "$1" 2>/dev/null
}

filter() { # stdin → stdout：去注释/空行、剔 IP-ASN 与通用关键词、剔通用第三方域名
  grep -vE '^[[:space:]]*(#|$)' \
  | grep -vE '^[[:space:]]*IP-ASN,' \
  | grep -viE "^[[:space:]]*DOMAIN-KEYWORD,($BAD_KW)([[:space:]]|$)" \
  | grep -viE "^[[:space:]]*DOMAIN(-SUFFIX)?,([a-z0-9.-]+\.)?($BAD_DOMAIN)([[:space:]]|$)"
}

gen() { # $1=outfile  $2=name  $3=manualfile(可空 "-")  $4..=urls
  out="$1"; name="$2"; manual="$3"; shift 3
  tmp=$(mktemp)
  { printf '# NAME: %s\n# GEN:  %s\n# NOTE: 合并 bm7 + VPSDance 两源；已剔除 IP-ASN 与通用 KEYWORD/域名\n' \
      "$name" "$(date '+%Y-%m-%d %H:%M:%S')"
    if [ "$manual" != "-" ] && [ -f "$manual" ]; then
      printf '# 含本机手动补充：%s\n\n' "$manual"
      grep -vE '^[[:space:]]*(#|$)' "$manual"
      printf '\n'
    else
      printf '\n'
    fi
    for u in "$@"; do fetch "$u" | filter; done
  } > "$tmp"
  if [ -s "$tmp" ]; then
    { grep -E '^#' "$tmp"; printf '\n'; grep -vE '^#' "$tmp" | sort -u; } > "$out.tmp"
    # 只在「规则内容」真变时重写该文件：
    # 头部注释里的 # GEN 时间戳每次都不同，若因此重写，会导致每天产生一条空提交。
    # 比较时剔掉注释头（只看规则行），无变化就保留旧文件（连 GEN 时间戳也不动）。
    if [ -f "$out" ] && \
       diff -q <(grep -vE '^#' "$out") <(grep -vE '^#' "$out.tmp") >/dev/null 2>&1; then
      rm -f "$out.tmp" "$tmp"
      printf '--   %-28s %s 行（无变化）\n' "$out" "$(grep -cvE '^#|^$' "$out")"
    else
      mv "$out.tmp" "$out"; rm -f "$tmp"
      printf 'OK   %-28s %s 行\n' "$out" "$(grep -cvE '^#|^$' "$out")"
    fi
  else echo "FAIL(all sources) $out"; rm -f "$tmp"; fi
}

#                                            输出文件              名称            手动补充表                        远程源
gen AI-OpenAI.list    "AI-OpenAI"      "AI-Supplement-OpenAI.list" "$BM7/OpenAI/OpenAI.list"   "$VPS/openai.list"
gen AI-Claude.list    "AI-Claude"      "AI-Supplement-Claude.list" "$BM7/Claude/Claude.list"   "$BM7/Anthropic/Anthropic.list" "$VPS/anthropic.list"
gen AI-Gemini.list    "AI-Gemini"      "AI-Supplement-Gemini.list" "$BM7/Gemini/Gemini.list"   "$BM7/BardAI/BardAI.list"       "$VPS/google-ai.list"
gen AI-Copilot.list   "AI-Copilot"     "-"                         "$BM7/Copilot/Copilot.list" "$VPS/copilot.list"
gen AI-Jetbrains.list "AI-Jetbrains"   "-"                         "$BM7/Jetbrains/Jetbrains.list" "$VPS/jetbrains-ai.list"
gen AI-Misc.list      "AI-Misc"        "AI-Supplement.list"        "$VPS/x-ai.list" "$VPS/meta-ai.list" \
                                                                   "$VPS/cursor.list" "$VPS/windsurf.list" \
                                                                   "$VPS/opencode.list" "$VPS/cline.list" \
                                                                   "$VPS/zed.list" "$VPS/model.list" \
                                                                   "$VPS/media.list" \
                                                                   "$BM7/aiXcoder/aiXcoder.list" \
                                                                   "$BM7/Civitai/Civitai.list"

echo "完成。Surge 会自动重载本机 list（无需手动 reload）。"

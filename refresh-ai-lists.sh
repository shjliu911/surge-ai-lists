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
# 用法：
#   ./refresh-ai-lists.sh              本地手动：源失败或缩水 → 告警但保留旧文件，退出码 0
#   CI_STRICT=1 ./refresh-ai-lists.sh  GitHub Actions：源失败或缩水 → 失败退出码 2，阻止提交
#
# 退出码：0=成功（或本地模式下的宽容跳过） 2=严格模式下检出问题（源失败 / 缩水）
# 自动运行：GitHub Actions（.github/workflows/generate.yml），本机无需任何定时任务。
set -u
cd "$(dirname "$0")" || exit 1

# 严格模式：CI 里开着；某张表出问题就让整个任务失败，绝不提交可疑内容。
STRICT="${CI_STRICT:-0}"
problem=0   # 累计问题表数；严格模式下用于最终退出码

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
  raw=$(mktemp); one=$(mktemp); fail=0

  # 手写补充表（本地文件，不会失败）先并入
  if [ "$manual" != "-" ] && [ -f "$manual" ]; then
    grep -vE '^[[:space:]]*(#|$)' "$manual" >> "$raw"
  fi

  # 逐个远程源抓取。任一源失败 → 整表放弃（见下方），避免写出缩水的半成品。
  for u in "$@"; do
    if fetch "$u" > "$one" && [ -s "$one" ]; then
      filter < "$one" >> "$raw"
    else
      fail=$((fail + 1))
      printf '     ! 源抓取失败: %s\n' "$u" >&2
    fi
  done
  rm -f "$one"

  # 关键安全闸：只要有源抓失败，就保留旧文件、不覆盖。
  # 否则一次网络抖动就会让列表缩水，把 AI 域名从代理里踢出去。
  if [ "$fail" -gt 0 ]; then
    printf 'SKIP %-28s %d 个源失败 → 保留旧文件，不覆盖\n' "$out" "$fail" >&2
    rm -f "$raw"; problem=$((problem + 1)); return 1
  fi

  if [ ! -s "$raw" ]; then
    printf 'FAIL %-28s 所有源为空 → 保留旧文件\n' "$out" >&2
    rm -f "$raw"; problem=$((problem + 1)); return 1
  fi

  # 组装：注释头 + 去重排序后的规则行
  opt=$(mktemp)
  { printf '# NAME: %s\n# GEN:  %s\n# NOTE: 合并 bm7 + VPSDance 两源；已剔除 IP-ASN 与通用 KEYWORD/域名\n' \
      "$name" "$(date '+%Y-%m-%d %H:%M:%S')"
    if [ "$manual" != "-" ] && [ -f "$manual" ]; then
      printf '# 含本机手动补充：%s\n' "$manual"
    fi
    printf '\n'
    sort -u "$raw"
  } > "$opt"
  rm -f "$raw"

  # 只在「规则内容」真变时重写该文件：
  # 头部注释里的 # GEN 时间戳每次都不同，若因此重写，会导致每天产生一条空提交。
  # 比较时剔掉注释行（只看规则行），无变化就保留旧文件（连 GEN 时间戳也不动）。
  if [ -f "$out" ] && \
     diff -q <(grep -vE '^#' "$out") <(grep -vE '^#' "$opt") >/dev/null 2>&1; then
    rm -f "$opt"
    printf '%s   %-28s %s 行（无变化）\n' '--' "$out" "$(grep -cvE '^#|^$' "$out")"
  else
    # 缩水检测：新内容若比旧版少于 70%，大概率是上游异常而非正常收敛。
    # 本地模式：告警但写入（人工确认后再 commit）；CI 严格模式：直接不写 + 计为问题。
    if [ -f "$out" ]; then
      oldn=$(grep -cvE '^#|^$' "$out"); newn=$(grep -cvE '^#|^$' "$opt")
      if [ "$oldn" -gt 10 ] && [ "$newn" -lt $((oldn * 7 / 10)) ]; then
        pct=$(( (oldn - newn) * 100 / oldn ))   # 纯 shell 算术，不依赖 bc
        printf '\n\033[31m!!! 缩水告警 %s: %s 行 → %s 行（少 %s%%）\033[0m\n' \
          "$out" "$oldn" "$newn" "$pct" >&2
        if [ "$STRICT" = 1 ]; then
          printf '    [CI 严格模式] 拒绝写入缩水内容 → 保留旧文件，任务将失败\n\n' >&2
          rm -f "$opt"; problem=$((problem + 1)); return 1
        fi
        printf '    请确认是上游正常收敛后，再 git push（本函数已写入该缩水版）\n\n' >&2
      fi
    fi
    mv "$opt" "$out"
    printf 'OK   %-28s %s 行\n' "$out" "$(grep -cvE '^#|^$' "$out")"
  fi
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

# 严格模式下：只要有任何一张表出问题，就以退出码 2 失败，阻止 CI 的提交步骤。
if [ "$STRICT" = 1 ] && [ "$problem" -gt 0 ]; then
  printf '\n\033[31m严格模式：%d 张表有问题，退出码 2（不提交）\033[0m\n' "$problem" >&2
  exit 2
fi
exit 0

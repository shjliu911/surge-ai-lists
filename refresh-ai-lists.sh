#!/bin/bash
# 刷新 AI 规则 list：合并 blackmatrix7 + VPSDance 两源，剔除宽泛规则，写入本机 list。
#
# 为什么用本地文件而不是直接 RULE-SET 远程 URL：
#   上游 list 带宽泛的 IP-ASN（14061 DigitalOcean / 20473 Vultr）和通用
#   DOMAIN-KEYWORD（sift / datadog / sentry），会按 ASN/关键字命中大量非 AI 站点，
#   把它们一起拉进 AI 策略组。Surge 无法对远程 list 做过滤，只能在本地预先生成。
#
# 过滤规则：剔除上游源里的 IP-ASN（14061 DigitalOcean / 20473 Vultr 这类宽泛托管商网段）
#           + 通用关键词；保留 IP-CIDR（服务商自有、较精确）。
#   例外：手写补充表（AI-Supplement*.list）**绕过 filter()**，是人工精选的。
#         其中两条 IP-ASN 是厂商自有网段（399358 Anthropic PBC / 401518 OpenAI OpCo），
#         与上面要剔的通用托管商不同，故有意保留。check-ai-lists.sh 断言「只允许这两位」。
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
BUILD=".build"   # 中间产物目录（生成结束即删）
OUTDIR="surge"   # Surge 生成表输出目录（与 clash/ 对称，见 README「目录结构」）

BM7="https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/refs/heads/master/rule/Surge"
VPS="https://raw.githubusercontent.com/VPSDance/ai-proxy-rules/main/rules/surge"
SUKKA="https://raw.githubusercontent.com/SukkaW/Surge/master/Source/non_ip"
DLER="https://raw.githubusercontent.com/dler-io/Rules/main/Surge/Surge%203/Provider"
ACL4="https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/Ruleset"
RABBIT="https://raw.githubusercontent.com/Rabbit-Spec/Surge/Master/Rules"

# 需要剔除的通用 DOMAIN-KEYWORD（太宽，会误抓）
#   colab：ACL4SSR 带 `DOMAIN-KEYWORD,colab` → 会抓 colab.research.google.com（Google Colab，非 AI 服务）
#   openai/claude/anthropic：VPSDance 等把这些当关键词，太宽（会抓任何含该串的域名）
BAD_KW="sift|datadog|sentry|colab|openai|claude|anthropic|alkalimakersuite-pa|chatgpt-async-webps-prod|generativelanguage|developerprofiles"

# 需要剔除的通用第三方域名（上游从 AI 登录页的 SDK 引用误收，会误抓一堆非 AI 站点）
BAD_DOMAIN="algolia.net|auth0.com|stripe.com|sentry.io|intercom.io|intercomcdn.com|segment.io|launchdarkly.com|featuregates.org|identrust.com|observeit.net|statsig.com|statsigapi.net|datadoghq.com|cloudflareinsights.com|growthbook.io|challenges.cloudflare.com|cloudflare.net|azurefd.net|imgix.net|workos.com|workoscdn.com|usefathom.com|arkoselabs.com|browser-intake-datadoghq.com"

# 通用云计算/开发平台的基础设施域（不是 AI 服务，会误代理大面积非 AI 流量）。
# 来源：VPSDance 的泛聚合表 all/global/coding 里夹带了整块 AWS 开发工具链。
#   sso.amazonaws.com       —— AWS **通用单点登录**，任何用 AWS SSO 的企业登录都会被代理
#   awsstatic.com/awsapps.com/console.aws.a2z.com —— AWS CDN / 应用门户 / 控制台，极宽
#   *-language-servers.amazonaws.com / aws-toolkit-* —— 通用语言服务器
#   cognito-identity / client-telemetry —— 通用身份服务 / 遥测
# 注意：Amazon Q / CodeWhisperer / Adobe Firefly **是** AI 服务（域名不出现在下面的模式里），会保留。
BAD_INFRA="sso\.amazonaws\.com|awsstatic\.com|awsapps\.com|console\.aws\.a2z\.com|cognito-identity|client-telemetry|idetoolkits|language-servers\.amazonaws\.com|q-developer-integration"

# Google 通用基础设施 —— **不是 AI 服务**，却在 2026-10-16 被 dler-io 的 AI Suite.list 整块灌入。
# 症状：AI-Overseas-Others 一夜多出 19 行 Google 基础域，于是 Play 商店、Google 字体、地图
# 图片 CDN 全被拉进「海外 AI」策略组 → 这些站被当 AI 流量走代理/被单独切换，行为错误。
# check-novel.sh 的 `^(cdn|static|assets|img|images|fonts|media)\.` 模式只拦下了 fonts.*，
# 其余（play./ssl./maps./lh3./ogs.…）长得像正常域名而漏过 —— 所以在源头按**精确清单**剔。
# 保留边界：Gemini/AI Studio/Gemini 的 gstatic 静态资源仍由品牌表按签名单独收。
BAD_GOOGLE_INFRA="content-autofill\.googleapis\.com|csp\.withgoogle\.com|encrypted-tbn[0-9]*\.gstatic\.com|fonts\.googleapis\.com|fonts\.gstatic\.com|jnn-pa\.googleapis\.com|lh3\.google\.com|lh3\.googleusercontent\.com|lh5\.googleusercontent\.com|maps\.googleapis\.com|maps\.gstatic\.com|ogs\.google\.com|optimizationguide-pa\.googleapis\.com|play\.google\.com|ssl\.gstatic\.com|streetviewpixels-pa\.googleapis\.com"

# 国内表（AI-CN）的剔除名单 —— 上游 VPSDance cn.list 自带的脏数据（2026-10-12 实证）。
# 剔的是「整个云平台」顶级域：一条 aliyun.com 会把阿里云**全部**非 AI 产品拉直连。
# 这些平台的 AI 子域（dashscope/qianfan/ark/hunyuan…）在源里已单独收录 → 收窄不丢覆盖面。
BAD_CN="aliyun\.com|volcengine\.com|volces\.com|tencentcloudapi\.com|baidubce\.com"

# DNS 查无此域（NXDOMAIN/no-A）或误收的域名 —— 规则永不命中，或指向无关站点。
#   tcwqqdy.guru/mchost.guru/mcbaas.work/mcprev.cn : DNS 无解析（上游疑似灌入的幻觉域名）
#   trae.guru        : Trae 官方是 trae.ai/trae.cn/trae.com.cn，此域无解析
#   deepseeksvc.com  : DeepSeek 官方无此域，DNS 无解析
#   doudou.com       : 解析到 Zenlayer 境外 CDN，非「豆包」(doubao.com)
#   pai.com          : 解析到 Webflow 建站平台，非阿里 PAI
#   minimax.com      : 解析到 AWS 共享邮件转发域，非 MiniMax(minimaxi.com)
BAD_DEAD="tcwqqdy\.guru|mchost\.guru|mcbaas\.work|mcprev\.cn|trae\.guru|deepseeksvc\.com|doudou\.com|pai\.com|minimax\.com"

# 错收的非 AI 域名（2026-10-12 审计 + DNS/whois 实证）。这些是「看起来像 AI 其实是别的东西」：
#   login.live.com      —— 微软消费者账号登录（MSA），与 AI 无关
#   humb.apple.com      —— Apple Tap to Pay（iPhone 收款）
#   gspe1-ssl.ls.apple.com —— Apple 定位服务
#   augment.com         —— **撞名**：实为爱尔兰 StayinFront 旗下 AR/3D 公司；
#                          真正的 AI 编程工具 Augment Code 是 augmentcode.com（已在表内）
#   origin-tracker.githubusercontent.com —— GitHub 仓库来源追踪（纯遥测）
#   ct.sendgrid.net     —— SendGrid 邮件点击追踪（跨行业通用）
# Apple iCloud 私人中继（apple-relay.*）与 AI 无关，也一并剔除。
# 分两组：子串匹配（域名独特，含即剔）；精确匹配（augment.com 必须只命中本身，
# 不能误伤 augmentcode.com，故用 (.*\.)?augment\.com + 边界）。
BAD_MISC_SUBSTR="login\.live\.com|humb\.apple\.com|gspe1-ssl\.ls\.apple\.com|origin-tracker\.githubusercontent\.com|ct\.sendgrid\.net|apple-relay|appcatalyst\.pa\.googleapis\.com|firebaseinstallations\.googleapis\.com|api\.revenuecat\.com|featureassets\.org|prodregistryv2\.org|waa-pa\.clients6\.google\.com"
# clients6.google.com 是 Google 内部 API 基础设施（Drive/Gmail/账号都走它），
# 作为 DOMAIN-SUFFIX 过宽 —— 但 Gemini 相关的具体子域（*-pa.clients6.google.com、
# webchannel-alkalimakersuite-…）必须保留，故按精确后缀剔，不用子串。
BAD_MISC_EXACT="augment\.com|llama\.com|atmeta\.com|byteoversea\.com|clients6\.google\.com"

fetch() { # $1=url  → stdout；失败重试 3 次（源变多了，得抗上游抖动）
  local i body
  for i in 1 2 3; do
    body=$(curl -fsS --max-time 30 "$1" 2>/dev/null) && [ -n "$body" ] && { printf '%s\n' "$body"; return 0; }
    sleep 2
  done
  return 1
}

filter() { # stdin → stdout：去注释/空行、剔 IP-ASN/进程规则与宽泛 KEYWORD、剔通用第三方域名、规范化
  grep -vE '^[[:space:]]*(#|$)' \
  | grep -vE '^[[:space:]]*IP-ASN,' \
  | grep -viE '^[[:space:]]*PROCESS-(NAME|PATH),' \
  | grep -viE "^[[:space:]]*DOMAIN-KEYWORD,($BAD_KW)([[:space:]]|$)" \
  | grep -viE "^[[:space:]]*DOMAIN(-SUFFIX)?,([a-z0-9.-]+[.-])?($BAD_DOMAIN)([[:space:]]|$)" \
  | grep -viE "^[[:space:]]*DOMAIN(-SUFFIX)?,.*datadoghq\.(com|eu)" \
  | grep -viE "^[[:space:]]*DOMAIN(-SUFFIX)?,[^,]*(sso\.amazonaws\.com|awsstatic\.com|awsapps\.com|console\.aws\.a2z\.com|cognito-identity|client-telemetry|idetoolkits|toolkit-language-servers|aws-language-servers|q-developer-integration)" \
  | grep -viE "^[[:space:]]*DOMAIN(-SUFFIX)?,($BAD_CN)([[:space:]]|,|$)" \
  | grep -viE "^[[:space:]]*DOMAIN(-SUFFIX)?,(.*\.)?($BAD_DEAD)([[:space:]]|,|$)" \
  | grep -viE "^[[:space:]]*DOMAIN(-SUFFIX)?,($BAD_GOOGLE_INFRA)([[:space:]]|,|$)" \
  | grep -viE "^[[:space:]]*DOMAIN(-SUFFIX)?,[^,]*($BAD_MISC_SUBSTR)" \
  | grep -viE "^[[:space:]]*DOMAIN(-SUFFIX)?,(.*\.)?($BAD_MISC_EXACT)([[:space:]]|,|$)" \
  | sed -E 's/[[:space:]]+$//' \
  | grep -vE '^[[:space:]]*$'
}

drop_covered() { # $1=待过滤文件  $2..=排除源文件 → stdout（剔除已被排除集覆盖的规则）
  # 结构性隔离：靠数据集而非"规则顺序"保证归属唯一。
  # 去重覆盖**所有规则类型**，不只域名 —— 非域名规则也要归一化后比对：
  #   · DOMAIN/DOMAIN-SUFFIX：后缀包含关系（a.b.com 被 b.com 覆盖）
  #   · IP-CIDR/IP-CIDR6：      整串归一化（大小写不敏感：2607:6BC0::/32 == 2607:6bc0::/32）
  #   · PROCESS-NAME/PATH、USER-AGENT、URL-REGEX、GEOIP 等：去空格后小写比对
  # 数据用文件参数传（不能用 stdin——heredoc 已占用，这个坑踩过两次）
  python3 - "$@" <<'PY'
import sys, re

def read_excluded(files):
    suf=set(); exact=set(); other=set()
    for f in files:
        try: fh = open(f)
        except FileNotFoundError: continue
        for ln in fh:
            t=ln.strip()
            if not t or t.startswith('#'): continue
            parts=t.split(',')
            k=parts[0].strip().upper()
            if len(parts) < 2: continue
            v=parts[1].strip()
            if k=='DOMAIN-SUFFIX':   suf.add(v.lower())
            elif k=='DOMAIN':        exact.add(v.lower())
            else:                    other.add((k, v.lower()))
    return suf, exact, other

SUF, EXACT, OTHER = read_excluded(sys.argv[2:])

def dom_cov(d):
    d=d.lower().split(',')[0].strip()
    if d in EXACT or d in SUF: return True
    p=d.split('.')
    return any('.'.join(p[i:]) in SUF for i in range(len(p)-1))

for ln in open(sys.argv[1]):
    t=ln.strip()
    if not t or t.startswith('#'):
        sys.stdout.write(ln if ln.endswith('\n') else ln+'\n'); continue
    parts=t.split(',')
    k=parts[0].strip().upper()
    v=parts[1].strip() if len(parts)>1 else ''
    # DOMAIN-KEYWORD 若本身写成某个已归属域名（如 DOMAIN-KEYWORD,x.google.com）也算重复；
    # 裸关键词（openai）对不上任何后缀 → 保留。
    if k in ('DOMAIN','DOMAIN-SUFFIX','DOMAIN-KEYWORD') and dom_cov(v):
        continue
    if k not in ('DOMAIN','DOMAIN-SUFFIX'):
        if (k, v.lower()) in OTHER:
            continue
        # IP-CIDR 的 no-resolve 后缀不参与比对（129.146.3.78/32 与 .../32,no-resolve 视为同一条）
        if k in ('IP-CIDR','IP-CIDR6','IP6-CIDR') and (k, v.lower()) in OTHER:
            continue
    sys.stdout.write(ln if ln.endswith('\n') else ln+'\n')
PY
}

brand_pick() { # $1=表名(如 AI-OpenAI)  $2=已 filter 的输入文件 → stdout
  # 品牌分发：聚合源（SukkaW ai.conf / ACL4SSR AI.list / Rabbit AIGC.list / dler AI Suite.list）
  # 里"什么 AI 都有"，直接并入任一品牌表都会把别家 AI 一起拖进来（实测 AI-OpenAI 曾被
  # 污染 64%）。这里只放行匹配本品牌签名的条目，其余留给 AI-Overseas-Others。
  # 注意：签名只用于**聚合源**；品牌专用源（BM7/VPSDance/ACL4SSR 的 OpenAI.list 等）原样并入，
  #       因为品牌源里合法地包含"同生态的别家域名"（如 Copilot 需要 openai.com）。
  python3 - "$1" "$2" <<'PY'
import sys, re
SIG = {
 'AI-OpenAI':   r'openai|chatgpt|oaistatic|oaiusercontent|sora\.com|(^|\.)ai\.com$|(^|\.)chat\.com$',
 'AI-Claude':   r'claude|anthropic|(^|\.)clau\.de$',
 'AI-Gemini':   r'gemini|bard|makersuite|notebooklm|deepmind|jules|opal|antigravity|aisandbox|cloudcode|aistudio|generativelanguage|stitch|labstailwind|aicode|robinfrontend|jetski|geller|proactivebackend|generativeai|flow\.google|notebook\.google|gemini\.gstatic|(^|\.)ai\.google|(^|\.)ai\.studio|(^|\.)g\.ai$',
 'AI-Copilot':  r'copilot|bing|microsoft|msn',
 'AI-Jetbrains':r'jetbrains|intellij|grazie|jedi|junie',
}
rx = re.compile(SIG[sys.argv[1]], re.I)
for ln in open(sys.argv[2]):
    t = ln.strip()
    if not t or t.startswith('#'):
        continue                                  # 聚合源的注释无意义，不并入品牌表
    k = t.split(',', 1)[0]
    val = t.split(',', 1)[1].split(',')[0].strip() if ',' in t else ''
    # 域名类、进程/UA 类、URL-REGEX 都能从取值里看出品牌；IP/GEOIP 无品牌信号 → 留给 Others
    if k in ('DOMAIN','DOMAIN-SUFFIX','DOMAIN-KEYWORD','PROCESS-NAME','PROCESS-PATH','USER-AGENT','URL-REGEX') and rx.search(val):
        sys.stdout.write(ln if ln.endswith('\n') else ln+'\n')
PY
}

collect() { # $1=outfile  $2..=urls → 写 outfile（已 filter）；任一源失败返回 1
  local out="$1"; shift
  local one fail=0
  : > "$out"
  for u in "$@"; do
    one=$(mktemp)
    if fetch "$u" > "$one" && [ -s "$one" ]; then
      filter < "$one" >> "$out"
    else
      fail=$((fail + 1))
      printf '     ! 源抓取失败: %s\n' "$u" >&2
    fi
    rm -f "$one"
  done
  [ "$fail" -eq 0 ]
}

gen() { # $1=outfile  $2=name  $3=manualfile(可空 "-")  $4..=内容文件（已 filter）
  # 可选环境变量 DEDUP_AGAINST：若设置，最终内容再剔除一遍被它覆盖的域名。
  # 手写补充表直接并入、绕过品牌分发，可能写进已被品牌表收走的域名（如
  # AI-Supplement.list 里的 githubcopilot.com）→ 这一步兜住。
  out="$OUTDIR/$1"; name="$2"; manual="$3"; shift 3
  raw=$(mktemp)

  # 手写补充表（本地文件，不会失败）先并入
  if [ "$manual" != "-" ] && [ -f "$manual" ]; then
    grep -vE '^[[:space:]]*(#|$)' "$manual" >> "$raw"
  fi
  for f in "$@"; do [ -f "$f" ] && cat "$f" >> "$raw"; done

  if [ -n "${DEDUP_AGAINST:-}" ] && [ -f "$DEDUP_AGAINST" ]; then
    drop_covered "$raw" "$DEDUP_AGAINST" > "$raw.d" && mv "$raw.d" "$raw"
  fi

  if [ ! -s "$raw" ]; then
    printf 'FAIL %-28s 内容为空 → 保留旧文件\n' "$out" >&2
    rm -f "$raw"; problem=$((problem + 1)); return 1
  fi

  # 组装：注释头 + 去重排序后的规则行
  # 注意：**不透传**手写补充表的注释。产物按字母排序，补充表里的分节标题
  #（如 `# ===== 绘图/图像生成 =====`）一旦透传就会与规则脱节、变成误导性注释。
  # 「为什么加这条」留在补充表本身（生成的表头有 `# 含本机手动补充：<文件>` 指路）。
  opt=$(mktemp)
  { printf '# NAME: %s\n# GEN:  %s\n# NOTE: 多源合并(blackmatrix7 + VPSDance + SukkaW + dler-io + ACL4SSR + Rabbit-Spec)；已剔宽泛KEYWORD/通用SaaS；IP-ASN 仅保留厂商自有网段\n' \
      "$name" "$(date '+%Y-%m-%d %H:%M:%S')"
    if [ "$manual" != "-" ] && [ -f "$manual" ]; then
      printf '# 含本机手动补充：%s\n' "$manual"
    fi
    printf '\n'
    # 按「值」去重：同一域名的 DOMAIN,x 与 DOMAIN-SUFFIX,x 是冗余（后者覆盖前者），
    # 只保留 DOMAIN-SUFFIX。key 必须**只用值**（不含类型），否则两者 key 不同、去不掉。
    # 其它类型（IP-CIDR/PROCESS-NAME/…）取值不会与域名撞车，按值去重同样安全。
    sort -u "$raw" | awk -F, '
      { key = $2; sub(/[ \t]+$/, "", key)
        if (key in seen) { if ($1=="DOMAIN-SUFFIX") lines[key]=$0 }
        else { seen[key]=1; lines[key]=$0; order[++n]=key } }
      END { for (i=1;i<=n;i++) print lines[order[i]] }' \
    | python3 -c '
import sys
# 再收一层「后缀冗余」：DOMAIN-SUFFIX 子域被同表的父域覆盖时是死规则
# （a.b.com 恒被 b.com 命中），删掉。只处理 DOMAIN-SUFFIX（后缀包含关系明确）；
# DOMAIN 不参与 —— 精确名不被父域"覆盖"（语义不同，且可能被父域规则一起搬走）。
rows=[]; suf=set()
for ln in sys.stdin:
    ln=ln.rstrip("\n"); rows.append(ln)
    if ln.startswith("DOMAIN-SUFFIX,"): suf.add(ln.split(",",1)[1].strip().lower())
out=[]
for ln in rows:
    if ln.startswith("DOMAIN-SUFFIX,"):
        d=ln.split(",",1)[1].strip().lower(); p=d.split(".")
        if any(".".join(p[i:]) in suf for i in range(1,len(p)-1)):
            continue
    out.append(ln)
sys.stdout.write("\n".join(out)+("\n" if out else ""))'
  } > "$opt"
  rm -f "$raw"

  # 只在「真变化」时重写该文件。
  # 比较时**只**剔掉 `# GEN:` 那一行（每次生成时间都不同，否则每天一条空提交）；
  # 其余注释（# NAME / # NOTE / # 含本机手动补充）**参与比较** ——
  # 曾经的写法是剔掉全部注释行，结果改了 NOTE/表头说明却永远不生效
  # （只在规则恰好也变了的那天才顺带写出去，很难发现）。别改回 `grep -vE '^#'`。
  norm() { grep -vE '^# GEN:' "$1"; }
  if [ -f "$out" ] && \
     diff -q <(norm "$out") <(norm "$opt") >/dev/null 2>&1; then
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

B="$BUILD"   # 中间产物目录
rm -rf "$B"; mkdir -p "$B"
mkdir -p "$OUTDIR"   # surge/ （生成表输出目录；.gitignore 已放行）

# ── ① 先建国内 AI 集合（DIRECT）─────────────────────────────
# 它是后面所有海外表的「排除集」：任何被它覆盖的域名，都会从海外表里结构化剔除，
# 从而彻底消除「海外表混入国内域名 → 被误走代理」的问题（不再依赖规则顺序兜底）。
if collect "$B/cn.raw" "$VPS/cn.list"; then
  gen AI-CN.list "AI-CN" "AI-Supplement-CN.list" "$B/cn.raw"
else
  printf 'SKIP %-28s 源失败 → 保留旧文件，不覆盖\n' "$OUTDIR/AI-CN.list" >&2
  problem=$((problem + 1))
fi

# ── ② 聚合源只抓一次（品牌表 + Others 都从这里取）────────────
# 聚合源（SukkaW ai.conf / ACL4SSR AI.list / Rabbit AIGC.list / dler AI Suite.list）
# 是「什么 AI 都有」的大杂烩。旧版把它们整份并进每张品牌表 → 严重污染：
# 实测 AI-OpenAI 有 64%、AI-Claude 76%、AI-Gemini 47%、AI-Copilot 68% 的行其实是别家域名。
# 现在改为：品牌表只取「匹配本品牌签名的」，其余留给 AI-Overseas-Others。
have_agg=1
if ! collect "$B/agg.raw" "$SUKKA/ai.conf" "$DLER/AI%20Suite.list" "$ACL4/AI.list" "$RABBIT/AIGC.list"; then
  have_agg=0; problem=$((problem + 1))
  printf '!! 聚合源抓取失败 → 品牌表将只剩本品牌源，Others 会缩水\n' >&2
fi

# 品牌表：品牌专用源（原样并入）+ 聚合源中匹配本品牌签名的 + 剔除国内域名 + 跨品牌去重
# 跨品牌去重按「先建者优先」：OpenAI > Claude > Gemini > Copilot > JetBrains。
# 品牌源之间有合法重叠（Copilot 表按上游设计含 openai.com 等），但同一域名进两张表
# 意味着后者被前者遮蔽、成为死规则 —— 让每个域名只归属一张表更干净。
: > "$B/claimed"
export DEDUP_AGAINST="$B/claimed"   # gen 里对手写补充表也做去重（claimed 逐步增长）
mkbrand() { # $1=表名(ex AI-OpenAI)  $2=manualfile  $3..=品牌专用 urls
  local t="$1" manual="$2"; shift 2
  local m="$B/$t"
  # 聚合源失败时不要退化成「只剩品牌专用源」—— 那会让品牌表静默缩水（覆盖面丢失）。
  # 与源失败同一处理：保留旧文件，严格模式下让整个任务失败。
  if [ "$have_agg" != 1 ]; then
    printf 'SKIP %-28s 聚合源失败 → 保留旧文件，不覆盖\n' "$t.list" >&2
    problem=$((problem + 1)); return 1
  fi
  if ! collect "$m.brand.raw" "$@"; then
    printf 'SKIP %-28s 品牌源失败 → 保留旧文件，不覆盖\n' "$t.list" >&2
    problem=$((problem + 1)); return 1
  fi
  cp "$m.brand.raw" "$m.merged"
  [ "$have_agg" = 1 ] && brand_pick "$t" "$B/agg.raw" >> "$m.merged"
  # 跨品牌去重（先建的品牌已登记在 claimed 里）
  drop_covered "$m.merged" "$B/claimed" > "$m.d1" && mv "$m.d1" "$m.merged"
  # 结构性隔离：国内域名不进任何海外表
  [ -f "$OUTDIR/AI-CN.list" ] && { drop_covered "$m.merged" "$OUTDIR/AI-CN.list" > "$m.d2" && mv "$m.d2" "$m.merged"; }
  gen "$t.list" "$t" "$manual" "$m.merged"
  cat "$m.merged" >> "$B/claimed"
}

mkbrand AI-OpenAI   "AI-Supplement-OpenAI.list" \
    "$BM7/OpenAI/OpenAI.list" "$VPS/openai.list" "$ACL4/OpenAi.list"

mkbrand AI-Claude   "AI-Supplement-Claude.list" \
    "$BM7/Claude/Claude.list" "$BM7/Anthropic/Anthropic.list" "$VPS/anthropic.list" "$ACL4/Claude.list" "$ACL4/ClaudeAI.list"

mkbrand AI-Gemini   "AI-Supplement-Gemini.list" \
    "$BM7/Gemini/Gemini.list" "$BM7/BardAI/BardAI.list" "$VPS/google-ai.list" "$ACL4/Gemini.list"

mkbrand AI-Copilot  "-" \
    "$BM7/Copilot/Copilot.list" "$VPS/copilot.list"

mkbrand AI-Jetbrains "-" \
    "$BM7/Jetbrains/Jetbrains.list" "$VPS/jetbrains-ai.list" "$ACL4/JetBrains.list"

# ── ③ 其余海外 AI：聚合源里「没被任何品牌表收走」的部分 ──────
# 用补集而非硬编码清单 —— 品牌表收哪个域名是运行时决定的，这里必须跟着它走，
# 否则要么重复（同一域名进两张表）要么漏（谁都不要）。
if [ "$have_agg" = 1 ]; then
  cp "$B/agg.raw" "$B/others.clean"
  # 先剔除已被品牌表覆盖的（用 claimed 集合，与品牌表口径完全一致）
  drop_covered "$B/others.clean" "$B/claimed" > "$B/others.c1" && mv "$B/others.c1" "$B/others.clean"
  # 再剔除国内域名
  [ -f "$OUTDIR/AI-CN.list" ] && { drop_covered "$B/others.clean" "$OUTDIR/AI-CN.list" > "$B/others.c2" && mv "$B/others.c2" "$B/others.clean"; }

  # VPSDance 的杂项品牌源（xAI/Meta/Cursor/…）也归这里，但也要过一遍去重
  collect "$B/others.misc" \
      "$VPS/x-ai.list" "$VPS/meta-ai.list" "$VPS/cursor.list" "$VPS/windsurf.list" \
      "$VPS/opencode.list" "$VPS/cline.list" "$VPS/zed.list" "$VPS/model.list" "$VPS/media.list" \
      "$VPS/global.list" "$VPS/coding.list" "$VPS/all.list" \
      "$BM7/aiXcoder/aiXcoder.list" "$BM7/Civitai/Civitai.list" || problem=$((problem + 1))
  # 剔除已被任何品牌表收走的（用 claimed 集合，与品牌表口径完全一致）
  drop_covered "$B/others.misc" "$B/claimed" > "$B/others.m1" && mv "$B/others.m1" "$B/others.misc"
  [ -f "$OUTDIR/AI-CN.list" ] && { drop_covered "$B/others.misc" "$OUTDIR/AI-CN.list" > "$B/others.m2" && mv "$B/others.m2" "$B/others.misc"; }

  gen AI-Overseas-Others.list "AI-Overseas-Others" "AI-Supplement.list" \
      "$B/others.clean" "$B/others.misc"
else
  printf 'SKIP %-28s 聚合源失败 → 保留旧文件，不覆盖\n' "$OUTDIR/AI-Overseas-Others.list" >&2
fi

rm -rf "$B"
echo "完成。Surge 会自动重载本机 list（无需手动 reload）。"

# 严格模式下：只要有任何一张表出问题，就以退出码 2 失败，阻止 CI 的提交步骤。
if [ "$STRICT" = 1 ] && [ "$problem" -gt 0 ]; then
  printf '\n\033[31m严格模式：%d 张表有问题，退出码 2（不提交）\033[0m\n' "$problem" >&2
  exit 2
fi
exit 0

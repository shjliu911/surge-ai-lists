#!/bin/bash
# 校验生成出来的 *.list：① 每行都是合法 Surge 规则类型 ② 关键国内 AI 域名确实在 AI-CN.list
# 供 CI 在生成后、提交前调用；退出码非 0 则阻止提交。
# 用法：./check-ai-lists.sh
set -u
cd "$(dirname "$0")" || exit 1
fail=0

# ── 1) 格式：每行前缀必须是已知规则类型 ──────────────────
VALID='^(DOMAIN|DOMAIN-SUFFIX|DOMAIN-KEYWORD|DOMAIN-SET|DOMAIN-WILDCARD|IP-CIDR|IP-CIDR6|IP6-CIDR|IP-ASN|URL-REGEX|USER-AGENT|PROCESS-NAME|PROCESS-PATH|GEOIP|RULE-SET|SRC-IP|SUBNET|DEST-PORT|PROTOCOL),'
for f in AI-*.list; do
  [ -e "$f" ] || continue
  bad=$(grep -vE '^[[:space:]]*(#|$)' "$f" | grep -vE "$VALID" || true)
  if [ -n "$bad" ]; then
    echo "✗ $f 有非法规则行："; echo "$bad" | head -5; fail=1
  fi
done
[ "$fail" = 0 ] && echo "✓ 格式检查通过（$(ls AI-*.list | wc -l | tr -d ' ') 张表）"

# ── 2) 断言：AI-CN.list 必须覆盖关键国内 AI 域名 ─────────
# 这些是用户日常在用的；缺任何一个都说明上游源出问题、或过滤误伤。
KEY_CN="deepseek.com moonshot.cn zhipuai.cn bigmodel.cn chatglm.cn \
dashscope.aliyuncs.com tongyi.aliyun.com qwen.ai \
yiyan.baidu.com ernie.baidu.com qianfan.baidubce.com \
doubao.com volcengine.com coze.cn \
hunyuan.tencent.com yuanbao.tencent.com \
siliconflow.cn modelscope.cn minimaxi.com hailuoai.com \
stepfun.com sensenova.cn xfyun.cn"
missing=""
for d in $KEY_CN; do
  grep -qE "^(DOMAIN(-SUFFIX)?,)$d\$" AI-CN.list 2>/dev/null || missing="$missing $d"
done
if [ -n "$missing" ]; then
  echo "✗ AI-CN.list 缺少关键国内 AI 域名：$missing"; fail=1
else
  echo "✓ AI-CN 关键域名齐全（$(echo $KEY_CN | wc -w | tr -d ' ') 个）"
fi

# ── 3) 断言：不得出现明显的非 AI 通用 SaaS ────────────────
LEAK=$(grep -rhE '^DOMAIN(-SUFFIX)?,(js\.)?stripe\.com$|^DOMAIN-SUFFIX,auth0\.com$|^DOMAIN-SUFFIX,segment\.io$|^DOMAIN-SUFFIX,datadoghq\.com$' AI-*.list || true)
if [ -n "$LEAK" ]; then
  echo "✗ 通用 SaaS 泄漏进 AI 表："; echo "$LEAK"; fail=1
else
  echo "✓ 无通用 SaaS 泄漏"
fi

# ── 4) 断言：海外表里不得出现被国内集合覆盖的域名（结构性隔离）──
if python3 - <<'PY'
import sys
cn=set()
for ln in open('AI-CN.list'):
    t=ln.strip()
    if t.startswith(('DOMAIN,','DOMAIN-SUFFIX,')):
        cn.add(t.split(',',1)[1].split(',')[0].strip().lower())
def is_cn(d):
    if d in cn: return True
    p=d.split('.')
    return any('.'.join(p[i:]) in cn for i in range(len(p)-1))
bad=[]
for f in ['AI-OpenAI.list','AI-Claude.list','AI-Gemini.list','AI-Copilot.list','AI-Jetbrains.list','AI-Overseas-Others.list']:
    try: lines=open(f)
    except FileNotFoundError: continue
    for ln in lines:
        t=ln.strip()
        if t.startswith(('DOMAIN,','DOMAIN-SUFFIX,')) and is_cn(t.split(',',1)[1]):
            bad.append(f+': '+t)
if bad:
    print("\n".join(bad[:10])); sys.exit(1)
PY
then echo "✓ 海外表无国内域名混入（结构性隔离生效）"
else echo "✗ 海外表混入了国内域名（见上）"; fail=1
fi

# ── 5) 断言：每个域名只归属一张表（跨表唯一）──────────────
# 品牌表之间有合法重叠（Copilot 按上游设计含 openai.com），但同一域名进两张表
# 意味着后者被前者遮蔽 → 死规则。生成器已按「先建者优先」去重，这里守住它。
if python3 - <<'PY'
import sys
from collections import Counter
T=['AI-CN','AI-OpenAI','AI-Claude','AI-Gemini','AI-Copilot','AI-Jetbrains','AI-Overseas-Others']
c=Counter(); owner={}
for t in T:
    try: fh=open(t+'.list')
    except FileNotFoundError: continue
    for ln in fh:
        ln=ln.strip()
        if not ln.startswith(('DOMAIN,','DOMAIN-SUFFIX,')): continue
        d=ln.split(',',1)[1].split(',')[0].strip().lower()
        if d in owner and owner[d]!=t: c[d]+=1; print(f'  {d} 同时在 {owner[d]} 与 {t}')
        else: owner.setdefault(d,t)
sys.exit(1 if c else 0)
PY
then echo "✓ 跨表无重复域名（归属唯一）"
else echo "✗ 同一域名出现在多张表（见上）"; fail=1
fi

# ── 6) 断言：品牌表纯度（聚合源不得把别家 AI 灌进品牌表）────
# 这是 2026-10-12 修复的那次事故：四个聚合源（SukkaW ai.conf / ACL4SSR AI.list /
# Rabbit AIGC.list / dler AI Suite.list）曾被整份并入每张品牌表 →
# AI-OpenAI 64% / AI-Claude 76% / AI-Gemini 47% / AI-Copilot 68% 的行是别家域名。
if python3 - <<'PY'
import sys, re
SIG={
 'AI-OpenAI':  r'openai|chatgpt|oaistatic|oaiusercontent|sora\.com|crixet|livekit|oaistatsig|(^|\.)ai\.com$|(^|\.)chat\.com$',
 'AI-Claude':  r'claude|anthropic|(^|\.)clau\.de$|modelcontextprotocol|mcpserver|antspace|lcic|interface\.feedback|chatbotclaude|muthos|sillylittleguy',
 'AI-Gemini':  r'gemini|bard|makersuite|notebooklm|deepmind|jules|opal|antigravity|aisandbox|cloudcode|aistudio|generativelanguage|stitch|labstailwind|aicode|robinfrontend|jetski|geller|proactivebackend|generativeai|flow\.google|notebook\.google|gemini\.gstatic|(^|\.)ai\.google|(^|\.)ai\.studio|(^|\.)g\.ai$|apis\.google|clients6|goog$',
 'AI-Copilot': r'copilot|bing|microsoft|msn|github|openai|chatgpt|oaistatic|oaiuser|livekit|appcenter|officeapps',
 'AI-Jetbrains':r'jetbrains|intellij|grazie|jedi|junie|kotlin|datalore',
}
THRESHOLD=0.80   # 品牌域名占比下限（留足余量；实测均 ≥80%）
bad=0
for t,rx in SIG.items():
    try: lines=[l.strip() for l in open(t+'.list') if l.strip() and not l.startswith('#')]
    except FileNotFoundError: continue
    dom=[l for l in lines if l.startswith(('DOMAIN,','DOMAIN-SUFFIX,','DOMAIN-KEYWORD'))]
    if not dom: continue
    R=re.compile(rx,re.I)
    ok=sum(1 for l in dom if R.search(l.split(',',1)[1].split(',')[0]))
    ratio=ok/len(dom)
    if ratio < THRESHOLD:
        print(f'  {t}: 本品牌占比 {ratio*100:.0f}%（< {THRESHOLD*100:.0f}%）—— 疑似聚合源污染')
        bad+=1
sys.exit(1 if bad else 0)
PY
then echo "✓ 品牌表纯度达标（无聚合源污染）"
else echo "✗ 品牌表被别家 AI 污染（见上）"; fail=1
fi

exit $fail

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
for f in ['AI-OpenAI.list','AI-Claude.list','AI-Gemini.list','AI-Copilot.list','AI-Jetbrains.list','AI-Misc.list']:
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

exit $fail

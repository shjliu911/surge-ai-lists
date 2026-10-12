#!/bin/bash
# 品牌串表检查：**别家的定义性域名**不得出现在本品牌表里。
#
# 为什么单独一个脚本（与 check-ai-lists.sh 第 6 项的差别）：
#   第 6 项查的是「本品牌占比 ≥80%」—— 是个**统计**，能发现大面积的聚合源污染，
#   但查不出「Gemini 表里混进了 1 条 claude.ai」这种少量串表。
#   本脚本按**品牌签名**逐条反查：OpenAI 表里出现任何 anthropic/claude 域名即失败。
#   这正是 2026-10-12 那次事故（claude.ai 躺在 Gemini 表 / openai.com 躺在 Copilot 表）
#   的精确防线 —— 统计断言当时可能仍显示"达标"，而这里会直接点名。
#
# 用法：./check-brand-isolation.sh
set -u
cd "$(dirname "$0")" || exit 1

python3 - <<'PY'
import sys, re

# 各品牌的「定义性」域名模式。命中即认定属于该品牌。
# 原则：贴合品牌名/产品名，避开过于通用的词（否则互相误报）。
BRAND = {
 'AI-OpenAI':   r'(^|\.)openai\.com$|(^|\.)openai\.(?:dev)$|chatgpt|oaistatic|oaiusercontent|(^|\.)sora\.com$|(^|\.)ai\.com$|(^|\.)chat\.com$|crixet',
 'AI-Claude':   r'claude|anthropic|(^|\.)clau\.de$|chatbotclaude|modelcontextprotocol|claudemcp|claudeusercontent|claudepages|claudestudio',
 'AI-Gemini':   r'gemini|(^|\.)bard\.|makersuite|notebooklm|deepmind|(^|\.)jules\.|(^|\.)opal\.|antigravity|aistudio|aisandbox|cloudcode|generativelanguage|labstailwind|(^|\.)labs\.google$|flow\.google',
 'AI-Copilot':  r'copilot|(^|\.)bing\.com$|bingapis|bingviz|bing-shopping|(^|\.)msn\.com$|microsoft|githubcopilot',
 'AI-Jetbrains':r'jetbrains|intellij|grazie|datalore|kotlin',
}
# 允许的跨品牌例外（域名模式 : 理由）。保持**极简** —— 每加一条都是放松防线。
ALLOW = [
  # Copilot 按上游设计会调 OpenAI 的端点（模型后端），但域名归属仍应唯一；
  # 若确有共享域，在此显式登记而不是放任。
]

tables = ['AI-OpenAI','AI-Claude','AI-Gemini','AI-Copilot','AI-Jetbrains']
bad = 0
for t in tables:
    try: fh = open(t + '.list')
    except FileNotFoundError: continue
    for ln in fh:
        ln = ln.strip()
        if not ln or ln.startswith('#'): continue
        k = ln.split(',',1)[0].upper()
        if k not in ('DOMAIN','DOMAIN-SUFFIX','DOMAIN-KEYWORD'): continue
        d = ln.split(',',1)[1].split(',')[0].strip().lower()
        if any(re.search(p, d) for p in ALLOW): continue
        for owner, pat in BRAND.items():
            if owner == t: continue
            if re.search(pat, d, re.I):
                print(f'  ✗ {t} 里出现 {owner} 的域名: {ln}')
                bad += 1
                break

if bad:
    print(f'\n共 {bad} 处品牌串表 —— 生成器的 brand_pick/claimed 归属逻辑可能回归。')
    sys.exit(1)
print('✓ 品牌表之间无串表（各家定义域各归其表）')
PY

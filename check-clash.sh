#!/bin/bash
# 校验 to-clash.sh 的产物：clash/*.yaml 必须是合法、非空、且与源表逐条对得上的 rule-provider。
#
# 守的三件事（对应历史踩过的坑）：
#   1) 格式：可被 YAML 解析、含非空 payload 列表 —— 否则 mihomo 拉下来直接报错。
#   2) 数量对账：payload 条数 == 源表规则数 − 被丢弃的 URL-REGEX 条数。
#      「静默丢行」比「格式错」更危险 —— mihomo 不报错、规则却少了。
#   3) 类型白名单：payload 里出现的规则类型必须在 mihomo 支持集内。
#      防以后 Surge 侧引入了新类型、转换器没跟着更新，就悄悄漏到 Clash 端。
set -u
cd "$(dirname "$0")" || exit 1
fail=0

python3 - <<'PY'
import sys, glob, os, re
try:
    import yaml
except ImportError:
    print("✗ 缺少 python3 yaml 模块（pip install pyyaml / apt install python3-yaml）")
    sys.exit(1)

# mihomo classical provider 支持的规则类型（2026-10 官方文档核对）。
# URL-REGEX 不在其中 —— Surge 独有，转换器会丢弃并计数。
SUPPORTED = {
    'DOMAIN', 'DOMAIN-SUFFIX', 'DOMAIN-KEYWORD', 'DOMAIN-WILDCARD', 'DOMAIN-REGEX',
    'IP-CIDR', 'IP-CIDR6', 'IP-SUFFIX', 'IP-ASN', 'GEOIP',
    'SRC-GEOIP', 'SRC-IP-ASN', 'SRC-IP-CIDR', 'SRC-IP-SUFFIX',
    'DST-PORT', 'SRC-PORT', 'IN-PORT', 'IN-TYPE', 'IN-USER', 'IN-NAME',
    'PROCESS-NAME', 'PROCESS-PATH', 'PROCESS-NAME-REGEX', 'PROCESS-PATH-REGEX',
    'UID', 'NETWORK', 'DSCP', 'RULE-SET', 'GEOSITE', 'MATCH',
}

files = sorted(glob.glob('clash/AI-*.yaml'))
if not files:
    print("✗ 没有找到 clash/*.yaml（to-clash.sh 是否跑过？）")
    sys.exit(1)

fail = 0
total_p = 0
for f in files:
    base = os.path.basename(f)
    src = 'AI-' + base[len('AI-'):-len('.yaml')] + '.list'
    # 1) YAML 可解析 + 结构
    try:
        doc = yaml.safe_load(open(f, encoding='utf-8'))
    except Exception as e:
        print(f"✗ {base}: YAML 解析失败: {e}"); fail = 1; continue
    if not isinstance(doc, dict) or not isinstance(doc.get('payload'), list):
        print(f"✗ {base}: 缺少 payload 列表"); fail = 1; continue
    payload = doc['payload']
    if not payload:
        print(f"✗ {base}: payload 为空"); fail = 1; continue

    # 3) 类型白名单
    bad = [p for p in payload if str(p).split(',', 1)[0].strip().upper() not in SUPPORTED]
    if bad:
        print(f"✗ {base}: 含 mihomo 不支持的规则类型：{bad[:3]}"); fail = 1

    # 2) 数量对账
    if not os.path.exists(src):
        print(f"✗ {base}: 源表 {src} 不存在，无法对账"); fail = 1; continue
    slines = [l for l in open(src, encoding='utf-8').read().splitlines()
              if l.strip() and not l.strip().startswith('#')]
    drop = sum(1 for l in slines if l.startswith('URL-REGEX,'))
    if len(payload) != len(slines) - drop:
        print(f"✗ {base}: 对账失败 payload={len(payload)} 源={len(slines)} 丢弃={drop}")
        fail = 1
    else:
        print(f"✓ {base}: {len(payload)} 条（源 {len(slines)}，丢弃 URL-REGEX {drop}）")
    total_p += len(payload)

if fail == 0:
    print(f"✓ Clash 规则集校验通过（{len(files)} 张表，共 {total_p} 条）")
sys.exit(fail)
PY

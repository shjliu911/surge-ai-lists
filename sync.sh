#!/bin/bash
# 一条命令完成 AI 规则集的全流程：刷新 → 部署到 Surge → 提交推送。
#
#   ./sync.sh            刷新(拉上游) → 部署 → 有变化才提交+推送
#   ./sync.sh --no-pull  跳过拉上游，只把当前仓库内容部署+提交（改了手写表后用）
#   ./sync.sh --dry-run  只显示会做什么，不动任何文件
#
# 设计要点：
#   - 仓库是「留痕副本」，Surge 读的是 Profiles 下的「生效副本」。本脚本负责把两者对齐。
#   - 生成表每次刷新的 GEN 时间戳都会变 → 用 `git status --porcelain` 判断「内容是否真变」，
#     只有真变才提交，避免每天顶一条无意义 commit。
set -u

REPO="$(cd "$(dirname "$0")" && pwd)"
PROFILES="$HOME/Library/Application Support/Surge/Profiles"
DRY=0; NOPULL=0
for a in "$@"; do case "$a" in
  --dry-run) DRY=1;;
  --no-pull) NOPULL=1;;
  *) echo "未知参数: $a"; exit 2;;
esac; done

cd "$REPO" || exit 1
say() { printf '\033[36m▸\033[0m %s\n' "$*"; }
run() { if [ "$DRY" = 1 ]; then echo "    [dry-run] $*"; else eval "$@"; fi; }

[ -d "$PROFILES" ] || { echo "找不到 Surge Profiles 目录: $PROFILES"; exit 1; }

# ── 1. 刷新（拉上游，重写 7 张生成表）────────────────────────
if [ "$NOPULL" = 1 ]; then
  say "跳过上游刷新（--no-pull）"
else
  say "刷新生成表（blackmatrix7 + VPSDance + SukkaW + dler-io + ACL4SSR + Rabbit-Spec → 7 张 AI-*.list）"
  run '"$REPO/refresh-ai-lists.sh"'
fi

# ── 1b. 由 Surge 表派生 Clash/mihomo rule-provider ─────────────
# 与 Surge 表同源、同一次生成，保证两套格式内容一致（「Surge 更新 → Clash 随之更新」）。
say "转换 Clash/mihomo rule-provider（clash/*.yaml）"
run '"$REPO/to-clash.sh"'

# ── 2. 同步到 Surge Profiles（本地备份副本，供离线查看/回滚）────────
# 注意：lll.conf 现在用 RULE-SET,<仓库 URL> 引用，Surge **不再读**这里的 .list。
# 这一步只是让 Profiles 目录留一份与仓库一致的副本，方便本地比对/手工回滚。
say "同步本地副本到 Surge Profiles（备份用）"
run "mkdir -p \"$PROFILES/surge\""
for f in surge/AI-*.list refresh-ai-lists.sh; do
  [ -e "$f" ] || continue
  if ! cmp -s "$f" "$PROFILES/$f"; then
    run "cp \"$f\" \"$PROFILES/$f\""
    echo "    ↑ $f"
  fi
done
# Clash 产物也留一份副本到 Profiles/clash/（便于离线查看；Clash 端不读这里，只作备份）
if [ -d clash ]; then
  run "mkdir -p \"$PROFILES/clash\""
  for f in clash/*.yaml; do
    [ -e "$f" ] || continue
    if ! cmp -s "$f" "$PROFILES/$f"; then
      run "cp \"$f\" \"$PROFILES/$f\""
      echo "    ↑ $f"
    fi
  done
fi
[ "$DRY" = 1 ] || chmod +x "$PROFILES/refresh-ai-lists.sh" 2>/dev/null

# ── 3. 安全检查：绝不提交敏感文件 ─────────────────────────
if git ls-files | grep -qE '\.conf$|\.bak|lll\.conf'; then
  echo "!!! 中止：仓库跟踪了敏感文件"; git ls-files | grep -E '\.conf$|\.bak|lll\.conf'; exit 1
fi

# ── 4. 有实质变化才提交 + 推送 ────────────────────────────
if [ -z "$(git status --porcelain)" ]; then
  say "内容无变化，无需提交"
  exit 0
fi

say "检测到变化："
if [ "$DRY" = 1 ]; then git --no-pager diff --stat; else git --no-pager diff --stat; fi

# 生成变更摘要（新增/删除的规则条数）
SUMMARY=$(git --no-pager diff --numstat -- '*.list' 'clash/' | awk '{a+=$1;d+=$2} END{printf "+%d/-%d 行", a, d}')
MSG="refresh: $(date +%F)  (${SUMMARY:-无行变})"

run "git add -A"
run "git commit -q -m \"$MSG\""
if [ "$DRY" = 1 ]; then
  echo "    [dry-run] git push"
else
  say "推送到 GitHub"
  # 竞态兜底：CI 可能刚好同时推过，remote 领先 → 先 rebase 再重试。
  ok=0
  for i in 1 2 3; do
    if git push -q origin main; then ok=1; break; fi
    echo "    push 被拒，rebase 后重试 (#$i)…"
    git pull -q --rebase --autostash origin main || { echo "    ✗ rebase 冲突，需人工处理"; break; }
  done
  [ "$ok" = 1 ] && echo "    ✓ 已推送" || echo "    ✗ 推送未成功"
fi

# ── 5. 让 Surge 立刻重拉远程 list ─────────────────────────
# lll.conf 现在用 RULE-SET,<仓库 URL> 引用，Surge 有自己的拉取周期。
# push 之后主动触发一次重拉，新规则即时生效（否则要等 Surge 下次自己拉）。
CLI="/Applications/Surge.app/Contents/Applications/surge-cli"
if [ "$DRY" = 1 ]; then
  echo "    [dry-run] 触发 Surge 重拉 AI list"
elif [ -x "$CLI" ]; then
  keys=$("$CLI" external-resource list --raw 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
rows = d.get("defines", d) if isinstance(d, dict) else d
for r in rows:
    if isinstance(r, dict) and "shjliu911/surge-ai-lists" in str(r.get("path","")):
        print(r.get("key",""))
' 2>/dev/null)
  if [ -n "$keys" ]; then
    say "触发 Surge 重拉 AI list"
    n=0
    for k in $keys; do
      "$CLI" external-resource update "$k" >/dev/null 2>&1 && n=$((n+1))
    done
    echo "    ✓ 已触发 $n 个远程 list 重拉"
  else
    echo "    ! 未能在 Surge 中找到本仓库资源（配置可能还没改成远程 URL）"
  fi
fi
say "完成：$MSG"

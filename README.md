# Surge AI 规则集（个人维护）

把 Surge 配置里 **AI 分流相关的本地规则集**纳入版本管理，方便随时回滚、跨机同步、留痕。

> ⚠️ **本仓库永不包含 `lll.conf`**。它里面有机场订阅 token 与 MITM 的 CA 私钥口令，
> 靠 `.gitignore` 的**白名单**（`*` + `!`）排除掉——只有下面列出的文件会被跟踪。

## 文件一览

| 文件 | 维护方式 | 策略组 |
|---|---|---|
| `AI-OpenAI.list` | 脚本生成 | 🧠 ChatGPT |
| `AI-Claude.list` | 脚本生成 | 🎭 Claude |
| `AI-Gemini.list` | 脚本生成 | 💎 Gemini |
| `AI-Copilot.list` | 脚本生成 | 🤖 AI 服务 |
| `AI-Jetbrains.list` | 脚本生成 | 🤖 AI 服务 |
| `AI-Misc.list` | 脚本生成 | 🤖 AI 服务 |
| `AI-Supplement-OpenAI.list` | **人工** | 折进 AI-OpenAI |
| `AI-Supplement-Claude.list` | **人工** | 折进 AI-Claude |
| `AI-Supplement-Gemini.list` | **人工** | 折进 AI-Gemini |
| `AI-Supplement.list` | **人工** | 折进 AI-Misc |
| `AI-CN.list` | **人工** | DIRECT（国内 AI） |
| `refresh-ai-lists.sh` | 引擎 | 生成上面 6 张主表 |

**生成 vs 人工**：`AI-Supplement*.list` 和 `AI-CN.list` 是**手写**的，脚本永不覆盖；
`refresh-ai-lists.sh` 把两源（blackmatrix7 + VPSDance）拉下来，剔除宽泛规则后，
再把对应的手写补充表折进去，写出 6 张主表。

## 为什么用本地文件、不直接 `RULE-SET` 远程 URL

上游 list 带宽泛的 **`IP-ASN`**（`14061` DigitalOcean、`20473` Vultr）与通用
`DOMAIN-KEYWORD`（sift/datadog/sentry）和通用 SaaS 域名（stripe/auth0/sentry…），
会按 ASN/关键字命中**大量非 AI 站点**，把它们一起拉进 AI 策略组。

Surge **无法对远程 list 做预过滤**（`RULE-SET` 只接受 URL 或本地路径），
所以「实时同步上游」与「不误抓」只能二选一 → 用**本地生成 + 定时任务**两全。

## 刷新流程

```bash
# 1) 手动跑一次（正常由 launchd 每天 09:17 / 21:17 自动跑）
./refresh-ai-lists.sh

# 2) 同步回 Surge（本机副本 → Surge Profiles）
cp AI-*.list refresh-ai-lists.sh \
   "/Users/coniublity/Library/Application Support/Surge/Profiles/"

# 3) 提交留痕
git add -A && git commit -m "refresh: $(date +%F)"
```

Surge **会自动热重载本机 list，无需手动 reload**。

## launchd

| 项 | 值 |
|---|---|
| 标签 | `com.user.surge-ai-lists` |
| 脚本 | `~/Library/LaunchAgents/com.user.surge-ai-lists.plist` |
| 频率 | 每天 09:17、21:17 |
| 日志 | `~/Library/Logs/surge-ai-lists.log` |

## 敏感点（改脚本前先看）

- `filter()` **全剔 `IP-ASN`**，但**保留 `IP-CIDR`**——那是服务商自有精确网段（如 Anthropic `160.79.104.0/21`）。
- `oaistatsig.com` 是 **OpenAI 自己的**，会被 `statsig` 正则误伤（假阳性），**别删**。
- `[Host]` 段不认 `DOMAIN-SUFFIX,x = server:...`，要写 `*x = server:...`。
- 改 Surge 配置的标准流程：`surge-cli --check <file>` → `reload` → `flush dns`。

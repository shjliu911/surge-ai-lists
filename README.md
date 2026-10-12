# Surge AI 规则集（个人维护）

Surge 的 AI 分流规则集。`lll.conf` 通过 **`RULE-SET,<本仓库 raw URL>`** 直接引用这些文件——
仓库既是版本管理，也是**运行时数据源**。改这里 → 推送 → Surge 重拉即生效。

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
| `AI-Overseas-Others.list` | 脚本生成 | 🤖 AI 服务 |
| `AI-Supplement-OpenAI.list` | **人工** | 折进 AI-OpenAI |
| `AI-Supplement-Claude.list` | **人工** | 折进 AI-Claude |
| `AI-Supplement-Gemini.list` | **人工** | 折进 AI-Gemini |
| `AI-Supplement.list` | **人工** | 折进 AI-Overseas-Others |
| `AI-CN.list` | **人工** | DIRECT（国内 AI） |
| `refresh-ai-lists.sh` | 引擎 | 生成 7 张主表 |
| `check-ai-lists.sh` | 引擎 | CI 校验：格式 / 关键国内 AI 域名 / SaaS 泄漏 |

**生成 vs 人工**：`AI-Supplement*.list` 和 `AI-CN.list` 是**手写**的，脚本永不覆盖；
`refresh-ai-lists.sh` 把两源（blackmatrix7 + VPSDance）拉下来，剔除宽泛规则后，
再把对应的手写补充表折进去，写出 6 张主表。

## 上游源（多源合并，查缺补漏）

单一上游一定有遗漏，所以**取并集**。当前合并 6 个源：

| 源 | 提供什么 |
|---|---|
| **blackmatrix7/ios_rule_script** | 海外分服务细表（OpenAI/Claude/Gemini/Copilot/Jetbrains/Civitai…）|
| **VPSDance/ai-proxy-rules** | `cn`（中国 AI 聚合）+ `global`/`coding`/`all` + 各 provider（x-ai/cursor/windsurf…）|
| **SukkaW/Surge** | `Source/non_ip/ai.conf` 人工精选 —— **聚合源** |
| **dler-io/Rules** | `AI Suite.list`（247 条，含 Azure OpenAI IP）—— **聚合源** |
| **ACL4SSR/ACL4SSR** | `OpenAi`/`Claude`/`Gemini`/`JetBrains.list`（品牌）+ `AI.list`（**聚合**）|
| **Rabbit-Spec/Surge** | `AIGC.list`（129 条）—— **聚合源** |

### 品牌归属：聚合源不能整份并进品牌表（重要）

上游源分两类，混用会出事：

- **品牌专用源** —— 只含本品牌（`BM7/OpenAI/OpenAI.list` 35 行、`VPS/openai.list` 51 行…）。
  品牌源里可以合法地含别家域名（Copilot 按上游设计要 `openai.com`），所以**原样并入**。
- **聚合源** —— 什么 AI 都有（SukkaW `ai.conf`、dler `AI Suite`、ACL4SSR `AI.list`、Rabbit `AIGC`）。

**2026-10-12 修的一次事故**：聚合源曾被整份并进**每一张**品牌表 → 实测
`AI-OpenAI` 有 **64%**、`AI-Claude` **76%**、`AI-Gemini` **47%**、`AI-Copilot` **68%**
的行是别家域名（`claude.ai` 躺在 Gemini 表里之类）。

现在改为：**品牌表 = 品牌专用源 + 聚合源中匹配本品牌签名的条目**；
剩下的聚合条目归 `AI-Overseas-Others`。归属保证：
1. **每个域名只进一张表**（`$B/claimed` 记录已归属，按 OpenAI>Claude>Gemini>Copilot>JetBrains 先建者优先）；
2. `AI-Overseas-Others` 取**补集**而非硬编码清单 —— 品牌表收什么它就让出什么，既不重复也不漏；
3. 手写补充表（`AI-Supplement*.list`）也过同一套去重，防止绕过。
`check-ai-lists.sh` 在 CI 里断言「跨表无重复」+「品牌纯度 ≥80%」，回归会被拦下。

### 国内 / 海外结构性隔离

- `AI-CN.list` = VPSDance `cn.list` + `AI-Supplement-CN.list`（手写），全部 DIRECT。
- `drop_covered` 用 `AI-CN` 当**排除集**：任何被国内集合覆盖的域名，从海外表里**结构化剔除**。
  所以 `AI-Overseas-Others` 里不会出现 `bigmodel.cn`/`siliconflow.cn` 之类的国内域名——
  靠**数据集**保证，而不是靠 `lll.conf` 的规则顺序兜底。`check-ai-lists.sh` 在 CI 里断言这条。

表结构：`AI-CN`（国内，DIRECT）+ `AI-OpenAI`/`AI-Claude`/`AI-Gemini`（主流海外各自成表）
+ `AI-Copilot`/`AI-Jetbrains`/`AI-Overseas-Others`（其余海外归一）。

## 为什么用本地文件、不直接 `RULE-SET` 远程 URL

上游 list 带宽泛的 **`IP-ASN`**（`14061` DigitalOcean、`20473` Vultr）与通用
`DOMAIN-KEYWORD`（sift/datadog/sentry）和通用 SaaS 域名（stripe/auth0/sentry…），
会按 ASN/关键字命中**大量非 AI 站点**，把它们一起拉进 AI 策略组。

Surge **无法对远程 list 做预过滤**（`RULE-SET` 只接受 URL 或本地路径），
所以「实时同步上游」与「不误抓」只能二选一 → 用**本地生成 + 定时任务**两全。

## 日常维护：一条命令

```bash
cd ~/surge-ai-lists && ./sync.sh
```

`sync.sh` 把全流程串起来：**拉上游刷新 6 张生成表 → 部署到 Surge Profiles → 有实质变化才提交+推送**。

| 命令 | 用途 |
|---|---|
| `./sync.sh` | 标准流程：刷新 + 部署 + 提交推送 |
| `./sync.sh --no-pull` | 只改了**手写表**时用：跳过拉上游，直接部署+提交 |
| `./sync.sh --dry-run` | 先看会动哪些文件，不做任何修改 |

关键性质：**幂等**。生成表内嵌的 `# GEN` 时间戳每次都不同，但脚本只在**规则内容真变**时才重写文件、
才提交 —— 上游没更新时跑一次只会输出「内容无变化，无需提交」，不会产生噪声提交。

Surge **会自动热重载本机 list，无需手动 reload**。

### 两种维护场景

| 场景 | 怎么做 |
|---|---|
| **上游规则更新**（黑名单收敛/新增域名） | **GitHub Actions 自动**（北京 09:17/21:17）；想立刻跑就 `gh workflow run generate.yml` |
| **自己要加/删域名**（上游没收录的服务） | 编辑 `AI-Supplement*.list`（走代理）或 `AI-CN.list`（直连）→ 推送即触发 CI 重建（或本地 `./sync.sh --no-pull`）|

### 两道防「缩水」保护（重要）

生成表靠 curl 拉 11 个上游源。网络抖动会让某个源静默返回空，**列表缩水 → AI 域名被踢出代理**。
所以 `refresh-ai-lists.sh` 有两道闸：

1. **任一源抓取失败 → 整表不写**（`SKIP`），保留旧版。宁可这次不更新，也不写半成品。
2. **内容骤减 > 30% → 红色缩水告警**（不拦截，因为上游确实会正常收敛），提醒人工确认后再 push。

排查：`~/Library/Logs/surge-ai-lists.log` 里出现 `SKIP ... 源失败` 就是第 1 道闸拦下的，
通常是 raw.githubusercontent.com 抽风，下次自动刷新自愈。

## Surge 如何引用（运行方式）

`lll.conf` 的 AI 段不再是本地文件，而是远程 URL：

```
RULE-SET,https://raw.githubusercontent.com/shjliu911/surge-ai-lists/main/AI-OpenAI.list,"🧠 ChatGPT"
RULE-SET,https://raw.githubusercontent.com/shjliu911/surge-ai-lists/main/AI-Overseas-Others.list,"🤖 AI 服务"
...
```

因此：
- **仓库必须保持 public** —— Surge 拉 `raw.githubusercontent.com` 是**匿名**的，私有仓库会 404。
- `sync.sh` 推完会**主动让 Surge 重拉**（`surge-cli external-resource update <key>`），无需等 Surge 自己的周期。
- 想让 Surge 手动立刻重拉全部：`surge-cli external-resource update <key>`（key 用 `surge-cli external-resource list --raw` 查）。

## 自动化：GitHub Actions（已取代本机 launchd）

生成完全跑在 **GitHub 服务器**上，与本机无关。

| 项 | 值 |
|---|---|
| 工作流 | `.github/workflows/generate.yml` |
| 触发 | 定时 `01:17` / `13:17` UTC（= 北京 09:17 / 21:17）+ 改生成器/手写表 + 手动 |
| 跑什么 | `CI_STRICT=1 ./refresh-ai-lists.sh` → 有变化则提交 `chore: refresh AI rules` |
| 严格模式 | 源失败或缩水 → **退出码 2，整个任务失败，绝不提交** |
| 手动触发 | `gh workflow run generate.yml --repo shjliu911/surge-ai-lists` |

**本机 launchd 已于 2026-10-12 移除**（原来每天 09:17/21:17 跑一次）。
现在即使 Mac 关机，规则照样每天更新。

`sync.sh` 仍在，但只用于**本机手动**场景（改了手写表想立刻推、或想本地预览）。
## 敏感点（改脚本前先看）

- `filter()` **全剔 `IP-ASN`**，但**保留 `IP-CIDR`**——那是服务商自有精确网段（如 Anthropic `160.79.104.0/21`）。
- `oaistatsig.com` 是 **OpenAI 自己的**，会被 `statsig` 正则误伤（假阳性），**别删**。
- `[Host]` 段不认 `DOMAIN-SUFFIX,x = server:...`，要写 `*x = server:...`。
- 改 Surge 配置的标准流程：`surge-cli --check <file>` → `reload` → `flush dns`。

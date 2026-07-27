# Claude Auto Review

**Languages:** [English](README.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Русский](README.ru.md) | [Português](README.pt.md)

> 英文版本为权威来源。其他语言为社区翻译,可能滞后于英文版。

一个可复用的 GitHub Action,用于自动为 Pull Request 生成代码审查。封装了 `anthropics/claude-code-action@v1`,并新增:

- **多模型并行审查 + 汇总**:当配置 ≥2 个模型时,各模型独立审查;summarize 任务会合并并去重发现项,标注置信度(`[Consensus N/M]` / `[Single model]`),并对 TODO 列表重新编号。配置为空时回退到单模型模式。
- PR 变更行数阈值(默认 10000);超过则自动跳过;支持手动重新运行以强制执行。
- 每次运行前最小化历史 Claude 评论,降低 PR 噪声。
- Claude CLI 自动检测 + 回退安装(在自托管 runner 上复用预装 CLI)。
- 审查质量检查(评论过短时自动重试一次)。
- 可参数化的审查语言(`review_language`,默认 English,回退到 English)+ 机器可解析的 `## TODO Fix List` 区块 + "Requires manual attention" 章节模板。

## 两种使用模式

### 模式 1:Composite Action(轻量单模型场景)

将该 action 作为现有 PR 工作流中的一个 step 嵌入。灵活性最高。**仅支持单模型审查**;输出直接作为 PR 评论发布。

```yaml
# .github/workflows/pr-review.yml (调用方仓库)
name: PR Review
on:
  pull_request:
    types: [opened, synchronize, reopened]
  issue_comment:
    types: [created]

jobs:
  claude-review:
    if: >-
      github.event_name == 'pull_request' ||
      (github.event_name == 'issue_comment' &&
       github.event.issue.pull_request != null &&
       github.event.comment.user.type != 'Bot' &&
       contains(github.event.comment.body, '@claude'))
    runs-on: [self-hosted, Linux, fargate-runner]   # 或 ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
      issues: write
      actions: read
    concurrency:
      group: claude-review-${{ github.event.pull_request.number || github.event.issue.number }}-${{ github.event_name }}
      cancel-in-progress: true
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 1
      - uses: gatellm-io/gatellm-code-review@v1
        with:
          anthropic_api_key: ${{ secrets.CODE_REVIEW_API_KEY }}
          anthropic_base_url: ${{ vars.CODE_REVIEW_BASE_URL }}
          # 所有其他输入项均有默认值;按需覆盖
```

### 模式 2:Reusable Workflow(推荐,支持多模型)

调用完整的 `setup → review(matrix) → summarize` 三阶段工作流。**支持多模型并行审查与汇总**;省去自行配置 `permissions` / `concurrency` / `runs-on` 的麻烦。

```yaml
# .github/workflows/pr-review.yml (调用方仓库)
name: PR Review
on:
  pull_request:
    types: [opened, synchronize, reopened]
  issue_comment:
    types: [created]

jobs:
  claude-review:
    if: >-
      github.event_name == 'pull_request' ||
      (github.event_name == 'issue_comment' &&
       github.event.issue.pull_request != null &&
       github.event.comment.user.type != 'Bot' &&
       contains(github.event.comment.body, '@claude'))
    uses: gatellm-io/gatellm-code-review/.github/workflows/claude-auto-review.yml@v1
    secrets: inherit           # 让 CODE_REVIEW_API_KEY 透传过去
    with:
      runs_on: "self-hosted, Linux, fargate-runner"
      # 单模型:将 `models` 留空以回退到 `model`
      # 多模型:传入逗号分隔的模型列表
      # models: "deepseek-v4-pro,claude-sonnet-4,glm-4-plus"
      # summary_model: "claude-sonnet-4"
```

## 输入项

### Composite Action 输入项(`action.yml`)

| 名称 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `anthropic_api_key` | string | `""` | Anthropic API key(调用方必须显式传入,例如 `${{ secrets.CODE_REVIEW_API_KEY }}`) |
| `anthropic_base_url` | string | `""` | Anthropic API base URL(调用方必须显式传入,例如 `${{ vars.CODE_REVIEW_BASE_URL }}`;通过网关代理时使用) |
| `github_token` | string | `${{ github.token }}` | GitHub token;需要 `pull-requests: write`、`issues: write`、`actions: read` |
| `model` | string | `""` | 单模型名称(调用方可传入 `${{ vars.CODE_REVIEW_MODEL }}` 或字面量;留空 = 使用 Claude CLI 默认模型) |
| `max_lines` | number | `10000` | PR 变更行数上限;超过则跳过审查;`-1` 表示不限 |
| `user_request` | string | `""` | 由 `@claude` 评论触发时的用户请求内容 |
| `review_language` | string | `"English"` | 审查评论语言(例如 `English`、`Simplified Chinese`、`Traditional Chinese`、`Japanese`、`Korean`);留空或不支持的值回退到 English |
| `prompt` | string | (见 `action.yml`) | 自定义审查 prompt(语言要求会根据 `review_language` 单独注入,不会内置到 prompt 默认值中) |

### Reusable Workflow 输入项(`.github/workflows/claude-auto-review.yml`)

| 名称 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `runs_on` | string | `"self-hosted, Linux, fargate-runner"` | Runner 标签,逗号分隔或单个标签;应用于 setup/review/summarize 任务 |
| `model` | string | `${{ vars.CODE_REVIEW_MODEL }}` | 单模型名称(当 `models` 为空时使用) |
| `models` | string | `${{ vars.CODE_REVIEW_MODELS }}` | 逗号分隔的模型列表(≥2 启用多模型并行模式;最多 3 个,超出截断) |
| `summary_model` | string | `${{ vars.CODE_REVIEW_SUMMARY_MODEL }}` | 汇总模型名称(多模型模式下使用;留空时取 `models` 中的第一个) |
| `max_lines` | number | `10000` | PR 变更行数上限;超过则跳过审查;`-1` 表示不限 |
| `user_request` | string | `""` | 由 `@claude` 评论触发时的用户请求内容 |
| `review_language` | string | `"English"` | 审查评论语言(例如 `English`、`Simplified Chinese`、`Traditional Chinese`、`Japanese`、`Korean`);留空或不支持的值回退到 English |
| `prompt` | string | (见工作流文件) | 自定义审查 prompt(语言要求会根据 `review_language` 单独注入,不会内置到 prompt 默认值中) |

## 调用方必须配置的 Secrets / vars

调用方仓库需在 Settings → Secrets and variables → Actions 中配置以下内容:

| 类型 | 名称 | 是否必需 | 用途 |
|---|---|---|---|
| Secret | `CODE_REVIEW_API_KEY` | ✅ | Anthropic API key |
| Variable | `CODE_REVIEW_BASE_URL` | 可选 | 通过网关代理时使用;直连官方 API 时可省略 |
| Variable | `CODE_REVIEW_MODEL` | 否 | 单模型模式下的默认模型名称 |
| Variable | `CODE_REVIEW_MODELS` | 否 | 多模型模式下的逗号分隔列表 |
| Variable | `CODE_REVIEW_SUMMARY_MODEL` | 否 | 多模型模式下的汇总模型名称 |

> 若要在组织内所有仓库间共享同一套凭据,可考虑使用 [Organization 级别的 secrets 和 variables](https://docs.github.com/en/actions/security-guides/using-secrets-in-github-actions#creating-secrets-for-an-organization)。

## 权限要求

调用方任务的 `permissions` 必须包含:

```yaml
permissions:
  contents: read
  pull-requests: write
  issues: write
  actions: read
```

Composite action 本身不设置 `permissions`;由调用方任务控制。Reusable workflow 在其三个任务上分别设置 `permissions`(`setup` 只需 `contents: read` + `pull-requests: read`;`review`/`summarize` 需要上述完整集合)。

## 版本管理

- `v1`:滚动 tag,指向最新的 1.x 发布
- `v1.0.0` 等:语义化 tag,固定到具体版本
- `main`:开发分支,不建议用于生产环境

发布流程:

```bash
git tag v1.1.0
git push origin v1.1.0
# 移动滚动 tag
git tag -f v1 v1.1.0
git push origin v1 --force
```

## 行为说明

### 模式判定(仅 Reusable Workflow)

setup 任务根据解析出的 `models` 数量决定模式:

- `models` 解析为 ≥2 → `mode=multi`:矩阵并行审查;结果写入 `./claude-review-output.md`,打包为 artifact;`summarize` 任务下载所有 artifact,合并、去重、标注置信度,并发布一条汇总评论。
- `models` 解析为 ≤1 → `mode=single`:单模型审查,直接发布 PR 评论,带质量检查和短结果重试。

> Composite action 始终为单模型模式,等价于 `mode=single`。

### PR 变更行数阈值

- `max_lines > 0`:当 PR `additions + deletions` 超过此值时跳过审查;手动重新运行会跳过该阈值检查。
- `max_lines == -1`:不限。
- `max_lines == 0`:拒绝任何 PR。

### 评论最小化

每次审查前,调用 GraphQL `minimizeComment` 将历史 Claude 评论折叠为 `OUTDATED`。若某条审查评论最终短于 100 字符,会自动最小化并重试一次。多模型模式下,该逻辑在 `summarize` 任务中执行。

### Claude CLI 安装

- Runner 已预装 Claude CLI(典型自托管场景):直接复用。
- Runner 未预装(典型 `ubuntu-latest` 场景):`action.yml` 先尝试 `npm install -g @anthropic-ai/claude-code`,再回退到 `curl -fsSL https://claude.ai/install.sh | bash`(npm 不受 Claude.ai 地理封锁影响,推荐)。Reusable workflow 仅检测 PATH,不安装(依赖自托管 runner 预装)。

### 审查输出格式

评论语言由 `review_language` 控制(默认 English;留空或不支持的值回退到 English;中文审查请传 `Simplified Chinese`)。结构:

1. **Findings analysis**:按严重度排序,带 `file:line` 引用;多模型模式下每条发现项标注 `[Consensus N/M]` 或 `[Single model]`。
2. **`## TODO Fix List`**:机器可解析的固定格式,每条一行:`- [ ] **[TODO-n] [Pn] \`file:line\`** — Issue summary; Fix requirement: ...`
   - 严重度分级:`[P0]` 严重 bug / 安全;`[P1]` 逻辑风险 / 行为回归;`[P2]` 性能 / 测试缺失;`[P3]` 风格。
   - 多模型汇总中,条目会合并、去重,并重新编号为连续的 `TODO-1..n`;置信度标注位于严重度 tag 之后。
3. **Requires manual attention**:需要人工审查的条目。
4. **(仅多模型)** 底部折叠区块展示每个模型的原始审查内容。

完整细节见 `action.yml` / 工作流文件中的 `prompt` 默认值。

## 本地校验

```bash
# YAML 语法检查
python3 -c "import yaml; yaml.safe_load(open('action.yml'))"
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/claude-auto-review.yml'))"

# actionlint(如已安装)
actionlint
```

## 许可证

MIT

# Claude Auto Review

可复用的 GitHub Action，为 Pull Request 自动生成中文 Code Review。基于 `anthropics/claude-code-action@v1` 封装，额外提供：

- **多模型并行 review + 汇总**：配置 ≥2 个模型时，每个模型独立 review，汇总 job 合并去重、标注置信度（`[共识 N/M]` / `[单模型]`）、重新编号 TODO 清单；为空时回退到单模型模式
- PR 变更行数门槛（默认 10000 行），超限自动跳过；支持 manual re-run 强制执行
- 执行前最小化历史 Claude 评论，避免噪音
- Claude CLI 自动检测 + fallback 安装（self-hosted runner 已预装则直接复用）
- Review 质量校验（评论过短自动重试一次）
- 评论中文化约束 + `## TODO 修改清单` 机器可解析区块 + "Requires manual attention" 段落模板

## 两种使用方式

### 方式 1：Composite Action（单模型轻量场景）

把 action 作为一步嵌入到调用方现有的 PR workflow 里，灵活度最高。**只支持单模型 review**，输出直接发 PR 评论。

```yaml
# .github/workflows/pr-review.yml（调用方 repo）
name: PR Review
on:
  pull_request:
    types: [opened, synchronize, reopened]
  issue_comment:
    types: [created]

jobs:
  claude-review:
    runs-on: [self-hosted, Linux, fargate-runner]   # 或 ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
      issues: write
      actions: read
    concurrency:
      group: claude-review-${{ github.event.pull_request.number || github.event.issue.number }}
      cancel-in-progress: true
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 1
      - uses: gatellm-io/gatellm-code-review@v1
        with:
          anthropic_api_key: ${{ secrets.CODE_REVIEW_ANTHROPIC_AUTH_TOKEN }}
          anthropic_base_url: ${{ vars.CODE_REVIEW_ANTHROPIC_BASE_URL }}
          # 其余 inputs 均有默认值，按需覆盖
```

### 方式 2：Reusable Workflow（推荐，支持多模型）

整体调用 `setup → review(matrix) → summarize` 三段式 workflow。**支持多模型并行 review 和汇总**，省去自己配 `permissions` / `concurrency` / `runs-on` 的麻烦。

```yaml
# .github/workflows/pr-review.yml（调用方 repo）
name: PR Review
on:
  pull_request:
    types: [opened, synchronize, reopened]
  issue_comment:
    types: [created]

jobs:
  claude-review:
    uses: gatellm-io/gatellm-code-review/.github/workflows/claude-auto-review.yml@v1
    secrets: inherit           # 让 CODE_REVIEW_ANTHROPIC_AUTH_TOKEN 透传
    with:
      runs_on: "self-hosted, Linux, fargate-runner"
      # 单模型：留空 models 即可回退到 model
      # 多模型：传入逗号分隔的模型列表
      # models: "deepseek-v4-pro,claude-sonnet-4,glm-4-plus"
      # summary_model: "claude-sonnet-4"
```

## Inputs

### Composite Action inputs（`action.yml`）

| 名称 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `anthropic_api_key` | string | `${{ secrets.CODE_REVIEW_ANTHROPIC_AUTH_TOKEN }}` | Anthropic API key |
| `anthropic_base_url` | string | `${{ vars.CODE_REVIEW_ANTHROPIC_BASE_URL }}` | Anthropic API base URL（对接代理/网关时使用） |
| `github_token` | string | `${{ github.token }}` | GitHub token，需 `pull-requests: write`、`issues: write`、`actions: read` |
| `model` | string | `${{ vars.CODE_REVIEW_MODEL }}` | 单模型名 |
| `max_lines` | number | `10000` | PR 变更行数上限，超限跳过；`-1` 表示不限制 |
| `user_request` | string | `""` | `@claude` 评论触发时的用户请求内容 |
| `prompt` | string | （见 `action.yml`） | 自定义 Review 提示词 |

### Reusable Workflow inputs（`.github/workflows/claude-auto-review.yml`）

| 名称 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `runs_on` | string | `"self-hosted, Linux, fargate-runner"` | Runner 标签，逗号分隔或单标签；应用于 setup/review/summarize 三个 job |
| `model` | string | `${{ vars.CODE_REVIEW_MODEL }}` | 单模型名（`models` 为空时使用） |
| `models` | string | `${{ vars.CODE_REVIEW_MODELS }}` | 逗号分隔的模型列表（≥2 个启用多模型并行；最多 3 个，超出截断） |
| `summary_model` | string | `${{ vars.CODE_REVIEW_SUMMARY_MODEL }}` | 汇总模型名（多模型模式下使用；为空取 `models` 第一个） |
| `max_lines` | number | `10000` | PR 变更行数上限，超限跳过；`-1` 表示不限制 |
| `user_request` | string | `""` | `@claude` 评论触发时的用户请求内容 |
| `prompt` | string | （见 workflow 文件） | 自定义 Review 提示词 |

## 调用方需要配置的 secrets / vars

调用方 repo 需要在 Settings → Secrets and variables → Actions 中配置：

| 类型 | 名称 | 必填 | 用途 |
|---|---|---|---|
| Secret | `CODE_REVIEW_ANTHROPIC_AUTH_TOKEN` | ✅ | Anthropic API key |
| Variable | `CODE_REVIEW_ANTHROPIC_BASE_URL` | 视情况 | 对接代理/网关时使用，直连官方 API 可不设 |
| Variable | `CODE_REVIEW_MODEL` | 否 | 单模型模式下的默认模型名 |
| Variable | `CODE_REVIEW_MODELS` | 否 | 多模型模式下的逗号分隔列表 |
| Variable | `CODE_REVIEW_SUMMARY_MODEL` | 否 | 多模型模式下的汇总模型名 |

> 若所有 repo 都希望共享同一份凭证，可考虑用 [Organization-level secrets and variables](https://docs.github.com/en/actions/security-guides/using-secrets-in-github-actions#creating-secrets-for-an-organization)。

## 权限要求

调用方 job 的 `permissions` 必须包含：

```yaml
permissions:
  contents: read
  pull-requests: write
  issues: write
  actions: read
```

Composite action 自身不设 `permissions`，由调用方 job 控制。Reusable workflow 在三个 job 上各自设了 `permissions`（`setup` 仅 `contents: read` + `pull-requests: read`，`review`/`summarize` 同上完整 4 项）。

## 版本管理

- `v1`：滚动 tag，指向最新的 1.x 版本
- `v1.0.0` 等语义化 tag：锁定精确版本
- `main`：开发分支，不建议在生产使用

发布流程：

```bash
git tag v1.1.0
git push origin v1.1.0
# 移动滚动 tag
git tag -f v1 v1.1.0
git push origin v1 --force
```

## 行为说明

### 模式判定（仅 reusable workflow）

setup job 根据解析后的 `models` 数量决定模式：

- `models` 解析后 ≥2 个 → `mode=multi`：matrix 并行 review，结果写到 `./claude-review-output.md` 打包成 artifact；`summarize` job 下载所有 artifact，合并、去重、置信度标注后发一条汇总评论
- `models` 解析后 ≤1 个 → `mode=single`：单模型 review，直接发 PR 评论，含质量校验和短结果重试

> Composite action 永远是单模型模式，行为等价于 `mode=single`。

### PR 变更行数门槛

- `max_lines > 0`：PR `additions + deletions` 超过此值则跳过 review；手动 re-run 时跳过门槛检查
- `max_lines == -1`：不限制
- `max_lines == 0`：禁止任何 PR

### 评论最小化

每次 review 前会调用 GraphQL `minimizeComment`，把历史 Claude 评论标记为 `OUTDATED` 折叠掉；若 review 后发现评论字数 < 100，会自动最小化并重试一次。多模型模式下此逻辑在 `summarize` job 执行。

### Claude CLI 安装

- Runner 已预装 Claude CLI（典型 self-hosted 场景）：直接复用
- Runner 未预装（典型 `ubuntu-latest` 场景）：`action.yml` 会自动 `curl -fsSL https://claude.ai/install.sh | bash`；reusable workflow 当前仅检测 PATH，不安装（依赖 self-hosted runner 预装）

### Review 输出格式

强制要求评论用简体中文撰写，结构：

1. **Findings 分析**：按严重程度排序，带 `file:line` 引用；多模型模式下每条标注 `[共识 N/M]` 或 `[单模型]`
2. **`## TODO 修改清单`**：机器可解析的固定格式，每条一行 `- [ ] **[TODO-n] [Pn] \`file:line\`** — 问题简述；修改要求：...`
   - 严重性分级：`[P0]` 严重 bug/安全；`[P1]` 逻辑风险/行为回归；`[P2]` 性能/测试缺失；`[P3]` 风格
   - 多模型汇总时合并去重后重新编号为连续 `TODO-1..n`，共识标注加在严重性后
3. **Requires manual attention**：需要人工复核的项
4. **（仅多模型）** 底部折叠块附各模型原始 review

详见 `action.yml` / workflow 文件的 `prompt` 默认值。

## 本地校验

```bash
# YAML 语法校验
python3 -c "import yaml; yaml.safe_load(open('action.yml'))"
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/claude-auto-review.yml'))"

# actionlint（如已安装）
actionlint
```

## License

MIT

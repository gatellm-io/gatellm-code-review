# Claude Auto Review

可复用的 GitHub Action，为 Pull Request 自动生成中文 Code Review。基于 `anthropics/claude-code-action@v1` 封装，额外提供：

- PR 变更行数门槛（默认 10000 行），超限自动跳过；支持 manual re-run 强制执行
- 执行前最小化历史 Claude 评论，避免噪音
- Claude CLI 自动检测 + fallback 安装（self-hosted runner 已预装则直接复用）
- Review 质量校验（评论过短自动重试一次）
- 评论中文化约束 + "Requires manual attention" 段落模板

## 两种使用方式

### 方式 1：Composite Action（推荐）

把 action 作为一步嵌入到调用方现有的 PR workflow 里，灵活度最高。

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

### 方式 2：Reusable Workflow

整体调用，省去自己配 `permissions` / `concurrency` / `runs-on` 的麻烦，但 runner 选择受限于 workflow 的默认值。

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
      action_ref: v1           # 与 @v1 保持一致，避免主分支漂移
      runs_on: "self-hosted, Linux, fargate-runner"
```

## Inputs

| 名称 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `anthropic_api_key` | string | `${{ secrets.CODE_REVIEW_ANTHROPIC_AUTH_TOKEN }}` | Anthropic API key |
| `anthropic_base_url` | string | `${{ vars.CODE_REVIEW_ANTHROPIC_BASE_URL }}` | Anthropic API base URL（对接代理/网关时使用） |
| `github_token` | string | `${{ github.token }}` | GitHub token，需 `pull-requests: write`、`issues: write`、`actions: read` |
| `model` | string | `${{ vars.CODE_REVIEW_MODEL }}` | 模型名 |
| `max_lines` | number | `10000` | PR 变更行数上限，超限跳过；`-1` 表示不限制 |
| `user_request` | string | `""` | `@claude` 评论触发时的用户请求内容 |
| `prompt` | string | （见 action.yml） | 自定义 Review 提示词 |

### Reusable Workflow 额外 inputs

| 名称 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `runs_on` | string | `"self-hosted, Linux, fargate-runner"` | Runner 标签，逗号分隔或单标签 |
| `action_ref` | string | `"main"` | 拉 action.yml 时用的 ref；**建议传与 workflow 调用 ref 一致的值**（如 `v1`），避免主分支漂移 |

## 调用方需要配置的 secrets / vars

调用方 repo 需要在 Settings → Secrets and variables → Actions 中配置：

| 类型 | 名称 | 必填 | 用途 |
|---|---|---|---|
| Secret | `CODE_REVIEW_ANTHROPIC_AUTH_TOKEN` | ✅ | Anthropic API key |
| Variable | `CODE_REVIEW_ANTHROPIC_BASE_URL` | 视情况 | 对接代理/网关时使用，直连官方 API 可不设 |
| Variable | `CODE_REVIEW_MODEL` | 否 | 默认模型名 |

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

Composite action 自身不设 `permissions`，由调用方 job 控制。

## 版本管理

- `v1`：滚动 tag，指向最新的 1.x 版本
- `v1.0.0` 等语义化 tag：锁定精确版本
- `main`：开发分支，不建议在生产使用

发布流程：

```bash
git tag v1.0.0
git push origin v1.0.0
# 移动滚动 tag
git tag -f v1 v1.0.0
git push origin v1 --force
```

## 行为说明

### PR 变更行数门槛

- `max_lines > 0`：PR `additions + deletions` 超过此值则跳过 review；手动 re-run 时跳过门槛检查
- `max_lines == -1`：不限制
- `max_lines == 0`：禁止任何 PR

### 评论最小化

每次 review 前会调用 GraphQL `minimizeComment`，把历史 Claude 评论标记为 `OUTDATED` 折叠掉；若 review 后发现评论字数 < 100，会自动最小化并重试一次。

### Claude CLI 安装

- Runner 已预装 Claude CLI（典型 self-hosted 场景）：直接复用
- Runner 未预装（典型 `ubuntu-latest` 场景）：自动 `curl -fsSL https://claude.ai/install.sh | bash`，安装到 `~/.claude/local/claude`

### Review 输出格式

强制要求评论用简体中文撰写，先列发现（按严重程度排序，带 `file:line` 引用），再列 "Requires manual attention" 段落。详见 `action.yml` 的 `prompt` 默认值。

## 本地校验

```bash
# YAML 语法校验
python3 -c "import yaml; yaml.safe_load(open('action.yml'))"
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/claude-auto-review.yml'))"

# actionlint（如已安装）
actionlint action.yml .github/workflows/claude-auto-review.yml
```

## License

MIT

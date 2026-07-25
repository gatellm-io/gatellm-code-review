# Claude Auto Review

**Languages:** [English](README.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Русский](README.ru.md) | [Português](README.pt.md)

> The English version is the authoritative source. Other languages are community translations and may lag behind.

A reusable GitHub Action that auto-generates code review for pull requests. Wraps `anthropics/claude-code-action@v1` and adds:

- **Multi-model parallel review + summary**: when ≥2 models are configured, each model reviews independently; the summarize job merges and deduplicates findings, annotates confidence (`[Consensus N/M]` / `[Single model]`), and renumbers the TODO list. Empty config falls back to single-model mode.
- PR changed-lines threshold (default 10000); auto-skips when exceeded; supports manual re-run to force execution.
- Minimizes historical Claude comments before each run to keep PR noise low.
- Claude CLI auto-detection + fallback install (reuses preinstalled CLI on self-hosted runners).
- Review quality check (auto-retries once when the comment is too short).
- Parameterizable review language (`review_language`, default English, falls back to English) + machine-parseable `## TODO Fix List` block + "Requires manual attention" section template.

## Two usage modes

### Mode 1: Composite Action (lightweight single-model scenarios)

Embed the action as one step in your existing PR workflow. Maximum flexibility. **Single-model review only**; output is posted directly as a PR comment.

```yaml
# .github/workflows/pr-review.yml (caller repo)
name: PR Review
on:
  pull_request:
    types: [opened, synchronize, reopened]
  issue_comment:
    types: [created]

jobs:
  claude-review:
    runs-on: [self-hosted, Linux, fargate-runner]   # or ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
      issues: write
      actions: read
    concurrency:
      group: claude-review-${{ github.event.pull_request.number || github.event.issue.number }}
      cancel-in-progress: true
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          fetch-depth: 1
      - uses: gatellm-io/gatellm-code-review@v1
        with:
          anthropic_api_key: ${{ secrets.CODE_REVIEW_API_KEY }}
          anthropic_base_url: ${{ vars.CODE_REVIEW_BASE_URL }}
          # All other inputs have defaults; override as needed
```

### Mode 2: Reusable Workflow (recommended, supports multi-model)

Calls the full `setup → review(matrix) → summarize` three-stage workflow. **Supports multi-model parallel review and summarization**; saves you from configuring `permissions` / `concurrency` / `runs-on` yourself.

```yaml
# .github/workflows/pr-review.yml (caller repo)
name: PR Review
on:
  pull_request:
    types: [opened, synchronize, reopened]
  issue_comment:
    types: [created]

jobs:
  claude-review:
    uses: gatellm-io/gatellm-code-review/.github/workflows/claude-auto-review.yml@v1
    secrets: inherit           # lets CODE_REVIEW_API_KEY pass through
    with:
      runs_on: "self-hosted, Linux, fargate-runner"
      # Single model: leave `models` empty to fall back to `model`
      # Multi-model: pass a comma-separated model list
      # models: "deepseek-v4-pro,claude-sonnet-4,glm-4-plus"
      # summary_model: "claude-sonnet-4"
```

## Inputs

### Composite Action inputs (`action.yml`)

| Name | Type | Default | Description |
|---|---|---|---|
| `anthropic_api_key` | string | `""` | Anthropic API key (caller must pass explicitly, e.g. `${{ secrets.CODE_REVIEW_API_KEY }}`) |
| `anthropic_base_url` | string | `""` | Anthropic API base URL (caller must pass explicitly, e.g. `${{ vars.CODE_REVIEW_BASE_URL }}`; used when proxying through a gateway) |
| `github_token` | string | `${{ github.token }}` | GitHub token; needs `pull-requests: write`, `issues: write`, `actions: read` |
| `model` | string | `""` | Single model name (caller may pass `${{ vars.CODE_REVIEW_MODEL }}` or a literal; empty = use the Claude CLI default model) |
| `max_lines` | number | `10000` | Max PR changed lines; skip review if exceeded; `-1` means unlimited |
| `user_request` | string | `""` | User request content when triggered by `@claude` comment |
| `review_language` | string | `"English"` | Review comment language (e.g. `English`, `Simplified Chinese`, `Traditional Chinese`, `Japanese`, `Korean`); empty or unsupported value falls back to English |
| `prompt` | string | (see `action.yml`) | Custom review prompt (language requirement is injected separately based on `review_language`, not baked into the prompt default) |

### Reusable Workflow inputs (`.github/workflows/claude-auto-review.yml`)

| Name | Type | Default | Description |
|---|---|---|---|
| `runs_on` | string | `"self-hosted, Linux, fargate-runner"` | Runner labels, comma-separated or a single label; applied to setup/review/summarize jobs |
| `model` | string | `${{ vars.CODE_REVIEW_MODEL }}` | Single model name (used when `models` is empty) |
| `models` | string | `${{ vars.CODE_REVIEW_MODELS }}` | Comma-separated model list (≥2 enables multi-model parallel mode; max 3, extras truncated) |
| `summary_model` | string | `${{ vars.CODE_REVIEW_SUMMARY_MODEL }}` | Summary model name (used in multi-model mode; empty takes the first of `models`) |
| `max_lines` | number | `10000` | Max PR changed lines; skip review if exceeded; `-1` means unlimited |
| `user_request` | string | `""` | User request content when triggered by `@claude` comment |
| `review_language` | string | `"English"` | Review comment language (e.g. `English`, `Simplified Chinese`, `Traditional Chinese`, `Japanese`, `Korean`); empty or unsupported value falls back to English |
| `prompt` | string | (see workflow file) | Custom review prompt (language requirement is injected separately based on `review_language`, not baked into the prompt default) |

## Secrets / vars the caller must configure

The caller repo needs the following in Settings → Secrets and variables → Actions:

| Type | Name | Required | Purpose |
|---|---|---|---|
| Secret | `CODE_REVIEW_API_KEY` | ✅ | Anthropic API key |
| Variable | `CODE_REVIEW_BASE_URL` | Optional | Used when proxying through a gateway; can be omitted when hitting the official API directly |
| Variable | `CODE_REVIEW_MODEL` | No | Default model name in single-model mode |
| Variable | `CODE_REVIEW_MODELS` | No | Comma-separated list in multi-model mode |
| Variable | `CODE_REVIEW_SUMMARY_MODEL` | No | Summary model name in multi-model mode |

> To share the same credentials across all repos in an org, consider [Organization-level secrets and variables](https://docs.github.com/en/actions/security-guides/using-secrets-in-github-actions#creating-secrets-for-an-organization).

## Permission requirements

The caller job's `permissions` must include:

```yaml
permissions:
  contents: read
  pull-requests: write
  issues: write
  actions: read
```

The composite action itself does not set `permissions`; the caller job controls them. The reusable workflow sets `permissions` on each of its three jobs (`setup` only needs `contents: read` + `pull-requests: read`; `review`/`summarize` need the full set above).

## Versioning

- `v1`: rolling tag, points to the latest 1.x release
- `v1.0.0` etc.: semantic tags that pin an exact version
- `main`: development branch, not recommended for production use

Release flow:

```bash
git tag v1.1.0
git push origin v1.1.0
# Move the rolling tag
git tag -f v1 v1.1.0
git push origin v1 --force
```

## Behavior notes

### Mode resolution (reusable workflow only)

The setup job decides the mode based on the parsed `models` count:

- `models` parses to ≥2 → `mode=multi`: matrix parallel review; results are written to `./claude-review-output.md`, packaged as an artifact; the `summarize` job downloads all artifacts, merges, deduplicates, annotates confidence, and posts one summary comment.
- `models` parses to ≤1 → `mode=single`: single-model review, posts a PR comment directly, with quality check and short-result retry.

> The composite action is always single-model mode, equivalent to `mode=single`.

### PR changed-lines threshold

- `max_lines > 0`: skip review if PR `additions + deletions` exceeds this value; manual re-run skips the threshold check.
- `max_lines == -1`: unlimited.
- `max_lines == 0`: rejects any PR.

### Comment minimization

Before each review, calls GraphQL `minimizeComment` to fold historical Claude comments as `OUTDATED`. If a review comment ends up shorter than 100 chars, it's auto-minimized and retried once. In multi-model mode, this logic runs in the `summarize` job.

### Claude CLI install

- Runner has Claude CLI preinstalled (typical self-hosted case): reused directly.
- Runner doesn't (typical `ubuntu-latest` case): `action.yml` first tries `npm install -g @anthropic-ai/claude-code`, then falls back to `curl -fsSL https://claude.ai/install.sh | bash` (npm isn't affected by Claude.ai geo-block, recommended). The reusable workflow only detects PATH and doesn't install (relies on self-hosted runner preinstall).

### Review output format

Comment language is controlled by `review_language` (default English; empty or unsupported value falls back to English; pass `Simplified Chinese` for Chinese reviews). Structure:

1. **Findings analysis**: ordered by severity, with `file:line` references; in multi-model mode each finding is annotated with `[Consensus N/M]` or `[Single model]`.
2. **`## TODO Fix List`**: machine-parseable fixed format, one line per entry: `- [ ] **[TODO-n] [Pn] \`file:line\`** — Issue summary; Fix requirement: ...`
   - Severity grading: `[P0]` critical bug / security; `[P1]` logic risk / behavioral regression; `[P2]` performance / missing tests; `[P3]` style.
   - In multi-model summary, entries are merged, deduplicated, and renumbered as continuous `TODO-1..n`; consensus annotations go after the severity tag.
3. **Requires manual attention**: items that need human review.
4. **(Multi-model only)** Collapsed blocks at the bottom with each model's original review.

See the `prompt` defaults in `action.yml` / the workflow file for full details.

## Local validation

```bash
# YAML syntax check
python3 -c "import yaml; yaml.safe_load(open('action.yml'))"
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/claude-auto-review.yml'))"

# actionlint (if installed)
actionlint
```

## License

MIT

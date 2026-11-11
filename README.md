# Claude Auto Review

**Languages:** [English](README.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Русский](README.ru.md) | [Português](README.pt.md)

> The English version is the authoritative source. Other languages are community translations and may lag behind.

A reusable GitHub Action that auto-generates code review for pull requests. Runs either `anthropics/claude-code-action@v1` or the **dsh** CLI (DeepSeek Harness) and adds:

- **Two engines**: `claude-code` (default) or `dsh`, selected per run with the `engine` input. Both share the size gate, comment minimization, multi-model matrix, summarization and token settings.
- **Multi-model parallel review + summary**: when ≥2 models are configured, each model reviews independently; the summarize job merges and deduplicates findings, annotates confidence (`[Consensus N/M]` / `[Single model]`), and renumbers the TODO list. Empty config falls back to single-model mode.
- PR changed-lines threshold (default 10000); auto-skips when exceeded; supports manual re-run to force execution.
- Minimizes historical Claude comments before each run to keep PR noise low.
- Claude CLI auto-detection + fallback install (reuses preinstalled CLI on self-hosted runners).
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
    if: >-
      github.event_name == 'pull_request' ||
      (github.event_name == 'issue_comment' &&
       github.event.issue.pull_request != null &&
       github.event.comment.user.type != 'Bot' &&
       contains(github.event.comment.body, '@claude'))
    runs-on: [self-hosted, Linux, fargate-runner]   # or ubuntu-latest
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
          model: ${{ vars.CODE_REVIEW_MODEL }}   # required in practice; empty fails the run
          # Remaining inputs have defaults; override as needed
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
    if: >-
      github.event_name == 'pull_request' ||
      (github.event_name == 'issue_comment' &&
       github.event.issue.pull_request != null &&
       github.event.comment.user.type != 'Bot' &&
       contains(github.event.comment.body, '@claude'))
    uses: gatellm-io/gatellm-code-review/.github/workflows/claude-auto-review.yml@v1
    # NOTE: `secrets: inherit` only passes secrets within the SAME org/enterprise.
    # Cross-org callers MUST pass the API key explicitly, or ANTHROPIC_API_KEY will be empty.
    secrets:
      CODE_REVIEW_API_KEY: ${{ secrets.CODE_REVIEW_API_KEY }}
    with:
      runs_on: "self-hosted, Linux, fargate-runner"
      # Single model: leave `models` empty to fall back to `model`
      # Multi-model: pass a comma-separated model list
      # models: "deepseek-v4-pro,claude-sonnet-4,glm-4-plus"
      # summary_model: "claude-sonnet-4"
```

## Engines

`engine` chooses which CLI performs the review. It applies to the whole run — the review jobs and, in multi-model mode, the summarize job.

| Value | CLI | Notes |
|---|---|---|
| `claude-code` (default) | `anthropics/claude-code-action@v1` | Existing behavior; posts the comment itself, `track_progress`, inline-comment MCP tool |
| `dsh` | `dsh --profile headless` | DeepSeek Harness; posts the comment itself, no progress comment, no inline comments |

### dsh specifics

- **Model selection.** `dsh` has no `--model` flag in headless mode. The action generates a patch layer and passes it with `dsh --patch`, pointing `agent-default-model` at the `model` input. The `[1m]` context-window suffix is stripped first, because it is a Claude Code convention that dsh would forward verbatim to the gateway; the strip is unconditional, so a gateway that only accepts a literal model id ending in `[1m]` is not supported by the `dsh` engine — configuring the id without the suffix sends a different id, which such a gateway rejects. Use the `claude-code` engine for that gateway. (`$DSH_HOME/settings.yaml` is not used: dsh 0.2 only imports that legacy file after the first boot has already resolved its default model, so it would never apply to a fresh per-run `DSH_HOME`.)
- **Gateway.** The provider is declared with `api: anthropic-messages`, `baseURL` from `anthropic_base_url` (default `https://api.anthropic.com`) and `apiKeyEnv: GATELLM_REVIEW_API_KEY`, which the runner environment supplies from `anthropic_api_key`. The generated patch contains only the variable *name*; the key is never written to disk. dsh requests `POST {baseURL}/v1/messages` with `x-api-key`, so one trailing `/v1` is stripped from the base URL: `anthropic_base_url` can stay exactly what the Claude Code engine expects.
- **Tokens.** `max_context_tokens` and `max_output_tokens` map to the provider's `contextWindow` and `maxTokens`; the latter becomes the request's `max_tokens`, so both settings behave the same as under Claude Code.
- **Permissions.** `dsh` presets that require approval (`read-only`, `workspace-write`) fail closed with no interactive answerer, so `run.sh` exports `DSH_PERMISSION_MODE=danger-full-access` (preset `danger-full-access`, sandbox `danger-full-access`, approval `never`): the agent gets an unrestricted shell plus the gateway key and GitHub token. See [Security](#security).
- **Fork PRs are skipped.** `run.sh` refuses to run against a cross-repository PR (and only proceeds when `gh` reports `isCrossRepository: false` exactly), because anyone able to comment on a fork PR could otherwise reach the agent's environment through prompt injection. The skip is reported as a `::notice::` and a workflow step-summary line; the check fails closed if it cannot be evaluated.
- **Output.** In single-model mode dsh posts the PR comment itself. In multi-model mode it is told not to post and to write the review body to `./claude-review-output.md` itself, exactly like the Claude Code path; the existing packaging and summarization steps consume that file unchanged. If the model ignores that instruction, `run.sh` falls back to its stdout and emits a `::warning::` that the packaged body may include more than the review.
- **Logs.** Execution logs, the composed prompt's stderr stream, the composed config dump, the generated patch layer and the dsh session logs are collected under `/tmp/dsh-execution-output-*-<run id>-attempt<attempt>`. The path is scoped to the run, so a shared self-hosted runner cannot pick up another in-flight run's files, and the gateway key / GitHub token are redacted from every collected file before upload. They are uploaded with the same artifact as the Claude execution log.

## Inputs

### Composite Action inputs (`action.yml`)

| Name | Type | Default | Description |
|---|---|---|---|
| `anthropic_api_key` | string | `""` | Anthropic API key (caller must pass explicitly, e.g. `${{ secrets.CODE_REVIEW_API_KEY }}`) |
| `anthropic_base_url` | string | `""` | Anthropic API base URL (caller must pass explicitly, e.g. `${{ vars.CODE_REVIEW_BASE_URL }}`; used when proxying through a gateway) |
| `github_token` | string | `${{ github.token }}` | GitHub token; needs `pull-requests: write`, `issues: write`, `actions: read` |
| `model` | string | `""` | Single model name (REQUIRED in practice: pass `${{ vars.CODE_REVIEW_MODEL }}` or a literal; empty fails the run — no silent fallback to the CLI default model). The `[1m]` suffix denotes the 1M-token context-window variant, recommended for large PRs; it is stripped before the name reaches the dsh engine |
| `engine` | string | `"claude-code"` | Review engine: `claude-code` or `dsh` (DeepSeek Harness). Whitespace and case are normalized; any other value fails the job |
| `dsh_version` | string | `""` | Exact dsh CLI version. Empty reuses any preinstalled dsh and installs the pinned default (`0.2.2-rc.1`) when none is found; an explicit version must match exactly, otherwise the preinstalled copy is ignored and that version is installed |
| `max_lines` | number | `10000` | Max PR changed lines; skip review if exceeded; `-1` means unlimited |
| `max_context_tokens` | string | `""` | Max context tokens for Claude Code, exported as `CLAUDE_CODE_MAX_CONTEXT_TOKENS`. An explicit value other than the literal `0` overrides everything, but a non-zero value that is not a positive integer fails the job; omitting it (the default), passing the literal `0`, or passing whitespace-only is treated as unset and falls back to a runner-provided `CLAUDE_CODE_MAX_CONTEXT_TOKENS` env var, then to `1000000` (this input is forwarded as a string by the composite action; other zero spellings such as `00`, `0.0` or `+0` are **not** treated as unset and fail the job as non-positive-integer input) |
| `max_output_tokens` | string | `""` | Max output tokens for Claude Code, exported as `CLAUDE_CODE_MAX_OUTPUT_TOKENS`. Same resolution and validation rules as `max_context_tokens`: an explicit non-zero value wins, otherwise a runner-provided `CLAUDE_CODE_MAX_OUTPUT_TOKENS` env var applies, otherwise `64000` |
| `user_request` | string | `""` | User request content when triggered by `@claude` comment |
| `review_language` | string | `"English"` | Review comment language (e.g. `English`, `Simplified Chinese`, `Traditional Chinese`, `Japanese`, `Korean`); empty or unsupported value falls back to English |
| `prompt` | string | (see `action.yml`) | Custom review prompt (language requirement is injected separately based on `review_language`, not baked into the prompt default) |

### Reusable Workflow inputs (`.github/workflows/claude-auto-review.yml`)

| Name | Type | Default | Description |
|---|---|---|---|
| `runs_on` | string | — (required) | Runner labels, comma-separated or a single label; applied to setup/review/summarize jobs. No default — the caller must pass it explicitly |
| `model` | string | `${{ vars.CODE_REVIEW_MODEL }}` | Single model name (used when `models` is empty) |
| `models` | string | `${{ vars.CODE_REVIEW_MODELS }}` | Comma-separated model list (≥2 enables multi-model parallel mode; max 3, extras truncated) |
| `summary_model` | string | `${{ vars.CODE_REVIEW_SUMMARY_MODEL }}` | Summary model name (used in multi-model mode; empty takes the first of `models`) |
| `engine` | string | `${{ vars.CODE_REVIEW_ENGINE }}` | Review engine: `claude-code` (empty default) or `dsh`. Applied to the review and summarize jobs; any other value fails the setup job |
| `dsh_version` | string | `""` | Exact dsh CLI version; same rules as the composite action input |
| `max_lines` | number | `10000` | Max PR changed lines; skip review if exceeded; `-1` means unlimited |
| `max_context_tokens` | number | `0` | Max context tokens for Claude Code, exported as `CLAUDE_CODE_MAX_CONTEXT_TOKENS`. An explicit non-zero value overrides everything, but a non-integer value fails the job; `0` (the default) falls back to a runner-provided `CLAUDE_CODE_MAX_CONTEXT_TOKENS` env var, then to `1000000` |
| `max_output_tokens` | number | `0` | Max output tokens for Claude Code, exported as `CLAUDE_CODE_MAX_OUTPUT_TOKENS`. Same rules as `max_context_tokens`: an explicit non-zero value wins, otherwise a runner-provided `CLAUDE_CODE_MAX_OUTPUT_TOKENS` env var applies, otherwise `64000` |
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
| Variable | `CODE_REVIEW_ENGINE` | No | Default engine for the reusable workflow (`claude-code` or `dsh`) |

> To share the same credentials across all repos in an org, consider [Organization-level secrets and variables](https://docs.github.com/en/actions/security-guides/using-secrets-in-github-actions#creating-secrets-for-an-organization).

## Runner requirements

**Self-hosted runners must run Actions Runner >= 2.327.1 with `node24` support.** The steps in this action use `actions/checkout@v7`, `actions/github-script@v9`, `actions/setup-node@v7`, `actions/upload-artifact@v7` and `actions/download-artifact@v8`; all five run on Node.js 24, and the artifact actions state a minimum Actions Runner version of 2.327.1 (`checkout`/`github-script`/`setup-node` carry the same floor). An older runner fails those steps: `Upload execution log` fails, and in multi-model mode `Upload review artifact` fails too, so the `summarize` job then fails at `Download all review artifacts` with `Artifact not found for pattern claude-review-*` and no summary comment is posted. GitHub-hosted runners are always current; this only affects self-hosted fleets, including the `[self-hosted, Linux, fargate-runner]` example in Mode 2 — upgrade them before moving the rolling `v1` tag to a release containing this change.

**The `dsh` engine adds three runner requirements** (the `claude-code` path is unaffected):

- **Node.js >= 24.9.0**, the floor declared by `@deepseek-ai/dsh`. The action detects an acceptable Node first and only runs `actions/setup-node` when none is found.
- **The GitHub CLI (`gh`) on `PATH`.** `run.sh` uses `gh pr view` for the fork-PR guard. A runner without it fails closed with an explicit `::error::` before any review runs.
- **Network access to the npm registry**, if dsh is not already installed on the runner. A fully offline runner must preinstall dsh (see [dsh CLI install](#dsh-cli-install)).

The reusable workflow also uses the `job.workflow_repository` / `job.workflow_sha` context to check out this repository's `scripts/` directory when the `dsh` engine is selected. Those properties are unavailable on GitHub Enterprise Server, where the `dsh` engine therefore cannot run; `claude-code` is unaffected there. That cross-repository checkout has not yet been exercised on a live runner, so treat it as unverified until the first `dsh` run. It uses the workflow's default `github.token`, whose scope is the caller's repository: GitHub does not let that token be granted read access to a *different* repository, and the checkout passes no `token:` input. A private copy of this repository therefore cannot be fetched by the `dsh` engine; use the default `claude-code` engine if `scripts/` must come from a private copy.

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

## Security

The `claude-code` path runs the CLI through `anthropics/claude-code-action`, which restricts it to the tools listed in `claude_args`. **The `dsh` engine has no equivalent allowlist**: its sandbox limits file writes only (not network or commands), and unattended runs require the `danger-full-access` preset. Concretely, a dsh review can execute arbitrary shell commands, reach the network, and read the gateway API key and the GitHub token from its environment.

Practical consequences and the built-in mitigation:

- **PR content is untrusted input.** A malicious diff, commit message or PR title could ask the agent to exfiltrate secrets. `run.sh` therefore refuses to run on cross-repository (fork) PRs, emitting a `::notice::` and a step-summary line instead of a review. The check is fail-closed: the engine runs only when `gh` reports `isCrossRepository: false` exactly, and stops with an `::error::` if `gh` is missing, errors, or returns anything else.
- **Trigger surface.** For `issue_comment` triggers, anyone who can comment can start a run. Add an `author_association` guard to the caller's `if:` condition when using the dsh engine on a public repository, e.g. `contains(fromJSON('["OWNER","MEMBER","COLLABORATOR"]'), github.event.comment.author_association)`.
- **Default stays `claude-code`.** Switching to dsh is an explicit, per-workflow decision.

If those trade-offs are unacceptable for a repository, keep the default engine.

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
- `models` parses to ≤1 → `mode=single`: single-model review, posts a PR comment directly.

> The composite action is always single-model mode, equivalent to `mode=single`.

### PR changed-lines threshold

- `max_lines > 0`: skip review if PR `additions + deletions` exceeds this value; manual re-run skips the threshold check.
- `max_lines == -1`: unlimited.
- `max_lines == 0`: skips any PR with changes.

### Comment minimization

Before each review, calls GraphQL `minimizeComment` to fold historical Claude comments as `OUTDATED`. In single-model mode (and for the composite action) this runs inside the review job; in multi-model mode it runs in the `summarize` job.

### Claude CLI install

- Runner has Claude CLI preinstalled (typical self-hosted case): reused directly.
- Runner doesn't (typical `ubuntu-latest` case): both the composite action and the reusable workflow (review and summarize jobs) first try `npm install -g @anthropic-ai/claude-code`, then fall back to `curl -fsSL https://claude.ai/install.sh | bash` (npm isn't affected by Claude.ai geo-block, recommended).

### dsh CLI install

The `dsh` engine reuses the same detect-then-install pattern as Claude CLI:

- **Runner has dsh preinstalled** (the usual case for self-hosted runners): reused directly. The search covers `PATH`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `~/.npm-global/bin`, `~/.nvm/versions/node/*/bin` and the action's own tool cache. Each candidate must run and report a version; broken binaries are skipped with a warning.
- **Runner has no dsh**: try `npm install -g @deepseek-ai/dsh@<version>`, then fall back to installing into `$RUNNER_TOOL_CACHE/gatellm-code-review/dsh/<version>` when the global prefix is not writable. The fallback location is one of the detection paths, so the next run on that runner reuses it.

`dsh_version` controls which version is accepted:

| `dsh_version` | Preinstalled dsh | Nothing installed |
|---|---|---|
| empty (default) | any version is accepted | pinned default `0.2.2-rc.1` is installed |
| `0.2.2-rc.1` | must match exactly; a different version is ignored with a `::notice::` | that version is installed |

Build metadata (`1.2.3+build`) is accepted in `dsh_version` but ignored when comparing, as semver specifies: `1.2.3+build` and `1.2.3` are the same version.

Because the default accepts any preinstalled version, a self-hosted runner whose dsh drifts from the tested version can behave differently between runs. Set `dsh_version` explicitly when reproducibility matters; the resolved version is printed in the log. The `--patch` overlay's provider/model schema and its "replace, not deep-merge" semantics were verified against `0.2.2-rc.1` only; `tests/dsh-engine.sh` pins that version and the emitted patch shape, so a version bump is caught and must be re-validated rather than drifting silently.

### Max context tokens

`CLAUDE_CODE_MAX_CONTEXT_TOKENS` controls Claude Code's context-window size during the review. Resolution order:

1. An explicit `max_context_tokens` input (non-zero) wins — callers can always override the runner.
2. Otherwise a runner-provided `CLAUDE_CODE_MAX_CONTEXT_TOKENS` environment variable is used. For the composite action this includes an `env:` set on the caller job; a reusable workflow does not inherit the caller's `env`, so there only the runner process environment (and the workflow's own job/step `env`) applies.
3. Otherwise the built-in default `1000000` applies.

"Unset" is spelled differently per entry point: the composite action input is a string and defaults to `""`; the reusable workflow input is a `number` and defaults to `0` (an empty value is not representable there). Both entry points treat the literal `0` as unset; for the composite action this is a string comparison after trimming, so alternative zero spellings (`00`, `0.0`, `+0`) are not recognized as unset and fail the job as non-positive-integer input.

Validation differs by source (both sources are trimmed of surrounding whitespace first, so `" 0 "` is treated as unset and `" 2000000 "` as `2000000`):

- An explicit, non-empty, non-zero `max_context_tokens` input that is not a positive integer fails the job early (`::error::`) — caller mistakes are loud.
- A runner-provided `CLAUDE_CODE_MAX_CONTEXT_TOKENS` env var is treated as a hint: `0` means unset, and any other non-positive-integer value (e.g. `1M`) emits a `::warning::` and falls back to `1000000`, so a misconfigured runner degrades instead of breaking the whole pipeline.

**Upgrade note:** an explicit `max_context_tokens` always wins over the runner value. If a caller sets the input only to mirror an old default and expects a larger runner-provided value to apply, it must omit the input or pass `0` after upgrading (either form means unset in both entry points).

The composite action and reusable workflow both resolve this into the `env` of the `claude-code-action` step. A regression test (`tests/resolve-token-limits.sh`) asserts that all copies of the resolution logic (three per token setting, for `max_context_tokens` and `max_output_tokens`) stay identical and exercises the precedence/validation table above for both settings; it runs in the `Tests` workflow.

### Max output tokens

`CLAUDE_CODE_MAX_OUTPUT_TOKENS` controls the maximum number of tokens Claude Code may emit per response during the review. Resolution order and validation are identical to `max_context_tokens`, with a different built-in default:

1. An explicit `max_output_tokens` input (non-zero) wins — callers can always override the runner.
2. Otherwise a runner-provided `CLAUDE_CODE_MAX_OUTPUT_TOKENS` environment variable is used (same visibility rules as above: the reusable workflow does not inherit the caller's `env`).
3. Otherwise the built-in default `64000` applies.

An explicit non-empty non-zero input that is not a positive integer fails the job (`::error::`); an invalid runner-provided value emits `::warning::` and falls back to `64000`. The same regression test exercises both settings.

**Default and model output caps:** when neither an input nor a runner-provided value is present, the built-in default `64000` is exported to every run. The supported cap depends on the specific model, not on its generation: newer Sonnet/Opus releases support 64k, while older models such as Opus 4 and 4.1 cap at 32k, and third-party gateways reached through a custom `anthropic_base_url` may enforce a lower limit; an over-limit value is either clamped or rejected, and in multi-model mode it is applied to every model in the matrix (a rejection drops that model's review). If you run such a model or gateway, set `max_output_tokens` (or a runner-provided `CLAUDE_CODE_MAX_OUTPUT_TOKENS`) to a value within its output cap. Note that the output budget is carved out of the context window, so reserving a large output budget reduces input headroom on 200k-context models; pair a large `max_output_tokens` with a matching `max_context_tokens` (and consider the `[1m]` model variant) for large PRs.

### Review output format

Comment language is controlled by `review_language` (default English; empty or unsupported value falls back to English; pass `Simplified Chinese` for Chinese reviews). Structure:

1. **Findings analysis**: ordered by severity, with `file:line` references; in multi-model mode each finding is annotated with `[Consensus N/M]` or `[Single model]`.
2. **`## TODO Fix List`**: machine-parseable fixed format, one line per entry: `- [ ] **[TODO-n] [Pn] \`file:line\`** — Issue summary; Fix requirement: ...`
   - Severity grading: `[P0]` critical bug / security; `[P1]` logic risk / behavioral regression; `[P2]` performance / missing tests; `[P3]` style.
   - In multi-model summary, entries are merged, deduplicated, and renumbered as continuous `TODO-1..n`; consensus annotations go after the severity tag.
3. **Requires manual attention**: items that need human review.
4. **(Multi-model only)** Collapsed blocks at the bottom with each model's original review.

See the `prompt` defaults in `action.yml` / the workflow file for full details.

### Artifacts

Each run uploads artifacts for debugging (download from the workflow run's summary page):

- `claude-exec-log*` (composite action and reusable workflow): engine execution logs — the Claude execution JSON, or the dsh `final.md`, `stderr.log`, `dump-config.txt`, generated `patch.yml` and session logs — retained 1 day by the composite action and 3 days by the reusable workflow. The artifact name is unchanged so existing download scripts keep working.
- `claude-review-*` (multi-model only): each model's raw review markdown, retained 7 days; the summarize job consumes them to build the merged comment.

## Local validation

```bash
# YAML syntax check (Ruby ships with macOS and the GitHub runners)
ruby -ryaml -e 'ARGV.each { |f| YAML.load_file(f, aliases: true) }' \
  action.yml .github/workflows/claude-auto-review.yml .github/workflows/tests.yml

# token-limit resolution regression test (max_context_tokens + max_output_tokens;
# also runs in the Tests workflow)
bash tests/resolve-token-limits.sh

# dsh engine tests: CLI detection/install, patch generation, prompt
# composition, run.sh, and the GitHub wiring (also runs in the Tests workflow)
bash tests/dsh-engine.sh

# actionlint (if installed)
actionlint
```

> `actionlint` releases before the September 2026 `job` context update report `job.workflow_repository` / `job.workflow_sha` as undefined. Those four warnings in `.github/workflows/claude-auto-review.yml` are a schema lag, not a workflow error; the properties are documented in the [GitHub Actions changelog](https://github.blog/changelog/2026-09-03-github-actions-early-september-2026-updates/). Everything else `actionlint` reports in this repository predates the dsh engine.

## License

MIT

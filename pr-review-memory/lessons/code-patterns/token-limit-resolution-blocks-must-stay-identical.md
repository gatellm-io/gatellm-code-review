---
title: Token-limit resolution blocks must stay byte-identical in all three copies
paths: ["action.yml", ".github/workflows/*.yml", "tests/*.sh", "README.md"]
tags: [duplication, tests, max-context-tokens, max-output-tokens]
sources: ["#6"]
created: 2026-10-19
---

# Token-limit resolution blocks must stay byte-identical in all three copies

The shell block that resolves `max_context_tokens` / `max_output_tokens` into
`CLAUDE_CODE_MAX_*_TOKENS` lives in **three** places — one copy in `action.yml`
(`- name: Resolve max context tokens` / `- name: Resolve max output tokens`) and
two copies in `.github/workflows/claude-auto-review.yml` (the review job and the
summarize job).

**Why it bites:** `tests/resolve-token-limits.sh` extracts each copy by step name
and fails if the dedented bodies differ, so editing only one copy turns CI red.
Conversely, when adding a new token setting you must add the same step to all
three files plus the `CLAUDE_CODE_MAX_*_TOKENS: ${{ env... }}` passthrough on
every `claude-code-action` step, otherwise the wiring assertion fails.

**Concrete action:** when changing validation/precedence/defaults, edit all three
copies identically (keep the `trim()` / `sanitize()` helpers verbatim), then run
`bash tests/resolve-token-limits.sh` locally. When adding a third setting, the
duplication reaches nine copies — extract a shared script instead of copying
again. Also update the `SETTINGS` table at the top of the test
(`input name, step name, env var, built-in default`) and the README tables/docs.

#!/usr/bin/env bash
# Compose the task text handed to a review engine.
#
# Engine-neutral on purpose: it owns the parts that are not provider specific
# (context loading, language requirement, the caller's review prompt, and the
# per-mode delivery instruction). Today only the dsh engine calls it; the
# Claude Code path keeps its prompt inline in the YAML so GHES users never need
# this repository's source checked out.
#
# Environment (all values arrive through `env:`, never through shell
# interpolation, so a prompt or a PR title cannot inject commands):
#   ROLE            review | summarize
#   MODE            single | multi
#   REPO            owner/repo
#   PR_NUMBER       pull request number
#   USER_REQUEST    optional @claude mention text
#   REVIEW_LANGUAGE review comment language (empty -> English)
#   REVIEW_PROMPT   caller-supplied review guidelines
#
# Writes the prompt to stdout. Nothing is evaluated: every dynamic value is
# passed as a printf argument, never as part of a format string or a heredoc
# body, so `$(...)` or backticks inside user input stay literal text.
set -euo pipefail

ROLE="${ROLE:?ROLE is required (review or summarize)}"
MODE="${MODE:-single}"
REPO="${REPO:?REPO is required}"
PR_NUMBER="${PR_NUMBER:?PR_NUMBER is required}"

USER_REQUEST="${USER_REQUEST:-}"
REVIEW_LANGUAGE="${REVIEW_LANGUAGE:-}"
REVIEW_PROMPT="${REVIEW_PROMPT:-}"

# Empty language keeps the historical default. Unsupported values are passed
# through exactly like the Claude Code path does.
[ -n "$REVIEW_LANGUAGE" ] || REVIEW_LANGUAGE="English"

# Lets a later run identify (and collapse) comments this engine posted.
HIDDEN_MARKER='<!-- gatellm-code-review:dsh -->'

JQ_LAST_REVIEW='[.[] | select(.user.login == "github-actions[bot]")] | last | .body'
JQ_USER_COMMENTS='[.[] | select(.user.login != "github-actions[bot]" and (.user.login | test("claude"; "i") | not) and .user.login != "cycode-security")] | .[] | "--- User: \(.user.login) ---\n\(.body)"'

print_header() {
  printf 'REPO: %s\n' "$REPO"
  printf 'PR NUMBER: %s\n\n' "$PR_NUMBER"
}

print_context_loading() {
  cat <<'EOF'
Before starting your review, run these commands with the shell to load context:

1. Load your last review comment (to avoid repeating findings and build on previous feedback):
EOF
  printf "gh api repos/%s/issues/%s/comments --jq '%s'\n\n" "$REPO" "$PR_NUMBER" "$JQ_LAST_REVIEW"
  cat <<'EOF'
2. Load all user comments on this PR (to ensure you don't miss user feedback):
EOF
  printf "gh api repos/%s/issues/%s/comments --jq '%s'\n\n" "$REPO" "$PR_NUMBER" "$JQ_USER_COMMENTS"
}

print_user_request() {
  [ -n "$USER_REQUEST" ] || return 0
  printf 'User request: %s\n\n' "$USER_REQUEST"
}

print_language_requirement() {
  printf '**CRITICAL - Language Requirement:**\n'
  printf '* All review comments MUST be written in %s\n' "$REVIEW_LANGUAGE"
  cat <<'EOF'
* Code snippets, technical terms, and file paths may remain in their original language
* This is a mandatory requirement and must not be ignored

EOF
}

print_review_delivery() {
  if [ "$MODE" = "multi" ]; then
    cat <<'EOF'
IMPORTANT: Do NOT post any comment to the PR. Instead, reply with your complete review in Markdown as your final answer; the harness captures the final answer as the review body. The reply must be exactly the review body you would otherwise post, nothing else.

EOF
    return 0
  fi
  cat <<'EOF'
Use the shell to run `gh pr comment` and leave your review as a comment on the PR.

EOF
  printf 'Start the comment body with this exact line so later runs can identify and collapse it:\n%s\n\n' "$HIDDEN_MARKER"
}

print_summary_guidelines() {
  printf 'Below are the guidelines for this review; the **language requirement (%s), TODO Fix List format, and Output formatting requirements apply equally to your summary comment**:\n' "$REVIEW_LANGUAGE"
  printf '<review-guidelines>\n%s\n</review-guidelines>\n\n' "$REVIEW_PROMPT"
  cat <<'EOF'
Final output requirements:
- Post **exactly one** PR comment (run `gh pr comment` with the shell); do not post multiple.
- Start the comment body with this exact line so later runs can identify and collapse it:
EOF
  printf '%s\n' "$HIDDEN_MARKER"
  cat <<'EOF'
- The first line after that marker states this is a joint review summary from N models (list model names).
- Comment structure:
  - Opening line stating the list of models in the joint review
  - Merged and deduplicated findings analysis (with confidence annotations, ordered by severity)
  - Unified `## TODO Fix List` (the only authoritative list, continuous numbering TODO-1..n)
  - Merged "Requires manual attention" section
  - Absent-model note (if any)
  - At the bottom, attach each model's original review in a collapsed block, formatted as:
    <details>
    <summary>Original Review: <model-name></summary>
    (Original content. Note: there must be a blank line between the <details> tag and the content for markdown to render correctly.)
    </details>
- GitHub comment limit is 65536 characters: if the total original reviews are too large, proportionally truncate the collapsed-block content and note "Truncated; full content in workflow artifacts"; the summary body and TODO list must not be truncated.
- Do not perform any other PR operations beyond this one comment.
EOF
}

case "$ROLE" in
  review)
    print_header
    print_context_loading
    print_user_request
    print_language_requirement
    printf '%s\n\n' "$REVIEW_PROMPT"
    print_review_delivery
    ;;
  summarize)
    print_header
    cat <<'EOF'
You are the summarizer for multi-model code review. Multiple AI models have independently completed reviews of this PR; the raw results are saved in the `./claude-reviews/` directory (each `.md` file corresponds to one model; the `# Reviewer: <model>` line at the top of the file identifies the model name).

Steps:
1. Use the shell to list and read all `.md` files under `./claude-reviews/`, and extract the model name from each file's `# Reviewer:` header.
EOF
    printf '2. You can use `GH_PAGER=cat gh pr diff %s` to view the actual diff for cross-verifying disputed findings.\n' "$PR_NUMBER"
    cat <<'EOF'
3. Merge all findings and deduplicate: the same issue reported by different models in different wording counts as one entry.
4. Annotate each finding with a confidence level:
   - Reported independently by >=2 models -> annotate after the title with `[Consensus N/M]` (N = number of models reporting the issue, M = total models); high confidence, ranked first
   - Reported by a single model only -> quick-check against the diff; obvious false positives (citing non-existent code, misreading diff context) are discarded outright; unverifiable items are kept and annotated with `[Single model]`
5. Merge each model's `## TODO Fix List` section: after dedup, **renumber** as continuous `TODO-1..n`, output a unified `## TODO Fix List` (format per the review-guidelines below). Consensus annotation goes after the severity tag on the TODO line, e.g. - [ ] **[TODO-1] [P0] [Consensus 2/3] `src/app.ts:42`** - .... The original reviews in the collapsed blocks keep their original numbering, but the comment must note that the body TODO list is the only authoritative list.
6. Order output by severity (critical bug / security issue -> logic risk / behavioral regression -> performance -> missing tests -> style suggestion).
7. Merge each model's "Requires manual attention" into one section, deduplicated.
8. If a model's file content is the failure placeholder ("No review output"), note at the end of the comment that the model was absent; this doesn't affect the rest of the summary.

EOF
    print_user_request
    print_language_requirement
    print_summary_guidelines
    ;;
  *)
    echo "::error::Unsupported ROLE '$ROLE' (expected review or summarize)." >&2
    exit 1
    ;;
esac

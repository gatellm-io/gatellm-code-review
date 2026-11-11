#!/usr/bin/env bash
# Run one review (or one multi-model summary) through the dsh CLI.
#
# Environment (set by the action/workflow step; never interpolated here):
#   ROLE, MODE, MODEL, REPO, PR_NUMBER
#   USER_REQUEST, REVIEW_LANGUAGE, REVIEW_PROMPT
#   ANTHROPIC_BASE_URL, ANTHROPIC_API_KEY, GH_TOKEN
#   CLAUDE_CODE_MAX_CONTEXT_TOKENS, CLAUDE_CODE_MAX_OUTPUT_TOKENS
#   DSH_BIN        resolved executable (detect.sh or install.sh)
#   DSH_PATCH_FILE optional path for the generated patch layer
#   OUTPUT_FILE    multi-mode review only: where to write the review body
#   LOG_SLUG       artifact-friendly label (review / summary / matrix slug)
#
# Exit code: dsh's own exit code (0 only when the turn completed).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

ROLE="${ROLE:?ROLE is required}"
MODE="${MODE:-single}"
REPO="${REPO:?REPO is required}"
PR_NUMBER="${PR_NUMBER:?PR_NUMBER is required}"
DSH_BIN="${DSH_BIN:-}"
LOG_SLUG="${LOG_SLUG:-review}"

# The existing artifacts use /tmp explicitly; keep both logs in the same place
# so a single upload glob covers every engine.
LOG_DIR="/tmp/dsh-execution-output-${LOG_SLUG}-${GITHUB_RUN_ID:-local}-attempt${GITHUB_RUN_ATTEMPT:-1}"

if [ -z "$DSH_BIN" ] || [ ! -x "$DSH_BIN" ]; then
  echo "::error::dsh CLI not found; detect.sh/install.sh must resolve an executable before run.sh is invoked."
  exit 1
fi

# --- Fork guard -----------------------------------------------------------
# The agent runs with an unrestricted shell, the gateway API key and the
# GitHub token in its environment. On a fork PR, anyone able to comment can
# reach that environment through prompt injection in the diff, so refuse to
# run there. `pull_request` runs from forks carry no secrets anyway; this
# closes the `issue_comment` path.
#
# Deliberately fail closed: if the check itself cannot be evaluated we stop
# rather than run unguarded.
if ! CROSS_REPO="$(env GH_PAGER=cat gh pr view "$PR_NUMBER" --repo "$REPO" --json isCrossRepository --jq '.isCrossRepository' 2>/dev/null)"; then
  echo "::error::Unable to determine whether PR #$PR_NUMBER comes from a fork; refusing to run the dsh engine without that check."
  exit 1
fi
CROSS_REPO="$(printf '%s' "$CROSS_REPO" | tr -d '[:space:]')"
if [ -z "$CROSS_REPO" ]; then
  echo "::error::Fork check for PR #$PR_NUMBER returned no result; refusing to run the dsh engine."
  exit 1
fi
if [ "$CROSS_REPO" = "true" ]; then
  echo "::warning::PR #$PR_NUMBER is from a fork. Skipping the dsh review: an unrestricted agent must not read untrusted PR content with repository secrets available."
  exit 0
fi

# --- Isolated harness home -------------------------------------------------
# A fresh DSH_HOME per run keeps profiles, sessions and settings from leaking
# between matrix legs that share a self-hosted runner.
if ! DSH_HOME="$(mktemp -d "/tmp/dsh-home-${LOG_SLUG}-XXXXXX")"; then
  echo "::error::Failed to create an isolated DSH_HOME."
  exit 1
fi
export DSH_HOME
# Self-hosted runners keep /tmp between runs; start from a clean log directory.
rm -rf "$LOG_DIR"
mkdir -p "$LOG_DIR"

echo "Preparing dsh: $("$DSH_BIN" --version 2>/dev/null || echo 'version unknown'), DSH_HOME=$DSH_HOME"

# The model and gateway are injected as a patch layer (`dsh --patch`), because
# headless has no --model flag and settings.yaml is only imported after the
# first boot has already resolved its default model.
PATCH_FILE="${DSH_PATCH_FILE:-$DSH_HOME/review.patch.yml}"
export DSH_PATCH_FILE="$PATCH_FILE"

if ! node "$SCRIPT_DIR/patch.mjs"; then
  echo "::error::Failed to generate the dsh patch layer at $PATCH_FILE."
  exit 1
fi

# --- Prompt ---------------------------------------------------------------
if ! PROMPT="$(bash "$SCRIPT_DIR/../../prompt/compose.sh")"; then
  echo "::error::Failed to compose the review prompt."
  exit 1
fi
if [ -z "$PROMPT" ]; then
  echo "::error::Composed prompt is empty."
  exit 1
fi
PROMPT_BYTES="$(printf '%s' "$PROMPT" | wc -c | tr -d '[:space:]')"
case "$PROMPT_BYTES" in
  '' | *[!0-9]*)
    # Never let an unmeasurable prompt skip the size guard below.
    echo "::error::Could not measure the composed prompt size."
    exit 1
    ;;
esac
# Linux caps a single argv element at MAX_ARG_STRLEN (128 KiB). Stay clear of
# it so an oversized prompt fails loudly here instead of inside execve.
if [ "$PROMPT_BYTES" -gt 120000 ]; then
  echo "::error::Composed prompt is ${PROMPT_BYTES} bytes, over the 120000-byte limit (Linux MAX_ARG_STRLEN is 128 KiB). Shorten inputs.prompt or the user request."
  exit 1
fi

# --- Run ------------------------------------------------------------------
export DSH_TELEMETRY_DISABLED=1
export DSH_PERMISSION_MODE=danger-full-access
# The generated patch references this variable by name; the value never touches disk.
export GATELLM_REVIEW_API_KEY="${ANTHROPIC_API_KEY:-}"

# The invoking directory is dsh's workspace root; always run from the PR
# checkout, never from wherever the caller happened to invoke us.
cd "${GITHUB_WORKSPACE:-$(pwd)}" || { echo "::error::Cannot enter the workspace."; exit 1; }

# Diagnostics only: which layer supplies each config value. Best effort.
"$DSH_BIN" --profile headless --patch "$PATCH_FILE" --dump-config > "$LOG_DIR/dump-config.txt" 2>&1 || true

echo "Running dsh (role=$ROLE, mode=$MODE, prompt ${PROMPT_BYTES} bytes)"
set +e
"$DSH_BIN" --profile headless --patch "$PATCH_FILE" "$PROMPT" > "$LOG_DIR/final.md" 2> >(tee "$LOG_DIR/stderr.log" >&2)
STATUS=$?
set -e
echo "dsh exited with status $STATUS"

# --- Collect diagnostics --------------------------------------------------
if [ -d "$DSH_HOME/sessions" ]; then
  cp -R "$DSH_HOME/sessions" "$LOG_DIR/sessions" 2>/dev/null || true
fi
if [ -f "$PATCH_FILE" ]; then
  cp "$PATCH_FILE" "$LOG_DIR/patch.yml" 2>/dev/null || true
fi

# --- Multi-model handoff --------------------------------------------------
# The packaging step reads ./claude-review-output.md for every engine, so only
# the body is handed over here. An empty answer is left unwritten on purpose:
# the packaging step then records the model as producing no output.
if [ "$ROLE" = "review" ] && [ "$MODE" = "multi" ] && [ -n "${OUTPUT_FILE:-}" ]; then
  if [ -s "$LOG_DIR/final.md" ] && [ -n "$(tr -d '[:space:]' < "$LOG_DIR/final.md")" ]; then
    if cp "$LOG_DIR/final.md" "$OUTPUT_FILE"; then
      echo "Wrote the review body to $OUTPUT_FILE"
    else
      echo "::error::Failed to write the review body to $OUTPUT_FILE."
      if [ "$STATUS" -eq 0 ]; then
        STATUS=1
      fi
    fi
  else
    echo "::warning::dsh produced no review output; leaving $OUTPUT_FILE unwritten."
  fi
fi

exit "$STATUS"

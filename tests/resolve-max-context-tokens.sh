#!/usr/bin/env bash
# Regression tests for the max_context_tokens resolution logic.
#
# The same shell block is duplicated three times (composite action, review job,
# summarize job). This test:
#   1. extracts each copy from the YAML sources and asserts they are identical
#      after dedenting, so a one-sided edit is caught;
#   2. executes the extracted block against the precedence/validation table.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="$ROOT/action.yml"
WORKFLOW="$ROOT/.github/workflows/claude-auto-review.yml"
PY="${PYTHON:-python3}"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# Reuse the interpreter that started this script, so a macOS run genuinely
# exercises /bin/bash 3.2 rather than whatever `bash` resolves to on PATH.
BASH_BIN="${BASH_BIN:-${BASH:-bash}}"
echo "bash: $BASH_VERSION ($BASH_BIN)"

"$PY" - "$ACTION" "$WORKFLOW" "$tmpdir" <<'PY'
import sys

action, workflow, out = sys.argv[1:4]
STEP = "- name: Resolve max context tokens"


def extract_all(path):
    lines = open(path, encoding="utf-8").read().splitlines()
    blocks = []
    for start, line in enumerate(lines):
        if line.strip() != STEP:
            continue
        try:
            run_idx = next(
                i for i in range(start, len(lines)) if lines[i].strip() == "run: |"
            )
        except StopIteration:
            raise SystemExit(f"{path}: step {STEP!r} has no 'run: |' block")
        # The run body alone is not enough: a typo in the env wiring would leave
        # every test green while that job silently ignores the caller input.
        header = lines[start:run_idx]
        if not any(l.strip() == "INPUT_TOKENS: ${{ inputs.max_context_tokens }}" for l in header):
            raise SystemExit(
                f"FAIL: {path}: resolve step at line {start + 1} is missing "
                "'INPUT_TOKENS: ${{ inputs.max_context_tokens }}'"
            )
        if path.endswith("action.yml") and not any(
            l.strip() == "if: steps.check.outputs.too_large != 'true'" for l in header
        ):
            raise SystemExit(
                f"FAIL: {path}: resolve step at line {start + 1} lost its "
                "'too_large' guard"
            )
        step_indent = len(line) - len(line.lstrip())
        body_indent = len(lines[run_idx]) - len(lines[run_idx].lstrip()) + 2
        body = []
        for body_line in lines[run_idx + 1 :]:
            if body_line.strip() and (len(body_line) - len(body_line.lstrip())) <= step_indent:
                break
            body.append(body_line[body_indent:] if len(body_line) >= body_indent else "")
        blocks.append("\n".join(body).rstrip() + "\n")
    return blocks


def assert_position(path, job_headers=None):
    """Assert the resolution step precedes the CLI detect/install steps.

    The step's position is what makes it fail fast; the identity check above
    would happily accept it being moved back below the install steps.
    """
    lines = open(path, encoding="utf-8").read().splitlines()
    sections = []
    if job_headers:
        starts = [i for i, line in enumerate(lines) if line in job_headers]
        if len(starts) != len(job_headers):
            raise SystemExit(
                f"FAIL: {path}: expected {len(job_headers)} job header(s) "
                f"{sorted(job_headers)}, found {len(starts)}"
            )
        for idx, start in enumerate(starts):
            end = starts[idx + 1] if idx + 1 < len(starts) else len(lines)
            sections.append((lines[start].strip(), start, end))
    else:
        sections.append(("<file>", 0, len(lines)))

    for name, start, end in sections:
        def find(step):
            for i in range(start, end):
                if lines[i].strip() == step:
                    return i
            return None

        resolve_idx = find(STEP)
        if resolve_idx is None:
            raise SystemExit(
                f"FAIL: {path} [{name}]: no '{STEP}' step; every job that runs "
                "the CLI must resolve the context window"
            )
        detect_idx = find("- name: Detect Claude CLI path")
        install_idx = find("- name: Install Claude CLI if missing")
        if detect_idx is None or install_idx is None:
            raise SystemExit(
                f"FAIL: {path} [{name}]: resolve step found but Detect/Install step missing"
            )
        if not (resolve_idx < detect_idx and resolve_idx < install_idx):
            raise SystemExit(
                f"FAIL: {path} [{name}]: '{STEP}' (line {resolve_idx + 1}) must precede "
                f"'Detect Claude CLI path' (line {detect_idx + 1}) and "
                f"'Install Claude CLI if missing' (line {install_idx + 1}) "
                "so a caller typo fails before installing the CLI"
            )
        print(f"OK: {path} [{name}]: resolve precedes CLI detect/install")


def assert_output_wiring(path, expected):
    """Assert every CLI step still forwards the resolved value.

    The resolution block is useless if the claude-code-action step stops
    reading it; assert one passthrough per resolve block.
    """
    lines = open(path, encoding="utf-8").read().splitlines()
    passthrough = "CLAUDE_CODE_MAX_CONTEXT_TOKENS: ${{ env.CLAUDE_CODE_MAX_CONTEXT_TOKENS }}"
    found = sum(1 for line in lines if line.strip() == passthrough)
    if found != expected:
        raise SystemExit(
            f"FAIL: {path}: expected {expected} '{passthrough}' line(s), found {found}"
        )
    print(f"OK: {path}: {found} CLI step(s) forward the resolved value")


assert_position(action)
assert_position(workflow, job_headers={"  review:", "  summarize:"})
assert_output_wiring(action, expected=1)
assert_output_wiring(workflow, expected=2)

action_blocks = extract_all(action)
workflow_blocks = extract_all(workflow)

if len(action_blocks) != 1:
    raise SystemExit(f"{action}: expected 1 resolution block, found {len(action_blocks)}")
if len(workflow_blocks) != 2:
    raise SystemExit(f"{workflow}: expected 2 resolution blocks, found {len(workflow_blocks)}")

canonical = action_blocks[0]
for label, block in (("action.yml", action_blocks[0]),
                     ("review job", workflow_blocks[0]),
                     ("summarize job", workflow_blocks[1])):
    if block != canonical:
        print(f"FAIL: {label} resolution block differs from action.yml", file=sys.stderr)
        print("--- action.yml ---", file=sys.stderr)
        print(canonical, file=sys.stderr)
        print(f"--- {label} ---", file=sys.stderr)
        print(block, file=sys.stderr)
        raise SystemExit(1)

with open(f"{out}/resolve.sh", "w", encoding="utf-8") as fh:
    fh.write(canonical)
print("OK: all three resolution blocks are identical")
PY

script="$tmpdir/resolve.sh"
failures=0

assert_case() {
  local name="$1" input="$2" runner="$3" expected_status="$4" expected_value="${5:-}" expected_log="${6:-}"
  local envfile="$tmpdir/github_env" log="$tmpdir/log"
  : > "$envfile"

  local status=0
  # Mirror the runner's `shell: bash` invocation: --noprofile --norc -eo pipefail.
  INPUT_TOKENS="$input" CLAUDE_CODE_MAX_CONTEXT_TOKENS="$runner" GITHUB_ENV="$envfile" \
    "$BASH_BIN" -eo pipefail "$script" >"$log" 2>&1 || status=$?

  if [ "$status" -ne "$expected_status" ]; then
    echo "FAIL [$name]: expected exit $expected_status, got $status"
    sed 's/^/    /' "$log"
    failures=$((failures + 1))
    return
  fi

  if [ -n "$expected_value" ]; then
    local actual
    actual="$(sed -n 's/^CLAUDE_CODE_MAX_CONTEXT_TOKENS=//p' "$envfile" | tail -1)"
    if [ "$actual" != "$expected_value" ]; then
      echo "FAIL [$name]: expected value '$expected_value', got '$actual'"
      failures=$((failures + 1))
      return
    fi
  fi

  if [ -n "$expected_log" ] && ! grep -qF "$expected_log" "$log"; then
    echo "FAIL [$name]: log does not contain '$expected_log'"
    sed 's/^/    /' "$log"
    failures=$((failures + 1))
    return
  fi

  # A rejected input must not write a value to GITHUB_ENV.
  if [ "$expected_status" -ne 0 ] && grep -q '^CLAUDE_CODE_MAX_CONTEXT_TOKENS=' "$envfile"; then
    echo "FAIL [$name]: rejected input still wrote CLAUDE_CODE_MAX_CONTEXT_TOKENS"
    failures=$((failures + 1))
    return
  fi

  echo "ok   $name"
}

assert_case "input wins over runner env"        "2000000" "1000000" 0 "2000000"
assert_case "input 0 defers to runner env"      "0"       "500000"  0 "500000"
assert_case "empty input defers to runner env"  ""        "500000"  0 "500000"
assert_case "no input, no runner env -> 1000000" ""       ""        0 "1000000"
assert_case "input 0, no runner env -> 1000000" "0"       ""        0 "1000000"
assert_case "input is trimmed"                  " 2000000 " ""      0 "2000000"
assert_case "runner env is trimmed"             ""        " 500000 " 0 "500000"
assert_case "literal 0 runner env is unset"     ""        "0"       0 "1000000"
assert_case "input 0 after trim is unset"       " 0 "     ""        0 "1000000"
assert_case "invalid input fails"               "abc"     ""        1
assert_case "negative input fails"              "-1"      ""        1
assert_case "shell injection input fails"       "2000000; rm -rf /" "" 1
assert_case "invalid runner env warns and falls back" "" "1M"      0 "1000000" "::warning::"
assert_case "invalid explicit 0 spelling fails"  "00"      ""        1

# Error messages must not emit a second workflow-command line when the value
# contains an embedded newline.
newline_input=$'123\n::add-mask::pwned'
assert_case "error path newline injection is sanitized" "$newline_input" "" 1
if grep -q '^::add-mask::pwned' "$tmpdir/log"; then
  echo "FAIL [error path newline injection is sanitized]: raw newline reached the log"
  failures=$((failures + 1))
fi

# The runner-env branch uses the same sanitizer for its ::warning:: message.
assert_case "warning path newline injection is sanitized" "" $'1M\n::add-mask::pwned' 0 "1000000" "::warning::"
if grep -q '^::add-mask::pwned' "$tmpdir/log"; then
  echo "FAIL [warning path newline injection is sanitized]: raw newline reached the log"
  failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all max_context_tokens resolution tests passed"

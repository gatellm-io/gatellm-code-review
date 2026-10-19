#!/usr/bin/env bash
# Regression tests for the token-limit resolution logic.
#
# Two settings share the same resolution semantics:
#   - max_context_tokens -> CLAUDE_CODE_MAX_CONTEXT_TOKENS, default 1000000
#   - max_output_tokens  -> CLAUDE_CODE_MAX_OUTPUT_TOKENS,  default 64000
#
# For each setting the same shell block is duplicated three times (composite
# action, review job, summarize job). This test:
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
import re
import sys

action, workflow, out = sys.argv[1:4]

# (input name, step name, exported env var, built-in default)
SETTINGS = [
    ("max_context_tokens", "Resolve max context tokens",
     "CLAUDE_CODE_MAX_CONTEXT_TOKENS", "1000000"),
    ("max_output_tokens", "Resolve max output tokens",
     "CLAUDE_CODE_MAX_OUTPUT_TOKENS", "64000"),
]


def dedent_blocks(path, step_name):
    lines = open(path, encoding="utf-8").read().splitlines()
    blocks = []
    for start, line in enumerate(lines):
        if line.strip() != f"- name: {step_name}":
            continue
        try:
            run_idx = next(
                i for i in range(start, len(lines)) if lines[i].strip() == "run: |"
            )
        except StopIteration:
            raise SystemExit(f"{path}: step '- name: {step_name}' has no 'run: |' block")
        step_indent = len(line) - len(line.lstrip())
        body_indent = len(lines[run_idx]) - len(lines[run_idx].lstrip()) + 2
        body = []
        for body_line in lines[run_idx + 1:]:
            if body_line.strip() and (len(body_line) - len(body_line.lstrip())) <= step_indent:
                break
            body.append(body_line[body_indent:] if len(body_line) >= body_indent else "")
        blocks.append((start, "\n".join(body).rstrip() + "\n"))
    return blocks


def assert_header(path, start, input_name, step_name):
    """Assert the env wiring and (for the action) the too_large guard.

    The run body alone is not enough: a typo in the env wiring would leave
    every test green while that job silently ignores the caller input.
    """
    lines = open(path, encoding="utf-8").read().splitlines()
    run_idx = next(
        i for i in range(start, len(lines)) if lines[i].strip() == "run: |"
    )
    header = lines[start:run_idx]
    expected_env = f"INPUT_TOKENS: ${{{{ inputs.{input_name} }}}}"
    if not any(l.strip() == expected_env for l in header):
        raise SystemExit(
            f"FAIL: {path}: {step_name} at line {start + 1} is missing "
            f"'{expected_env}'"
        )
    if path.endswith("action.yml") and not any(
        l.strip() == "if: steps.check.outputs.too_large != 'true'" for l in header
    ):
        raise SystemExit(
            f"FAIL: {path}: {step_name} at line {start + 1} lost its "
            "'too_large' guard"
        )


def assert_input_declared(path, input_name):
    """Assert the input is declared in the file's `inputs:` section.

    A step that references `${{ inputs.<name> }}` still resolves to an empty
    string when the declaration is dropped, so the header and identity checks
    alone would leave every case green while the input silently stops working.
    The section is located by its key rather than a fixed line number.
    """
    lines = open(path, encoding="utf-8").read().splitlines()
    start = next((i for i, l in enumerate(lines) if l.strip() == "inputs:"), None)
    if start is None:
        raise SystemExit(f"FAIL: {path}: no 'inputs:' section found")
    inputs_indent = len(lines[start]) - len(lines[start].lstrip())
    for line in lines[start + 1:]:
        if line.strip() and (len(line) - len(line.lstrip())) <= inputs_indent:
            break  # end of the inputs section
        if line.strip().split(":")[0] == input_name:
            print(f"OK: {path}: '{input_name}' is declared under 'inputs:'")
            return
    raise SystemExit(
        f"FAIL: {path}: input '{input_name}' is not declared under 'inputs:'"
    )


def assert_position(path, step_name, workflow_src=False):
    """Assert the resolution step precedes the CLI detect/install steps.

    The step's position is what makes it fail fast; the identity check above
    would happily accept it being moved back below the install steps.
    Job sections are discovered dynamically, so a newly added CLI job cannot
    escape the check.
    """
    lines = open(path, encoding="utf-8").read().splitlines()
    if workflow_src:
        starts = [i for i, line in enumerate(lines) if re.match(r"^  [A-Za-z0-9_-]+:$", line)]
        sections = []
        for idx, start in enumerate(starts):
            end = starts[idx + 1] if idx + 1 < len(starts) else len(lines)
            sections.append((lines[start].strip(), start, end))
    else:
        sections = [("<file>", 0, len(lines))]

    for name, start, end in sections:
        def find(step):
            for i in range(start, end):
                if lines[i].strip() == step:
                    return i
            return None

        detect_idx = find("- name: Detect Claude CLI path")
        if detect_idx is None:
            continue  # this job does not run the CLI
        install_idx = find("- name: Install Claude CLI if missing")
        resolve_idx = find(f"- name: {step_name}")
        if resolve_idx is None:
            raise SystemExit(
                f"FAIL: {path} [{name}]: CLI steps present but no '- name: {step_name}' "
                "step; every job that runs the CLI must resolve the token limit"
            )
        if install_idx is None:
            raise SystemExit(
                f"FAIL: {path} [{name}]: resolve step found but Install step missing"
            )
        if not (resolve_idx < detect_idx and resolve_idx < install_idx):
            raise SystemExit(
                f"FAIL: {path} [{name}]: {step_name!r} (line {resolve_idx + 1}) must precede "
                f"'Detect Claude CLI path' (line {detect_idx + 1}) and "
                f"'Install Claude CLI if missing' (line {install_idx + 1}) "
                "so a caller typo fails before installing the CLI"
            )
        print(f"OK: {path} [{name}]: {step_name} precedes CLI detect/install")


def assert_output_wiring(path, env_var, expected):
    """Assert every CLI step still forwards the resolved value.

    The resolution block is useless if the claude-code-action step stops
    reading it; locate each CLI step and require the passthrough inside it,
    rather than counting the string file-wide.
    """
    lines = open(path, encoding="utf-8").read().splitlines()
    passthrough = f"{env_var}: ${{{{ env.{env_var} }}}}"
    cli_names = ("- name: Automatic PR Review", "- name: Summarize reviews")
    found = 0
    for start, line in enumerate(lines):
        if not any(line.strip().startswith(name) for name in cli_names):
            continue
        step_indent = len(line) - len(line.lstrip())
        end = len(lines)
        for i in range(start + 1, len(lines)):
            if lines[i].strip() and (len(lines[i]) - len(lines[i].lstrip())) <= step_indent \
                    and lines[i].lstrip().startswith("- "):
                end = i
                break
        if not any(lines[i].strip() == passthrough for i in range(start, end)):
            raise SystemExit(
                f"FAIL: {path}: CLI step at line {start + 1} does not forward "
                f"'{passthrough}'"
            )
        found += 1
    if found != expected:
        raise SystemExit(
            f"FAIL: {path}: expected {expected} CLI step(s), found {found}"
        )
    print(f"OK: {path}: {found} CLI step(s) forward {env_var}")


for input_name, step_name, env_var, default in SETTINGS:
    print(f"== {input_name} ({env_var}, default {default}) ==")
    assert_input_declared(action, input_name)
    assert_input_declared(workflow, input_name)
    assert_position(action, step_name)
    assert_position(workflow, step_name, workflow_src=True)
    assert_output_wiring(action, env_var, expected=1)
    assert_output_wiring(workflow, env_var, expected=2)

    action_blocks = dedent_blocks(action, step_name)
    workflow_blocks = dedent_blocks(workflow, step_name)

    if len(action_blocks) != 1:
        raise SystemExit(f"{action}: expected 1 {step_name} block, found {len(action_blocks)}")
    if len(workflow_blocks) != 2:
        raise SystemExit(f"{workflow}: expected 2 {step_name} blocks, found {len(workflow_blocks)}")

    for start, _ in action_blocks:
        assert_header(action, start, input_name, step_name)
    for start, _ in workflow_blocks:
        assert_header(workflow, start, input_name, step_name)

    canonical = action_blocks[0][1]
    for label, (_, block) in (("action.yml", action_blocks[0]),
                              ("review job", workflow_blocks[0]),
                              ("summarize job", workflow_blocks[1])):
        if block != canonical:
            print(f"FAIL: {label} {step_name} block differs from action.yml", file=sys.stderr)
            print("--- action.yml ---", file=sys.stderr)
            print(canonical, file=sys.stderr)
            print(f"--- {label} ---", file=sys.stderr)
            print(block, file=sys.stderr)
            raise SystemExit(1)

    with open(f"{out}/resolve-{input_name}.sh", "w", encoding="utf-8") as fh:
        fh.write(canonical)
    print(f"OK: all three {step_name} blocks are identical")
PY

failures=0

run_suite() {
  local envvar="$1" default="$2" script="$3"

  assert_case() {
    local name="$1" input="$2" runner="$3" expected_status="$4" expected_value="${5:-}" expected_log="${6:-}"
    local envfile="$tmpdir/github_env" log="$tmpdir/log"
    : > "$envfile"

    local status=0
    # Mirror the runner's `shell: bash` invocation exactly.
    env INPUT_TOKENS="$input" "$envvar=$runner" GITHUB_ENV="$envfile" \
      "$BASH_BIN" --noprofile --norc -eo pipefail "$script" >"$log" 2>&1 || status=$?

    if [ "$status" -ne "$expected_status" ]; then
      echo "FAIL [$envvar/$name]: expected exit $expected_status, got $status"
      sed 's/^/    /' "$log"
      failures=$((failures + 1))
      return
    fi

    if [ -n "$expected_value" ]; then
      local actual
      actual="$(sed -n "s/^${envvar}=//p" "$envfile" | tail -1)"
      if [ "$actual" != "$expected_value" ]; then
        echo "FAIL [$envvar/$name]: expected value '$expected_value', got '$actual'"
        failures=$((failures + 1))
        return
      fi
    fi

    if [ -n "$expected_log" ] && ! grep -qF "$expected_log" "$log"; then
      echo "FAIL [$envvar/$name]: log does not contain '$expected_log'"
      sed 's/^/    /' "$log"
      failures=$((failures + 1))
      return
    fi

    # A rejected input must not write a value to GITHUB_ENV.
    if [ "$expected_status" -ne 0 ] && grep -q "^${envvar}=" "$envfile"; then
      echo "FAIL [$envvar/$name]: rejected input still wrote ${envvar}"
      failures=$((failures + 1))
      return
    fi

    echo "ok   $envvar/$name"
  }

  assert_case "input wins over runner env"        "2000000" "1000000" 0 "2000000"
  assert_case "input 0 defers to runner env"      "0"       "500000"  0 "500000"
  assert_case "empty input defers to runner env"  ""        "500000"  0 "500000"
  assert_case "no input, no runner env -> default" ""       ""        0 "$default"
  assert_case "input 0, no runner env -> default" "0"       ""        0 "$default"
  assert_case "input is trimmed"                  " 2000000 " ""      0 "2000000"
  assert_case "runner env is trimmed"             ""        " 500000 " 0 "500000"
  assert_case "literal 0 runner env is unset"     ""        "0"       0 "$default"
  assert_case "input 0 after trim is unset"       " 0 "     ""        0 "$default"
  assert_case "invalid input fails"               "abc"     ""        1
  assert_case "negative input fails"              "-1"      ""        1
  assert_case "shell injection input fails"       "2000000; rm -rf /" "" 1
  assert_case "invalid runner env warns and falls back" "" "1M"      0 "$default" "::warning::"
  assert_case "invalid explicit 0 spelling fails"  "00"      ""        1
  assert_case "explicit +0 spelling fails"         "+0"      ""        1
  assert_case "explicit 0.0 spelling fails"        "0.0"     ""        1

  # Error messages must not emit a second workflow-command line when the value
  # contains an embedded newline.
  local newline_input=$'123\n::add-mask::pwned'
  assert_case "error path newline injection is sanitized" "$newline_input" "" 1
  if grep -q '^::add-mask::pwned' "$tmpdir/log"; then
    echo "FAIL [$envvar/error path newline injection is sanitized]: raw newline reached the log"
    failures=$((failures + 1))
  fi

  # The runner-env branch uses the same sanitizer for its ::warning:: message.
  assert_case "warning path newline injection is sanitized" "" $'1M\n::add-mask::pwned' 0 "$default" "::warning::"
  if grep -q '^::add-mask::pwned' "$tmpdir/log"; then
    echo "FAIL [$envvar/warning path newline injection is sanitized]: raw newline reached the log"
    failures=$((failures + 1))
  fi
}

run_suite CLAUDE_CODE_MAX_CONTEXT_TOKENS 1000000 "$tmpdir/resolve-max_context_tokens.sh"
run_suite CLAUDE_CODE_MAX_OUTPUT_TOKENS 64000 "$tmpdir/resolve-max_output_tokens.sh"

if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all token-limit resolution tests passed"

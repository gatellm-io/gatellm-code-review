#!/usr/bin/env bash
# Regression tests for the dsh review engine.
#
# Everything runs offline against test doubles in tests/fixtures: fake node,
# fake npm, fake dsh and fake gh. The GitHub wiring (input declarations, step
# gating, step order) is asserted by parsing the YAML textually, the same way
# tests/resolve-token-limits.sh does, so no third-party YAML parser is needed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DSH_DIR="$ROOT/scripts/engines/dsh"
FIXTURES="$ROOT/tests/fixtures"
PY="${PYTHON:-python3}"
BASH_BIN="${BASH_BIN:-${BASH:-bash}}"
# Resolve to an absolute path now: several cases run with a restricted PATH
# that contains no `bash`, and a bare name would then fail to launch.
BASH_BIN="$(command -v "$BASH_BIN" || true)"
[ -n "$BASH_BIN" ] || { echo "FAIL: cannot resolve the bash interpreter" >&2; exit 1; }

if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node is required to run the dsh engine tests" >&2
  exit 1
fi

tmpdir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmpdir"
  rm -rf /tmp/dsh-execution-output-test-*
  rm -rf /tmp/dsh-home-test-*
}
trap cleanup EXIT

failures=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; failures=$((failures + 1)); }

dump_context() {
  # The last command's captured output, so a CI failure is diagnosable.
  [ -s "$tmpdir/out" ] && { echo "    --- last output ---"; sed 's/^/    /' "$tmpdir/out" | tail -n 15; }
}
assert_eq() { # name expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; dump_context; fi
}
assert_contains() { # name haystack needle
  case "$2" in
    *"$3"*) ok "$1" ;;
    *) bad "$1 (missing '$3')" ;;
  esac
}
assert_not_contains() { # name haystack needle
  case "$2" in
    *"$3"*) bad "$1 (unexpected '$3')" ;;
    *) ok "$1" ;;
  esac
}

# --- Sandbox --------------------------------------------------------------
# A minimal PATH holding only the tools the scripts use, so `command -v dsh`
# and `command -v npm` cannot accidentally find the developer's real tools.
mkdir -p "$tmpdir/tools" "$tmpdir/bin" "$tmpdir/home" "$tmpdir/workspace" "$tmpdir/empty"
for tool in tr grep head sed dirname mktemp cp mv mkdir rm chmod cat ln env bash sh wc tee find; do
  src="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$src" ] && ln -sf "$src" "$tmpdir/tools/$tool"
done
ln -sf "$FIXTURES/fake-gh" "$tmpdir/bin/gh"
ln -sf "$FIXTURES/fake-npm" "$tmpdir/bin/npm"
# run.sh shells out to node for patch.mjs; use the real interpreter.
ln -sf "$(command -v node)" "$tmpdir/bin/node"

SANDBOX_PATH="$tmpdir/bin:$tmpdir/tools"
SANDBOX_HOME="$tmpdir/home"

new_out() { : > "$tmpdir/out"; }
read_out() { cat "$tmpdir/out" 2>/dev/null || true; }

# ==========================================================================
echo "== check-node.sh =="
# check-node.sh is builtin-only, so it can run with an empty PATH.
node_case() { # version expected
  local dir="$tmpdir/node-$1"
  mkdir -p "$dir"
  printf '#!/bin/sh\necho "%s"\n' "$1" > "$dir/node"
  chmod +x "$dir/node"
  : > "$tmpdir/gh_output"
  PATH="$dir" HOME="$SANDBOX_HOME" \
    FAKE_NODE_VERSION="$1" GITHUB_OUTPUT="$tmpdir/gh_output" GITHUB_PATH="$tmpdir/gh_path" \
    DSH_NODE_SEARCH_DIRS='' \
    "$BASH_BIN" "$DSH_DIR/check-node.sh" > "$tmpdir/out" 2>&1
  tr -d '\r' < "$tmpdir/gh_output" | grep -q '^node_ok=true$' && echo true || echo false
}
assert_eq "node 22.19.0 is too old" false "$(node_case v22.19.0)"
assert_eq "node 24.8.0 is too old" false "$(node_case v24.8.0)"
assert_eq "node 24.9.0 is accepted" true "$(node_case v24.9.0)"
assert_eq "node 25.1.0 is accepted" true "$(node_case v25.1.0)"

: > "$tmpdir/gh_output"
PATH="$tmpdir/empty" HOME="$SANDBOX_HOME" GITHUB_OUTPUT="$tmpdir/gh_output" \
  GITHUB_PATH="$tmpdir/gh_path" DSH_NODE_SEARCH_DIRS='' \
  "$BASH_BIN" "$DSH_DIR/check-node.sh" > "$tmpdir/out" 2>&1
assert_eq "no node anywhere -> node_ok=false" "node_ok=false" "$(tr -d '\r' < "$tmpdir/gh_output")"

# A node only in the nvm layout is found and its directory is exported. The
# search list is pinned to the nvm tree so a runner's own Homebrew/usr-local
# node cannot win the race and change which directory gets exported.
mkdir -p "$tmpdir/home/.nvm/versions/node/v24.10.0/bin"
printf '#!/bin/sh\necho v24.10.0\n' > "$tmpdir/home/.nvm/versions/node/v24.10.0/bin/node"
chmod +x "$tmpdir/home/.nvm/versions/node/v24.10.0/bin/node"
: > "$tmpdir/gh_output"; : > "$tmpdir/gh_path"
PATH="$tmpdir/empty" HOME="$tmpdir/home" GITHUB_OUTPUT="$tmpdir/gh_output" GITHUB_PATH="$tmpdir/gh_path" \
  DSH_NODE_SEARCH_DIRS="$tmpdir/home/.nvm/versions/node/*/bin" \
  "$BASH_BIN" "$DSH_DIR/check-node.sh" > "$tmpdir/out" 2>&1
assert_eq "nvm-installed node is found" "node_ok=true" "$(tr -d '\r' < "$tmpdir/gh_output")"
assert_contains "nvm node dir is added to GITHUB_PATH" "$(cat "$tmpdir/gh_path")" "$tmpdir/home/.nvm/versions/node/v24.10.0/bin"

# ==========================================================================
echo "== detect.sh =="
detect() { # dsh_version -> stdout path
  : > "$tmpdir/gh_output"
  PATH="$SANDBOX_PATH" HOME="$SANDBOX_HOME" DSH_VERSION="$1" GITHUB_OUTPUT="$tmpdir/gh_output" \
    "$BASH_BIN" "$DSH_DIR/detect.sh" > "$tmpdir/out" 2>&1
  sed -n 's/^dsh_path=//p' "$tmpdir/gh_output" | tail -1
}

assert_eq "detect: nothing installed" "" "$(detect '')"
assert_contains "detect: warns when nothing is found" "$(cat "$tmpdir/out")" "::warning::dsh CLI not found"

mkdir -p "$SANDBOX_HOME/.local/bin"
cp "$FIXTURES/fake-dsh" "$SANDBOX_HOME/.local/bin/dsh"
chmod +x "$SANDBOX_HOME/.local/bin/dsh"
export FAKE_DSH_VERSION="0.2.2-rc.1"

assert_eq "detect: finds ~/.local/bin/dsh" "$SANDBOX_HOME/.local/bin/dsh" "$(detect '')"
assert_eq "detect: any version accepted when unset" "$SANDBOX_HOME/.local/bin/dsh" "$(detect '')"
assert_eq "detect: matching dsh_version accepted" "$SANDBOX_HOME/.local/bin/dsh" "$(detect '0.2.2-rc.1')"
assert_eq "detect: mismatched dsh_version rejected" "" "$(detect '9.9.9')"
assert_contains "detect: mismatch is reported" "$(cat "$tmpdir/out")" "::notice::"

# Build metadata must validate and normalize to the same string.
export FAKE_DSH_VERSION="1.2.3+build"
assert_eq "detect: build-metadata version accepted" "$SANDBOX_HOME/.local/bin/dsh" "$(detect '1.2.3+build')"
export FAKE_DSH_VERSION="0.2.2-rc.1"

# --- version grammar (lib.sh) ----------------------------------------------
# normalize_version and is_valid_version must agree on the same grammar.
version_valid() { ( . "$DSH_DIR/lib.sh"; is_valid_version "$1" ) && echo yes || echo no; }
version_norm() { ( . "$DSH_DIR/lib.sh"; normalize_version "$1" ); }
assert_eq "lib: plain semver validates" yes "$(version_valid '1.2.3')"
assert_eq "lib: pre-release validates" yes "$(version_valid '0.2.2-rc.1')"
assert_eq "lib: build metadata validates" yes "$(version_valid '1.2.3+build')"
assert_eq "lib: pre-release plus build metadata validates" yes "$(version_valid '1.2.3-rc.1+build.5')"
assert_eq "lib: junk is rejected" no "$(version_valid '1.2.3 x')"
assert_eq "lib: npm spec is rejected" no "$(version_valid 'latest')"
assert_eq "lib: normalize keeps build metadata" "1.2.3+build" "$(version_norm 'dsh 1.2.3+build (abcdef)')"
assert_eq "lib: normalize keeps pre-release plus build metadata" \
  "1.2.3-rc.1+build.5" "$(version_norm '1.2.3-rc.1+build.5')"
assert_eq "lib: a validated version survives normalization" "1.2.3+build" \
  "$(version_norm "$(version_norm 'v1.2.3+build')")"

# A broken binary must be skipped in favour of a later working one.
rm -rf "$SANDBOX_HOME/.local"
mkdir -p "$tmpdir/bin2" "$SANDBOX_HOME/.npm-global/bin"
printf '#!/bin/sh\nexit 7\n' > "$tmpdir/bin2/dsh"
chmod +x "$tmpdir/bin2/dsh"
cp "$FIXTURES/fake-dsh" "$SANDBOX_HOME/.npm-global/bin/dsh"
chmod +x "$SANDBOX_HOME/.npm-global/bin/dsh"
: > "$tmpdir/gh_output"
PATH="$tmpdir/bin2:$SANDBOX_PATH" HOME="$SANDBOX_HOME" DSH_VERSION='' GITHUB_OUTPUT="$tmpdir/gh_output" \
  "$BASH_BIN" "$DSH_DIR/detect.sh" > "$tmpdir/out" 2>&1
assert_eq "detect: skips a dsh that fails --version" "$SANDBOX_HOME/.npm-global/bin/dsh" \
  "$(sed -n 's/^dsh_path=//p' "$tmpdir/gh_output" | tail -1)"
rm -rf "$tmpdir/bin2" "$SANDBOX_HOME/.npm-global"

# The action's own tool cache is a candidate too.
rm -rf "$SANDBOX_HOME/.local"
CACHE="$tmpdir/toolcache/gatellm-code-review/dsh/0.2.2-rc.1/node_modules/.bin"
mkdir -p "$CACHE"
cp "$FIXTURES/fake-dsh" "$CACHE/dsh"
chmod +x "$CACHE/dsh"
: > "$tmpdir/gh_output"
PATH="$SANDBOX_PATH" HOME="$SANDBOX_HOME" RUNNER_TOOL_CACHE="$tmpdir/toolcache" DSH_VERSION='' \
  GITHUB_OUTPUT="$tmpdir/gh_output" "$BASH_BIN" "$DSH_DIR/detect.sh" > "$tmpdir/out" 2>&1
assert_eq "detect: finds the action tool cache" "$CACHE/dsh" \
  "$(sed -n 's/^dsh_path=//p' "$tmpdir/gh_output" | tail -1)"

# Invalid input is rejected loudly.
: > "$tmpdir/gh_output"
PATH="$SANDBOX_PATH" HOME="$SANDBOX_HOME" DSH_VERSION='1.0; rm -rf /' GITHUB_OUTPUT="$tmpdir/gh_output" \
  "$BASH_BIN" "$DSH_DIR/detect.sh" > "$tmpdir/out" 2>&1
assert_eq "detect: rejects an invalid dsh_version" 1 "$?"

# ==========================================================================
echo "== install.sh =="
install_run() { # dsh_version [extra env...]
  : > "$tmpdir/gh_output"; : > "$tmpdir/npm.log"
  : > "$tmpdir/out"
  local version="$1"; shift
  env PATH="$SANDBOX_PATH" HOME="$SANDBOX_HOME" RUNNER_TOOL_CACHE="$tmpdir/toolcache" \
    DSH_VERSION="$version" GITHUB_OUTPUT="$tmpdir/gh_output" FAKE_NPM_LOG="$tmpdir/npm.log" \
    FAKE_NPM_GLOBAL_BIN="$SANDBOX_HOME/.local/bin" "$@" \
    "$BASH_BIN" "$DSH_DIR/install.sh" > "$tmpdir/out" 2>&1
  echo $?
}
installed_path() { sed -n 's/^dsh_path=//p' "$tmpdir/gh_output" | tail -1; }

rm -rf "$tmpdir/toolcache" "$SANDBOX_HOME/.local" "$SANDBOX_HOME/.npm-global"
status="$(install_run '')"
assert_eq "install: empty dsh_version installs the pinned default" 0 "$status"
assert_contains "install: uses the DEFAULT_VERSION pin" "$(cat "$tmpdir/npm.log")" "@deepseek-ai/dsh@0.2.2-rc.1"
assert_eq "install: global flag is used first" 1 "$(grep -c 'npm install -g' "$tmpdir/npm.log")"
assert_eq "install: path comes from the global bin" "$SANDBOX_HOME/.local/bin/dsh" "$(installed_path)"

rm -rf "$SANDBOX_HOME/.local" "$tmpdir/toolcache"
status="$(install_run '0.2.1' FAKE_NPM_GLOBAL_EXIT=1)"
assert_eq "install: falls back successfully when -g fails" 0 "$status"
assert_contains "install: fallback uses --prefix" "$(cat "$tmpdir/npm.log")" "--prefix"
assert_eq "install: fallback path is inside the tool cache" \
  "$tmpdir/toolcache/gatellm-code-review/dsh/0.2.1/node_modules/.bin/dsh" "$(installed_path)"

rm -rf "$SANDBOX_HOME/.local" "$tmpdir/toolcache"
status="$(install_run '' FAKE_NPM_GLOBAL_EXIT=1 FAKE_NPM_PREFIX_EXIT=1)"
assert_eq "install: fails when every attempt fails" 1 "$status"
assert_contains "install: failure is an ::error::" "$(cat "$tmpdir/out")" "::error::"

rm -rf "$SANDBOX_HOME/.local" "$tmpdir/toolcache"
status="$(install_run '' FAKE_NPM_SKIP_WRITE=1)"
assert_eq "install: fails when no binary appears" 1 "$status"

status="$(install_run 'not a version')"
assert_eq "install: rejects an invalid version" 1 "$status"
assert_eq "install: invalid version never reaches npm" 0 "$(grep -c '@deepseek-ai/dsh' "$tmpdir/npm.log" || true)"

# Without npm, fail early with an accurate message instead of blaming the tool
# cache. The tools-only PATH has bash's helpers but no npm (and no dsh).
: > "$tmpdir/gh_output"; : > "$tmpdir/out"
env PATH="$tmpdir/tools" HOME="$SANDBOX_HOME" RUNNER_TOOL_CACHE="$tmpdir/toolcache" \
  DSH_VERSION='' GITHUB_OUTPUT="$tmpdir/gh_output" \
  "$BASH_BIN" "$DSH_DIR/install.sh" > "$tmpdir/out" 2>&1
assert_eq "install: missing npm fails" 1 "$?"
assert_contains "install: missing npm is named in the error" "$(cat "$tmpdir/out")" "npm is required"
assert_not_contains "install: missing npm does not blame the tool cache" \
  "$(cat "$tmpdir/out")" "npm install into the action tool cache failed"

# ==========================================================================
echo "== patch.mjs =="
make_patch() { # out file, then assignments for node
  local out="$1"; shift
  env DSH_PATCH_FILE="$out" "$@" node "$DSH_DIR/patch.mjs" 2>&1
}

PATCH="$tmpdir/patch/review.patch.yml"
rm -rf "$tmpdir/patch"
out="$(make_patch "$PATCH" MODEL='deepseek-v4-pro[1m]' ANTHROPIC_BASE_URL='https://gw.example/v1' \
  CLAUDE_CODE_MAX_CONTEXT_TOKENS=1000000 CLAUDE_CODE_MAX_OUTPUT_TOKENS=64000)"
assert_contains "patch: [1m] is stripped" "$(cat "$PATCH")" '"model": "deepseek-v4-pro"'
assert_not_contains "patch: no [1m] left behind" "$(cat "$PATCH")" 'deepseek-v4-pro[1m]'
assert_contains "patch: targets agent-default-model" "$(cat "$PATCH")" '"id": "agent-default-model"'
assert_contains "patch: targets llm-pi-ai" "$(cat "$PATCH")" '"id": "llm-pi-ai"'
assert_contains "patch: uses anthropic-messages" "$(cat "$PATCH")" '"api": "anthropic-messages"'
# dsh appends /v1/messages, so a trailing /v1 must be removed.
assert_contains "patch: strips a trailing /v1 from baseURL" "$(cat "$PATCH")" '"baseURL": "https://gw.example"'
assert_contains "patch: numeric contextWindow" "$(cat "$PATCH")" '"contextWindow": 1000000'
assert_contains "patch: numeric maxTokens" "$(cat "$PATCH")" '"maxTokens": 64000'
assert_contains "patch: references the key by name" "$(cat "$PATCH")" '"apiKeyEnv": "GATELLM_REVIEW_API_KEY"'
assert_contains "patch: prints a summary" "$out" "provider=gatellm-review"

make_patch "$PATCH" MODEL='m' ANTHROPIC_BASE_URL='' > /dev/null 2>&1
assert_contains "patch: empty baseURL falls back to the public API" \
  "$(cat "$PATCH")" '"baseURL": "https://api.anthropic.com"'

make_patch "$PATCH" MODEL='m' ANTHROPIC_BASE_URL='https://gw.example/v1/' > /dev/null 2>&1
assert_contains "patch: handles a trailing slash before /v1" \
  "$(cat "$PATCH")" '"baseURL": "https://gw.example"'

# Only a *trailing* /v1 segment is stripped. A /v1 followed by a path segment
# is part of the gateway's base path and must survive untouched, otherwise the
# request would land on the wrong URL.
make_patch "$PATCH" MODEL='m' ANTHROPIC_BASE_URL='https://gw.example/v1/tenant' > /dev/null 2>&1
assert_contains "patch: keeps /v1 when a path segment follows it" \
  "$(cat "$PATCH")" '"baseURL": "https://gw.example/v1/tenant"'

make_patch "$PATCH" MODEL='m' ANTHROPIC_BASE_URL='https://gw.example/' > /dev/null 2>&1
assert_contains "patch: strips a lone trailing slash" \
  "$(cat "$PATCH")" '"baseURL": "https://gw.example"'

# --- patch shape is pinned to the version it was verified against -----------
# The overlay relies on `config` being a full-line replacement (not a deep
# merge) and on the two plugin ids below, both verified against this version
# only. Pinning the version and the emitted shape here means a dsh bump cannot
# change that assumption without a deliberate edit to this test.
assert_eq "patch: DEFAULT_VERSION is the version the schema was verified against" \
  "0.2.2-rc.1" "$(tr -d '[:space:]' < "$DSH_DIR/DEFAULT_VERSION")"
make_patch "$PATCH" MODEL='m' ANTHROPIC_BASE_URL='' > /dev/null 2>&1
assert_eq "patch: emits exactly two plugin layers" 2 \
  "$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).length)' "$PATCH")"
assert_eq "patch: agent-default-model config is exactly provider+model" "provider,model" \
  "$(node -e 'const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); console.log(Object.keys(p[0].config).join(","))' "$PATCH")"
assert_eq "patch: llm-pi-ai config is exactly providers" "providers" \
  "$(node -e 'const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); console.log(Object.keys(p[1].config).join(","))' "$PATCH")"

# The secret must never be written to disk.
make_patch "$PATCH" MODEL='m' ANTHROPIC_API_KEY='sk-secret-value-123' \
  GATELLM_REVIEW_API_KEY='sk-secret-value-123' > /dev/null 2>&1
assert_eq "patch: the API key never reaches the file" 0 \
  "$(grep -rl 'sk-secret-value-123' "$tmpdir/patch" 2>/dev/null | wc -l | tr -d ' ')"

out="$(make_patch "$PATCH" MODEL='')"
assert_contains "patch: an empty model is rejected" "$out" "::error::MODEL is required"

# ==========================================================================
echo "== compose.sh =="
compose() { # role mode
  ROLE="$1" MODE="$2" REPO='o/r' PR_NUMBER='7' USER_REQUEST='' \
    REVIEW_LANGUAGE='Japanese' REVIEW_PROMPT='REVIEW-BODY' \
    "$BASH_BIN" "$ROOT/scripts/prompt/compose.sh"
}
single="$(compose review single)"
assert_contains "compose: review has the repo" "$single" "REPO: o/r"
assert_contains "compose: review loads the previous review" "$single" "Load your last review comment"
assert_contains "compose: review carries the language" "$single" "MUST be written in Japanese"
assert_contains "compose: review carries the caller prompt" "$single" "REVIEW-BODY"
assert_contains "compose: review posts with gh pr comment" "$single" "gh pr comment"
assert_contains "compose: single mode carries the collapse marker" "$single" "<!-- gatellm-code-review:dsh -->"

multi="$(compose review multi)"
assert_contains "compose: multi says not to post" "$multi" "Do NOT post any comment"
assert_contains "compose: multi writes the output file itself" "$multi" "./claude-review-output.md"
assert_not_contains "compose: multi does not post through gh pr comment" "$multi" "leave your review as a comment"

summary="$(compose summarize multi)"
assert_contains "compose: summary reads the reviews" "$summary" "./claude-reviews/"
assert_contains "compose: summary applies the caller guidelines" "$summary" "<review-guidelines>"
assert_contains "compose: summary posts exactly one comment" "$summary" "exactly one"
assert_contains "compose: summary carries the marker" "$summary" "<!-- gatellm-code-review:dsh -->"

# User input must stay inert text.
injected="$(ROLE=review MODE=single REPO='o/r' PR_NUMBER='7' REVIEW_PROMPT='x' \
  USER_REQUEST='$(touch /tmp/dsh-pwned) and `touch /tmp/dsh-pwned2`' \
  "$BASH_BIN" "$ROOT/scripts/prompt/compose.sh")"
assert_contains "compose: command substitution stays literal" "$injected" '$(touch /tmp/dsh-pwned)'
if [ -e /tmp/dsh-pwned ] || [ -e /tmp/dsh-pwned2 ]; then
  bad "compose: user input was executed"
  rm -f /tmp/dsh-pwned /tmp/dsh-pwned2
else
  ok "compose: user input was not executed"
fi

# ==========================================================================
echo "== run.sh =="
run_case() { # slug [extra env...]
  local slug="$1"; shift
  : > "$tmpdir/argv"; : > "$tmpdir/env"
  env PATH="$SANDBOX_PATH" HOME="$SANDBOX_HOME" \
    ROLE=review MODE=single MODEL='deepseek-v4-pro' REPO='o/r' PR_NUMBER='7' \
    USER_REQUEST='' REVIEW_LANGUAGE='English' REVIEW_PROMPT='do the thing' \
    ANTHROPIC_BASE_URL='' ANTHROPIC_API_KEY='sk-test' GH_TOKEN='ghs_test' \
    CLAUDE_CODE_MAX_CONTEXT_TOKENS=1000000 CLAUDE_CODE_MAX_OUTPUT_TOKENS=64000 \
    DSH_BIN="$FIXTURES/fake-dsh" LOG_SLUG="$slug" \
    GITHUB_WORKSPACE="$tmpdir/workspace" GITHUB_RUN_ID='1' GITHUB_RUN_ATTEMPT='1' \
    FAKE_DSH_ARGV_FILE="$tmpdir/argv" FAKE_DSH_ENV_FILE="$tmpdir/env" \
    "$@" \
    "$BASH_BIN" "$DSH_DIR/run.sh" > "$tmpdir/out" 2>&1
  echo $?
}

status="$(run_case test-pass)"
assert_eq "run: exits with dsh's status" 0 "$status"
assert_eq "run: profile + headless + patch + prompt" "#argc=5" "$(sed -n '1p' "$tmpdir/argv")"
assert_eq "run: first arg is --profile" "--profile" "$(sed -n '2p' "$tmpdir/argv")"
assert_eq "run: second arg is headless" "headless" "$(sed -n '3p' "$tmpdir/argv")"
assert_eq "run: third arg is --patch" "--patch" "$(sed -n '4p' "$tmpdir/argv")"
assert_contains "run: fourth arg is the patch file" "$(sed -n '5p' "$tmpdir/argv")" "review.patch.yml"
assert_contains "run: the prompt is the last argv element" "$(tail -n +6 "$tmpdir/argv")" "do the thing"
assert_contains "run: danger-full-access is exported" "$(cat "$tmpdir/env")" "DSH_PERMISSION_MODE=danger-full-access"
assert_contains "run: telemetry is disabled" "$(cat "$tmpdir/env")" "DSH_TELEMETRY_DISABLED=1"
assert_contains "run: the key is exposed to dsh" "$(cat "$tmpdir/env")" "GATELLM_REVIEW_API_KEY=sk-test"
assert_contains "run: DSH_HOME is isolated under /tmp" "$(cat "$tmpdir/env")" "DSH_HOME=/tmp/dsh-home-test-pass-"
assert_contains "run: dsh runs from the workspace" "$(cat "$tmpdir/env")" "PWD=$tmpdir/workspace"

status="$(run_case test-fail FAKE_DSH_EXIT=3)"
assert_eq "run: a failed turn keeps dsh's exit code" 3 "$status"

: > "$tmpdir/step_summary"
status="$(run_case test-fork FAKE_GH_CROSS_REPO=true GITHUB_STEP_SUMMARY="$tmpdir/step_summary")"
assert_eq "run: a fork PR is skipped successfully" 0 "$status"
assert_contains "run: the fork skip is a notice" "$(cat "$tmpdir/out")" "::notice::"
assert_contains "run: the fork skip is recorded in the step summary" \
  "$(cat "$tmpdir/step_summary")" "dsh review skipped"
if [ -s "$tmpdir/argv" ]; then
  bad "run: dsh must not be invoked for a fork PR"
else
  ok "run: dsh is not invoked for a fork PR"
fi

# Only an exact `false` may proceed: an unexpected value must fail closed.
status="$(run_case test-fork-null FAKE_GH_CROSS_REPO=null)"
assert_eq "run: an unexpected isCrossRepository value fails closed" 1 "$status"
assert_contains "run: the unexpected value is named" "$(cat "$tmpdir/out")" "instead of true or false"
if [ -s "$tmpdir/argv" ]; then
  bad "run: dsh must not be invoked for an unevaluable fork check"
else
  ok "run: dsh is not invoked for an unevaluable fork check"
fi

status="$(run_case test-ghfail FAKE_GH_EXIT=1)"
assert_eq "run: an unevaluable fork check fails closed" 1 "$status"

# The fork guard needs gh; a runner without it must say so up front.
status="$(run_case test-nogh PATH="$tmpdir/tools")"
assert_eq "run: a missing gh fails closed" 1 "$status"
assert_contains "run: a missing gh is named in the error" "$(cat "$tmpdir/out")" "GitHub CLI (gh)"

status="$(run_case test-no-bin DSH_BIN='')"
assert_eq "run: a missing DSH_BIN fails" 1 "$status"

# Multi mode: the model writes the output file itself (claude-code parity).
outfile="$tmpdir/multi-out.md"
rm -f "$outfile"
status="$(run_case test-multi MODE=multi OUTPUT_FILE="$outfile" \
  FAKE_DSH_WRITE_FILE="$outfile" FAKE_DSH_WRITE_CONTENT='REVIEW OUTPUT' FAKE_DSH_STDOUT='STDOUT NOISE')"
assert_eq "run: multi review succeeds" 0 "$status"
assert_eq "run: multi review uses the file the model wrote" "REVIEW OUTPUT" "$(cat "$outfile" 2>/dev/null)"
assert_not_contains "run: the file wins over noisy stdout" "$(cat "$outfile" 2>/dev/null)" "STDOUT NOISE"

# Fallback: if the model ignored the instruction, stdout is used but announced.
rm -f "$outfile"
status="$(run_case test-multi-stdout MODE=multi OUTPUT_FILE="$outfile" FAKE_DSH_STDOUT='STDOUT REVIEW')"
assert_eq "run: multi review still succeeds from stdout" 0 "$status"
assert_eq "run: stdout fallback writes the output file" "STDOUT REVIEW" "$(cat "$outfile" 2>/dev/null)"
assert_contains "run: the stdout fallback is announced" "$(cat "$tmpdir/out")" "falling back to its stdout"

rm -f "$outfile"
status="$(run_case test-multi-empty MODE=multi OUTPUT_FILE="$outfile")"
assert_eq "run: empty output still succeeds" 0 "$status"
if [ -e "$outfile" ]; then
  bad "run: empty output must not create the file"
else
  ok "run: empty output leaves the file unwritten"
fi

# Credentials must be scrubbed from the diagnostics that get uploaded, and from
# the stderr echo that goes into the workflow log.
status="$(run_case test-secret FAKE_DSH_STDOUT='stdout sk-test and ghs_test' \
  FAKE_DSH_STDERR='stderr sk-test and ghs_test')"
assert_eq "run: a run whose output echoes secrets succeeds" 0 "$status"
log_dir="/tmp/dsh-execution-output-test-secret-1-attempt1"
assert_eq "run: the collected diagnostics no longer contain the gateway key" 0 \
  "$(grep -rl 'sk-test' "$log_dir" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "run: the collected diagnostics no longer contain the GitHub token" 0 \
  "$(grep -rl 'ghs_test' "$log_dir" 2>/dev/null | wc -l | tr -d ' ')"
assert_contains "run: the redaction marker is in stdout and stderr" \
  "$(cat "$log_dir/final.md" "$log_dir/stderr.log" 2>/dev/null)" "***REDACTED***"
assert_not_contains "run: the workflow log echo is redacted too" "$(cat "$tmpdir/out")" "sk-test"

# The isolated harness home must not survive the run.
assert_eq "run: DSH_HOME is removed on exit" 0 \
  "$(ls -d /tmp/dsh-home-test-pass-* 2>/dev/null | wc -l | tr -d ' ')"

big="$(printf 'x%.0s' $(seq 1 130000))"
status="$(run_case test-big REVIEW_PROMPT="$big")"
assert_eq "run: an oversized prompt fails" 1 "$status"
assert_contains "run: the oversized prompt explains the limit" "$(cat "$tmpdir/out")" "MAX_ARG_STRLEN"

# ==========================================================================
echo "== GitHub wiring =="
"$PY" - "$ROOT/action.yml" "$ROOT/.github/workflows/claude-auto-review.yml" <<'PY'
import re
import sys

action, workflow = sys.argv[1:3]

failures = 0


def fail(message):
    global failures
    failures += 1
    print("FAIL " + message)


def ok(message):
    print("ok   " + message)


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read().splitlines()


def input_block(path, name):
    """Raw text of one key inside the file's first `inputs:` section."""
    lines = read(path)
    start = next((i for i, l in enumerate(lines) if l.strip() == "inputs:"), None)
    if start is None:
        return None
    section_indent = len(lines[start]) - len(lines[start].lstrip())
    key_indent = None
    block = []
    for line in lines[start + 1:]:
        stripped = line.strip()
        indented = len(line) - len(line.lstrip())
        if stripped and indented <= section_indent:
            break
        if key_indent is None:
            if stripped.split(":")[0] == name:
                key_indent = indented
                block.append(line)
            continue
        if stripped and indented <= key_indent:
            break
        block.append(line)
    return "\n".join(block) if block else None


def steps(path, job_re=None):
    """[(line_no, name, body)] for every `- name:` step, optionally per job."""
    lines = read(path)
    jobs = []
    if job_re:
        starts = [i for i, l in enumerate(lines) if re.match(job_re, l)]
        for idx, start in enumerate(starts):
            end = starts[idx + 1] if idx + 1 < len(starts) else len(lines)
            jobs.append((lines[start].strip(), start, end))
    else:
        jobs.append(("<file>", 0, len(lines)))

    found = []
    for job, start, end in jobs:
        for i in range(start, end):
            m = re.match(r"^(\s*)- name:\s*(.*)$", lines[i])
            if not m:
                continue
            indent = len(m.group(1))
            body = []
            for j in range(i + 1, end):
                line = lines[j]
                if line.strip() and (len(line) - len(line.lstrip())) <= indent \
                        and line.lstrip().startswith("- "):
                    break
                body.append(line)
            found.append((job, i + 1, m.group(2).strip(), "\n".join(body)))
    return found


# --- inputs -----------------------------------------------------------------
engine = input_block(action, "engine")
if engine is None or "default: \"claude-code\"" not in engine:
    fail("action.yml: 'engine' must be declared with default \"claude-code\"")
else:
    ok("action.yml: 'engine' defaults to claude-code")

ver = input_block(action, "dsh_version")
if ver is None or 'default: ""' not in ver:
    fail("action.yml: 'dsh_version' must be declared with an empty default")
else:
    ok("action.yml: 'dsh_version' defaults to empty")

engine = input_block(workflow, "engine")
if engine is None or "vars.CODE_REVIEW_ENGINE" not in engine:
    fail("workflow: 'engine' must default to vars.CODE_REVIEW_ENGINE")
else:
    ok("workflow: 'engine' defaults to vars.CODE_REVIEW_ENGINE")

ver = input_block(workflow, "dsh_version")
if ver is None or 'default: ""' not in ver:
    fail("workflow: 'dsh_version' must be declared with an empty default")
else:
    ok("workflow: 'dsh_version' defaults to empty")

# --- engine gating ----------------------------------------------------------
CLAUDE_STEP_PREFIXES = ("Automatic PR Review", "Summarize reviews")
CLAUDE_CLI_STEPS = ("Detect Claude CLI path", "Install Claude CLI if missing")

for path in (action, workflow):
    for job, line, name, body in steps(path, r"^  [A-Za-z0-9_-]+:$" if path == workflow else None):
        if "anthropics/claude-code-action" in body:
            if "'claude-code'" not in body:
                fail(f"{path}:{line} [{job}] {name!r} is not gated on the claude-code engine")
        if "scripts/engines/dsh/run.sh" in body:
            if "'dsh'" not in body:
                fail(f"{path}:{line} [{job}] {name!r} is not gated on the dsh engine")
    ok(f"{path}: every engine-specific step is gated")

# --- step names must not collide with the token-limit test's expectations ---
for path in (action, workflow):
    for job, line, name, body in steps(path, r"^  [A-Za-z0-9_-]+:$" if path == workflow else None):
        if "scripts/engines/dsh/run.sh" not in body and "dsh" not in name.lower():
            continue
        if name.startswith(CLAUDE_STEP_PREFIXES):
            fail(f"{path}:{line} {name!r} starts with a Claude CLI step prefix")
        if name in CLAUDE_CLI_STEPS:
            fail(f"{path}:{line} {name!r} collides with a Claude CLI step name")
ok("step names do not collide with the token-limit test's expectations")

# --- detection/installation order and gating -------------------------------
SEQUENCE = [
    "Check Node.js for dsh",
    "Set up Node.js 24 for dsh",
    "Detect dsh CLI path",
    "Install dsh CLI if missing",
]

by_job = {}
for path in (action, workflow):
    job_re = r"^  [A-Za-z0-9_-]+:$" if path == workflow else None
    for job, line, name, body in steps(path, job_re):
        by_job.setdefault((path, job), []).append((line, name, body))

expected_runs = {action: 1, workflow: 2}
seen_runs = {action: 0, workflow: 0}

for (path, job), entries in by_job.items():
    names = [n for _, n, _ in entries]
    if "Run dsh review" not in names and "Run dsh summary" not in names:
        continue
    seen_runs[path] += 1
    positions = [names.index(n) if n in names else -1 for n in SEQUENCE]
    if -1 in positions:
        fail(f"{path} [{job}]: missing a dsh setup step (have {names})")
        continue
    if positions != sorted(positions):
        fail(f"{path} [{job}]: dsh setup steps are out of order (have {names})")
    else:
        ok(f"{path} [{job}]: dsh setup steps run in order")

    node_body = dict((n, b) for _, n, b in entries)["Check Node.js for dsh"]
    if "setup-node" in dict((n, b) for _, n, b in entries)["Set up Node.js 24 for dsh"]:
        setup_body = dict((n, b) for _, n, b in entries)["Set up Node.js 24 for dsh"]
        if "node_ok != 'true'" not in setup_body:
            fail(f"{path} [{job}]: setup-node is not gated on node_ok != 'true'")
        else:
            ok(f"{path} [{job}]: setup-node only runs when Node is missing")

    install_body = dict((n, b) for _, n, b in entries)["Install dsh CLI if missing"]
    if "dsh_path == ''" not in install_body:
        fail(f"{path} [{job}]: install is not gated on dsh_path == ''")
    else:
        ok(f"{path} [{job}]: install only runs when no dsh was detected")

for path, expected in expected_runs.items():
    if seen_runs[path] != expected:
        fail(f"{path}: expected {expected} dsh run step(s), found {seen_runs[path]}")
    else:
        ok(f"{path}: {expected} dsh run step(s)")

# --- reusable workflow must check out its own scripts ----------------------
for job, line, name, body in steps(workflow, r"^  [A-Za-z0-9_-]+:$"):
    if "Run dsh review" not in body and "Run dsh summary" not in body:
        continue
    job_steps = [b for j, _, _, b in steps(workflow, r"^  [A-Za-z0-9_-]+:$") if j == job]
    joined = "\n".join(job_steps)
    if "job.workflow_sha" not in joined or ".gatellm-code-review" not in joined:
        fail(f"workflow [{job}]: dsh steps must check out the action's own scripts at job.workflow_sha")
    elif "job.workflow_repository" not in joined:
        fail(f"workflow [{job}]: the scripts checkout does not set repository: job.workflow_repository"
             " (it would silently clone the caller's repository instead)")
    else:
        ok(f"workflow [{job}]: scripts are checked out from job.workflow_repository @ job.workflow_sha")

# --- dsh artifacts are scoped to this run ----------------------------------
# An unanchored glob can pick up another in-flight run's session transcripts on
# a shared self-hosted runner.
DSH_SCOPED_GLOB = "/tmp/dsh-execution-output-*-${{ github.run_id }}-*"
CLAUDE_SCOPED_GLOB = "/tmp/claude-execution-output-*-${{ github.run_id }}-*.json"
action_text = "\n".join(read(action))
workflow_text = "\n".join(read(workflow))
for label, text in (("action.yml", action_text), ("workflow", workflow_text)):
    if DSH_SCOPED_GLOB not in text:
        fail(f"{label}: the dsh artifact glob is not scoped to ${{ github.run_id }}")
    else:
        ok(f"{label}: the dsh artifact glob is scoped to the run")
    if CLAUDE_SCOPED_GLOB not in text:
        fail(f"{label}: the claude artifact glob is not scoped to ${{ github.run_id }}")
    else:
        ok(f"{label}: the claude artifact glob is scoped to the run")

# --- engine normalization must not drift between the two copies -------------
# action.yml resolves the engine in bash, the reusable workflow in JavaScript;
# both must accept exactly the same values (see the NOTE in each file).
m = re.search(r'case "\$ENGINE" in\s*\n\s*([A-Za-z0-9_|.-]+)\)', action_text)
action_values = set(m.group(1).split("|")) if m else None
m = re.search(r"\[([^\]]*)\]\.includes\(engine\)", workflow_text)
workflow_values = set(re.findall(r"'([^']+)'", m.group(1))) if m else None
if not action_values or not workflow_values:
    fail("engine allow-list could not be located in one of the two files")
elif action_values != workflow_values:
    fail(f"engine allow-lists drifted: action.yml={sorted(action_values)} "
         f"workflow={sorted(workflow_values)}")
else:
    ok(f"engine allow-lists match in both files: {sorted(action_values)}")

if "tr '[:upper:]' '[:lower:]'" not in action_text or ".toLowerCase()" not in workflow_text:
    fail("engine normalization no longer lowercases in both copies")
else:
    ok("engine normalization lowercases in both copies")
if "tr -d '[:space:]'" not in action_text or "replace(/\\s+/g, '')" not in workflow_text:
    fail("engine normalization no longer strips whitespace in both copies")
else:
    ok("engine normalization strips whitespace in both copies")

sys.exit(1 if failures else 0)
PY
if [ $? -ne 0 ]; then
  failures=$((failures + 1))
fi

# ==========================================================================
if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all dsh engine tests passed"

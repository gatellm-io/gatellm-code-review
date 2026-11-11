#!/usr/bin/env bash
# Install the dsh CLI when detect.sh found nothing usable.
#
# Order, mirroring the Claude CLI step:
#   1. `npm install -g @deepseek-ai/dsh@<version>` — the normal case
#   2. `npm install --prefix <tool cache>` — when the global prefix is not
#      writable, or the global install did not produce a usable binary
# The tool cache lives under RUNNER_TOOL_CACHE, so a self-hosted runner reuses
# it on the next run instead of reinstalling.
#
# Environment:
#   DSH_VERSION    exact version to install; empty means DEFAULT_VERSION
#   GITHUB_OUTPUT  receives dsh_path
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

VERSION="$(printf '%s' "${DSH_VERSION:-}" | tr -d '[:space:]')"
if [ -z "$VERSION" ]; then
  VERSION="$(default_dsh_version)"
  echo "dsh_version not set; installing the pinned default version $VERSION."
fi

if ! is_valid_version "$VERSION"; then
  echo "::error::Invalid dsh_version '$VERSION': expected a plain semantic version such as 0.2.2-rc.1."
  exit 1
fi

# Everything after this point uses the normalized form, which drops build
# metadata (semver: it does not take part in precedence). Detection compares on
# that same form, so `1.2.3+build` must install what it detects: passing the raw
# spelling to npm would ask the registry for a spec that detection then reports
# as a different version.
VERSION_KEY="$(normalize_version "$VERSION")"
[ -n "$VERSION_KEY" ] || {
  echo "::error::Invalid dsh_version '$VERSION': expected a plain semantic version such as 0.2.2-rc.1."
  exit 1
}

SPEC="@deepseek-ai/dsh@$VERSION_KEY"

fail_install() {
  echo "::error::Failed to locate dsh CLI after install (requested $VERSION)."
  exit 1
}

# Both install branches need npm (dsh is an npm package). Say that instead of
# falling through to a tool-cache failure that names the wrong cause.
if ! command -v npm >/dev/null 2>&1; then
  echo "::error::npm is required to install the dsh CLI but was not found on PATH. Install Node.js/npm, or preinstall dsh and re-run (see README, dsh CLI install)."
  exit 1
fi

# 1) Global install.
echo "Trying npm install -g $SPEC ..."
if npm install -g "$SPEC"; then
  if FOUND="$(find_dsh "$VERSION")"; then
    echo "dsh_path=$FOUND" >> "$GITHUB_OUTPUT"
    echo "Installed dsh CLI via npm -g at: $FOUND (version $(dsh_version_of "$FOUND"))"
    exit 0
  fi
  echo "::warning::npm -g succeeded but no usable dsh binary was found; falling back to the action tool cache."
else
  echo "::warning::npm install -g failed (often EACCES on the global prefix); falling back to the action tool cache."
fi

# 2) Private prefix under the tool cache.
PREFIX="$(dsh_tool_cache)/$VERSION_KEY"
mkdir -p "$PREFIX" || fail_install
echo "Trying npm install --prefix $PREFIX $SPEC ..."
if ! npm install --prefix "$PREFIX" "$SPEC"; then
  echo "::error::npm install into the action tool cache failed."
  fail_install
fi

BIN="$PREFIX/node_modules/.bin/dsh"
[ -x "$BIN" ] || fail_install
VER="$(dsh_version_of "$BIN")"
[ -n "$VER" ] || fail_install
if [ "$VER" != "$VERSION_KEY" ]; then
  echo "::error::Installed dsh reports version $VER, expected $VERSION_KEY."
  fail_install
fi

echo "dsh_path=$BIN" >> "$GITHUB_OUTPUT"
echo "Installed dsh CLI at: $BIN (version $VER)"

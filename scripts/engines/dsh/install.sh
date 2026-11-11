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

SPEC="@deepseek-ai/dsh@$VERSION"

fail_install() {
  echo "::error::Failed to locate dsh CLI after install (requested $VERSION)."
  exit 1
}

# 1) Global install.
if command -v npm >/dev/null 2>&1; then
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
else
  echo "::warning::npm not found on PATH; cannot install dsh without npm."
fi

# 2) Private prefix under the tool cache.
PREFIX="$(dsh_tool_cache)/$VERSION"
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
if [ "$VER" != "$VERSION" ]; then
  echo "::error::Installed dsh reports version $VER, expected $VERSION."
  fail_install
fi

echo "dsh_path=$BIN" >> "$GITHUB_OUTPUT"
echo "Installed dsh CLI at: $BIN (version $VER)"

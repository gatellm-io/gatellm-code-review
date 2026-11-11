#!/usr/bin/env bash
# Look for a dsh CLI that is already installed on the runner.
#
# Mirrors the "Detect Claude CLI path" step: self-hosted runners usually have
# the CLI preinstalled, and reinstalling it on every run is slow.
#
# Environment:
#   DSH_VERSION    optional exact version the caller wants; empty accepts any
#   GITHUB_OUTPUT  receives dsh_path (empty when nothing usable was found)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

EXPECTED="$(printf '%s' "${DSH_VERSION:-}" | tr -d '[:space:]')"

if [ -n "$EXPECTED" ] && ! is_valid_version "$EXPECTED"; then
  echo "::error::Invalid dsh_version '$EXPECTED': expected a plain semantic version such as 0.2.2-rc.1."
  exit 1
fi

if FOUND="$(find_dsh "$EXPECTED")"; then
  echo "dsh_path=$FOUND" >> "$GITHUB_OUTPUT"
  echo "dsh CLI found at: $FOUND (version $(dsh_version_of "$FOUND"))"
else
  if [ -n "$EXPECTED" ]; then
    echo "::warning::No dsh CLI matching version $EXPECTED found in PATH, common locations, or the action tool cache; will attempt install."
  else
    echo "::warning::dsh CLI not found in PATH, common locations, or the action tool cache; will attempt install."
  fi
  echo "dsh_path=" >> "$GITHUB_OUTPUT"
fi

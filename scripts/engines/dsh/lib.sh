#!/usr/bin/env bash
# Shared helpers for the dsh engine scripts. Sourced, never executed directly.
#
# Every function here is POSIX-ish bash and safe on the macOS /bin/bash 3.2 that
# self-hosted runners use, so no associative arrays and no `mapfile`.

# The version grammar shared by normalize_version and is_valid_version:
#   MAJOR.MINOR.PATCH[-PRERELEASE][+BUILDMETA]
# Both accept build metadata. Normalization then *drops* it, because semver
# defines build metadata as not taking part in version precedence: for matching
# purposes `1.2.3+build` and `1.2.3` are the same version, and comparing raw
# strings would make a preinstalled `1.2.3+build` miss an exact `1.2.3` request
# (and vice versa). So a version that validates always normalizes to the same
# core version with or without its build suffix.

# Extract the first semantic version from arbitrary `--version` output.
# Prints nothing when the input contains no version.
normalize_version() {
  # Takes the raw string as an argument (not on stdin) so callers stay
  # explicit about what they are parsing.
  local raw="${1:-}"
  [ -n "$raw" ] || return 0
  printf '%s\n' "$raw" \
    | tr -d '\r' \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?' \
    | head -n 1
}

# Run `<bin> --version` and return the normalized version (empty on failure).
dsh_version_of() {
  local raw
  [ -n "${1:-}" ] || return 0
  raw="$("$1" --version 2>/dev/null)"
  normalize_version "$raw"
}

# Root of the action's private dsh install cache, e.g.
#   $RUNNER_TOOL_CACHE/gatellm-code-review/dsh
# Falls back to RUNNER_TEMP and finally /tmp so the scripts also work locally.
dsh_tool_cache() {
  local base="${RUNNER_TOOL_CACHE:-}"
  [ -n "$base" ] || base="${RUNNER_TEMP:-}"
  [ -n "$base" ] || base=/tmp
  printf '%s/gatellm-code-review/dsh' "$base"
}

# Print every plausible dsh executable, one per line, in preference order.
# Candidates that do not exist are still printed; callers test -x themselves so
# `set -o pipefail` and word splitting never turn a missing glob into an error.
dsh_candidates() {
  local dir
  command -v dsh 2>/dev/null || true
  printf '%s\n' /opt/homebrew/bin/dsh /usr/local/bin/dsh
  printf '%s\n' "$HOME/.local/bin/dsh" "$HOME/.npm-global/bin/dsh"
  for dir in "$HOME"/.nvm/versions/node/*/bin; do
    [ -d "$dir" ] && printf '%s\n' "$dir/dsh"
  done
  for dir in "$(dsh_tool_cache)"/*/node_modules/.bin; do
    [ -d "$dir" ] && printf '%s\n' "$dir/dsh"
  done
  return 0
}

# find_dsh [expected-version]
#
# Prints the path of the first candidate that runs and reports a usable
# version. With a non-empty expected version the candidate must match it
# exactly. Diagnostics go to stderr so callers can capture the path cleanly.
# Returns 1 when nothing usable is found.
find_dsh() {
  local expected="${1:-}"
  local candidate ver
  if [ -n "$expected" ]; then
    # Compare on the normalized form: build metadata does not affect version
    # precedence, so `1.2.3+build` and `1.2.3` are the same version.
    expected="$(normalize_version "$expected")"
    if [ -z "$expected" ]; then
      echo "::warning::Could not parse the expected dsh version; no candidate can match it." >&2
      return 1
    fi
  fi
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    [ -x "$candidate" ] || continue
    ver="$(dsh_version_of "$candidate")"
    if [ -z "$ver" ]; then
      echo "::warning::Found '$candidate' but 'dsh --version' reported no version; skipping it." >&2
      continue
    fi
    if [ -n "$expected" ] && [ "$ver" != "$expected" ]; then
      echo "::notice::'$candidate' reports version $ver, but dsh_version is '$expected'; ignoring it." >&2
      continue
    fi
    printf '%s\n' "$candidate"
    return 0
  done < <(dsh_candidates)
  return 1
}

# Reject anything that is not a plain semver, so a caller-supplied value can
# never turn into an arbitrary npm spec (or a shell word). Accepts build
# metadata (`1.2.3+build`); normalize_version then drops it for comparison.
is_valid_version() {
  case "$1" in
    '' | *[!0-9A-Za-z.+-]*) return 1 ;;
  esac
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?([+][0-9A-Za-z.]+)?$ ]]
}

# Read the pinned default version shipped next to this file.
default_dsh_version() {
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  tr -d '[:space:]' < "$dir/DEFAULT_VERSION"
}

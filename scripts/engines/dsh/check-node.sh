#!/usr/bin/env bash
# Decide whether the runner already has a Node.js that dsh can run on.
#
# dsh requires Node >= 24.9.0 (declared by @deepseek-ai/dsh's engines field).
# When a usable Node exists anywhere we use it and skip actions/setup-node;
# otherwise the workflow installs Node 24.
#
# Outputs `node_ok=true|false` on GITHUB_OUTPUT. When a usable Node is found
# outside PATH, its directory is appended to GITHUB_PATH so later steps see it.
#
# Deliberately builtin-only (no grep/sed/tr): the regression test runs this
# with an empty PATH to prove the "no node anywhere" branch.
set -uo pipefail

REQUIRED="${DSH_NODE_MIN_VERSION:-24.9.0}"

# Extra directories to probe when `node` is not on PATH. Overridable so tests
# can point the search at a scratch directory.
SEARCH_DIRS="${DSH_NODE_SEARCH_DIRS:-/opt/homebrew/bin /usr/local/bin $HOME/.nvm/versions/node/*/bin}"

parse_version() {
  local v="$1"
  v="${v#v}"
  v="${v%%-*}"
  v="${v%%+*}"
  printf '%s' "$v"
}

# version_ge <actual> <required>; both are plain x.y.z strings.
version_ge() {
  local a1=0 a2=0 a3=0 r1=0 r2=0 r3=0 rest
  IFS=. read -r a1 a2 a3 rest <<< "$1"
  IFS=. read -r r1 r2 r3 rest <<< "$2"
  local n
  for n in "$a1" "$a2" "$a3" "$r1" "$r2" "$r3"; do
    case "$n" in
      '' | *[!0-9]*) return 1 ;;
    esac
  done
  [ "$a1" -gt "$r1" ] && return 0
  [ "$a1" -lt "$r1" ] && return 1
  [ "$a2" -gt "$r2" ] && return 0
  [ "$a2" -lt "$r2" ] && return 1
  [ "$a3" -ge "$r3" ] && return 0
  return 1
}

# True when <path> is an executable node new enough for dsh.
node_usable() {
  local candidate="$1" ver
  [ -n "$candidate" ] || return 1
  [ -x "$candidate" ] || return 1
  ver="$(parse_version "$("$candidate" --version 2>/dev/null || true)")"
  [ -n "$ver" ] || return 1
  case "$ver" in
    *[!0-9.]*) return 1 ;;
  esac
  version_ge "$ver" "$REQUIRED"
}

# Prints the absolute path of a usable node, or nothing.
find_node() {
  local candidate dir
  candidate="$(command -v node 2>/dev/null || true)"
  if node_usable "$candidate"; then
    printf '%s\n' "$candidate"
    return 0
  fi
  # SEARCH_DIRS entries are directories (Homebrew prefixes, nvm version bins).
  for dir in $SEARCH_DIRS; do
    [ -n "$dir" ] || continue
    candidate="$dir/node"
    if node_usable "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

if NODE_PATH="$(find_node)"; then
  # Parameter expansion instead of `dirname`: this script must run with no PATH.
  NODE_DIR="${NODE_PATH%/*}"
  [ -n "$NODE_DIR" ] || NODE_DIR=.
  case ":$PATH:" in
    *":$NODE_DIR:"*) ;;
    *)
      if [ -n "${GITHUB_PATH:-}" ]; then
        printf '%s\n' "$NODE_DIR" >> "$GITHUB_PATH"
        echo "Added $NODE_DIR to PATH for later steps."
      fi
      ;;
  esac
  echo "Using Node $("$NODE_PATH" --version 2>/dev/null) at $NODE_PATH (dsh requires >= $REQUIRED)"
  echo "node_ok=true" >> "$GITHUB_OUTPUT"
  exit 0
fi

echo "No Node >= $REQUIRED found on this runner; actions/setup-node will install Node 24."
echo "node_ok=false" >> "$GITHUB_OUTPUT"

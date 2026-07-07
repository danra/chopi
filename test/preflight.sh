#!/usr/bin/env bash
#
# test/preflight.sh -- unit tests for preflight checks
#
# Covers the security-critical logic that decides whether a run is even allowed to start:
#
#   * is_path_within / the workspace-overlap predicate -- if this loosens, a sandboxed
#     command could be handed read/write to its own sandboxing policy.
#   * preflight's observable behavior: the chopi-dir overlap refusal (and its
#     CHOPI_ALLOW_SELF downgrade), and the --config-inside-the-workspace refusal.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo/.internal/util.sh"
. "$repo/test/lib.sh"

header "test/preflight.sh -- unit tests preflight checks"

# Exported so the scripts under test leave their temporaries here too.
TMPDIR="$(mktemp -d)"; export TMPDIR
trap 'rm -rf "$TMPDIR"' EXIT


# ---------------------------------------------------------------------------
echo "is_path_within (workspace-overlap predicate)"
# ---------------------------------------------------------------------------
. "$repo/.internal/preflight.sh"
set +euo pipefail

assert_within() {
    arity 3
    local inner="$1" outer="$2" desc="$3"
    if is_path_within "$inner" "$outer"; then
        ok "$desc: is_path_within '$inner' '$outer'"
    else
        bad "$desc: is_path_within '$inner' '$outer'"
    fi
}

assert_not_within() {
    arity 3
    local inner="$1" outer="$2" desc="$3"
    if is_path_within "$inner" "$outer"; then
        bad "$desc: is_path_within '$inner' '$outer'"
    else
        ok "$desc: is_path_within '$inner' '$outer'"
    fi
}

assert_within     /a/b       /a      "one level nested is within"
assert_within     /a/b/c/d   /a      "deeply nested is within"
assert_within     /a         /a      "identical paths overlap"
assert_within     /a/b       /       "everything is within the root"
assert_within     /          /       "root is within root"
assert_not_within /ab        /a      "sibling sharing a name prefix is NOT within"
assert_not_within /a/bc      /a/b    "sibling one level down is NOT within"
assert_not_within /foobar    /foo    "prefix that is not a path boundary is NOT within"
assert_not_within /a         /a/b    "outer deeper than inner is NOT within"

assert_within     "/a b/c"   "/a b"  "paths with spaces nest correctly"
# Verify we keep literal "*" in path names properly quoted, not treat it as a wildcard
assert_within     "/a*b/c"   "/a*b"  "literal '*' in outer matches itself"
assert_not_within "/axxb/c"  "/a*b"  "literal '*' in outer does NOT glob-match other chars"
assert_not_within "/a*b/c"  "/axxb"  "literal '*' in inner does NOT glob-match other chars"


# ---------------------------------------------------------------------------
echo "preflight chopi/workspace directories overlap test"
# ---------------------------------------------------------------------------
out="$(cd "$repo"        && env -u CHOPI_ALLOW_SELF ./.internal/preflight.sh 2>&1)"; st=$?
assert_contains "$out" "overlaps chopi's own directory" "refuses when workspace IS chopi's dir"
if [ "$st" -ne 0 ]; then ok "  -> and exits non-zero"; else bad "  -> should exit non-zero (got $st)"; fi

out="$(cd "$repo/config" && "$repo/.internal/preflight.sh" 2>&1)"
assert_contains "$out" "overlaps chopi's own directory" "refuses when workspace is INSIDE chopi's dir"

out="$(cd "$(dirname "$repo")" && "$repo/.internal/preflight.sh" 2>&1)"
assert_contains "$out" "overlaps chopi's own directory" "refuses when workspace CONTAINS chopi's dir"

out="$(cd "$repo" && CHOPI_ALLOW_SELF=1 ./.internal/preflight.sh 2>&1)"
assert_contains "$out" "warning:"          "CHOPI_ALLOW_SELF downgrades overlap to a warning"
assert_contains "$out" "continuing anyway" "CHOPI_ALLOW_SELF proceeds past the overlap check"

tmp="$(mktemp -d)"
out="$(cd "$tmp" && "$repo/.internal/preflight.sh" 2>&1)"
assert_not_contains "$out" "overlaps chopi's own directory" "non-overlapping workspace clears the overlap check"


# ---------------------------------------------------------------------------
echo "preflight --config (custom sandbox config must live outside the workspace)"
# ---------------------------------------------------------------------------
work="$(mktemp -d)"
cfg_inside="$work/sandbox.sh"; : > "$cfg_inside"

out="$(cd "$work" && env -u CHOPI_ALLOW_SELF "$repo/.internal/preflight.sh" --config "$cfg_inside" 2>&1)"; st=$?
assert_contains "$out" "is inside the workspace" "refuses a --config placed inside the workspace"
if [ "$st" -ne 0 ]; then ok "  -> and exits non-zero"; else bad "  -> should exit non-zero (got $st)"; fi

out="$(cd "$work" && "$repo/.internal/preflight.sh" --config sandbox.sh 2>&1)"
assert_contains "$out" "is inside the workspace" "refuses a relative --config that lands inside the workspace"

mkdir -p "$work/sub"; : > "$work/sub/cfg.sh"
out="$(cd "$work" && "$repo/.internal/preflight.sh" --config "$work/sub/cfg.sh" 2>&1)"
assert_contains "$out" "is inside the workspace" "refuses a --config nested in a workspace subdir"

out="$(cd "$work" && CHOPI_ALLOW_SELF=1 "$repo/.internal/preflight.sh" --config "$cfg_inside" 2>&1)"
assert_contains "$out" "warning:"          "CHOPI_ALLOW_SELF downgrades the --config overlap to a warning"
assert_contains "$out" "continuing anyway" "CHOPI_ALLOW_SELF proceeds past the --config overlap check"

cfg_outside="$(mktemp)"
out="$(cd "$work" && "$repo/.internal/preflight.sh" --config "$cfg_outside" 2>&1)"
assert_not_contains "$out" "is inside the workspace" "a --config outside the workspace clears the overlap check"

out="$(cd "$work" && "$repo/.internal/preflight.sh" --config /no/such/dir/cfg.sh 2>&1)"; st=$?
assert_contains "$out" "cannot resolve --config" "a nonexistent --config path fails fast"
if [ "$st" -ne 0 ]; then ok "  -> and exits non-zero"; else bad "  -> should exit non-zero (got $st)"; fi

# Symlink consistency: enter the workspace through a symlink but name --config by its REAL
# path. Logical-only handling would miss the overlap (the two spellings share no prefix);
# canonicalizing both sides (workspace via `pwd -P`, config via `realpath`) catches it.
real="$(mktemp -d)"; : > "$real/cfg.sh"
linkdir="$(mktemp -d)"; ln -s "$real" "$linkdir/ws"
out="$(cd "$linkdir/ws" && "$repo/.internal/preflight.sh" --config "$real/cfg.sh" 2>&1)"
assert_contains "$out" "is inside the workspace" "config under a symlinked workspace is caught via its real path"

out="$(cd "$work" && "$repo/.internal/preflight.sh" --config 2>&1)"; st=$?
assert_contains "$out" "--config requires a file path" "--config with no argument is rejected"
if [ "$st" -ne 0 ]; then ok "  -> and exits non-zero"; else bad "  -> should exit non-zero (got $st)"; fi


# ---------------------------------------------------------------------------
summary

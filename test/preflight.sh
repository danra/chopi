#!/usr/bin/env bash
#
# test/preflight.sh -- unit tests for preflight checks
#
# Covers the security-critical logic that decides whether a run is even allowed to start:
#
#   * is_path_within / the workspace-overlap predicate -- if this loosens, a sandboxed
#     command could be handed read/write to its own sandboxing policy.
#   * preflight_initial -- the chopi-dir overlap refusal (and its CHOPI_ALLOW_SELF
#     downgrade), and refusing a run when the GitHub relay's port is dead.
#   * preflight_config_placement -- refusing a custom --config that lives inside the workspace.
#   * rule / the Seatbelt-rule emitter -- its empty-PATH refusal keeps an
#     accidentally-empty variable from becoming a silently misapplied rule.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo/.internal/util.sh"
. "$repo/.internal/preflight.sh"
. "$repo/test/lib.sh"

header "test/preflight.sh -- unit tests preflight checks"

# Exported so the scripts under test leave their temporaries here too.
TMPDIR="$(mktemp -d)"; export TMPDIR
trap 'rm -rf "$TMPDIR"' EXIT


# ---------------------------------------------------------------------------
echo "is_path_within (workspace-overlap predicate)"
# ---------------------------------------------------------------------------
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

# An empty argument is a caller bug, not a boolean result: an empty outer would otherwise
# match every absolute path.
( is_path_within ""   "/a" ) 2>/dev/null; st=$?
if [ "$st" -eq 2 ]; then ok "an empty inner path is a hard error (exit 2)"; else bad "an empty inner path should be a hard error (got $st)"; fi
( is_path_within "/a" ""   ) 2>/dev/null; st=$?
if [ "$st" -eq 2 ]; then ok "an empty outer path is a hard error (exit 2)"; else bad "an empty outer path should be a hard error (got $st)"; fi


# ---------------------------------------------------------------------------
echo "preflight_initial (chopi/workspace directory overlap)"
# ---------------------------------------------------------------------------
out="$( cd "$repo" && { unset CHOPI_ALLOW_SELF; preflight_initial; } 2>&1 )"; st=$?
assert_contains "$out" "overlaps chopi's own directory" "refuses when workspace IS chopi's dir"
if [ "$st" -ne 0 ]; then ok "  -> and returns non-zero"; else bad "  -> should return non-zero (got $st)"; fi

out="$( cd "$repo/config" && preflight_initial 2>&1 )"
assert_contains "$out" "overlaps chopi's own directory" "refuses when workspace is INSIDE chopi's dir"

out="$( cd "$(dirname "$repo")" && preflight_initial 2>&1 )"
assert_contains "$out" "overlaps chopi's own directory" "refuses when workspace CONTAINS chopi's dir"

out="$( cd "$repo" && { CHOPI_ALLOW_SELF=1; preflight_initial; } 2>&1 )"
assert_contains "$out" "warning:"          "CHOPI_ALLOW_SELF downgrades overlap to a warning"
assert_contains "$out" "continuing anyway" "CHOPI_ALLOW_SELF proceeds past the overlap check"

tmp="$(mktemp -d)"
out="$( cd "$tmp" && preflight_initial 2>&1 )"
assert_not_contains "$out" "overlaps chopi's own directory" "non-overlapping workspace clears the overlap check"


# ---------------------------------------------------------------------------
echo "preflight_config_placement (custom --config must live outside the workspace)"
# ---------------------------------------------------------------------------
work="$(mktemp -d)"
cfg_inside="$work/sandbox.sh"; : > "$cfg_inside"

out="$( cd "$work" && { unset CHOPI_ALLOW_SELF; preflight_config_placement "$cfg_inside" "$work"; } 2>&1 )"; st=$?
assert_contains "$out" "is inside the workspace" "refuses a --config inside the workspace"
if [ "$st" -ne 0 ]; then ok "  -> and returns non-zero"; else bad "  -> should return non-zero (got $st)"; fi

# A relative --config resolves against the current dir (the invocation dir), so entering
# $work and naming it 'sandbox.sh' still lands inside the workspace.
out="$( cd "$work" && preflight_config_placement sandbox.sh "$work" 2>&1 )"
assert_contains "$out" "is inside the workspace" "refuses a relative --config that lands inside the workspace"

mkdir -p "$work/sub"; : > "$work/sub/cfg.sh"
out="$( cd "$work" && preflight_config_placement "$work/sub/cfg.sh" "$work" 2>&1 )"
assert_contains "$out" "is inside the workspace" "refuses a --config nested in a workspace subdir"

out="$( cd "$work" && { CHOPI_ALLOW_SELF=1; preflight_config_placement "$cfg_inside" "$work"; } 2>&1 )"
assert_contains "$out" "warning:"          "CHOPI_ALLOW_SELF downgrades the --config overlap to a warning"
assert_contains "$out" "continuing anyway" "CHOPI_ALLOW_SELF proceeds past the --config overlap check"

cfg_outside="$(mktemp)"
out="$( cd "$work" && preflight_config_placement "$cfg_outside" "$work" 2>&1 )"; st=$?
assert_not_contains "$out" "is inside the workspace" "a --config outside the workspace clears the overlap check"
if [ "$st" -eq 0 ]; then ok "  -> and returns zero"; else bad "  -> should return zero (got $st)"; fi

# Symlink consistency: name the workspace through a symlink but the --config by its REAL path.
# Logical-only handling would miss the overlap (the two spellings share no prefix);
# canonicalizing both sides (via `realpath`) catches it.
real="$(mktemp -d)"; : > "$real/cfg.sh"
linkdir="$(mktemp -d)"; ln -s "$real" "$linkdir/ws"
out="$(preflight_config_placement "$real/cfg.sh" "$linkdir/ws" 2>&1)"
assert_contains "$out" "is inside the workspace" "config under a symlinked workspace is caught via its real path"


# ---------------------------------------------------------------------------
echo "preflight_config_placement checks the workspace, not the invocation dir"
# ---------------------------------------------------------------------------
parent="$(mktemp -d)"
mkdir -p "$parent/wt"                                   # the "worktree" the command runs in
repo_cfg="$parent/repo-cfg.sh"; : > "$repo_cfg"         # in the parent, OUTSIDE wt

# Verify no false positives
out="$( cd "$parent" && preflight_config_placement "$repo_cfg" "$parent/wt" 2>&1 )"; st=$?
assert_not_contains "$out" "is inside the workspace" "a config under the invocation dir but outside the workspace is allowed"
if [ "$st" -eq 0 ]; then ok "  -> and returns zero"; else bad "  -> should return zero (got $st)"; fi

# Verify no false negatives
inside_wt_cfg="$parent/wt/cfg.sh"; : > "$inside_wt_cfg"
sibling="$(mktemp -d)"
out="$( cd "$sibling" && preflight_config_placement "$inside_wt_cfg" "$parent/wt" 2>&1 )"; st=$?
assert_contains "$out" "is inside the workspace" "a config inside the workspace is refused even when invoked from elsewhere"
if [ "$st" -ne 0 ]; then ok "  -> and returns non-zero"; else bad "  -> should return non-zero (got $st)"; fi


# ---------------------------------------------------------------------------
echo "preflight_config_placement argument handling"
# ---------------------------------------------------------------------------
out="$( cd "$work" && preflight_config_placement /no/such/dir/cfg.sh "$work" 2>&1 )"; st=$?
assert_contains "$out" "cannot resolve --config" "a nonexistent --config path fails fast"
if [ "$st" -ne 0 ]; then ok "  -> and returns non-zero"; else bad "  -> should return non-zero (got $st)"; fi

out="$(preflight_config_placement "$cfg_outside" /no/such/run/dir 2>&1)"; st=$?
assert_contains "$out" "cannot resolve run dir" "a nonexistent run dir fails fast"
if [ "$st" -ne 0 ]; then ok "  -> and returns non-zero"; else bad "  -> should return non-zero (got $st)"; fi

( preflight_config_placement "$cfg_outside" ) 2>/dev/null; st=$?
if [ "$st" -eq 2 ]; then ok "a wrong number of arguments is a hard error (exit 2)"; else bad "wrong arity should be a hard error (got $st)"; fi


# ---------------------------------------------------------------------------
echo "preflight_initial (the GitHub relay must be live for every run)"
# ---------------------------------------------------------------------------
# Stub `nc` -- inherited into the command-substitution subshell -- so the check is hermetic: it
# must not depend on a real chopi-proxy being up, nor probe the live ports. The stub echoes its
# args so we can assert GITHUB_RELAY_PORT (the relay) is probed, not just PROXY_PORT
# (smokescreen); it reports the proxy port up, and the relay port up (RC 0) or down (RC != 0).
# relay_probe RC runs preflight_initial under the stub, from a non-overlapping dir.
relay_probe() {
    arity 1
    local rc="$1"
    # shellcheck disable=SC2329  # nc stub invoked indirectly
    ( cd "$tmp" && { nc() { echo "nc $*"; [ "$3" = "$PROXY_PORT" ] || return "$rc"; }; preflight_initial; } 2>&1 )
}

out="$(relay_probe 1)"; st=$?
assert_contains "$out" "nc -z 127.0.0.1 $GITHUB_RELAY_PORT" "probes the relay port (GITHUB_RELAY_PORT), not just the smokescreen port"
assert_contains "$out" "no GitHub relay"         "a dead relay is refused with a clear message"
if [ "$st" -ne 0 ]; then ok "  -> and returns non-zero"; else bad "  -> should return non-zero (got $st)"; fi

# The check cleared is all this case pins: past it, preflight_initial goes on to probe
# host state (the safehouse CLI) that a unit test doesn't control.
out="$(relay_probe 0)"
assert_not_contains "$out" "no GitHub relay" "a live relay clears the check"


# ---------------------------------------------------------------------------
echo "rule (the Seatbelt-rule emitter)"
# ---------------------------------------------------------------------------
out="$(rule 'allow file-read*' subpath '/a b/c')"
assert_eq "$out" '(allow file-read* (subpath "/a b/c"))' "emits the (ACTION (MATCHER \"PATH\")) form"

# An empty PATH is a caller bug, not a rule (it would silently misapply). The guard
# hard-exits, so probe it in a subshell.
( rule 'deny file-write*' subpath '' ) >/dev/null 2>&1; st=$?
if [ "$st" -eq 2 ]; then ok "an empty PATH is a hard error (exit 2)"; else bad "an empty PATH should be a hard error (got $st)"; fi


# ---------------------------------------------------------------------------
summary

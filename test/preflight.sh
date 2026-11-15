#!/usr/bin/env bash
#
# test/preflight.sh -- unit tests for preflight checks
#
# Covers the security-critical logic that decides whether a run is even allowed to start:
#
#   * is_path_within / the workspace-overlap predicate -- if this loosens, a sandboxed
#     command could be handed read/write to its own sandboxing policy.
#   * preflight_initial -- the chopi-dir overlap refusal (and its CHOPI_ALLOW_SELF
#     downgrade).
#   * preflight_config_placement -- refusing a custom --config that lives inside the workspace.
#   * resolve_proxy_config -- resolving the proxy's config to the real paths that
#     write_proxy_config_profile keeps the sandboxed command from writing.
#   * preflight_proxy_config_links -- refusing a proxy config file with other hard links, which the
#     sandboxed command may write through.
#   * rule / the Seatbelt-rule emitter -- its empty-PATH refusal keeps an
#     accidentally-empty variable from becoming a silently misapplied rule.
#   * ancestry_rules -- where its walk up a path's ancestry starts and stops.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Exported so the scripts under test leave their temporaries here too.
TMPDIR="$(mktemp -d)"; export TMPDIR
trap 'rm -rf "$TMPDIR"' EXIT
# A run dir of the test's own, not the user's: util.sh derives PROXY_RUN_DIR from it.
CHOPI_RUN_DIR="$TMPDIR/chopi"

. "$repo/.internal/util.sh"
. "$repo/.internal/preflight.sh"
. "$repo/test/lib.sh"

header "test/preflight.sh -- unit tests preflight checks"


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
assert_eq "$st" 2 "an empty inner path is a hard error (exit 2)"
( is_path_within "/a" ""   ) 2>/dev/null; st=$?
assert_eq "$st" 2 "an empty outer path is a hard error (exit 2)"


# ---------------------------------------------------------------------------
echo "overlapping_dirs (the same question in both directions)"
# ---------------------------------------------------------------------------
overlapping_dirs /a/b /a; st=$?
assert_zero "$st" "a directory inside the other overlaps it"
overlapping_dirs /a /a/b; st=$?
assert_zero "$st" "  -> and the same pair asked the other way round"
overlapping_dirs /a /a; st=$?
assert_zero "$st" "a directory overlaps itself"
overlapping_dirs /a/b /a/c; st=$?
assert_nonzero "$st" "siblings do not overlap"


# ---------------------------------------------------------------------------
echo "preflight_initial (chopi/workspace directory overlap)"
# ---------------------------------------------------------------------------
out="$( cd "$repo" && { unset CHOPI_ALLOW_SELF; preflight_initial; } 2>&1 )"; st=$?
assert_contains "$out" "overlaps chopi's own directory" "refuses when workspace IS chopi's dir"
assert_nonzero "$st" "  -> and returns non-zero"

out="$( cd "$repo/config" && preflight_initial 2>&1 )"
assert_contains "$out" "overlaps chopi's own directory" "refuses when workspace is INSIDE chopi's dir"

out="$( cd "$(dirname "$repo")" && preflight_initial 2>&1 )"
assert_contains "$out" "overlaps chopi's own directory" "refuses when workspace CONTAINS chopi's dir"

out="$( cd "$repo" && { CHOPI_ALLOW_SELF=1; preflight_initial; } 2>&1 )"
assert_contains "$out" "warning:"          "CHOPI_ALLOW_SELF downgrades overlap to a warning"
assert_contains "$out" "continuing anyway" "CHOPI_ALLOW_SELF proceeds past the overlap check"
# stdout belongs to the sandboxed command (`chopi cmd > out`): the warning must not touch it. The
# trailing marker keeps the command substitution from stripping a stray newline.
out="$( cd "$repo" && { CHOPI_ALLOW_SELF=1; preflight_initial; } 2>/dev/null; echo end )"
assert_eq "$out" "end" "  -> and writes nothing to stdout"

tmp="$(mktemp -d)"
out="$( cd "$tmp" && preflight_initial 2>&1 )"
assert_not_contains "$out" "overlaps chopi's own directory" "non-overlapping workspace clears the overlap check"
assert_not_contains "$out" "overlaps the proxy's run directory" "  -> and the run-dir overlap check"


# ---------------------------------------------------------------------------
echo "preflight_initial (run dir/workspace overlap)"
# ---------------------------------------------------------------------------
# The run dir holds each session's proxy dir, whose ports file aims that session's holes and
# HTTP_PROXY: a workspace reaching it would let the sandboxed command aim another session's.
# CHOPI_ALLOW_SELF, for working on chopi itself, has no business relaxing that. The run dir is the
# run/ chopi keeps inside CHOPI_RUN_DIR: the rest of CHOPI_RUN_DIR, a shared dir such as /tmp, say,
# is no concern.
# preflight_under DIR ENV... -- preflight_initial run from DIR, with util.sh sourced under ENV.
preflight_under() {
    local dir="$1"; shift
    # shellcheck disable=SC2016  # expands in the child bash, against the environment under test
    (cd "$dir" && env "$@" bash -c \
        '. "$1/.internal/util.sh"; . "$1/.internal/preflight.sh"; preflight_initial' _ "$repo" 2>&1)
}
work="$(mktemp -d)"; mkdir -p "$work/run/sub" "$work/sub"
out="$(preflight_under "$work" CHOPI_RUN_DIR="$work")"; st=$?
assert_contains "$out" "overlaps the proxy's run directory" "refuses when workspace CONTAINS the run dir"
assert_nonzero "$st" "  -> and returns non-zero"
out="$(preflight_under "$work/run/sub" CHOPI_RUN_DIR="$work")"
assert_contains "$out" "overlaps the proxy's run directory" "refuses when workspace is INSIDE the run dir"
out="$(preflight_under "$work/sub" CHOPI_RUN_DIR="$work")"
assert_not_contains "$out" "overlaps the proxy's run directory" \
    "a workspace beside the run dir, inside CHOPI_RUN_DIR, clears the check"
out="$(preflight_under "$work" CHOPI_ALLOW_SELF=1 CHOPI_RUN_DIR="$work")"; st=$?
assert_contains "$out" "error: workspace" "CHOPI_ALLOW_SELF does not downgrade the run-dir overlap"
assert_nonzero "$st" "  -> and still returns non-zero"

# ---------------------------------------------------------------------------
echo "preflight_initial (proxy config/workspace overlap)"
# ---------------------------------------------------------------------------
# The proxy's config sets every session's outgoing limits. The profile denies changing it anyway,
# so CHOPI_ALLOW_SELF, for working on chopi, whose dir holds the default config, may downgrade this.
# The config dir links into a tree of its own, for a workspace to hold it, but not the run dir.
cw="$(mktemp -d)"; cw="$(realpath "$cw")"; mkdir -p "$cw/linked/config/team" "$cw/beside"
ln -s "$cw/linked/config" "$cw/config"
out="$(preflight_under "$cw/linked" CHOPI_RUN_DIR="$cw")"; st=$?
assert_contains "$out" "overlaps the proxy's config ('$cw/linked/config')" \
    "refuses when workspace CONTAINS the proxy config dir"
assert_nonzero "$st" "  -> and returns non-zero"
out="$(preflight_under "$cw/linked/config/team" CHOPI_RUN_DIR="$cw")"
assert_contains "$out" "overlaps the proxy's config" "refuses when workspace is INSIDE the proxy config dir"
out="$(preflight_under "$cw/beside" CHOPI_RUN_DIR="$cw")"
assert_not_contains "$out" "overlaps the proxy's config" \
    "a workspace beside the proxy config dir, inside CHOPI_RUN_DIR, clears the check"
out="$(preflight_under "$cw/linked/config" CHOPI_ALLOW_SELF=1 CHOPI_RUN_DIR="$cw")"
assert_contains "$out" "warning: workspace '$cw/linked/config' overlaps the proxy's config" \
    "CHOPI_ALLOW_SELF downgrades the proxy config overlap to a warning"


# ---------------------------------------------------------------------------
echo "preflight_config_placement (custom --config must live outside the workspace)"
# ---------------------------------------------------------------------------
work="$(mktemp -d)"
cfg_inside="$work/sandbox.sh"; : > "$cfg_inside"

out="$( cd "$work" && { unset CHOPI_ALLOW_SELF; preflight_config_placement "$cfg_inside" "$work"; } 2>&1 )"; st=$?
assert_contains "$out" "is inside the workspace" "refuses a --config inside the workspace"
assert_nonzero "$st" "  -> and returns non-zero"

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
assert_zero "$st" "  -> and returns zero"

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
assert_zero "$st" "  -> and returns zero"

# Verify no false negatives
inside_wt_cfg="$parent/wt/cfg.sh"; : > "$inside_wt_cfg"
sibling="$(mktemp -d)"
out="$( cd "$sibling" && preflight_config_placement "$inside_wt_cfg" "$parent/wt" 2>&1 )"; st=$?
assert_contains "$out" "is inside the workspace" "a config inside the workspace is refused even when invoked from elsewhere"
assert_nonzero "$st" "  -> and returns non-zero"


# ---------------------------------------------------------------------------
echo "preflight_config_placement argument handling"
# ---------------------------------------------------------------------------
out="$( cd "$work" && preflight_config_placement /no/such/dir/cfg.sh "$work" 2>&1 )"; st=$?
assert_contains "$out" "cannot resolve --config" "a nonexistent --config path fails fast"
assert_nonzero "$st" "  -> and returns non-zero"

out="$(preflight_config_placement "$cfg_outside" /no/such/run/dir 2>&1)"; st=$?
assert_contains "$out" "cannot resolve run dir" "a nonexistent run dir fails fast"
assert_nonzero "$st" "  -> and returns non-zero"

( preflight_config_placement "$cfg_outside" ) 2>/dev/null; st=$?
assert_eq "$st" 2 "a wrong number of arguments is a hard error (exit 2)"


# ---------------------------------------------------------------------------
echo "where the sessions' proxies keep their sockets and ports (out of the sandbox's reach)"
# ---------------------------------------------------------------------------
# The ports a session's proxy reports decide which holes chopi opens: a sandboxed command that could
# rewrite them -- as it can anything under the login TMPDIR -- would aim the session's holes, and
# HTTP_PROXY, at a local service of its choosing.
# run_dir ENV... -- the run dir util.sh derives under ENV, with TMPDIR set aside and CHOPI_RUN_DIR
# unset unless ENV sets it.
run_dir() {
    # shellcheck disable=SC2016  # expands in the child bash, against the environment under test
    env -u CHOPI_RUN_DIR TMPDIR=/login-tmp "$@" \
        bash -c '. "$1/.internal/util.sh"; echo "$PROXY_RUN_DIR"' _ "$repo"
}
assert_eq "$(run_dir HOME=/home)" "/home/.chopi/run" "the run dir is ~/.chopi/run, not under TMPDIR"
assert_eq "$(run_dir HOME=/home CHOPI_RUN_DIR=/elsewhere)" "/elsewhere/run" \
    "  -> and CHOPI_RUN_DIR moves it, into a run/ of its own"
# chopi moves into a worktree, so a relative CHOPI_RUN_DIR is taken from where it was given, lest it
# name a different dir there.
assert_eq "$(cd /tmp && run_dir HOME=/home CHOPI_RUN_DIR=rel/dir)" "$(cd /tmp && pwd)/rel/dir/run" \
    "  -> a relative one is taken from the directory it is given in"


# ---------------------------------------------------------------------------
echo "resolve_proxy_config (resolving the proxy's config paths once, up front)"
# ---------------------------------------------------------------------------
rp="$(mktemp -d)"; rp="$(realpath "$rp")"
mkdir "$rp/team" "$rp/chopi" "$rp/chopi/config" "$rp/elsewhere"
: > "$rp/team/rules.yaml"
: > "$rp/elsewhere/rules.yaml"
ln -s "$rp/team" "$rp/link"
ln -s "$rp/elsewhere/rules.yaml" "$rp/team/escaping.yaml"
# The dir a configured file must be in, every session keeping its command from changing it.
PROXY_CONFIG_DIR="$rp/link"

out="$( CHOPI_PROXY_RULES="$rp/link/rules.yaml"
        resolve_proxy_config CHOPI_PROXY_RULES proxy-rules.yaml proxy-rules.template.yaml && printf '%s' "$CHOPI_PROXY_RULES" )"
assert_eq "$out" "$rp/team/rules.yaml" "a configured path is resolved through its symlinks"

out="$( CHOPI_PROXY_RULES="$rp/elsewhere/rules.yaml"
        resolve_proxy_config CHOPI_PROXY_RULES proxy-rules.yaml proxy-rules.template.yaml 2>&1 )"; st=$?
assert_nonzero "$st" "a configured path outside the config dir is refused"
assert_contains "$out" "CHOPI_PROXY_RULES must be in $rp/link" "  -> naming the setting, and where it must be"
assert_contains "$out" "another session's" "  -> saying why"
out="$( CHOPI_PROXY_RULES="$rp/link/escaping.yaml"
        resolve_proxy_config CHOPI_PROXY_RULES proxy-rules.yaml proxy-rules.template.yaml 2>&1 )"; st=$?
assert_nonzero "$st" "  -> as is one in it that links out of it"

out="$( CHOPI_PROXY_RULES=""; CHOPI_DIR="$rp/chopi"
        ln -s "$rp/team/rules.yaml" "$rp/chopi/config/proxy-rules.yaml"
        resolve_proxy_config CHOPI_PROXY_RULES proxy-rules.yaml proxy-rules.template.yaml && printf '%s' "$CHOPI_PROXY_RULES" )"
assert_eq "$out" "$rp/team/rules.yaml" "with none configured, the default is resolved too"
rm "$rp/chopi/config/proxy-rules.yaml"

out="$( CHOPI_PROXY_RULES=""; CHOPI_DIR="$rp/chopi"
        resolve_proxy_config CHOPI_PROXY_RULES proxy-rules.yaml proxy-rules.template.yaml 2>&1 )"; st=$?
assert_nonzero "$st" "a missing default is refused"
assert_contains "$out" "cp \"$rp/chopi/config/templates/proxy-rules.template.yaml\" \"$rp/chopi/config/proxy-rules.yaml\"" \
    "  -> saying how to create it"

# shellcheck disable=SC2034 # read by resolve_proxy_config, through its name
out="$( CHOPI_PROXY_RULES=rules.yaml; resolve_proxy_config CHOPI_PROXY_RULES proxy-rules.yaml proxy-rules.template.yaml 2>&1 )"; st=$?
assert_nonzero "$st" "a relative path is refused"
assert_contains "$out" "CHOPI_PROXY_RULES must be an absolute path" "  -> naming the setting"

# GNU realpath, often first on PATH, resolves a missing path as BSD's doesn't: stand one in.
mkdir "$rp/gnu"
cat > "$rp/gnu/realpath" <<'EOF'
#!/bin/sh
printf '%s\n' "$1"
EOF
chmod +x "$rp/gnu/realpath"
# shellcheck disable=SC2034 # read by resolve_proxy_config, through its name
out="$( CHOPI_GITHUB_ALLOWLIST="$rp/team/missing"; PATH="$rp/gnu:$PATH"
        resolve_proxy_config CHOPI_GITHUB_ALLOWLIST github-allowlist github-allowlist.template 2>&1 )"; st=$?
assert_nonzero "$st" "a configured path that doesn't exist is refused, whichever realpath is on PATH"
assert_contains "$out" "no CHOPI_GITHUB_ALLOWLIST file at '$rp/team/missing'" "  -> naming the setting"


# ---------------------------------------------------------------------------
echo "preflight_proxy_config_links (refusing a proxy config with other hard links)"
# ---------------------------------------------------------------------------
# Checked outside the sandbox, where the file's link count can always be read: in a session, the
# sandbox may not let the command so much as stat it. Every config the proxy may read is checked,
# chopi not knowing which one it was started with.
hl="$(mktemp -d)"; hl="$(realpath "$hl")"
mkdir -p "$hl/chopi/config" "$hl/config/team" "$hl/elsewhere"
echo 'allow: []' >"$hl/chopi/config/$DEFAULT_PROXY_RULES"
: >"$hl/chopi/config/$DEFAULT_GITHUB_ALLOWLIST"
echo 'allow: []' >"$hl/config/team/rules.yaml"
# links_check ENV... -- preflight_proxy_config_links on the configs in $hl, under ENV
links_check() {
    ( CHOPI_DIR="$hl/chopi"; PROXY_CONFIG_DIR="$hl/config"; unset CHOPI_ALLOW_SELF
      for assignment in "$@"; do export "${assignment?}"; done
      preflight_proxy_config_links )
}

out="$(links_check 2>&1)"; st=$?
assert_zero "$st" "config files with no other hard links pass"
out="$(links_check PROXY_CONFIG_DIR="$hl/missing" 2>&1)"; st=$?
assert_zero "$st" "  -> as does a config dir not made yet"

ln "$hl/config/team/rules.yaml" "$hl/elsewhere/other-link.yaml"
out="$(links_check 2>&1)"; st=$?
assert_nonzero "$st" "a custom config file in the config dir with other hard links is refused"
assert_contains "$out" "the proxy's config file '$hl/config/team/rules.yaml' has other hard links" "  -> naming it"
assert_contains "$out" "Review what is in it, as it may have been written through another hard link" \
    "  -> asking for it to be reviewed"
assert_contains "$out" "cp '$hl/config/team/rules.yaml' '$hl/config/team/rules.yaml.tmp' && mv '$hl/config/team/rules.yaml.tmp' '$hl/config/team/rules.yaml'" \
    "  -> and saying how to replace it with a fresh copy"

out="$(links_check CHOPI_ALLOW_SELF=1 2>&1)"; st=$?
assert_zero "$st" "CHOPI_ALLOW_SELF downgrades the refusal"
assert_contains "$out" "warning: the proxy's config file '$hl/config/team/rules.yaml' has other hard links" "  -> to a warning"
rm "$hl/elsewhere/other-link.yaml"

# A file the proxy refused for its other hard links is moved aside, where it never reads it.
echo 'allow: []' >"$hl/config/team/rules.yaml.refused-20261113-120000"
ln "$hl/config/team/rules.yaml.refused-20261113-120000" "$hl/elsewhere/refused.yaml"
out="$(links_check 2>&1)"; st=$?
assert_zero "$st" "a refused file the proxy moved aside, with other hard links, passes"
rm "$hl/elsewhere/refused.yaml" "$hl/config/team/rules.yaml.refused-20261113-120000"

ln "$hl/chopi/config/$DEFAULT_GITHUB_ALLOWLIST" "$hl/elsewhere/allowlist"
out="$(links_check 2>&1)"; st=$?
assert_nonzero "$st" "a default config file with other hard links is refused"
assert_contains "$out" "'$hl/chopi/config/$DEFAULT_GITHUB_ALLOWLIST' has other hard links" "  -> naming it"
rm "$hl/elsewhere/allowlist"

mkdir "$hl/config/locked"; chmod 000 "$hl/config/locked"
out="$(links_check CHOPI_ALLOW_SELF=1 2>&1)"; st=$?
chmod 700 "$hl/config/locked"
assert_nonzero "$st" "a config dir find can't fully check is refused, even with CHOPI_ALLOW_SELF"
assert_contains "$out" "could not check every proxy config file for other hard links" "  -> saying so"


# ---------------------------------------------------------------------------
echo "rule (the Seatbelt-rule emitter)"
# ---------------------------------------------------------------------------
out="$(rule 'allow file-read*' subpath '/a b/c')"
assert_eq "$out" '(allow file-read* (subpath "/a b/c"))' "emits the (ACTION (MATCHER \"PATH\")) form"

# An empty PATH is a caller bug, not a rule (it would silently misapply). The guard
# hard-exits, so probe it in a subshell.
( rule 'deny file-write*' subpath '' ) >/dev/null 2>&1; st=$?
assert_eq "$st" 2 "an empty PATH is a hard error (exit 2)"


# ---------------------------------------------------------------------------
echo "ancestry_rules (a rule on each node of a path's ancestry)"
# ---------------------------------------------------------------------------
nl=$'\n'
out="$(ancestry_rules 'allow file-read-metadata' /a /a/b/c /a/b/d)"
assert_eq "$out" "(allow file-read-metadata (literal \"/a/b/c\"))$nl(allow file-read-metadata (literal \"/a/b\"))$nl(allow file-read-metadata (literal \"/a/b/d\"))" \
    "each START up to STOP, exclusive, each node once"
out="$(ancestry_rules 'deny file-write*' /elsewhere /a/b)"
assert_eq "$out" "(deny file-write* (literal \"/a/b\"))$nl(deny file-write* (literal \"/a\"))" \
    "a STOP off the ancestry ends the walk at the root, excluded"
out="$(ancestry_rules 'allow file-read-metadata' /a /a)"
assert_eq "$out" "" "a START at STOP emits nothing"
# claude-context-reads passes the root as "" (its PARENT, and the dir of a file directly under it)
out="$(ancestry_rules 'allow file-read-metadata' "" "")"
assert_eq "$out" "" "an empty START is the root, which is excluded"
out="$(ancestry_rules 'allow file-read-metadata' /elsewhere "")"
assert_eq "$out" "" "  -> also under an off-path STOP"
# A relative START never reaches the root, so it would loop forever. The guard hard-exits, so
# probe it in a subshell.
( ancestry_rules 'allow file-read-metadata' /a rel/b ) >/dev/null 2>&1; st=$?
assert_eq "$st" 2 "a relative START is a hard error (exit 2)"


# ---------------------------------------------------------------------------
summary

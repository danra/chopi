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
#   * workspace_config_dir / resolve_workspace_config_dir -- which repo's own proxy config a
#     session reads, and refusing one that leads out of the dir every session protects.
#   * preflight_proxy_config_links -- refusing a proxy config file with other hard links, which the
#     sandboxed command may write through, whether a session uses it or not.
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

newline_root="$(mktemp -d)"
mkdir "$newline_root/config"$'\n'
ln -s 'config'$'\n' "$newline_root/config"
out="$(preflight_under "$cw/beside" CHOPI_ALLOW_SELF=1 CHOPI_RUN_DIR="$newline_root")"; st=$?
assert_nonzero "$st" "preflight refuses a proxy config root linking to a directory ending in a newline"
assert_contains "$out" "must not contain a newline" "  -> explaining the refusal even with CHOPI_ALLOW_SELF"

mkdir "$newline_root/parent"$'\n'"dir"
ln -s 'parent'$'\n''dir' "$newline_root/alias"
out="$(preflight_under "$cw/beside" CHOPI_RUN_DIR="$newline_root/alias")"; st=$?
assert_nonzero "$st" "preflight refuses a newline in the resolved root's ancestry"
assert_contains "$out" "must not contain a newline" "  -> even when the config directory does not exist yet"

mkdir "$newline_root/clean-config" "$newline_root/intermediate"
ln -s clean-config "$newline_root/hop"$'\n'
ln -s '../hop'$'\n' "$newline_root/intermediate/config"
out="$(preflight_under "$cw/beside" CHOPI_RUN_DIR="$newline_root/intermediate")"; st=$?
assert_nonzero "$st" "preflight refuses a newline in an intermediate symlink"
assert_contains "$out" "must not contain a newline" "  -> even when the final path is clean"

( PROXY_CONFIG_DIR="$newline_root/intermediate/config"
  write_proxy_config_profile "$newline_root/rejected.sb" ) 2>/dev/null; st=$?
assert_nonzero "$st" "profile generation propagates a path rejection"
assert_absent "$newline_root/rejected.sb" "  -> without emitting a partial profile"

# A newline in the root itself, not in any link: split, it would protect two made-up paths instead.
out="$(preflight_under "$cw/beside" CHOPI_RUN_DIR="$newline_root/split"$'\n'"run")"; st=$?
assert_nonzero "$st" "preflight refuses a proxy config root with a newline in its own name"
assert_contains "$out" "must not contain a newline" "  -> rather than checking the halves as two paths"

( CHOPI_DIR="$newline_root/split"$'\n'"chopi"
  write_proxy_config_profile "$newline_root/split-chopi.sb" ) 2>/dev/null; st=$?
assert_nonzero "$st" "profile generation refuses a newline in chopi's own dir, holding the default configs"
assert_absent "$newline_root/split-chopi.sb" "  -> without emitting a profile for its halves"


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
# GNU realpath, often first on PATH, keeps a path's case as given, and resolves a missing one as
# BSD's doesn't: a stand-in, for what is resolved not to depend on which one is.
mkdir "$rp/gnu"
cat > "$rp/gnu/realpath" <<'EOF'
#!/bin/sh
printf '%s\n' "$1"
EOF
chmod +x "$rp/gnu/realpath"

out="$( CHOPI_PROXY_RULES="$rp/link/rules.yaml"
        resolve_proxy_config CHOPI_PROXY_RULES proxy-rules.yaml proxy-rules.template.yaml && printf '%s' "$CHOPI_PROXY_RULES" )"
assert_eq "$out" "$rp/team/rules.yaml" "a configured path is resolved through its symlinks"

# A case-insensitive volume (macOS's default) takes a path in any case; the profile's rules match
# the case on disk.
if [ -e "$rp/TEAM/RULES.yaml" ]; then
    for path_prefix in "" "$rp/gnu:"; do
        out="$( PROXY_CONFIG_DIR="$rp/team"; CHOPI_PROXY_RULES="$rp/TEAM/RULES.yaml"
                PATH="$path_prefix$PATH" resolve_proxy_config CHOPI_PROXY_RULES proxy-rules.yaml proxy-rules.template.yaml \
                    && printf '%s' "$CHOPI_PROXY_RULES" )"
        assert_eq "$out" "$rp/team/rules.yaml" \
            "  -> and to its case on disk, where the volume ignores case, with realpath from PATH='$path_prefix'"
    done
    # Every path deciding the file goes in the profile, each in its case on disk: a link, by its own
    # name and through its target's, and a dir before a missing node.
    ln -s "$rp/TEAM" "$rp/upper-link"
    assert_eq "$(resolution_paths "$rp/UPPER-LINK/ESCAPING.yaml")" \
        "$rp/upper-link"$'\n'"$rp/team/escaping.yaml"$'\n'"$rp/elsewhere/rules.yaml" \
        "  -> as is every link on the way, by its own name and through its target"
    assert_eq "$(resolution_paths "$rp/TEAM/Missing/x")" "$rp/team/Missing/x" \
        "  -> and the part before a missing node"
else
    echo "case-sensitive volume -- skipping the case-insensitive path test"
fi

out="$( CHOPI_PROXY_RULES="$rp/elsewhere/rules.yaml"
        resolve_proxy_config CHOPI_PROXY_RULES proxy-rules.yaml proxy-rules.template.yaml 2>&1 )"; st=$?
assert_nonzero "$st" "a configured path outside the config dir is refused"
assert_contains "$out" "CHOPI_PROXY_RULES must be in $rp/link" "  -> naming the setting, and where it must be"
assert_contains "$out" "another session's" "  -> saying why"
out="$( CHOPI_PROXY_RULES="$rp/link/escaping.yaml"
        resolve_proxy_config CHOPI_PROXY_RULES proxy-rules.yaml proxy-rules.template.yaml 2>&1 )"; st=$?
assert_nonzero "$st" "  -> as is one in it that links out of it"

newline_config_dir="$rp/team"$'\n'
mkdir "$newline_config_dir"
ln -s "$newline_config_dir" "$rp/newline-config-link"
out="$( PROXY_CONFIG_DIR="$rp/newline-config-link"
        CHOPI_PROXY_RULES="$rp/team/rules.yaml"
        resolve_proxy_config CHOPI_PROXY_RULES proxy-rules.yaml proxy-rules.template.yaml 2>&1 )"; st=$?
assert_nonzero "$st" "a configured path in the sibling of a config dir ending in a newline is refused"
assert_contains "$out" "must not contain a newline" "  -> rejecting the config dir's newline target"

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

newline_rules="$rp/team/rules"$'\n'"backup.yaml"
trailing_newline_rules="$rp/team/rules.yaml"$'\n'
: >"$newline_rules"
: >"$trailing_newline_rules"
ln -s "$trailing_newline_rules" "$rp/team/newline-target.yaml"
for selected_rules in "$newline_rules" "$rp/team/newline-target.yaml"; do
    # shellcheck disable=SC2034 # read by resolve_proxy_config, through its name
    out="$( CHOPI_PROXY_RULES="$selected_rules"
            resolve_proxy_config CHOPI_PROXY_RULES proxy-rules.yaml proxy-rules.template.yaml 2>&1 )"; st=$?
    assert_nonzero "$st" "a configured path with a newline in its name or target is refused"
    assert_contains "$out" "must not contain a newline" "  -> explaining the refusal"
done

# shellcheck disable=SC2034 # read by resolve_proxy_config, through its name
out="$( CHOPI_GITHUB_ALLOWLIST="$rp/team/missing"; PATH="$rp/gnu:$PATH"
        resolve_proxy_config CHOPI_GITHUB_ALLOWLIST github-allowlist github-allowlist.template 2>&1 )"; st=$?
assert_nonzero "$st" "a configured path that doesn't exist is refused, whichever realpath is on PATH"
assert_contains "$out" "no CHOPI_GITHUB_ALLOWLIST file at '$rp/team/missing'" "  -> naming the setting"


# ---------------------------------------------------------------------------
echo "preflight_proxy_config_links (refusing a proxy config with other hard links)"
# ---------------------------------------------------------------------------
# Check the files the proxy can use, and every file in PROXY_CONFIG_DIR, before entering the
# sandbox.
hl="$(mktemp -d)"; hl="$(realpath "$hl")"
mkdir -p "$hl/chopi/config" "$hl/config/team" "$hl/elsewhere"
echo 'allow: []' >"$hl/chopi/config/$DEFAULT_PROXY_RULES"
: >"$hl/chopi/config/$DEFAULT_GITHUB_ALLOWLIST"
echo 'allow: []' >"$hl/config/team/rules.yaml"
unset CHOPI_ALLOW_SELF
PROXY_CONFIG_DIR="$hl/config"
# links_check FILE... -- preflight_proxy_config_links on the configs in $hl
links_check() {
    CHOPI_DIR="$hl/chopi" PROXY_RUN_DIR="$hl/run" preflight_proxy_config_links "$@"
}

out="$(links_check "$hl/config/team/rules.yaml" 2>&1)"; st=$?
assert_zero "$st" "config files with no other hard links pass"
session_dir="$hl/run/$PROXY_SESSION_DIR_PREFIX.test"
mkdir -p "$session_dir"
printf '%s\n' "$hl/missing/rules.yaml" >"$session_dir/$PROXY_CONFIGS_FILE_NAME"
out="$(links_check 2>&1)"; st=$?
assert_zero "$st" "  -> as does a config file from a finished session that was removed"
out="$(links_check "$hl/missing/rules.yaml" 2>&1)"; st=$?
assert_zero "$st" "  -> as does an optional config file not made yet"

ln "$hl/config/team/rules.yaml" "$hl/elsewhere/other-link.yaml"
out="$(links_check 2>&1)"; st=$?
assert_nonzero "$st" "a custom config file with other hard links is refused, even if no session uses it"
assert_contains "$out" "the proxy's config file '$hl/config/team/rules.yaml' has other hard links" "  -> naming it"
assert_contains "$out" "Review what is in it, as it may have been written through another hard link" \
    "  -> asking for it to be reviewed"
assert_contains "$out" "cp '$hl/config/team/rules.yaml' '$hl/config/team/rules.yaml.tmp' && mv '$hl/config/team/rules.yaml.tmp' '$hl/config/team/rules.yaml'" \
    "  -> and saying how to replace it with a fresh copy"

out="$(CHOPI_ALLOW_SELF=1 links_check 2>&1)"; st=$?
assert_zero "$st" "CHOPI_ALLOW_SELF downgrades the refusal"
assert_contains "$out" "warning: the proxy's config file '$hl/config/team/rules.yaml' has other hard links" "  -> to a warning"
ln -s "$hl/config" "$hl/config-link"
out="$(PROXY_CONFIG_DIR="$hl/config-link" links_check 2>&1)"; st=$?
assert_nonzero "$st" "a hard-linked config is refused when PROXY_CONFIG_DIR is a symlink"
assert_contains "$out" "'$hl/config-link/team/rules.yaml' has other hard links" "  -> naming it"
rm "$hl/config-link" "$hl/elsewhere/other-link.yaml"

ln "$hl/chopi/config/$DEFAULT_GITHUB_ALLOWLIST" "$hl/elsewhere/allowlist"
out="$(CHOPI_ALLOW_SELF='' links_check 2>&1)"; st=$?
assert_nonzero "$st" "a default config file with other hard links is refused"
assert_contains "$out" "'$hl/chopi/config/$DEFAULT_GITHUB_ALLOWLIST' has other hard links" "  -> naming it"
rm "$hl/elsewhere/allowlist"

mkdir "$hl/config/unused"; chmod 000 "$hl/config/unused"
out="$(links_check 2>&1)"; st=$?
chmod 700 "$hl/config/unused"
assert_zero "$st" "an unreadable unused config directory does not block startup"
if [ "$EUID" -ne 0 ]; then
    # Search without read: find can't list it, yet a session can open a config in it by name.
    mkdir "$hl/config/listless"; chmod 300 "$hl/config/listless"
    out="$(links_check 2>&1)"; st=$?
    assert_nonzero "$st" "a config directory that can be searched but not listed is refused"
    assert_contains "$out" "'$hl/config/listless' can be searched but not listed" "  -> naming it"
    out="$(CHOPI_ALLOW_SELF=1 links_check 2>&1)"; st=$?
    assert_contains "$out" "warning: the proxy config directory '$hl/config/listless'" \
        "  -> CHOPI_ALLOW_SELF downgrades it to a warning"
    rmdir "$hl/config/listless"
fi

# A repo whose proxy config is unreadable should not prevent a different repo from starting.
mkdir -p "$hl/config/workspaces/unrelated" "$hl/config/workspaces/current"
current_rules="$hl/config/workspaces/current/$DEFAULT_PROXY_RULES"
other_rules="$hl/config/workspaces/unrelated/$DEFAULT_PROXY_RULES"
: >"$current_rules"
: >"$other_rules"
chmod 000 "$hl/config/workspaces/unrelated"
out="$(links_check "$current_rules" 2>&1)"; st=$?
chmod 700 "$hl/config/workspaces/unrelated"
assert_zero "$st" "an unreadable unrelated workspace config does not block startup"

ln "$other_rules" "$hl/elsewhere/workspace-rules"
out="$(links_check "$current_rules" 2>&1)"; st=$?
assert_nonzero "$st" "a hard-linked workspace config is refused even if no session uses it"
assert_contains "$out" "'$other_rules' has other hard links" "  -> naming it"
rm "$hl/elsewhere/workspace-rules"

# A session may list a file outside PROXY_CONFIG_DIR, which the scan misses: a default's target,
# say, since repointed.
mkdir "$hl/repointed"; echo 'allow: []' >"$hl/repointed/rules.yaml"
ln "$hl/repointed/rules.yaml" "$hl/elsewhere/repointed-link.yaml"
printf '%s\n' "$hl/repointed/rules.yaml" >"$session_dir/$PROXY_CONFIGS_FILE_NAME"
out="$(links_check 2>&1)"; st=$?
assert_nonzero "$st" "a hard-linked config in use by another session is refused"
assert_contains "$out" "'$hl/repointed/rules.yaml' has other hard links" "  -> naming it"
rm "$hl/elsewhere/repointed-link.yaml"
printf '%s\n' "$hl/config/team/rules.yaml" >"$session_dir/$PROXY_CONFIGS_FILE_NAME"

if [ "$EUID" -ne 0 ]; then
    chmod 000 "$hl/config/team"
    out="$(CHOPI_ALLOW_SELF=1 links_check 2>&1)"; st=$?
    chmod 700 "$hl/config/team"
    assert_nonzero "$st" "a registered config whose directory can't be searched blocks startup"
    assert_contains "$out" "could not check proxy config file '$hl/config/team/rules.yaml'" \
        "  -> naming the file that couldn't be checked"
fi


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
echo "workspace_config_dir / resolve_workspace_config_dir (a repo's own proxy config)"
# ---------------------------------------------------------------------------
PROXY_CONFIG_DIR="$CHOPI_RUN_DIR/config"
mkdir -p "$PROXY_CONFIG_DIR"
ws_repo="$TMPDIR/my repo.v2"
make_repo "$ws_repo"
real_ws_repo="$(cd "$ws_repo" && pwd -P)"
mangled="$(printf '%s' "$real_ws_repo" | tr -c 'A-Za-z0-9-' -)-$(path_id "$real_ws_repo/.git")"
out="$(workspace_config_dir "$ws_repo")"
assert_eq "$out" "$PROXY_CONFIG_DIR/workspaces/$mangled" \
    "named for the repo's path, each character but a letter, digit or dash made a dash, then its git dir's id"
assert_eq "$(workspace_config_dir "$ws_repo/")" "$out" "  -> however the path is given"
git -C "$ws_repo" worktree add -q "$TMPDIR/linked" -b linked
assert_eq "$(workspace_config_dir "$TMPDIR/linked")" "$out" "  -> shared by the repo's linked worktrees"
other_repo="$TMPDIR/other"
make_repo "$other_repo"
assert_not_contains "$(workspace_config_dir "$other_repo")" "$mangled" "  -> but not by another repo"
make_repo "$TMPDIR/acme/tools"
make_repo "$TMPDIR/acme-tools"
assert_not_eq "$(workspace_config_dir "$TMPDIR/acme/tools")" "$(workspace_config_dir "$TMPDIR/acme-tools")" \
    "  -> nor by one whose path differs only in a character made a dash"
make_repo "$TMPDIR/sep-a" --separate-git-dir "$TMPDIR/meta"
make_repo "$TMPDIR/sep-b" --separate-git-dir "$TMPDIR/meta/.git"
assert_not_eq "$(workspace_config_dir "$TMPDIR/sep-a")" "$(workspace_config_dir "$TMPDIR/sep-b")" \
    "  -> nor by one whose git dir is the other's, but for a .git at its end"
long_repo="$TMPDIR/$(printf 'a%.0s' {1..120})/$(printf 'b%.0s' {1..120})"
make_repo "$long_repo"
long_name="$(basename -- "$(workspace_config_dir "$long_repo")")"
assert_eq "${#long_name}" $((WORKSPACE_NAME_MAX + 17)) \
    "a long name is cut short, before its id, within a file name's 255 bytes"
out="$(workspace_config_dir "$TMPDIR" 2>&1)"; st=$?
assert_nonzero "$st" "outside a repo -> refused"
assert_contains "$out" "cannot find the git repo" "  -> saying so"

out="$(resolve_workspace_config_dir "$ws_repo")"; st=$?
assert_zero "$st" "a workspace config dir that doesn't exist yet resolves"
assert_eq "$out" "$(realpath "$CHOPI_RUN_DIR/config")/workspaces/$mangled" "  -> to its real path"
mkdir -p "$TMPDIR/elsewhere"
ln -s "$TMPDIR/elsewhere" "$CHOPI_RUN_DIR/config/workspaces"
out="$(resolve_workspace_config_dir "$ws_repo" 2>&1)"; st=$?
assert_nonzero "$st" "one whose way leads out of the config dir, by a link -> refused"
assert_contains "$out" "leads out of" "  -> saying so"
rm "$CHOPI_RUN_DIR/config/workspaces"
mkdir -p "$CHOPI_RUN_DIR/config/workspaces"
ln -s "$CHOPI_RUN_DIR/config/workspaces/target" "$CHOPI_RUN_DIR/config/workspaces/$mangled"
out="$(resolve_workspace_config_dir "$ws_repo")"; st=$?
assert_zero "$st" "a link staying in the config dir is followed"
assert_eq "$out" "$(realpath "$CHOPI_RUN_DIR/config")/workspaces/target" "  -> to where it leads"


# ---------------------------------------------------------------------------
summary

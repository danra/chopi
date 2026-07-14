#!/usr/bin/env bash
#
# test/git-protect-wrapper.sh -- unit tests for the in-sandbox git-protect wrapper: its
# git-config appending and its run-the-command-then-cleanup teardown.

# shellcheck disable=SC2016  # GIT_CONFIG_* vars expand in the shell the wrapper execs, not in this script

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
. "$repo/.internal/util.sh"
. "$repo/test/lib.sh"

header "test/git-protect-wrapper.sh -- unit tests for the git-protect wrapper"

WRAP="$repo/.internal/git-protect-wrapper.sh"

# Exported so the scripts under test leave their temporaries here too.
TMPDIR="$(mktemp -d)"; export TMPDIR
trap 'rm -rf "$TMPDIR"' EXIT

# The wrapper requires a CLEANUP_SCRIPT_PATH first argument and runs it on every exit path. Most
# cases don't care what it does, so use a stub that just records that it ran (to a file, so it
# never lands in captured stdout); the cleanup cases below reset and inspect the marker.
cleanup_marker="$TMPDIR/cleanup-marker"
cleanup_script="$TMPDIR/cleanup.sh"
cat > "$cleanup_script" <<EOF
#!/bin/sh
printf 'CLEANUP\n' >> "$cleanup_marker"
EOF
chmod +x "$cleanup_script"

# Each case states its GIT_CONFIG_COUNT input exactly; env -u scrubs one that might leak in
# from this test's own environment. (Stray KEY_n/VALUE_n vars without a covering COUNT are
# inert for both git and the wrapper, so they need no scrubbing.)
scrubbed() { env -u GIT_CONFIG_COUNT "$@"; }

# Captured exit codes below rely on errexit being off.
set +e


# ---------------------------------------------------------------------------
echo "appending into a fresh environment"
# ---------------------------------------------------------------------------
out="$(scrubbed "$WRAP" "$cleanup_script" gc.auto=0 maintenance.auto=false -- /bin/sh -c \
    'echo "$GIT_CONFIG_COUNT|$GIT_CONFIG_KEY_0=$GIT_CONFIG_VALUE_0|$GIT_CONFIG_KEY_1=$GIT_CONFIG_VALUE_1"')"
assert_eq "$out" "2|gc.auto=0|maintenance.auto=false" \
    "with GIT_CONFIG_COUNT unset, pairs land at indices 0.. and COUNT is set"

out="$(scrubbed "$WRAP" "$cleanup_script" 'alias.lg=log --pretty=%h' -- /bin/sh -c 'echo "$GIT_CONFIG_VALUE_0"')"
assert_eq "$out" "log --pretty=%h" "a value containing '=' splits on the FIRST '=' only"

out="$(scrubbed "$WRAP" "$cleanup_script" -- /bin/sh -c 'echo "count=$GIT_CONFIG_COUNT"')"
assert_eq "$out" "count=0" "zero pairs is a passthrough (COUNT pinned to 0 -- no entries)"


# ---------------------------------------------------------------------------
echo "merging with pre-existing GIT_CONFIG_* entries"
# ---------------------------------------------------------------------------
out="$(env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.key GIT_CONFIG_VALUE_0=uservalue \
    "$WRAP" "$cleanup_script" gc.auto=0 -- /bin/sh -c \
    'echo "$GIT_CONFIG_COUNT|$GIT_CONFIG_KEY_0=$GIT_CONFIG_VALUE_0|$GIT_CONFIG_KEY_1=$GIT_CONFIG_VALUE_1"')"
assert_eq "$out" "2|user.key=uservalue|gc.auto=0" \
    "pre-existing entries are preserved; appends continue at the next index"

# The precedence the merge relies on is git's, not the wrapper's: for a single-valued key,
# git gives the LATER index the last word, so an appended pair overrides a same-key entry
# already in the environment.
if command -v git >/dev/null 2>&1; then
    tmp="$(mktemp -d)"
    git init -q "$tmp/r"
    out="$(cd "$tmp/r" && env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=chopi.t GIT_CONFIG_VALUE_0=preexisting \
        "$WRAP" "$cleanup_script" chopi.t=appended -- git config chopi.t)"
    assert_eq "$out" "appended" "git resolves a conflicting single-valued key to the APPENDED entry"
else
    bad "git-precedence check needs git on PATH"
fi


# ---------------------------------------------------------------------------
echo "run the command, then the cleanup, in the same (confined) process"
# ---------------------------------------------------------------------------
: > "$cleanup_marker"
out="$(scrubbed "$WRAP" "$cleanup_script" gc.auto=0 -- \
    /bin/sh -c 'echo "cfg=$GIT_CONFIG_COUNT:$GIT_CONFIG_KEY_0=$GIT_CONFIG_VALUE_0"')"; rc=$?
assert_eq "$rc" "0"                            "the command's exit code propagates"
assert_eq "$out" "cfg=1:gc.auto=0"             "  -> git config is still forwarded"
assert_eq "$(cat "$cleanup_marker")" "CLEANUP" "  -> the cleanup runs afterward"

: > "$cleanup_marker"
rc=0; scrubbed "$WRAP" "$cleanup_script" a.b=c -- /bin/sh -c 'exit 7' || rc=$?
assert_eq "$rc" "7"                            "the wrapped command's exit code propagates"
assert_eq "$(cat "$cleanup_marker")" "CLEANUP" "  -> and the cleanup still runs"

# A missing command is still named and non-zero, now via the child-run path (not exec).
out=""; rc=0; out="$(scrubbed "$WRAP" "$cleanup_script" -- /no/such/cmd 2>&1)" || rc=$?
assert_contains "$out" "/no/such/cmd" "a missing command is named in the error"
if [ "$rc" -ne 0 ]; then ok "  -> and exits non-zero"; else bad "  -> should exit non-zero (got $rc)"; fi

# The command must stay interruptible -- SIGINT reaches it with its default disposition -- and the
# cleanup must still run when it is interrupted. The command SIGINTs itself; were it NOT interruptible
# it would fall through to `sleep` and exit 0 after a delay instead of dying 128+SIGINT.
: > "$cleanup_marker"
rc=0; scrubbed "$WRAP" "$cleanup_script" -- /bin/sh -c 'kill -INT $$; sleep 1' || rc=$?
assert_eq "$rc" "130"                          "the command is interruptible (dies 128+SIGINT)"
assert_eq "$(cat "$cleanup_marker")" "CLEANUP" "  -> and the cleanup runs despite the interrupt"

# A SIGINT that also hits the wrapper (as a terminal Ctrl-C to the foreground group would): the
# wrapper must survive it (its trap) and still run the cleanup.
: > "$cleanup_marker"
rc=0; scrubbed "$WRAP" "$cleanup_script" -- /bin/sh -c 'kill -INT $PPID; kill -INT $$; sleep 1' || rc=$?
assert_eq "$(cat "$cleanup_marker")" "CLEANUP" "the wrapper survives its own SIGINT and still runs the cleanup"


# ---------------------------------------------------------------------------
echo "malformed input is refused before anything runs"
# ---------------------------------------------------------------------------
out="$(scrubbed "$WRAP" -- /bin/sh -c 'echo RAN' 2>&1)"; st=$?
assert_contains     "$out" "invalid" "a run without CLEANUP_SCRIPT_PATH is refused"
assert_not_contains "$out" "RAN"   "  -> and the command does not run"
if [ "$st" -ne 0 ]; then ok "  -> and exits non-zero"; else bad "  -> should exit non-zero (got $st)"; fi

out="$(env GIT_CONFIG_COUNT=nope "$WRAP" "$cleanup_script" a.b=c -- /bin/sh -c 'echo RAN' 2>&1)"; st=$?
assert_contains     "$out" "integer" "a non-integer pre-existing GIT_CONFIG_COUNT is refused"
assert_not_contains "$out" "RAN"     "  -> and the command does not run"
if [ "$st" -ne 0 ]; then ok "  -> and exits non-zero"; else bad "  -> should exit non-zero (got $st)"; fi

out="$(scrubbed "$WRAP" "$cleanup_script" a.b=c 2>&1)"; st=$?
assert_contains "$out" "no command given" "pairs without '-- <command>' are refused"
if [ "$st" -ne 0 ]; then ok "  -> and exits non-zero"; else bad "  -> should exit non-zero (got $st)"; fi

out="$(scrubbed "$WRAP" "$cleanup_script" notapair -- /bin/sh -c 'echo RAN' 2>&1)"; st=$?
assert_contains     "$out" "expected key=value" "an argument without '=' before '--' is refused"
assert_not_contains "$out" "RAN"                "  -> and the command does not run"
if [ "$st" -ne 0 ]; then ok "  -> and exits non-zero"; else bad "  -> should exit non-zero (got $st)"; fi

out="$(scrubbed "$WRAP" "$cleanup_script" =value -- /bin/sh -c 'echo RAN' 2>&1)"; st=$?
assert_contains     "$out" "non-empty" "an empty key is refused"
assert_not_contains "$out" "RAN"       "  -> and the command does not run"
if [ "$st" -ne 0 ]; then ok "  -> and exits non-zero"; else bad "  -> should exit non-zero (got $st)"; fi


# ---------------------------------------------------------------------------
summary

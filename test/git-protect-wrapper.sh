#!/usr/bin/env bash
#
# test/git-protect-wrapper.sh -- unit tests for the in-sandbox git-protect
# wrapper (currently only its git-config appending)

# shellcheck disable=SC2016  # GIT_CONFIG_* vars expand in the shell the wrapper execs, not in this script

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
. "$repo/.internal/util.sh"
. "$repo/test/lib.sh"

header "test/git-protect-wrapper.sh -- unit tests for the git-protect wrapper's git-config appending"

WRAP="$repo/.internal/git-protect-wrapper.sh"

# Exported so the scripts under test leave their temporaries here too.
TMPDIR="$(mktemp -d)"; export TMPDIR
trap 'rm -rf "$TMPDIR"' EXIT

# Each case states its GIT_CONFIG_COUNT input exactly; env -u scrubs one that might leak in
# from this test's own environment. (Stray KEY_n/VALUE_n vars without a covering COUNT are
# inert for both git and the wrapper, so they need no scrubbing.)
scrubbed() { env -u GIT_CONFIG_COUNT "$@"; }

# Captured exit codes below rely on errexit being off.
set +e


# ---------------------------------------------------------------------------
echo "appending into a fresh environment"
# ---------------------------------------------------------------------------
out="$(scrubbed "$WRAP" gc.auto=0 maintenance.auto=false -- /bin/sh -c \
    'echo "$GIT_CONFIG_COUNT|$GIT_CONFIG_KEY_0=$GIT_CONFIG_VALUE_0|$GIT_CONFIG_KEY_1=$GIT_CONFIG_VALUE_1"')"
assert_eq "$out" "2|gc.auto=0|maintenance.auto=false" \
    "with GIT_CONFIG_COUNT unset, pairs land at indices 0.. and COUNT is set"

out="$(scrubbed "$WRAP" 'alias.lg=log --pretty=%h' -- /bin/sh -c 'echo "$GIT_CONFIG_VALUE_0"')"
assert_eq "$out" "log --pretty=%h" "a value containing '=' splits on the FIRST '=' only"

out="$(scrubbed "$WRAP" -- /bin/sh -c 'echo "count=$GIT_CONFIG_COUNT"')"
assert_eq "$out" "count=0" "zero pairs is a passthrough (COUNT pinned to 0 -- no entries)"


# ---------------------------------------------------------------------------
echo "merging with pre-existing GIT_CONFIG_* entries"
# ---------------------------------------------------------------------------
out="$(env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.key GIT_CONFIG_VALUE_0=uservalue \
    "$WRAP" gc.auto=0 -- /bin/sh -c \
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
        "$WRAP" chopi.t=appended -- git config chopi.t)"
    assert_eq "$out" "appended" "git resolves a conflicting single-valued key to the APPENDED entry"
else
    bad "git-precedence check needs git on PATH"
fi


# ---------------------------------------------------------------------------
echo "exec semantics"
# ---------------------------------------------------------------------------
rc=0; scrubbed "$WRAP" a.b=c -- /bin/sh -c 'exit 7' || rc=$?
assert_eq "$rc" "7" "the wrapped command's exit code propagates"

out=""; rc=0; out="$(scrubbed "$WRAP" a.b=c -- /no/such/cmd 2>&1)" || rc=$?
assert_contains "$out" "/no/such/cmd" "a missing command is named in the error"
if [ "$rc" -ne 0 ]; then ok "  -> and exits non-zero"; else bad "  -> should exit non-zero (got $rc)"; fi


# ---------------------------------------------------------------------------
echo "malformed input is refused before anything runs"
# ---------------------------------------------------------------------------
out="$(env GIT_CONFIG_COUNT=nope "$WRAP" a.b=c -- /bin/sh -c 'echo RAN' 2>&1)"; st=$?
assert_contains     "$out" "integer" "a non-integer pre-existing GIT_CONFIG_COUNT is refused"
assert_not_contains "$out" "RAN"     "  -> and the command does not run"
if [ "$st" -ne 0 ]; then ok "  -> and exits non-zero"; else bad "  -> should exit non-zero (got $st)"; fi

out="$(scrubbed "$WRAP" a.b=c 2>&1)"; st=$?
assert_contains "$out" "no command given" "pairs without '-- <command>' are refused"
if [ "$st" -ne 0 ]; then ok "  -> and exits non-zero"; else bad "  -> should exit non-zero (got $st)"; fi

out="$(scrubbed "$WRAP" notapair -- /bin/sh -c 'echo RAN' 2>&1)"; st=$?
assert_contains     "$out" "expected key=value" "an argument without '=' before '--' is refused"
assert_not_contains "$out" "RAN"                "  -> and the command does not run"
if [ "$st" -ne 0 ]; then ok "  -> and exits non-zero"; else bad "  -> should exit non-zero (got $st)"; fi

out="$(scrubbed "$WRAP" =value -- /bin/sh -c 'echo RAN' 2>&1)"; st=$?
assert_contains     "$out" "non-empty" "an empty key is refused"
assert_not_contains "$out" "RAN"       "  -> and the command does not run"
if [ "$st" -ne 0 ]; then ok "  -> and exits non-zero"; else bad "  -> should exit non-zero (got $st)"; fi


# ---------------------------------------------------------------------------
summary

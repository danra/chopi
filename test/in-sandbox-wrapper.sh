#!/usr/bin/env bash
#
# test/in-sandbox-wrapper.sh -- unit tests for the in-sandbox wrapper: its
# git-config appending, its GitHub->relay reroute gate, and its run-the-command-then-cleanup
# teardown.

# shellcheck disable=SC2016  # GIT_CONFIG_* vars expand in the shell the wrapper execs, not in this script

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
. "$repo/.internal/util.sh"
. "$repo/test/lib.sh"

header "test/in-sandbox-wrapper.sh -- unit tests for the in-sandbox wrapper"

if ! command -v git >/dev/null 2>&1; then
    bad "in-sandbox-wrapper tests need git on PATH"
    summary
    exit
fi

WRAP="$repo/.internal/in-sandbox-wrapper.sh"

# Exported so the scripts under test leave their temporaries here too.
TMPDIR="$(mktemp -d)"; export TMPDIR
trap 'rm -rf "$TMPDIR"' EXIT

# The wrapper gates every run on the GitHub->relay reroute being effective under the ambient git
# config. For the config test cases, neutralize the developer's config and satisfy the gate by using
# a global config and running from a clean dir.
# The gate test cases later override GIT_CONFIG_GLOBAL, so the config setup here doesn't affect them.
export GIT_CONFIG_SYSTEM=/dev/null
relay="http://127.0.0.1:$GITHUB_RELAY_PORT"
relay_global_config="$TMPDIR/relay-global.gitconfig"
while IFS= read -r pair; do
    git config --file "$relay_global_config" --add "${pair%%=*}" "${pair#*=}"
done < <(github_relay_git_config)
export GIT_CONFIG_GLOBAL="$relay_global_config"
cd "$TMPDIR"

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
tmp="$(mktemp -d)"
git init -q "$tmp/r"
out="$(cd "$tmp/r" && env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=chopi.t GIT_CONFIG_VALUE_0=preexisting \
    "$WRAP" "$cleanup_script" chopi.t=appended -- git config chopi.t)"
assert_eq "$out" "appended" "git resolves a conflicting single-valued key to the APPENDED entry"


# ---------------------------------------------------------------------------
echo "run the command, then the cleanup, in the same (confined) process"
# ---------------------------------------------------------------------------
: > "$cleanup_marker"
out="$(scrubbed "$WRAP" "$cleanup_script" gc.auto=0 -- \
    /bin/sh -c 'echo "cfg=$GIT_CONFIG_COUNT:$GIT_CONFIG_KEY_0=$GIT_CONFIG_VALUE_0"')"; rc=$?
assert_zero "$rc"                              "the command's exit code propagates"
assert_eq "$out" "cfg=1:gc.auto=0"             "  -> git config is still forwarded"
assert_eq "$(cat "$cleanup_marker")" "CLEANUP" "  -> the cleanup runs afterward"

: > "$cleanup_marker"
rc=0; scrubbed "$WRAP" "$cleanup_script" a.b=c -- /bin/sh -c 'exit 7' || rc=$?
assert_eq "$rc" "7"                            "the wrapped command's exit code propagates"
assert_eq "$(cat "$cleanup_marker")" "CLEANUP" "  -> and the cleanup still runs"

# A missing command is still named and non-zero, now via the child-run path (not exec).
out=""; rc=0; out="$(scrubbed "$WRAP" "$cleanup_script" -- /no/such/cmd 2>&1)" || rc=$?
assert_contains "$out" "/no/such/cmd" "a missing command is named in the error"
assert_nonzero "$rc" "  -> and exits non-zero"

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
echo "editing the wrapper's own file mid-run does not affect the running wrapper"
# ---------------------------------------------------------------------------
# The wrapper blocks on the wrapped command for the whole session while bash keeps the script
# file open; when the file is edited meanwhile (routine when developing chopi from inside a
# chopi session), bash must not read the edited content -- resuming at a stale byte offset
# executes garbage and drops the command's exit code. The command edits a COPY of the wrapper
# (with the in-sandbox libs beside it), leaving the repo's own file alone.
edited_dir="$TMPDIR/edited-wrapper"; mkdir -p "$edited_dir"
for lib in "${CHOPI_IN_SANDBOX_LIBS[@]}"; do cp "$repo/.internal/$lib" "$edited_dir/"; done
cp "$WRAP" "$edited_dir/wrapper.sh"
leak_marker="$TMPDIR/leak-marker"; rm -f "$leak_marker"
rc=0; scrubbed "$edited_dir/wrapper.sh" "$cleanup_script" -- /bin/sh -c \
    "echo touch $leak_marker >> $edited_dir/wrapper.sh; exit 7" || rc=$?
assert_eq "$rc" "7" "the command's exit code propagates despite the mid-run edit"
assert_absent "$leak_marker" "  -> the line appended mid-run is never executed"


# ---------------------------------------------------------------------------
echo "the run is gated on the GitHub->relay reroute being effective"
# ---------------------------------------------------------------------------
relay_pairs=()
while IFS= read -r pair; do relay_pairs+=("$pair"); done < <(github_relay_git_config)
empty_global="$TMPDIR/empty.gitconfig"; : > "$empty_global"

out=""; rc=0
out="$(env -u GIT_CONFIG_COUNT GIT_CONFIG_GLOBAL="$empty_global" \
    "$WRAP" "$cleanup_script" "${relay_pairs[@]}" -- git ls-remote --get-url https://github.com/o/r)" || rc=$?
assert_zero "$rc"             "chopi's rewrites, passed as pairs, satisfy the gate"
assert_eq "$out" "$relay/o/r" "  -> and the command itself sees github rerouted to the relay"

# A competing insteadOf of the same prefix in an earlier-read scope (here: global) wins the
# longest-prefix tie against the appended command-scope rewrite, so github git would leave the
# relay -- the wrapper must refuse without running the command.
competing_global="$TMPDIR/competing.gitconfig"
printf '[url "git@github.com:"]\n\tinsteadOf = https://github.com/\n' > "$competing_global"
: > "$cleanup_marker"
out=""; rc=0
out="$(env -u GIT_CONFIG_COUNT GIT_CONFIG_GLOBAL="$competing_global" \
    "$WRAP" "$cleanup_script" "${relay_pairs[@]}" -- /bin/sh -c 'echo RAN' 2>&1)" || rc=$?
assert_contains     "$out" "overrides chopi's GitHub relay routing" "a competing insteadOf that overrides the reroute is refused"
assert_not_contains "$out" "RAN"                                    "  -> and the command does not run"
assert_nonzero "$rc" "  -> and exits non-zero"
assert_eq "$(cat "$cleanup_marker")" "" "  -> the cleanup is not run (no command ran)"


# ---------------------------------------------------------------------------
echo "the Claude-context refusal gate runs only for claude"
# ---------------------------------------------------------------------------
gate_dir="$TMPDIR/ctx-gate"; mkdir -p "$gate_dir/lib" "$gate_dir/ws"
for lib in "${CHOPI_IN_SANDBOX_LIBS[@]}"; do cp "$repo/.internal/$lib" "$gate_dir/lib/"; done
cp "$WRAP" "$gate_dir/lib/wrapper.sh"
cat >> "$gate_dir/lib/claude-context-check.sh" <<'EOF'
probe_read() {
    arity 1
    [ "$1" = "${CHOPI_TEST_DENY-}" ] && return "$PROBE_READ_DENIED"
    [ -f "$1" ] && return "$PROBE_READ_OK"
    return "$PROBE_READ_SKIP"
}
EOF
gate_real="$(cd "$gate_dir" && pwd -P)"
printf '@notes.md\n' > "$gate_dir/CLAUDE.md"
printf 'n\n'         > "$gate_dir/notes.md"
printf '#!/bin/sh\necho RAN\n' > "$gate_dir/claude"
chmod +x "$gate_dir/claude"

both=""; rc=0
both="$( (cd "$gate_dir/ws" && scrubbed CHOPI_TEST_DENY="$gate_real/notes.md" \
    "$gate_dir/lib/wrapper.sh" "$cleanup_script" -- "$gate_dir/claude") 2>&1 )" || rc=$?
assert_nonzero      "$rc"                         "claude is refused while a context @-import is unreadable"
assert_contains     "$both" "$gate_real/notes.md" "  -> listing the denied import"
assert_not_contains "$both" "RAN"                 "  -> and does not run"

out=""; rc=0
out="$( (cd "$gate_dir/ws" && scrubbed CHOPI_TEST_DENY="$gate_real/notes.md" \
    "$gate_dir/lib/wrapper.sh" "$cleanup_script" -- /bin/sh -c 'echo RAN') 2>&1 )" || rc=$?
assert_zero     "$rc"        "any other command runs despite the unreadable @-import"
assert_contains "$out" "RAN" "  -> the command itself runs"


# ---------------------------------------------------------------------------
echo "malformed input is refused before anything runs"
# ---------------------------------------------------------------------------
out="$(scrubbed "$WRAP" -- /bin/sh -c 'echo RAN' 2>&1)"; st=$?
assert_contains     "$out" "invalid" "a run without CLEANUP_SCRIPT_PATH is refused"
assert_not_contains "$out" "RAN"   "  -> and the command does not run"
assert_nonzero "$st" "  -> and exits non-zero"

out="$(env GIT_CONFIG_COUNT=nope "$WRAP" "$cleanup_script" a.b=c -- /bin/sh -c 'echo RAN' 2>&1)"; st=$?
assert_contains     "$out" "integer" "a non-integer pre-existing GIT_CONFIG_COUNT is refused"
assert_not_contains "$out" "RAN"     "  -> and the command does not run"
assert_nonzero "$st" "  -> and exits non-zero"

out="$(scrubbed "$WRAP" "$cleanup_script" a.b=c 2>&1)"; st=$?
assert_contains "$out" "no command given" "pairs without '-- <command>' are refused"
assert_nonzero "$st" "  -> and exits non-zero"

out="$(scrubbed "$WRAP" "$cleanup_script" notapair -- /bin/sh -c 'echo RAN' 2>&1)"; st=$?
assert_contains     "$out" "expected key=value" "an argument without '=' before '--' is refused"
assert_not_contains "$out" "RAN"                "  -> and the command does not run"
assert_nonzero "$st" "  -> and exits non-zero"

out="$(scrubbed "$WRAP" "$cleanup_script" =value -- /bin/sh -c 'echo RAN' 2>&1)"; st=$?
assert_contains     "$out" "non-empty" "an empty key is refused"
assert_not_contains "$out" "RAN"       "  -> and the command does not run"
assert_nonzero "$st" "  -> and exits non-zero"


# ---------------------------------------------------------------------------
summary

#!/usr/bin/env bash
#
# test/lead-group.sh -- unit tests for lead_group, which runs a command at the head of its own
# process group

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo/.internal/util.sh"
. "$repo/test/lib.sh"
set +euo pipefail

header "test/lead-group.sh -- unit tests for .internal/util.sh's lead_group"

TMPDIR="$(mktemp -d)"; export TMPDIR
trap 'rm -rf "$TMPDIR"' EXIT

# Each lead_group runs in a shell with `set -euo pipefail`, as chopi-proxy runs it: a failing
# command lead_group leaves unguarded would end it there, skipping the rest of its work.


# ---------------------------------------------------------------------------
echo "process group (lead_group stops what it leads, and nothing of its caller's)"
# ---------------------------------------------------------------------------
# lead_group's caller, and anything else in its group, outlive it. The caller is put in a group of
# its own, for a lead_group stopping that group not to stop this script too.
out="$(bash -c 'set -m; bash -c "bash -c \"set -euo pipefail; . \\\"\$1\\\"; lead_group true\" _ \"\$1\"; echo survived" _ "$1" & wait $!' \
    _ "$repo/.internal/util.sh" 2>/dev/null)"
assert_contains "$out" "survived" "lead_group leaves its caller's process group alone"

# A helper COMMAND leaves running as it exits (Caddy, after a crash) is stopped with it.
helper_pid_file="$TMPDIR/lead-group-helper"
bash -c 'set -m; bash -c "set -euo pipefail; . \"\$1\"; lead_group sh -c \"sleep 30 & echo \\\$! > \\\"\\\$1\\\"\" sh \"\$2\"" _ "$1" "$2" & wait $!' \
    _ "$repo/.internal/util.sh" "$helper_pid_file" 2>/dev/null
helper="$(cat "$helper_pid_file")"
assert_pid_exits "$helper" "a helper COMMAND left running is stopped as COMMAND exits"

# A stand-in for a COMMAND that handles its stop signals itself, as chopi-smokescreen and Caddy do:
# once ready it touches the file READY, and it writes the signals it got, up to a moment past its
# first TERM, to the file LOG.
#
# usage: python3 -I -c "$signal_recorder" LOG READY
signal_recorder='
import signal, sys, time
log, ready = sys.argv[1:]
got = []
signal.signal(signal.SIGINT, lambda sig, _: got.append(sig))
signal.signal(signal.SIGTERM, lambda sig, _: got.append(sig))
open(ready, "w").close()
for _ in range(300):
    if signal.SIGTERM in got:
        break
    time.sleep(0.1)
time.sleep(0.2)  # for a signal that comes with the TERM
open(log, "w").write(" ".join(signal.Signals(sig).name for sig in got))
'

# A Ctrl-C, sent to the terminal's whole foreground group, reaches COMMAND only as the one TERM
# lead_group passes on: had it its own INT too, it (or Caddy) could stop in a way of its own first.
# COMMAND handles INT itself, as chopi-smokescreen and Caddy do, so an INT that reached it shows.
signals_file="$TMPDIR/lead-group-signals"
ready_file="$TMPDIR/lead-group-ready"
(
    set -m
    bash -c 'set -euo pipefail; . "$1"; lead_group python3 -I -c "$2" "$3" "$4"' lead "$repo/.internal/util.sh" "$signal_recorder" "$signals_file" "$ready_file" &
    leader=$!
    for _ in {1..50}; do [ -e "$ready_file" ] && break; sleep 0.1; done
    kill -INT -- "-$leader"
    wait "$leader"
) 2>/dev/null
assert_eq "$(cat "$signals_file" 2>/dev/null)" "SIGTERM" "a Ctrl-C reaches COMMAND as one TERM, not as its own INT"

# A stop signal sent to the leader alone (a plain `kill <chopi-proxy pid>`) must stop what it leads
# too: left behind, chopi-smokescreen and Caddy would serve on, with the GitHub token, unsupervised.
for sig in TERM HUP; do
    child_pid_file="$TMPDIR/lead-group-child-$sig"
    (
        set -m
        bash -c 'set -euo pipefail; . "$1"; lead_group sh -c "echo \$\$ > \"\$1\"; exec sleep 30" sh "$2"' \
            lead "$repo/.internal/util.sh" "$child_pid_file" &
        leader=$!
        for _ in {1..50}; do [ -s "$child_pid_file" ] && break; sleep 0.1; done
        kill -"$sig" "$leader"
        wait "$leader"
    ) 2>/dev/null
    child="$(cat "$child_pid_file")"
    assert_pid_exits "$child" "SIG$sig to lead_group's leader stops what it leads"
done

# A stop signal that comes as COMMAND starts, before lead_group has its pid, must still stop it. A
# DEBUG trap sends the signal just as COMMAND is forked, right before `pid=$!`, and records `$!`
# only once lead_group waits, not to hold up the signal's passing on. If the trap never fires, no
# pid is recorded and the check fails too. COMMAND is a shell function, as chopi-proxy's
# run_smokescreen is, and runs under macOS's bash 3.2 too. We wait for the pid alone, not for
# lead_group: were the signal dropped, COMMAND would end by itself in time, and pass for stopped.
for shell in bash /bin/bash; do
    child_pid_file="$TMPDIR/lead-group-early"
    rm -f "$child_pid_file"
    (
        set -m
        # shellcheck disable=SC2016 # expanded by the inner shell
        "$shell" -c '
            set -euo pipefail; . "$1"; child_pid_file="$2"
            hook() {
                case "$BASH_COMMAND" in
                    "pid=\$!") kill -TERM "$$" ;;
                    wait*) echo "$!" > "$child_pid_file" ;;
                esac
            }
            stand_in() { sleep 30; }
            set -T
            trap hook DEBUG
            lead_group stand_in
        ' lead "$repo/.internal/util.sh" "$child_pid_file" &
        for _ in {1..50}; do [ -s "$child_pid_file" ] && break; sleep 0.1; done
    ) 2>/dev/null
    assert_pid_exits "$(cat "$child_pid_file" 2>/dev/null)" \
        "a stop signal as COMMAND starts stops it ($shell)"
done

# A stop signal that comes once lead_group has COMMAND's pid, but before it checks for one that
# came earlier, must reach COMMAND as one TERM, not as one from the trap and another from that
# check: a second stop signal makes many a program (a Go server such as chopi-smokescreen) quit at
# once, skipping its orderly shutdown. A DEBUG trap sends the signal right after `pid=$!`, once
# COMMAND is ready to count what it gets.
signals_file="$TMPDIR/lead-group-once-signals"
ready_file="$TMPDIR/lead-group-once-ready"
(
    set -m
    # shellcheck disable=SC2016 # expanded by the inner shell
    bash -c '
        set -euo pipefail; . "$1"; ready_file="$4"
        hook() {
            [ "$BASH_COMMAND" = "set +m" ] || return 0
            for _ in {1..50}; do [ -e "$ready_file" ] && break; sleep 0.1; done
            kill -TERM "$$"
        }
        set -T
        trap hook DEBUG
        lead_group python3 -I -c "$2" "$3" "$4"
    ' lead "$repo/.internal/util.sh" "$signal_recorder" "$signals_file" "$ready_file" &
    wait $!
) 2>/dev/null
assert_eq "$(cat "$signals_file" 2>/dev/null)" "SIGTERM" \
    "a stop signal right after COMMAND starts reaches it as one TERM"

# A stop signal passed on to COMMAND cuts lead_group's wait short. lead_group's exit status must
# still be COMMAND's, not the interrupted wait's 143. Here COMMAND exits 0 on the TERM. A `kill`
# that lingers after sending keeps lead_group's trap busy until COMMAND has exited, so COMMAND is
# gone by the time the cut-short wait returns.
ready_file="$TMPDIR/lead-group-status-ready"
st=0
(
    set -m
    # shellcheck disable=SC2016 # expanded by the inner shell
    bash -c '
        set -euo pipefail; . "$1"
        kill() { local st=0; builtin kill "$@" || st=$?; sleep 0.1; return "$st"; }
        lead_group python3 -I -c "$2" "$3"
    ' lead "$repo/.internal/util.sh" '
import signal, sys, time
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
open(sys.argv[1], "w").close()
time.sleep(30)
' "$ready_file" &
    leader=$!
    for _ in {1..50}; do [ -e "$ready_file" ] && break; sleep 0.1; done
    kill -TERM "$leader"
    wait "$leader"
) 2>/dev/null || st=$?
assert_zero "$st" "a stop signal passed on leaves lead_group with COMMAND's own status"

# chopi-smokescreen leads its group, for Caddy to go with it however it goes: here a stand-in for
# Caddy, which COMMAND starts, left in the group as COMMAND is killed outright.
st=0
(
    set -m
    # shellcheck disable=SC2016 # expanded by the inner shells
    bash -c 'set -euo pipefail; . "$1"; lead_group sh -c "sleep 30 & echo \$! > \"\$1\"; kill -KILL \$\$" sh "$2"' \
        _ "$repo/.internal/util.sh" "$TMPDIR/lead-child" &
    wait $!
) 2>/dev/null || st=$?
assert_eq "$st" 137 "lead_group exits with its command's status, a SIGKILL's included"
assert_pid_exits "$(cat "$TMPDIR/lead-child")" "  -> stopping the rest of its group"

# A COMMAND that leaves no helper behind leaves no group to stop: lead_group must still exit with
# its status.
st=0
bash -c 'set -euo pipefail; . "$1"; lead_group sh -c "exit 3"' _ "$repo/.internal/util.sh" \
    2>/dev/null || st=$?
assert_eq "$st" 3 "lead_group exits with its command's status, its group gone with it"

# ---------------------------------------------------------------------------
summary

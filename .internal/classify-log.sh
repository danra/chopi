# shellcheck shell=bash
#
# classify-log.sh -- the smokescreen-log classifier, shared by the proxy and its tests.
#
# smokescreen's combined output arrives line by line, and each line is routed through a
# cascade of single-purpose jq filters -- each in its own .internal/*.jq file so it can be
# unit-tested in isolation -- rather than one filter that branches internally and packs its
# result into a delimited record for the shell to re-split:
#
#   connection-request.jq  an ACL decision (a connection smokescreen evaluated)?
#     yes -> deny-host.jq   denied? -> name the host: run the deny hook, format-deny.jq prints it
#                           allowed -> nothing to show, drop it
#     no  -> format-misc.jq drop the known noise, pass anything else through unchanged
#
# That is a couple of extra jq invocations per line, which is nothing at log volumes, in
# exchange for filters that each do exactly one thing.
#
# Both the live proxy (bin/chopi-proxy.sh) and the unit tests source this file and call
# classify_log, so the tests exercise the real routing rather than a copy that can drift.

# The filter files sit next to this one in .internal/. Resolve them from this file's own
# location so each path is written once; the proxy checks they exist (a missing one is a
# broken checkout, not user misconfiguration).
_classify_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONNECTION_FILTER="$_classify_dir/connection-request.jq"
DENY_HOST_FILTER="$_classify_dir/deny-host.jq"
FORMAT_DENY_FILTER="$_classify_dir/format-deny.jq"
FORMAT_MISC_FILTER="$_classify_dir/format-misc.jq"
unset _classify_dir

# classify_log <is_interactive> <script> <on_deny_cmd>
#
# Read smokescreen log lines on stdin; write the display output to stdout, one line in to
# zero-or-one line out (empty == the line is dropped).
#
#   <is_interactive>  true/false -- enables the DENY bell + red color in format-deny.jq;
#                     both are noise in a file or a pipe, so the proxy passes the result of
#                     its own `[ -t 1 ]` and the tests drive both values explicitly.
#   <script>          name shown in the "[<script>] DENY host @ time" prefix.
#   <on_deny_cmd>     called as `<on_deny_cmd> <host>` once per denied connection, or ""
#                     for none. The proxy passes notify_deny (pops a macOS banner); the
#                     tests pass "" so a test run never fires real notifications.
#
# The `|| [ -n "$line" ]` tail flushes a final line that arrives without a trailing newline.
#
# Every per-line jq pipeline is guarded so a single line's failure surfaces the raw line and the
# loop continues, rather than aborting. The live proxy runs this inside `> >(...)` under its own
# `set -euo pipefail`, so an unguarded jq that exits non-zero (a .internal/*.jq filter edited or
# removed while the long-lived proxy runs, a SIGPIPE, an OOM-kill) would trip errexit and kill the
# consumer for good -- silencing every later DENY. Degraded formatting on a broken line is fine; a
# silently dropped DENY is not, so a failed classifier always errs toward surfacing the raw line.
classify_log() {
    arity 3
    local is_interactive="$1" script="$2" on_deny="$3" line host
    while IFS= read -r line || [ -n "$line" ]; do
        if [ -n "$(printf '%s\n' "$line" | jq -R -r -f "$CONNECTION_FILTER")" ]; then
            # deny-host.jq decides deny-or-allow; if it fails we can't tell, so surface the raw
            # line (fail-safe) rather than guessing ALLOW and dropping a possible DENY.
            if ! host=$(printf '%s\n' "$line" | jq -R -r -f "$DENY_HOST_FILTER"); then
                printf '%s\n' "$line"
                continue
            fi
            if [ -n "$host" ]; then
                [ -n "$on_deny" ] && "$on_deny" "$host"
                printf '%s\n' "$line" | jq -R -r \
                    --argjson is_interactive "$is_interactive" --arg script "$script" \
                    --arg host "$host" \
                    -f "$FORMAT_DENY_FILTER" || printf '%s\n' "$line"
            fi
        else
            printf '%s\n' "$line" | jq -R -r -f "$FORMAT_MISC_FILTER" || printf '%s\n' "$line"
        fi
    done
}

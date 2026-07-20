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
#     yes -> deny-host.jq   denied? -> name the host, then known-deny.jq splits the denials
#                             (format-deny.jq renders both flavors):
#                             on the configured denylist -> one plain "deny(known)" line
#                               per host per session, no deny hook
#                             anything else -> run the deny hook, print a loud DENY line
#                           allowed -> nothing to show, drop it
#     no  -> format-reload.jq a rules hot-reload line? render it: plain for a reload,
#                           loud for a failed one (the previous rules stay in effect)
#       no  -> format-misc.jq drop the known noise, pass anything else through unchanged
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
KNOWN_DENY_FILTER="$_classify_dir/known-deny.jq"
FORMAT_DENY_FILTER="$_classify_dir/format-deny.jq"
FORMAT_RELOAD_FILTER="$_classify_dir/format-reload.jq"
FORMAT_MISC_FILTER="$_classify_dir/format-misc.jq"
JQ_LIB_DIR="$_classify_dir"
unset _classify_dir

# emit the raw line, unless verbose mode already printed it
surface_raw() {
    arity 2
    local verbose="$1" line="$2"
    [ "$verbose" = true ] || printf '%s\n' "$line"
}

# Returns 1 iff a denylist-matching host was already logged this session
known_deny_seen() {
    arity 1
    local host="$1" seen
    for seen in "${known_seen[@]:-}"; do
        if [ "$seen" = "$host" ]; then return 0; fi
    done
    return 1
}

# classify_log <is_interactive> <script> <on_deny_cmd> <verbose>
#
# Read smokescreen log lines on stdin; write the display output to stdout, one line in to
# zero-or-one line out (empty == the line is dropped) -- or, in verbose mode, one-or-two.
#
#   <is_interactive>  true/false -- enables the DENY bell + red color in format-deny.jq;
#                     both are noise in a file or a pipe, so the proxy passes the result of
#                     its own `[ -t 1 ]` and the tests drive both values explicitly.
#   <script>          name shown in the "[<script>] DENY host @ time" prefix.
#   <on_deny_cmd>     called as `<on_deny_cmd> <host>` once per denied connection -- except
#                     known denies, see below -- or "" for none. The proxy passes notify_deny
#                     (pops a macOS banner); the tests pass "" so a test run never fires
#                     real notifications.
#   <verbose>         true/false -- when true, nothing is dropped or replaced: every raw
#                     smokescreen line is passed through as-is, interleaved with chopi-proxy's
#                     own output. Normally-dropped lines (allowed connections, known noise)
#                     become visible, and a DENY's formatted line is emitted *after* its raw
#                     line rather than in place of it.
#
# Denials of hosts matching the configured denylist (smokescreen's global_deny_list, recognized
# by known-deny.jq) are *known* denies -- the user listed the host precisely because its
# blocked traffic is expected -- so they stay quiet: no <on_deny_cmd>, no color, and a
# single plain "deny(known)" line per host per session, with the repeats dropped (their
# raw lines still show in verbose mode). The classification errs loud: only a line
# known-deny.jq is certain about takes the quiet route.
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
    arity 4
    local is_interactive="$1" script="$2" on_deny="$3" verbose="$4" line host known reload_line
    # Hosts whose denylist denial was already logged this session (read by known_deny_seen)
    local -a known_seen=()
    while IFS= read -r line || [ -n "$line" ]; do
        [ "$verbose" = true ] && printf '%s\n' "$line"
        if [ -n "$(printf '%s\n' "$line" | jq -R -r -f "$CONNECTION_FILTER")" ]; then
            # deny-host.jq decides deny-or-allow; if it fails we can't tell, so surface the
            # raw line (fail-safe) rather than guessing ALLOW and dropping a possible DENY.
            if ! host=$(printf '%s\n' "$line" | jq -R -r -f "$DENY_HOST_FILTER"); then
                surface_raw "$verbose" "$line"
                continue
            fi
            if [ -n "$host" ]; then
                # known-deny.jq decides known-or-not; if it fails we can't tell, so take the
                # loud path (fail-safe) rather than guessing known and swallowing an alert.
                known=$(printf '%s\n' "$line" | jq -R -r -f "$KNOWN_DENY_FILTER") || known=""
                if [ -n "$known" ]; then
                    if known_deny_seen "$host"; then continue; fi
                    known_seen+=("$host")
                else
                    [ -n "$on_deny" ] && "$on_deny" "$host"
                fi
                printf '%s\n' "$line" | jq -R -r -L "$JQ_LIB_DIR" \
                    --argjson is_interactive "$is_interactive" --arg script "$script" \
                    --arg host "$host" --arg known "$known" \
                    -f "$FORMAT_DENY_FILTER" || surface_raw "$verbose" "$line"
            fi
        elif [[ "$line" == *'"msg":"egress ACL reload'* ]] && \
             reload_line=$(printf '%s\n' "$line" | jq -R -r -L "$JQ_LIB_DIR" \
                --argjson is_interactive "$is_interactive" --arg script "$script" \
                -f "$FORMAT_RELOAD_FILTER") && [ -n "$reload_line" ]; then
            printf '%s\n' "$reload_line"
        elif [ "$verbose" != true ]; then
            printf '%s\n' "$line" | jq -R -r -f "$FORMAT_MISC_FILTER" || surface_raw "$verbose" "$line"
        fi
    done
}

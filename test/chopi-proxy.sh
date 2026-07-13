#!/usr/bin/env bash
#
# test/chopi-proxy.sh -- unit tests for chopi's proxy

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo/.internal/util.sh"
. "$repo/test/lib.sh"
. "$repo/.internal/classify-log.sh"
BEL="$(printf '\007')"   # U+0007 BEL: format-deny.jq prefixes an interactive DENY with it
ESC="$(printf '\033')"   # U+001B ANSI escape: introduces the DENY color code
set +euo pipefail

header "test/chopi-proxy.sh -- unit tests for bin/chopi-proxy.sh's log logic + proxy-port invariant"

# Exported so the scripts under test leave their temporaries here too.
TMPDIR="$(mktemp -d)"; export TMPDIR
trap 'rm -rf "$TMPDIR"' EXIT


# ---------------------------------------------------------------------------
echo "log classifier (connection-request / deny-host / format-deny / format-misc)"
# ---------------------------------------------------------------------------
# The security property under test: a DENY is always surfaced, never silently dropped.
# The classifier is fail-safe by design: anything ambiguous is surfaced as a DENY rather
# than dropped as an ALLOW, and the edge cases below pin that down.
classify() {
    arity 1
    local is_interactive="$1"
    classify_log "$is_interactive" "chopi-proxy.sh" "" false
}

out="$(printf '%s\n' '{"allow":false,"requested_host":"evil.com","time":"T"}' | classify false)"
assert_eq "$out" "[chopi-proxy.sh] DENY  evil.com  @ T" "DENY -> formatted deny line naming the host"

out="$(printf '%s\n' '{"allow":false}' | classify false)"
assert_eq "$out" "[chopi-proxy.sh] DENY  ?  @ ?" "DENY missing host/time -> '?' placeholders"

out="$(printf '%s\n' '{"allow":false,"requested_host":""}' | classify false)"
assert_eq "$out" "[chopi-proxy.sh] DENY  ?  @ ?" "DENY with empty-string host -> '?' placeholders"

# A whitespace-only host (here a lone newline) must still surface as a DENY, never be dropped.
# The host collapses to "?" so classify_log's command substitution can't strip the decision to
# empty and swallow the line.
out="$(printf '%s\n' '{"allow":false,"requested_host":"\n","time":"T"}' | classify false)"
assert_eq "$out" "[chopi-proxy.sh] DENY  ?  @ T" "DENY with whitespace-only host -> surfaced with '?' (never dropped)"

out="$(printf '%s\n' '{"allow":false,"requested_host":"x.io","time":"T"}' | classify true)"
assert_prefix "$out" "$BEL" "interactive DENY is prefixed with a BEL (dock badge)"
assert_contains "$out" "${ESC}[31m" "interactive DENY is ANSI-colored red"
assert_contains "$out" "DENY" "interactive DENY still names the decision"
assert_contains "$out" "x.io" "interactive DENY still names the host"

out="$(printf '%s\n' '{"allow":true,"requested_host":"ok.com"}' | classify false)"
assert_eq "$out" "" "allowed connection -> dropped"

out="$(printf '%s\n' '{"bytes_in":1,"bytes_out":2}' | classify false)"
assert_eq "$out" "" "connection-close (bytes_in) -> dropped"

out="$(printf '%s\n' 'time="x" level=warning msg="no statsd addr provided, using a noop client"' | classify false)"
assert_eq "$out" "" "statsd startup warning -> dropped"

out="$(printf '%s\n' '{"msg":"no statsd addr provided, using a noop client"}' | classify false)"
assert_eq "$out" "" "statsd warning as JSON object -> dropped (matched on raw text)"

out="$(printf '%s\n' 'goproxy: WARN: Error copying to client: read tcp: connection reset by peer' | classify false)"
assert_eq "$out" "" "client-hangup relay-copy warning -> dropped"

passthrough_line='some smokescreen startup line'
out="$(printf '%s\n' "$passthrough_line" | classify false)"
assert_eq "$out" "$passthrough_line" "unknown line -> passed through unchanged"

passthrough_json='{"level":"info","msg":"booting"}'
out="$(printf '%s\n' "$passthrough_json" | classify false)"
assert_eq "$out" "$passthrough_json" "unknown JSON object -> passed through unchanged"

# A DENY must never be silently dropped: of a mixed batch, exactly the one DENY survives.
out="$(printf '%s\n' \
        '{"allow":true,"requested_host":"ok.com"}' \
        '{"bytes_in":1}' \
        '{"allow":false,"requested_host":"blocked.example","time":"T"}' \
        'WARN: Error copying to client' \
      | classify false)"
assert_eq "$out" "[chopi-proxy.sh] DENY  blocked.example  @ T" "mixed batch -> only the DENY is emitted"

# The live proxy runs classify_log inside `> >(format_smokescreen_log)`, a consumer subshell
# that inherits chopi-proxy.sh's `set -euo pipefail`. A single jq failure on one line -- a
# filter edited/removed mid-run, a SIGPIPE, an OOM-kill -- must NOT trip errexit and abort the
# loop, which would silence every later DENY for the life of the proxy. Reproduce it under a
# real `set -e` by pointing one filter at a jq program that errors on a poison line, then feed
# a genuine DENY *after* it: the DENY must still surface. (These unit tests otherwise run with
# errexit off, so `set -e` is re-enabled inside the subshell to match the proxy.)
poison_filter="$(mktemp)"
printf '%s\n' 'if . == "POISON-LINE" then error("simulated jq failure") else . end' > "$poison_filter"
out="$(
    set -euo pipefail
    FORMAT_MISC_FILTER="$poison_filter"
    printf '%s\n' 'POISON-LINE' '{"allow":false,"requested_host":"late.example","time":"T"}' \
        | classify_log false "chopi-proxy.sh" "" false
)"
assert_contains "$out" "[chopi-proxy.sh] DENY  late.example  @ T" \
    "a jq failure on one line does not abort the loop and silence later DENYs (under set -e)"


# ---------------------------------------------------------------------------
echo "verbose mode (--verbose: nothing dropped or replaced)"
# ---------------------------------------------------------------------------
# With verbose on, every raw smokescreen line is passed through: normally-dropped lines
# (allowed connections, known noise) become visible, and a DENY's raw line is emitted
# *before* the formatted line that normally replaces it. The deny hook still fires (tests
# pass "" so nothing pops).
classify_verbose() {
    arity 1
    local is_interactive="$1"
    classify_log "$is_interactive" "chopi-proxy.sh" "" true
}

deny_raw='{"allow":false,"requested_host":"evil.com","time":"T"}'
out="$(printf '%s\n' "$deny_raw" | classify_verbose false)"
assert_eq "$out" "$deny_raw
[chopi-proxy.sh] DENY  evil.com  @ T" "verbose DENY -> raw line, then the formatted deny line after it"

out="$(printf '%s\n' '{"allow":true,"requested_host":"ok.com"}' | classify_verbose false)"
assert_eq "$out" '{"allow":true,"requested_host":"ok.com"}' "verbose allowed connection -> raw line surfaced (not dropped)"

noise='time="x" level=warning msg="no statsd addr provided, using a noop client"'
out="$(printf '%s\n' "$noise" | classify_verbose false)"
assert_eq "$out" "$noise" "verbose known noise -> raw line surfaced (not dropped)"

passthrough='some smokescreen startup line'
out="$(printf '%s\n' "$passthrough" | classify_verbose false)"
assert_eq "$out" "$passthrough" "verbose unknown line -> surfaced exactly once (not doubled)"

# The whole cascade at once: every raw line is kept in order, and the lone DENY gains its
# formatted line right after its raw line -- nothing is dropped or replaced.
out="$(printf '%s\n' \
        '{"allow":true,"requested_host":"ok.com"}' \
        '{"bytes_in":1}' \
        '{"allow":false,"requested_host":"blocked.example","time":"T"}' \
        'WARN: Error copying to client' \
      | classify_verbose false)"
assert_eq "$out" '{"allow":true,"requested_host":"ok.com"}
{"bytes_in":1}
{"allow":false,"requested_host":"blocked.example","time":"T"}
[chopi-proxy.sh] DENY  blocked.example  @ T
WARN: Error copying to client' "verbose mixed batch -> every raw line kept in order, DENY also formatted after its raw line"


# ---------------------------------------------------------------------------
echo "known denies (denylist matches: quiet, once per host, no notification)"
# ---------------------------------------------------------------------------
# A deny whose decision_reason is smokescreen's denylist verdict is one the user asked for
# by listing the host: it gets a single plain "deny(known)" line per host per session --
# no bell, no color, no deny hook -- and every other deny stays exactly as loud as before.
known_deny='{"allow":false,"decision_reason":"host matched rule in global deny list","requested_host":"tele.example:443","time":"T"}'
unknown_deny='{"allow":false,"decision_reason":"default rule policy used","requested_host":"tele.example:443","time":"T2"}'

out="$(printf '%s\n' "$known_deny" | classify false)"
assert_eq "$out" "[chopi-proxy.sh] deny(known)  tele.example:443  @ T" "known deny -> plain deny(known) line naming the host"

out="$(printf '%s\n' "$known_deny" | classify true)"
assert_eq "$out" "[chopi-proxy.sh] deny(known)  tele.example:443  @ T" "interactive known deny -> still plain (no BEL, no color)"

out="$(printf '%s\n' "$unknown_deny" | classify false)"
assert_eq "$out" "[chopi-proxy.sh] DENY  tele.example:443  @ T2" "a deny with any other decision_reason -> loud DENY as before"

# The deny hook (the macOS notification in the live proxy) fires for unknown denies only.
record_deny() { arity 1; printf 'HOOK:%s\n' "$1"; }
out="$(printf '%s\n' "$known_deny" | classify_log false "chopi-proxy.sh" record_deny false)"
assert_not_contains "$out" "HOOK:" "known deny does NOT fire the deny hook (no notification)"
out="$(printf '%s\n' "$unknown_deny" | classify_log false "chopi-proxy.sh" record_deny false)"
assert_contains "$out" "HOOK:tele.example:443" "unknown deny still fires the deny hook"

# Once per host per session: a repeat is silent, a different host gets its own line.
out="$(printf '%s\n' "$known_deny" "$known_deny" | classify false)"
assert_eq "$out" "[chopi-proxy.sh] deny(known)  tele.example:443  @ T" "repeated known deny of the same host -> logged once"

known_deny_other='{"allow":false,"decision_reason":"host matched rule in global deny list","requested_host":"other.example:443","time":"T3"}'
out="$(printf '%s\n' "$known_deny" "$known_deny_other" | classify false)"
assert_eq "$out" "[chopi-proxy.sh] deny(known)  tele.example:443  @ T
[chopi-proxy.sh] deny(known)  other.example:443  @ T3" "known denies of two different hosts -> one line each"

# The seen-set only mutes known denies: the same host denied again by another rule is loud.
# (never expecting such a case currently; will be possible in the future if we make the proxy's lists hot-reloadable)
out="$(printf '%s\n' "$known_deny" "$unknown_deny" | classify false)"
assert_eq "$out" "[chopi-proxy.sh] deny(known)  tele.example:443  @ T
[chopi-proxy.sh] DENY  tele.example:443  @ T2" "an unknown deny of an already-seen host is still loud"

# Verbose keeps its contract: every raw line survives, and the formatted deny(known) line
# still appears only once -- a repeat shows as its raw line alone.
out="$(printf '%s\n' "$known_deny" "$known_deny" | classify_verbose false)"
assert_eq "$out" "$known_deny
[chopi-proxy.sh] deny(known)  tele.example:443  @ T
$known_deny" "verbose repeated known deny -> raw lines always, formatted line once"

# A real smokescreen denylist line, verbatim from a live run.
real_line='{"allow":false,"content_length":115,"decision_reason":"host matched rule in global deny list","dns_lookup_time_ms":0,"enforce_would_deny":true,"id":"d95k1d4k4keehrrdmagg","inbound_remote_addr":"127.0.0.1:60749","level":"warning","msg":"CANONICAL-PROXY-DECISION","project":"","proxy_type":"connect","requested_host":"http-intake.logs.us5.datadoghq.com:443","role":"","start_time":"2026-07-06T05:44:20.961655Z","time":"2026-07-05T22:44:20-07:00","trace_id":""}'
out="$(printf '%s\n' "$real_line" | classify false)"
assert_eq "$out" "[chopi-proxy.sh] deny(known)  http-intake.logs.us5.datadoghq.com:443  @ 2026-07-05T22:44:20-07:00" \
    "a real smokescreen denylist line -> deny(known)"

# Fail-safe under the live proxy's `set -e`: if known-deny.jq itself fails we can't tell
# known from unknown, so the deny goes the LOUD path -- a broken classifier must never
# mute an alert -- and the loop survives to process later lines.
poison_filter="$(mktemp)"
printf '%s\n' 'error("simulated jq failure")' > "$poison_filter"
out="$(
    set -euo pipefail
    # shellcheck disable=SC2030 # deliberately subshell-local: the real filter must survive for later tests
    KNOWN_DENY_FILTER="$poison_filter"
    printf '%s\n' "$known_deny" '{"allow":false,"requested_host":"late.example","time":"T"}' \
        | classify_log false "chopi-proxy.sh" "" false
)"
assert_eq "$out" "[chopi-proxy.sh] DENY  tele.example:443  @ T
[chopi-proxy.sh] DENY  late.example  @ T" \
    "a known-deny.jq failure -> the deny surfaces LOUD and the loop continues (under set -e)"


# ---------------------------------------------------------------------------
echo "log classifier building blocks (connection-request / deny-host / known-deny)"
# ---------------------------------------------------------------------------
# The building blocks, each on its own. connection-request.jq gates the chain; deny-host.jq
# is the single security-critical step that decides denied-or-not and names the host;
# known-deny.jq decides whether a deny may go the quiet route.
conn()       { jq -R -r -f "$CONNECTION_FILTER"; }
deny_host()  { jq -R -r -f "$DENY_HOST_FILTER"; }
# shellcheck disable=SC2031 # the poison test above overrode this in a subshell on purpose; here it is intact
known_deny() { jq -R -r -f "$KNOWN_DENY_FILTER"; }

assert_eq "$(printf '%s\n' '{"allow":false,"requested_host":"e.com"}' | conn)" "1"  "deny is a connection request"
assert_eq "$(printf '%s\n' '{"allow":true,"requested_host":"ok.com"}' | conn)" "1"  "allow is a connection request"
assert_eq "$(printf '%s\n' '{"bytes_in":1}' | conn)"                          ""   "connection-close is NOT a connection request"
assert_eq "$(printf '%s\n' '{"level":"info"}' | conn)"                        ""   "JSON without allow is NOT a connection request"
assert_eq "$(printf '%s\n' 'some startup line' | conn)"                       ""   "non-JSON line is NOT a connection request"

assert_eq "$(printf '%s\n' '{"allow":false,"requested_host":"evil.com"}' | deny_host)" "evil.com" "denied connection -> host named"
assert_eq "$(printf '%s\n' '{"allow":false}' | deny_host)"                             "?"        "denied connection missing host -> '?'"
assert_eq "$(printf '%s\n' '{"allow":true,"requested_host":"ok.com"}' | deny_host)"    ""         "allowed connection -> no host (no notification)"

# conn() edge cases
assert_eq "$(printf '%s\n' '{"allow":null}' | conn)"               "1"  "allow:null is still a connection request (key presence, not value)"
assert_eq "$(printf '%s\n' '{"allowed":false}' | conn)"            ""   "a different key ('allowed') is NOT a connection request"
assert_eq "$(printf '%s\n' '{"data":{"allow":false}}' | conn)"     ""   "a nested 'allow' is NOT a top-level connection request"
assert_eq "$(printf '%s\n' '[{"allow":false}]' | conn)"            ""   "a JSON array (even one wrapping an allow) is NOT a connection request"
assert_eq "$(printf '%s\n' '42' | conn)"                           ""   "a bare JSON scalar is NOT a connection request"
assert_eq "$(printf '%s\n' '   {"allow":false,"requested_host":"e.com"}' | conn)" "1" "leading whitespace still parses (fromjson tolerates it)"
assert_eq "$(printf '%s\n' '{"allow":false' | conn)"               ""   "truncated/malformed JSON is NOT a connection request (try/catch swallows it)"

# deny_host() edge cases. deny-host.jq is fail-safe by design: it drops a line as a clean ALLOW
# *only* for a single "allow" key whose value is the boolean true; every other shape is surfaced
# as a DENY (named by a non-empty requested_host, else "?"). If we actually witness spurious
# DENYs we can investigate and possibly fix; an unexpectedly weird DENY slipping through unlogged
# is worse.
assert_eq "$(printf '%s\n' '{"allow":null}' | deny_host)"                                        "?"         "a null decision is surfaced as a DENY, not dropped (fail-safe)"
assert_eq "$(printf '%s\n' '{"allow":false,"requested_host":null}' | deny_host)"                 "?"         "explicit null host -> '?' placeholder"
assert_eq "$(printf '%s\n' '{"allow":false,"requested_host":"e.com:443"}' | deny_host)"          "e.com:443" "a host:port is named verbatim"

# (1) Duplicate "allow" keys are ambiguous, so the line is surfaced as a DENY regardless of the
# values -- even two trues. fromjson keeps only the last key, so this is decided on the raw text.
assert_eq "$(printf '%s\n' '{"allow":true,"allow":false,"requested_host":"d.com"}' | deny_host)" "d.com"     "duplicate 'allow' keys -> DENY, host named (here false anyway)"
assert_eq "$(printf '%s\n' '{"allow":true,"allow":true,"requested_host":"d.com"}' | deny_host)"  "d.com"     "duplicate 'allow' keys -> DENY even when both are true"
assert_eq "$(printf '%s\n' '{"allow":true,"allow":true}' | deny_host)"                           "?"         "duplicate 'allow' keys with no host -> 'DENY ?'"
# A genuine ALLOW with a host that merely contains the text 'allow' is still dropped: a string
# value cannot hold an unescaped "allow": (JSON escapes its quotes), so the raw-text key count
# stays 1.
assert_eq "$(printf '%s\n' '{"allow":true,"requested_host":"allow.example.com"}' | deny_host)"      ""  "host text containing 'allow' does not turn a clean ALLOW into a DENY"
assert_eq "$(printf '%s\n' '{"allow":true,"requested_host":"x\"allow\":y"}' | deny_host)"           ""  "an escaped \"allow\": inside a string value does NOT count as a second key"
# Accepted false positive, made explicit: a NESTED object with its own "allow" key bumps the
# raw-text count to 2, indistinguishable from a duplicated top-level key, so an otherwise-clean
# ALLOW is surfaced as a DENY. smokescreen does not emit nested allow fields, and erring toward a
# spurious DENY is the safe direction, so we accept it rather than parse structure to avoid it.
assert_eq "$(printf '%s\n' '{"allow":true,"meta":{"allow":true}}' | deny_host)"                     "?" "a nested 'allow' key trips the raw-text count -> spurious DENY (accepted, fail-safe)"

# (2) Only a real JSON boolean is trusted. A string, number, array -- anything but `true` -- is
# surfaced as a DENY, so a source-format change (e.g. allow stringified) can never read as ALLOW.
assert_eq "$(printf '%s\n' '{"allow":"false"}' | deny_host)"                                     "?"         "a string \"false\" (not the boolean) -> DENY, not ALLOW"
assert_eq "$(printf '%s\n' '{"allow":"true"}' | deny_host)"                                      "?"         "a string \"true\" (not the boolean) -> DENY, not ALLOW"
assert_eq "$(printf '%s\n' '{"allow":1,"requested_host":"n.com"}' | deny_host)"                  "n.com"     "a numeric 'allow' -> DENY, host named"

# (3a) A denied connection with an empty-string host is surfaced as 'DENY ?', not dropped.
assert_eq "$(printf '%s\n' '{"allow":false,"requested_host":""}' | deny_host)"                   "?"         "empty-string host -> '?' (surfaced as a DENY, never dropped)"

# (3b) A whitespace-only host (newline-only, or blanks) is not a usable name and must collapse to
# "?" -- never be emitted verbatim, which command substitution in classify_log would strip back to
# empty and silently drop the DENY.
assert_eq "$(printf '%s\n' '{"allow":false,"requested_host":"\n"}' | deny_host)"                 "?"         "newline-only host -> '?' (surfaced as a DENY, never dropped)"
assert_eq "$(printf '%s\n' '{"allow":false,"requested_host":"   "}' | deny_host)"                "?"         "blank (spaces-only) host -> '?' (surfaced as a DENY, never dropped)"

# known_deny() edge cases. The quiet route mutes a notification, so the doubt here points the
# other way from deny_host(): "1" only on a certain denylist match, empty (-> loud) otherwise.
reason='host matched rule in global deny list'
assert_eq "$(printf '%s\n' '{"allow":false,"decision_reason":"'"$reason"'"}' | known_deny)"      "1"  "smokescreen's exact denylist verdict -> known"
assert_eq "$(printf '%s\n' '{"allow":false,"decision_reason":"default rule policy used"}' | known_deny)" \
                                                                                                 ""   "the default-rule verdict -> NOT known (loud)"
assert_eq "$(printf '%s\n' '{"allow":false}' | known_deny)"                                      ""   "no decision_reason at all -> NOT known (loud)"
assert_eq "$(printf '%s\n' '{"allow":false,"decision_reason":"'"$reason"' extended"}' | known_deny)" \
                                                                                                 ""   "a longer reason merely containing the verdict -> NOT known (exact match only)"
assert_eq "$(printf '%s\n' '{"allow":false,"decision_reason":null}' | known_deny)"               ""   "a null decision_reason -> NOT known (loud)"
assert_eq "$(printf '%s\n' '{"allow":false' | known_deny)"                                       ""   "malformed JSON -> NOT known (loud)"
# Duplicated decision_reason keys parse as fromjson's last-key-wins, accepted as-is
# (should never happen. Worst case: a quiet deny log instead of a loud one).
assert_eq "$(printf '%s\n' '{"allow":false,"decision_reason":"x","decision_reason":"'"$reason"'"}' | known_deny)" \
                                                                                                 "1"  "duplicate decision_reason keys -> fromjson's last key wins (accepted)"


# ---------------------------------------------------------------------------
echo "proxy port consistency (network.sb <-> util.sh)"
# ---------------------------------------------------------------------------
# The network Seatbelt profile permits exactly one outgoing loopback port; it must match the
# port the proxy actually listens on.
digits() { tr -cd '0-9'; }
port_sb="$(grep -oE 'localhost:[0-9]+' "$repo/.internal/network.sb" | head -1 | digits)"
assert_eq "$port_sb" "$PROXY_PORT" "network.sb outgoing port matches util.sh PROXY_PORT ($PROXY_PORT)"


# ---------------------------------------------------------------------------
summary

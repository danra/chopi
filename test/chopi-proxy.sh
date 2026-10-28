#!/usr/bin/env bash
#
# test/chopi-proxy.sh -- unit tests for chopi's proxy

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Exported so the scripts under test leave their temporaries here too.
TMPDIR="$(mktemp -d)"; export TMPDIR
trap 'rm -rf "$TMPDIR"' EXIT
# The sessions' dirs go in a run dir of the test's own, not the user's: util.sh derives
# PROXY_RUN_DIR from it.
# shellcheck disable=SC2034  # read by util.sh
CHOPI_RUN_DIR="$TMPDIR/chopi"

. "$repo/.internal/util.sh"
. "$repo/test/lib.sh"
. "$repo/.internal/classify-log.sh"
. "$repo/.internal/session-proxy.sh"
set +euo pipefail

header "test/chopi-proxy.sh -- unit tests for the proxy's log logic + github migration refusal + session network holes + session proxy lifecycle"


# ---------------------------------------------------------------------------
echo "log classifier (connection-request / deny-host / format-deny / format-misc)"
# ---------------------------------------------------------------------------
# The security property under test: a DENY is always surfaced, never silently dropped.
# The classifier is fail-safe by design: anything ambiguous is surfaced as a DENY rather
# than dropped as an ALLOW, and the edge cases below pin that down.
classify() {
    arity 0
    classify_log "chopi-proxy.sh" "" "" false
}

out="$(printf '%s\n' '{"allow":false,"requested_host":"evil.com","time":"T"}' | classify)"
assert_eq "$out" "[chopi-proxy.sh] DENY  evil.com  @ T" "DENY -> formatted deny line naming the host"

out="$(printf '%s\n' '{"allow":false}' | classify)"
assert_eq "$out" "[chopi-proxy.sh] DENY  ?  @ ?" "DENY missing host/time -> '?' placeholders"

out="$(printf '%s\n' '{"allow":false,"requested_host":""}' | classify)"
assert_eq "$out" "[chopi-proxy.sh] DENY  ?  @ ?" "DENY with empty-string host -> '?' placeholders"

# A whitespace-only host (here a lone newline) must still surface as a DENY, never be dropped.
# The host collapses to "?" so classify_log's command substitution can't strip the decision to
# empty and swallow the line.
out="$(printf '%s\n' '{"allow":false,"requested_host":"\n","time":"T"}' | classify)"
assert_eq "$out" "[chopi-proxy.sh] DENY  ?  @ T" "DENY with whitespace-only host -> surfaced with '?' (never dropped)"

out="$(printf '%s\n' '{"allow":true,"requested_host":"ok.com"}' | classify)"
assert_eq "$out" "" "allowed connection -> dropped"

out="$(printf '%s\n' '{"bytes_in":1,"bytes_out":2}' | classify)"
assert_eq "$out" "" "connection-close (bytes_in) -> dropped"

out="$(printf '%s\n' 'time="x" level=warning msg="no statsd addr provided, using a noop client"' | classify)"
assert_eq "$out" "" "statsd startup warning -> dropped"

out="$(printf '%s\n' '{"msg":"no statsd addr provided, using a noop client"}' | classify)"
assert_eq "$out" "" "statsd warning as JSON object -> dropped (matched on raw text)"

out="$(printf '%s\n' 'goproxy: WARN: Error copying to client: read tcp: connection reset by peer' | classify)"
assert_eq "$out" "" "client-hangup relay-copy warning -> dropped"

passthrough_line='some smokescreen startup line'
out="$(printf '%s\n' "$passthrough_line" | classify)"
assert_eq "$out" "$passthrough_line" "unknown line -> passed through unchanged"

passthrough_json='{"level":"info","msg":"booting"}'
out="$(printf '%s\n' "$passthrough_json" | classify)"
assert_eq "$out" "$passthrough_json" "unknown JSON object -> passed through unchanged"

# A DENY must never be silently dropped: of a mixed batch, exactly the one DENY survives.
out="$(printf '%s\n' \
        '{"allow":true,"requested_host":"ok.com"}' \
        '{"bytes_in":1}' \
        '{"allow":false,"requested_host":"blocked.example","time":"T"}' \
        'WARN: Error copying to client' \
      | classify)"
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
        | classify_log "chopi-proxy.sh" "" "" false
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
    arity 0
    classify_log "chopi-proxy.sh" "" "" true
}

deny_raw='{"allow":false,"requested_host":"evil.com","time":"T"}'
out="$(printf '%s\n' "$deny_raw" | classify_verbose)"
assert_eq "$out" "$deny_raw
[chopi-proxy.sh] DENY  evil.com  @ T" "verbose DENY -> raw line, then the formatted deny line after it"

out="$(printf '%s\n' '{"allow":true,"requested_host":"ok.com"}' | classify_verbose)"
assert_eq "$out" '{"allow":true,"requested_host":"ok.com"}' "verbose allowed connection -> raw line surfaced (not dropped)"

noise='time="x" level=warning msg="no statsd addr provided, using a noop client"'
out="$(printf '%s\n' "$noise" | classify_verbose)"
assert_eq "$out" "$noise" "verbose known noise -> raw line surfaced (not dropped)"

passthrough='some smokescreen startup line'
out="$(printf '%s\n' "$passthrough" | classify_verbose)"
assert_eq "$out" "$passthrough" "verbose unknown line -> surfaced exactly once (not doubled)"

# The whole cascade at once: every raw line is kept in order, and the lone DENY gains its
# formatted line right after its raw line -- nothing is dropped or replaced.
out="$(printf '%s\n' \
        '{"allow":true,"requested_host":"ok.com"}' \
        '{"bytes_in":1}' \
        '{"allow":false,"requested_host":"blocked.example","time":"T"}' \
        'WARN: Error copying to client' \
      | classify_verbose)"
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
# no deny hook -- and every other deny stays exactly as loud as before.
known_deny='{"allow":false,"decision_reason":"host matched rule in global deny list","requested_host":"tele.example:443","time":"T"}'
unknown_deny='{"allow":false,"decision_reason":"default rule policy used","requested_host":"tele.example:443","time":"T2"}'

out="$(printf '%s\n' "$known_deny" | classify)"
assert_eq "$out" "[chopi-proxy.sh] deny(known)  tele.example:443  @ T" "known deny -> plain deny(known) line naming the host"

out="$(printf '%s\n' "$unknown_deny" | classify)"
assert_eq "$out" "[chopi-proxy.sh] DENY  tele.example:443  @ T2" "a deny with any other decision_reason -> loud DENY as before"

# The deny hook (the macOS notification in the live proxy) fires for unknown denies only.
# record_hook stands in for each hook in turn.
record_hook() { arity 1; printf 'HOOK:%s\n' "$1"; }
out="$(printf '%s\n' "$known_deny" | classify_log "chopi-proxy.sh" record_hook "" false)"
assert_not_contains "$out" "HOOK:" "known deny does NOT fire the deny hook (no notification)"
out="$(printf '%s\n' "$unknown_deny" | classify_log "chopi-proxy.sh" record_hook "" false)"
assert_contains "$out" "HOOK:tele.example:443" "unknown deny still fires the deny hook"

# Once per host per session: a repeat is silent, a different host gets its own line.
out="$(printf '%s\n' "$known_deny" "$known_deny" | classify)"
assert_eq "$out" "[chopi-proxy.sh] deny(known)  tele.example:443  @ T" "repeated known deny of the same host -> logged once"

known_deny_other='{"allow":false,"decision_reason":"host matched rule in global deny list","requested_host":"other.example:443","time":"T3"}'
out="$(printf '%s\n' "$known_deny" "$known_deny_other" | classify)"
assert_eq "$out" "[chopi-proxy.sh] deny(known)  tele.example:443  @ T
[chopi-proxy.sh] deny(known)  other.example:443  @ T3" "known denies of two different hosts -> one line each"

# The seen-set only mutes known denies: the same host denied again by another rule is loud.
# (reachable since the rules hot-reload: an edit mid-session can remove a known deny entry, so it's now unknown)
out="$(printf '%s\n' "$known_deny" "$unknown_deny" | classify)"
assert_eq "$out" "[chopi-proxy.sh] deny(known)  tele.example:443  @ T
[chopi-proxy.sh] DENY  tele.example:443  @ T2" "an unknown deny of an already-seen host is still loud"

# Verbose keeps its contract: every raw line survives, and the formatted deny(known) line
# still appears only once -- a repeat shows as its raw line alone.
out="$(printf '%s\n' "$known_deny" "$known_deny" | classify_verbose)"
assert_eq "$out" "$known_deny
[chopi-proxy.sh] deny(known)  tele.example:443  @ T
$known_deny" "verbose repeated known deny -> raw lines always, formatted line once"

# A real smokescreen denylist line, verbatim from a live run.
real_line='{"allow":false,"content_length":115,"decision_reason":"host matched rule in global deny list","dns_lookup_time_ms":0,"enforce_would_deny":true,"id":"d95k1d4k4keehrrdmagg","inbound_remote_addr":"127.0.0.1:60749","level":"warning","msg":"CANONICAL-PROXY-DECISION","project":"","proxy_type":"connect","requested_host":"http-intake.logs.us5.datadoghq.com:443","role":"","start_time":"2026-07-06T05:44:20.961655Z","time":"2026-07-05T22:44:20-07:00","trace_id":""}'
out="$(printf '%s\n' "$real_line" | classify)"
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
        | classify_log "chopi-proxy.sh" "" "" false
)"
assert_eq "$out" "[chopi-proxy.sh] DENY  tele.example:443  @ T
[chopi-proxy.sh] DENY  late.example  @ T" \
    "a known-deny.jq failure -> the deny surfaces LOUD and the loop continues (under set -e)"


# ---------------------------------------------------------------------------
echo "rules hot-reload lines (format-reload: plain on reload, loud on failure)"
# ---------------------------------------------------------------------------
# The proxy wrapper (.internal/proxy/main.go) logs a reload of the rules file as JSON;
# the classifier renders it. A successful reload is routine -> plain line; a FAILED
# reload means the user's edit did NOT take effect (the previous rules stay in force),
# so it is as loud as a DENY.
reload_ok='{"level":"info","msg":"egress ACL reloaded","rules":"/x/rules.yaml","time":"T"}'
reload_fail='{"level":"error","msg":"egress ACL reload failed; keeping the previous rules","error":"yaml: line 3: could not find expected key","rules":"/x/rules.yaml","time":"T"}'

out="$(printf '%s\n' "$reload_ok" | classify)"
assert_eq "$out" "[chopi-proxy.sh] rules reloaded  @ T" "rules reload -> plain 'rules reloaded' line"

out="$(printf '%s\n' "$reload_fail" | classify)"
assert_eq "$out" "[chopi-proxy.sh] RULES RELOAD FAILED (previous rules kept)  yaml: line 3: could not find expected key  @ T" \
    "failed reload -> loud line naming the parse error"

out="$(printf '%s\n' '{"level":"error","msg":"egress ACL reload failed; keeping the previous rules","time":"T"}' | classify)"
assert_eq "$out" "[chopi-proxy.sh] RULES RELOAD FAILED (previous rules kept)  ?  @ T" \
    "a failed reload missing the error field still surfaces loud"

# The reload hook (the macOS notification in the live proxy) tells failures from successes.
record_reload_hook() { arity 2; printf 'HOOK:%s %s\n' "$1" "$2"; }
out="$(printf '%s\n' "$reload_fail" | classify_log "chopi-proxy.sh" "" record_reload_hook false)"
assert_contains "$out" "HOOK:failed rules" "a failed reload fires the reload hook with 'failed', of the rules"
assert_not_contains "$out" "HOOK:ok" "  -> and not with 'ok'"
out="$(printf '%s\n' "$reload_ok" | classify_log "chopi-proxy.sh" "" record_reload_hook false)"
assert_contains "$out" "HOOK:ok rules" "a successful reload fires the reload hook with 'ok', of the rules"
assert_not_contains "$out" "HOOK:failed" "  -> and not with 'failed'"

out="$(printf '%s\n' "$reload_ok" | classify_verbose)"
assert_eq "$out" "$reload_ok
[chopi-proxy.sh] rules reloaded  @ T" "verbose rules reload -> raw line, then the formatted line after it"

# Fail-safe under the live proxy's `set -e`: if format-reload.jq itself fails, the line
# surfaces raw (via format-misc.jq) and the loop survives to process later lines.
poison_filter="$(mktemp)"
printf '%s\n' 'error("simulated jq failure")' > "$poison_filter"
out="$(
    set -euo pipefail
    # shellcheck disable=SC2030 # deliberately subshell-local
    FORMAT_RELOAD_FILTER="$poison_filter"
    printf '%s\n' "$reload_ok" '{"allow":false,"requested_host":"late.example","time":"T"}' \
        | classify_log "chopi-proxy.sh" "" "" false
)"
assert_eq "$out" "$reload_ok
[chopi-proxy.sh] DENY  late.example  @ T" \
    "a format-reload.jq failure -> the reload line surfaces raw and the loop continues (under set -e)"


# ---------------------------------------------------------------------------
echo "GitHub allowlist hot-reload lines (format-reload, as for the rules)"
# ---------------------------------------------------------------------------
# The relays' supervisor (.internal/proxy/supervise.go) logs a reload of the allowlist as the rules'
# is logged: a failure keeps the relays serving the previous allowlist.
allowlist_ok='{"level":"info","msg":"GitHub allowlist reloaded","allowlist":"/x/github-allowlist","time":"T"}'
allowlist_fail='{"level":"error","msg":"GitHub allowlist reload failed; keeping the previous relays","error":"rendering the GitHub relays'"'"' config from /x/github-allowlist: exit status 1","allowlist":"/x/github-allowlist","time":"T"}'

out="$(printf '%s\n' "$allowlist_ok" | classify)"
assert_eq "$out" "[chopi-proxy.sh] GitHub allowlist reloaded  @ T" "allowlist reload -> plain 'GitHub allowlist reloaded' line"
out="$(printf '%s\n' "$allowlist_fail" | classify)"
assert_eq "$out" "[chopi-proxy.sh] GITHUB ALLOWLIST RELOAD FAILED (previous relays kept)  rendering the GitHub relays' config from /x/github-allowlist: exit status 1  @ T" \
    "failed allowlist reload -> loud line naming the error"

out="$(printf '%s\n' "$allowlist_fail" | classify_log "chopi-proxy.sh" "" record_reload_hook false)"
assert_contains "$out" "HOOK:failed allowlist" "a failed allowlist reload fires the reload hook with 'failed', of the allowlist"
out="$(printf '%s\n' "$allowlist_ok" | classify_log "chopi-proxy.sh" "" record_reload_hook false)"
assert_contains "$out" "HOOK:ok allowlist" "a successful allowlist reload fires the reload hook with 'ok', of the allowlist"


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
echo "exfiltration-prone github allowed domains (migration-oriented refusal)"
# ---------------------------------------------------------------------------
old_rules="$TMPDIR/pre-relay-rules.yaml"
cat > "$old_rules" <<'EOF'
version: v1
services: []
default:
  name: default
  action: enforce
  allowed_domains:
    - api.anthropic.com

    - github.com
    - api.github.com
    - raw.githubusercontent.com

    - pypi.org
global_deny_list:
    - "*.datadoghq.com"
EOF
assert_eq "$(exfiltration_prone_github_allowed_domains "$old_rules")" "github.com
api.github.com" "a pre-relay rules file -> both GitHub domains named (blank lines don't end the list)"

assert_eq "$(exfiltration_prone_github_allowed_domains "$repo/config/templates/proxy-rules.template.yaml")" "" \
    "the shipped template is clean (github.com in global_deny_list / comments doesn't match)"

quoted_rules="$TMPDIR/quoted-rules.yaml"
cat > "$quoted_rules" <<'EOF'
default:
  allowed_domains:
    - "api.github.com"   # quoted, with a trailing comment
EOF
assert_eq "$(exfiltration_prone_github_allowed_domains "$quoted_rules")" "api.github.com" \
    "a quoted entry with a trailing comment still matches"

lookalike_rules="$TMPDIR/lookalike-rules.yaml"
cat > "$lookalike_rules" <<'EOF'
default:
  allowed_domains:
    - raw.githubusercontent.com
    - mygithub.com
    - github.com.evil.example
EOF
assert_eq "$(exfiltration_prone_github_allowed_domains "$lookalike_rules")" "" \
    "lookalike domains don't match (exact github.com / api.github.com entries only)"


# ---------------------------------------------------------------------------
echo "the session's network holes (network.sb denies, the session profile re-opens)"
# ---------------------------------------------------------------------------
assert_eq "$(grep -c '^[[:space:]]*(allow' "$repo/.internal/network.sb")" "0" \
    "network.sb opens nothing itself: the holes are per session"

gh_sock="$TMPDIR/gh sock"
: > "$gh_sock"
write_proxy_network_profile "$TMPDIR/net.sb" 24760 24761 "$gh_sock"
net_rules="$(grep -v '^;' "$TMPDIR/net.sb")"
assert_eq "$net_rules" '(allow network-outbound (remote ip "localhost:24760"))
(allow network-outbound (remote ip "localhost:24761"))
(allow network-outbound (literal "'"$(realpath "$gh_sock")"'"))' \
    "the session profile opens exactly the session's two ports and its API relay socket"


# ---------------------------------------------------------------------------
echo "the proxy's run dir is out of the sandbox's reach, whatever else is granted"
# ---------------------------------------------------------------------------
run_dir_t="$TMPDIR/home dir/.chopi/run"
mkdir -p "$run_dir_t"
write_proxy_run_dir_profile "$TMPDIR/run-dir.sb" "$run_dir_t"
run_dir_rules="$(grep -v '^;' "$TMPDIR/run-dir.sb")"
run_dir_real="$(realpath "$run_dir_t")"
assert_contains "$run_dir_rules" '(deny file-read* file-write* (subpath "'"$run_dir_real"'"))' \
    "the profile denies reading and writing the run dir, by its canonical path"
assert_contains "$run_dir_rules" '(deny file-write* (literal "'"$(dirname "$run_dir_real")"'"))' \
    "  -> and pins its ancestors, so it can't be renamed away and replaced"
assert_not_contains "$run_dir_rules" '(literal "/")' \
    "  -> up to, not including, the root"


# ---------------------------------------------------------------------------
echo "the proxies' config is out of the sandbox's reach to change, whatever else is granted"
# ---------------------------------------------------------------------------
# A stand-in chopi dir, its default config linking elsewhere, and a config dir that doesn't exist.
config_t="$TMPDIR/home dir"
mkdir -p "$config_t/chopi/config" "$config_t/dotfiles"
config_t="$(realpath "$config_t")"   # as the profile has them, through the TMPDIR's symlinks
: > "$config_t/dotfiles/rules.yaml"
ln -s "$config_t/dotfiles/rules.yaml" "$config_t/chopi/config/proxy-rules.yaml"
: > "$config_t/chopi/config/github-allowlist"
( CHOPI_DIR="$config_t/chopi" PROXY_CONFIG_DIR="$config_t/.chopi/config"
  write_proxy_config_profile "$TMPDIR/config.sb" )
config_rules="$(grep -v '^;' "$TMPDIR/config.sb")"
assert_contains "$config_rules" '(deny file-write* (subpath "'"$config_t/.chopi/config"'"))' \
    "the profile denies changing anything in the custom config dir, any session's"
assert_contains "$config_rules" '(deny file-write* (subpath "'"$config_t/dotfiles/rules.yaml"'"))' \
    "  -> and the default rules, where they link"
assert_contains "$config_rules" '(deny file-write* (subpath "'"$config_t/chopi/config/github-allowlist"'"))' \
    "  -> and the default allowlist"
assert_not_contains "$config_rules" 'file-read' "  -> leaving reading them as granted"
assert_contains "$config_rules" '(deny file-write* (literal "'"$config_t/.chopi"'"))' \
    "  -> and pins their ancestors, so none can be renamed away and replaced, nor made where missing"
assert_eq "$(grep -c "(literal \"$config_t\")" "$TMPDIR/config.sb")" 1 \
    "  -> each once, however many paths it holds"
assert_not_contains "$config_rules" '(literal "/")' \
    "  -> up to, not including, the root"


# ---------------------------------------------------------------------------
echo "session proxy lifecycle (launch, await the ports it reports, stop)"
# ---------------------------------------------------------------------------
# Hermetic: a stub stands in for chopi-proxy.sh, reporting made-up ports in its --dir, so
# nothing binds a real port. The stub's behavior comes from STUB_PLAN: "up" starts a child standing
# in for Caddy (its pid left in stub-child), reports the ports, and stays up until killed;
# "warn" does the same after a warning on stderr; "garbled" reports a port that isn't one; "fail"
# exits 1 with a reason on stderr; "crash" exits 1 with its reason only in the log, as smokescreen
# would; "warn-crash" warns on stderr first; "starting" stays at its startup, as
# chopi-proxy.sh is at its checks; and "slow" takes a while before going on as "up". It records the
# TMPDIR it was started with.
stub="$TMPDIR/stub-proxy.sh"
cat > "$stub" <<EOF
#!/usr/bin/env bash
printf 'TMPDIR=%s\\n' "\${TMPDIR-<unset>}" >> "$TMPDIR/stub-args"
# Owning its dir as chopi-proxy.sh does.
dir=""
trap '[ -z "\$dir" ] || rm -rf "\$dir"' EXIT
trap 'exit 143' TERM HUP
while [ "\$#" -gt 0 ]; do
    case "\$1" in
        --log) log="\$2" ;;
        --dir) dir="\$2" ;;
    esac
    case "\$1" in
        --log|--parent|--dir|--rules|--github-allowlist) printf '%s=%s\n' "\$1" "\$2" >> "$TMPDIR/stub-args"; shift 2 ;;
        *) shift ;;
    esac
done
case "\$STUB_PLAN" in
    fail)  echo "the proxy says why" >&2; exit 1 ;;
    warn|warn-crash) echo "a warning for the user" >&2 ;;
esac
case "\$STUB_PLAN" in
    crash|warn-crash) echo "smokescreen says why" >> "\$log"; exit 1 ;;
    starting) while :; do sleep 0.05; done ;;
    slow) sleep 1.5 ;;
esac
if [ "\$STUB_PLAN" = garbled ]; then relay="not a port"; else relay=24761; fi
# Led as chopi-proxy.sh leads chopi-smokescreen, with a stand-in Caddy beside it.
. "$repo/.internal/util.sh"
lead_group sh -c 'sleep 30 & echo \$! > "\$1"; printf "proxy 24760\\nrelay %s\\n" "\$3" > "\$2/ports"
    exec sleep 30' sh "$TMPDIR/stub-child" "\$dir" "\$relay"
EOF
chmod +x "$stub"
CHOPI_PROXY_SCRIPT="$stub"
CHOPI_PROXY_LOG_DIR="$TMPDIR/logs"
# The TMPDIR chopi was started with, before it took one of its own.
user_tmpdir="$TMPDIR/user tmp"

# start_proxy_with PLAN [USER_TMPDIR] -- start a session proxy under the stub.
start_proxy_with() {
    : > "$TMPDIR/stub-args"
    STUB_PLAN="$1" launch_session_proxy "$TMPDIR/rules.yaml" "$TMPDIR/allowlist" "" \
        "${2-$user_tmpdir}" && await_session_proxy
}

# Not in a $(...): the proxy must outlive the call, as it does in chopi, and a job started under job
# control in a command substitution is killed on leaving it.
start_proxy_with up 2>"$TMPDIR/start.err"; st=$?
assert_zero "$st" "the proxy starts"
assert_eq "$(cat "$TMPDIR/start.err")" "" "  -> quietly"
assert_eq "$SESSION_PROXY_PORT" 24760 "  -> its port the one it reports"
assert_eq "$SESSION_RELAY_PORT" 24761 "  -> and the relay's"
assert_eq "$SESSION_GH_SOCK" "$SESSION_PROXY_DIR/gh.sock" "  -> and the API relay's socket"
assert_contains "$(cat "$TMPDIR/stub-args")" "--rules=$TMPDIR/rules.yaml" "  -> passing the configured rules"
assert_contains "$(cat "$TMPDIR/stub-args")" "--github-allowlist=$TMPDIR/allowlist" "  -> and the configured allowlist"
assert_contains "$(cat "$TMPDIR/stub-args")" "--log=$CHOPI_PROXY_LOG_DIR/proxy-" "  -> logging under the log dir"
pid="$SESSION_PROXY_PID" dir="$SESSION_PROXY_DIR" child="$(cat "$TMPDIR/stub-child")"
kill -0 "$pid" 2>/dev/null
assert_zero $? "  -> and stays up"
assert_contains "$(cat "$TMPDIR/stub-args")" "--dir=$dir" "  -> with a dir of its own"
assert_eq "$(dirname "$dir")" "$PROXY_RUN_DIR" "  -> in the run dir, out of the sandbox's reach"
# Not chopi's TMPDIR, which goes with the session: an editor a banner opens can outlive it.
assert_contains "$(cat "$TMPDIR/stub-args")" "TMPDIR=$user_tmpdir"$'\n' "  -> with the TMPDIR chopi was started with"
stop_session_proxy
assert_pid_exits "$pid" "stop_session_proxy stops it"
# chopi-proxy.sh stops what it leads with it, Caddy included.
assert_pid_exits "$child" "  -> and its children too"
assert_absent "$dir" "  -> which removes its dir"

# A proxy gone on its own, and reaped, leaves its pid free for reuse: signalling its group then
# could reach an unrelated process. Its stand-in Caddy, left behind in the group, stands in for
# that process.
start_proxy_with up 2>/dev/null
pid="$SESSION_PROXY_PID" dir="$SESSION_PROXY_DIR" child="$(cat "$TMPDIR/stub-child")"
kill -KILL "$pid"; wait "$pid" 2>/dev/null
stop_session_proxy
sleep 0.2
kill -0 "$child" 2>/dev/null
assert_zero $? "stop_session_proxy signals nothing once the proxy is gone"
kill "$child" 2>/dev/null
rm -rf "$dir"

start_proxy_with up "" 2>/dev/null
assert_contains "$(cat "$TMPDIR/stub-args")" "TMPDIR=<unset>" "a proxy of a chopi started with no TMPDIR gets none"
stop_session_proxy

start_proxy_with warn 2>"$TMPDIR/start.err"; st=$?
assert_zero "$st" "a proxy that warns as it starts still starts"
assert_contains "$(cat "$TMPDIR/start.err")" "a warning for the user" "  -> showing the warning"
stop_session_proxy

# Stopped while still starting, as chopi stops it when its own setup fails or the user hits Ctrl-C.
STUB_PLAN=starting launch_session_proxy "$TMPDIR/rules.yaml" "$TMPDIR/allowlist" "" ""
pid="$SESSION_PROXY_PID" dir="$SESSION_PROXY_DIR"
sleep 0.2
stop_session_proxy
assert_pid_exits "$pid" "stop_session_proxy stops a proxy still starting"
assert_absent "$dir" "  -> which removes its dir"

# Slower to start than chopi waits quietly for, as on a keychain prompt for the GitHub token.
CHOPI_PROXY_START_NOTICE_SECS=1 start_proxy_with slow 2>"$TMPDIR/start.err"; st=$?
assert_zero "$st" "a proxy slow to start still starts"
assert_contains "$(cat "$TMPDIR/start.err")" "chopi: waiting for the proxy to start" "  -> saying what chopi waits on"
assert_eq "$(grep -c 'waiting for the proxy' "$TMPDIR/start.err")" 1 "  -> once"
stop_session_proxy

out="$(start_proxy_with fail 2>&1)"; st=$?
assert_nonzero "$st" "a proxy that fails to start fails the start"
assert_contains "$out" "the proxy says why" "  -> showing the proxy's reason"
assert_not_contains "$out" "its log:" "  -> without the log, which has nothing on it"

out="$(start_proxy_with crash 2>&1)"; st=$?
assert_nonzero "$st" "a proxy that dies with its reason in its log fails the start"
assert_contains "$out" "smokescreen says why" "  -> showing the log's tail"

out="$(start_proxy_with warn-crash 2>&1)"; st=$?
assert_nonzero "$st" "a proxy that warns, then dies with its reason in its log, fails the start"
assert_contains "$out" "a warning for the user" "  -> showing the warning"
assert_contains "$out" "smokescreen says why" "  -> and the log's tail too"

out="$(start_proxy_with garbled 2>&1)"; st=$?
assert_nonzero "$st" "a proxy reporting a malformed port fails the start"
assert_contains "$out" "malformed ports" "  -> saying so"
kill "$(cat "$TMPDIR/stub-child")" 2>/dev/null



# ---------------------------------------------------------------------------
echo "option values (an option given no value, or an empty one, is refused)"
# ---------------------------------------------------------------------------
# Refused before anything is started, the log included.
required=(--dir --log --parent --rules --github-allowlist)
for opt in "${required[@]}"; do
    others=()
    for other in "${required[@]}"; do
        [ "$other" = "$opt" ] || others+=("$other" "$TMPDIR/opt-value")
    done
    out="$("$repo/.internal/chopi-proxy.sh" "${others[@]}" 2>&1)"; st=$?
    assert_nonzero "$st" "a run without $opt is refused"
    assert_contains "$out" "are required" "  -> saying what is required"
    out="$("$repo/.internal/chopi-proxy.sh" "${others[@]}" "$opt" 2>&1)"; st=$?
    assert_nonzero "$st" "$opt with no value is refused"
    assert_contains "$out" "are required" "  -> saying what is required"
    out="$("$repo/.internal/chopi-proxy.sh" "$opt" "" "${others[@]}" 2>&1)"; st=$?
    assert_nonzero "$st" "$opt with an empty value is refused"
    assert_contains "$out" "are required" "  -> saying what is required"
done
assert_absent "$TMPDIR/opt-value" "  -> with nothing started"


# ---------------------------------------------------------------------------
echo "make_private_dir (the run dir holding the token-bearing socket is ours alone)"
# ---------------------------------------------------------------------------
perms() { stat -f %Lp "$1"; }
priv="$TMPDIR/private"
make_private_dir "$priv"; st=$?
assert_zero "$st" "a missing dir is created"
assert_eq "$(perms "$priv")" "700" "  -> private"
chmod 755 "$priv"
make_private_dir "$priv"; st=$?
assert_zero "$st" "an existing dir of ours is accepted"
assert_eq "$(perms "$priv")" "700" "  -> and made private"
mkdir -m 755 "$TMPDIR/link-target"
ln -s "$TMPDIR/link-target" "$TMPDIR/link"
out="$(make_private_dir "$TMPDIR/link" 2>&1)"; st=$?
assert_nonzero "$st" "a symlink is refused"
assert_contains "$out" "not a directory" "  -> as not a directory"
assert_eq "$(perms "$TMPDIR/link-target")" "755" "  -> leaving what it points to as it was"
touch "$TMPDIR/plain-file"
out="$(make_private_dir "$TMPDIR/plain-file" 2>&1)"; st=$?
assert_nonzero "$st" "a file is refused"
out="$(make_private_dir /usr 2>&1)"; st=$?
assert_nonzero "$st" "another user's dir is refused"
assert_contains "$out" "another user" "  -> naming why"


# ---------------------------------------------------------------------------
echo "a missing rules file"
# ---------------------------------------------------------------------------
# A missing rules file ends any run that gets past startup's checks, with nothing started.
no_rules="$TMPDIR/no-such-rules.yaml"
mkdir -p "$TMPDIR/pg-proxy"
out="$("$repo/.internal/chopi-proxy.sh" --dir "$TMPDIR/pg-proxy" --log "$TMPDIR/pg-proxy.log" \
    --parent $$ --rules "$no_rules" --github-allowlist /dev/null 2>&1)"
assert_contains "$out" "$no_rules" "a missing rules file is named on stderr"


# ---------------------------------------------------------------------------
echo "reload banner groups (shared by the sessions whose reloads of a file can't differ)"
# ---------------------------------------------------------------------------
# token_source ENV... -- gh_token_source under ENV, with GH_TOKEN and GITHUB_TOKEN unset unless
# ENV sets them.
token_source() {
    # shellcheck disable=SC2016  # expands in the child bash, against the environment under test
    env -u GH_TOKEN -u GITHUB_TOKEN "$@" \
        bash -c '. "$1/.internal/util.sh"; gh_token_source' _ "$repo"
}
assert_eq "$(token_source)" "gh" "no token in the environment: gh's"
assert_eq "$(token_source GH_TOKEN=t1)" "env" "a GH_TOKEN: the environment's"
assert_eq "$(token_source GITHUB_TOKEN=t1)" "env" "  -> a GITHUB_TOKEN too"
assert_eq "$(token_source GH_TOKEN=' ' GITHUB_TOKEN=t1)" "none" \
    "  -> an empty GH_TOKEN is none, taking precedence as resolve_gh_token takes it"
assert_eq "$(reload_banner_group /x/allow env)" "$(reload_banner_group /x/allow env)" \
    "sessions reading the same file with the same token source share a group"
assert_not_eq "$(reload_banner_group /x/allow env)" "$(reload_banner_group /x/allow none)" \
    "  -> but not with a different one, whose reload can fail where theirs succeeds"
assert_not_eq "$(reload_banner_group /x/allow env)" "$(reload_banner_group /y/allow env)" \
    "  -> nor with a different file"


# ---------------------------------------------------------------------------
summary

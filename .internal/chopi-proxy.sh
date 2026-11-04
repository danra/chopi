#!/usr/bin/env bash
#
# chopi-proxy.sh -- run a chopi session's outgoing network traffic proxy
#
# Not run directly: chopi starts one per session and stops it when the session ends. Its ports are
# the kernel's picks, which it reports in its --dir. What it says before it is up goes to stderr, so
# chopi's terminal shows why a session couldn't start, or a note the user should see as it starts;
# everything else -- the formatted smokescreen log -- goes to the --log file, and the relays' own
# to a .caddy.log beside it.
#
# usage: chopi-proxy.sh --dir DIR --log FILE --parent PID --rules FILE --github-allowlist FILE
#                       [--verbose]

set -euo pipefail

SCRIPT_NAME="${BASH_SOURCE[0]##*/}"
SCRIPT_DIR="${BASH_SOURCE[0]%/*}"

. "$SCRIPT_DIR/util.sh"

PROXY_DIR=""
LOG=""
PARENT_PID=""
RULES=""
GITHUB_ALLOWLIST=""
VERBOSE=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --dir)              PROXY_DIR="${2:-}" ;;
        --rules)            RULES="${2:-}" ;;
        --github-allowlist) GITHUB_ALLOWLIST="${2:-}" ;;
        --log)              LOG="${2:-}" ;;
        --parent)           PARENT_PID="${2:-}" ;;
        --verbose) VERBOSE=true; shift; continue ;;
        *) echo "error: unknown option: $1" >&2; exit 1 ;;
    esac
    # A last option given no value leaves it empty, for the check below to refuse.
    shift 2 || break
done

if [ -z "$PROXY_DIR" ] || [ -z "$LOG" ] || [ -z "$PARENT_PID" ] \
    || [ -z "$RULES" ] || [ -z "$GITHUB_ALLOWLIST" ]; then
    echo "error: --dir, --log, --parent, --rules and --github-allowlist are required" >&2
    exit 1
fi
# The relays' log sits beside ours, outliving the session as it does.
CADDY_LOG="${LOG%.log}.caddy.log"

exec >>"$LOG" || { echo "error: cannot write the proxy log $LOG" >&2; exit 1; }

cd "$CHOPI_DIR"

if [ ! -x "$SMOKESCREEN_BIN" ]; then
    echo "Can't run chopi's proxy. Build it with the installer ($CHOPI_DIR/install.sh)" >&2
    echo "or manually:  make -C \"$CHOPI_DIR\" build" >&2
    exit 1
fi

if ! command -v caddy >/dev/null 2>&1; then
    echo "error: caddy is required for the GitHub relay but was not found." >&2
    echo "Install it with the installer ($CHOPI_DIR/install.sh) or manually:  brew install caddy" >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "error: jq is required to format the smokescreen log. Install it with the installer ($CHOPI_DIR/install.sh)" >&2
    echo "or manually:  brew install jq" >&2
    exit 1
fi

if ! command -v alerter >/dev/null 2>&1; then
    echo "error: alerter is required to notify on denied connections. Install it with the installer ($CHOPI_DIR/install.sh)" >&2
    echo "or manually:  brew install vjeantet/tap/alerter" >&2
    exit 1
fi

echo "[$SCRIPT_NAME] using proxy rules: $RULES"

# Rules that allow GitHub's own domains defeat the GitHub repos allowlist: a sandboxed
# command could push data to ANY repo directly, skipping the relays. The expected case is
# a rules file copied from a template predating the relays, so refuse with migration
# directions. The override's name marks the relays' coverage; it rotates when coverage
# grows, so an override set for an already-closed gap doesn't silently carry over.
github_exfil_domains="$(exfiltration_prone_github_allowed_domains "$RULES")"
if [ -n "$github_exfil_domains" ]; then
    exfil_list="${github_exfil_domains//$'\n'/, }"
    if [ -n "${CHOPI_ALLOW_EXFILTRATION_PRONE_GITHUB_DOMAINS_DESPITE_API_RELAY:-}" ]; then
        echo "[$SCRIPT_NAME] warning: the proxy rules allow $exfil_list -- a sandboxed command can push data" >&2
        echo "              to any GitHub repo. Continuing anyway (CHOPI_ALLOW_EXFILTRATION_PRONE_GITHUB_DOMAINS_DESPITE_API_RELAY is set)." >&2
    else
        echo "error: refusing to run, proxy rules allow $exfil_list" >&2
        echo >&2
        echo "A sandboxed command could push stolen data to ANY GitHub repo." >&2
        echo "github.com git and gh's api.github.com REST calls now go through" >&2
        echo "dedicated relays which limit push and private-repo access to the" >&2
        echo "repos in config/$DEFAULT_GITHUB_ALLOWLIST." >&2
        echo >&2
        echo "To migrate, overwrite your proxy rules with the current template:" >&2
        echo "    cp \"$CHOPI_DIR/config/templates/proxy-rules.template.yaml\" \"$RULES\"" >&2
        echo "or move the domains from allowed_domains to global_deny_list in $RULES." >&2
        echo >&2
        echo "To run anyway, set CHOPI_ALLOW_EXFILTRATION_PRONE_GITHUB_DOMAINS_DESPITE_API_RELAY=1." >&2
        exit 1
    fi
fi

echo "[$SCRIPT_NAME] using GitHub allowlist: $GITHUB_ALLOWLIST"

. "$CHOPI_DIR/.internal/classify-log.sh"
for f in "$CONNECTION_FILTER" "$DENY_HOST_FILTER" "$KNOWN_DENY_FILTER" \
         "$FORMAT_DENY_FILTER" "$FORMAT_RELOAD_FILTER" "$FORMAT_MISC_FILTER" \
         "$JQ_LIB_DIR/util.jq"; do
    if [ ! -f "$f" ]; then
        echo "error: missing log filter at $f" >&2
        exit 1
    fi
done

# Stream smokescreen's combined output through the shared classifier:
# - Denied connections show as "DENY host @ time" and trigger notifications
# - Denials of hosts matching the configured denylist show as a plain "deny(known)" line,
#   once per host per session -- no notification, repeats dropped
# - Rules hot-reloads show as a plain "rules reloaded" line; a failed reload (the edit
#   did NOT take effect) shows as a loud "RULES RELOAD FAILED" line, and notifies; the next
#   successful reload withdraws that notification
# - Allowed connections and the known noise are dropped
# - Every other line passes through. notify_deny and notify_reload manage the macOS banners.
format_smokescreen_log() {
    # A formatter that fails takes the rest of the log with it, while the proxy keeps serving: the
    # log says so where it ends, rather than just going quiet.
    trap 'report_formatter_failure $?' EXIT
    # Not interactive: the log is a file, where the bell and colors would be noise.
    classify_log false "$SCRIPT_NAME" notify_deny notify_reload "$VERBOSE"
}

report_formatter_failure() {
    arity 1
    [ "$1" -eq 0 ] && return
    echo "[$SCRIPT_NAME] BUG: the log formatter failed (status $1); the proxy keeps serving," \
         "but logs nothing more, and notifies of no more denials"
}

# A denial's banner replaces the session's last one, but not another session's.
notify_deny() {
    arity 1
    notify "chopi-proxy-deny-$PARENT_PID" 'connection denied' "DENY $1"
}

# Each config file's reload failure has a banner group of its own: a reload of one says nothing of
# the other's last edit.
#
# usage: notify_reload ok|failed rules|allowlist
notify_reload() {
    arity 2
    local group="chopi-proxy-reload-$2" file="$RULES" subtitle='rules reload failed'
    if [ "$2" = allowlist ]; then
        file="$GITHUB_ALLOWLIST" subtitle='GitHub allowlist reload failed'
    fi
    case "$1" in
        failed) notify "$group" "$subtitle" "Your edit to ${file##*/} did not take effect" ;;
        # The config now in effect is the user's latest: a failure banner still up is stale.
        ok) { alerter --remove "$group" >/dev/null 2>&1 || true; } & ;;
    esac
}

echo "[$SCRIPT_NAME] relay log: $CADDY_LOG"
echo "[$SCRIPT_NAME] starting the outgoing proxy and the GitHub relays"
# Run chopi-smokescreen with fd 4 for its stderr, which the call below sets aside for it.
run_smokescreen() {
    run_chopi_smokescreen "$@" 2>&4 4>&-
}

# chopi-smokescreen opens the listeners, serves the proxy, and starts Caddy on the relays' config,
# which it renders from the allowlist, and again on each edit to it. It reports its ports in
# DIR/ports once up; until then, its stderr is still ours as chopi started us, where chopi shows why
# it couldn't start, and its log output, on stdout, goes through the formatter. Our own stderr goes
# to the log from here on, as does the formatter's: both outlive the startup, whose stderr chopi
# reads only then -- the shell's word of how chopi-smokescreen ended, a crash's say, would be lost
# there. We stay, for Caddy to go with chopi-smokescreen however it goes; chopi's stop signal
# reaches it as a TERM from us. Its temporaries, Caddy's among them, go in its private dir, which
# chopi removes as the session ends -- but only theirs: an editor opened from a notification can
# outlive the session, and so must the TMPDIR it's given.
TMPDIR="$PROXY_DIR" lead_group run_smokescreen "$PROXY_DIR" "$RULES" \
    "$GITHUB_ALLOWLIST" "$CHOPI_DIR/.internal/github-relays-config.sh" "$CADDY_LOG" \
    4>&2 2>&1 > >(unset GH_TOKEN GITHUB_TOKEN; format_smokescreen_log 2>&1)

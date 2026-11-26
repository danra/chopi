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
#                       --add-rules FILE --add-github-allowlist FILE [--verbose]
#
# The --rules and --github-allowlist files are the base ones, chopi's. The --add-rules and
# --add-github-allowlist files are a workspace's own (see workspace_config_dir), which add to the
# base ones. Either may be missing.

set -euo pipefail
# The GitHub token is chopi-smokescreen's alone, which exports it again (see run_smokescreen): kept
# set, for gh_token_source to tell where it comes from, but from no other command we run.
export -n GH_TOKEN GITHUB_TOKEN

SCRIPT_NAME="${BASH_SOURCE[0]##*/}"
SCRIPT_DIR="${BASH_SOURCE[0]%/*}"

PROXY_DIR=""
LOG=""
PARENT_PID=""
RULES=""
GITHUB_ALLOWLIST=""
ADD_RULES=""
ADD_GITHUB_ALLOWLIST=""
VERBOSE=false
# The --dir, which chopi made for us, is ours to remove, however we exit: only once what we lead is
# gone, as chopi-smokescreen and Caddy keep their temporaries, and the API relay's socket, in it.
# Set first thing, so a stop signal from here on, before lead_group passes it on, removes it too.
trap '[ -z "$PROXY_DIR" ] || rm -rf "$PROXY_DIR"' EXIT
trap 'exit 143' TERM HUP

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dir)              PROXY_DIR="${2:-}" ;;
        --rules)            RULES="${2:-}" ;;
        --github-allowlist) GITHUB_ALLOWLIST="${2:-}" ;;
        --add-rules)        ADD_RULES="${2:-}" ;;
        --add-github-allowlist) ADD_GITHUB_ALLOWLIST="${2:-}" ;;
        --log)              LOG="${2:-}" ;;
        --parent)           PARENT_PID="${2:-}" ;;
        --verbose) VERBOSE=true; shift; continue ;;
        *) echo "error: unknown option: $1" >&2; exit 1 ;;
    esac
    # A last option given no value leaves it empty, for the check below to refuse.
    shift 2 || break
done

. "$SCRIPT_DIR/util.sh"

if [ -z "$PROXY_DIR" ] || [ -z "$LOG" ] || [ -z "$PARENT_PID" ] \
    || [ -z "$RULES" ] || [ -z "$GITHUB_ALLOWLIST" ] \
    || [ -z "$ADD_RULES" ] || [ -z "$ADD_GITHUB_ALLOWLIST" ]; then
    echo "error: --dir, --log, --parent, --rules, --github-allowlist, --add-rules and" \
         "--add-github-allowlist are required" >&2
    exit 1
fi
# The relays' log sits beside ours, outliving the session as it does: named for chopi's sweep of
# old logs to cover it too, the session's pid still what follows its last dash (see
# launch_session_proxy).
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
echo "[$SCRIPT_NAME] using GitHub allowlist: $GITHUB_ALLOWLIST"
echo "[$SCRIPT_NAME] adding the proxy rules in, where present: $ADD_RULES"
echo "[$SCRIPT_NAME] adding the GitHub allowlist in, where present: $ADD_GITHUB_ALLOWLIST"

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
# - Rules hot-reloads show as a plain "rules reloaded" line.
# - A failed reload, whose edit did NOT take effect, shows as a loud "RULES RELOAD FAILED"
#   line and triggers a notification. The next successful reload replaces that notification with a
#   brief confirmation.
# - Allowed connections and the known noise are dropped
# - Every other line passes through. notify_deny and notify_reload manage the macOS banners.
format_smokescreen_log() {
    # A formatter that fails takes the rest of the log with it, while the proxy keeps serving: the
    # log says so where it ends, rather than just going quiet.
    trap 'report_formatter_failure $?' EXIT
    # Work out the reload banners' groups (see notify_reload) here, off the proxy's startup path.
    # Each group is keyed by its file and the other file it is taken up with, and an allowlist's
    # group by where the token comes from too.
    local token_source
    token_source="$(gh_token_source)"
    RULES_RELOAD_GROUP="$(reload_banner_group "$RULES" "$ADD_RULES")"
    RULES_WS_RELOAD_GROUP="$(reload_banner_group "$ADD_RULES" "$RULES")"
    ALLOWLIST_RELOAD_GROUP="$(reload_banner_group "$GITHUB_ALLOWLIST" "$ADD_GITHUB_ALLOWLIST" "$token_source")"
    ALLOWLIST_WS_RELOAD_GROUP="$(reload_banner_group "$ADD_GITHUB_ALLOWLIST" "$GITHUB_ALLOWLIST" "$token_source")"
    classify_log "$SCRIPT_NAME" notify_deny notify_reload "$VERBOSE"
}

report_formatter_failure() {
    arity 1
    [ "$1" -eq 0 ] && return
    echo "[$SCRIPT_NAME] BUG: the log formatter failed (status $1); the proxy keeps serving," \
         "but logs nothing more, and notifies of no more denials"
}

# The banners: a click on one opens the session's log, which has the event in context. Each kind
# has its own group, lest a frequent kind (denials) bury a rare one. A denial replaces the session's
# last one, but not another session's.
notify_deny() {
    arity 1
    notify "chopi-proxy-deny-$PARENT_PID" "$LOG" 'connection denied' "DENY $1" "$NOTIFY_ALERT_SECS"
}

# Each config file's reloads have a banner group of their own, since a reload of one file says
# nothing of another file's last edit.
#
# The sessions whose reloads of the file go alike share its group (reload_banner_group): those that
# take the file up with the same base and workspace files, and, for an allowlist, take the token
# from the same place. So a base edit shows once per workspace, and a base edit refused for what a
# workspace's file holds shows only in that workspace's sessions.
#
# A reload's banner replaces its group's last one. A failure stays up until the user fixes it, and
# the fix's confirmation then takes its place, briefly. The proxy has no terminal, so the
# confirmation is how the user learns that an edit took effect before they retry what it allows.
# Without one, they learn that the edit went to a file the session doesn't read.
#
# The banner says what reloaded and names the file as the proxy's log LINE does.
#
# usage: notify_reload ok|failed rules|allowlist LINE
notify_reload() {
    arity 3
    local group="$RULES_RELOAD_GROUP" ws_group="$RULES_WS_RELOAD_GROUP"
    local what name added
    if [ "$2" = allowlist ]; then
        group="$ALLOWLIST_RELOAD_GROUP" ws_group="$ALLOWLIST_WS_RELOAD_GROUP"
    fi
    # A jq of its own, not a filter file: one edited as the proxy runs can't swallow the banner.
    { IFS= read -r what && IFS= read -r name && IFS= read -r added; } \
        < <(printf '%s\n' "$3" | jq -r '(.what // "proxy config"), (.name // "the proxy config"),
                                        (.added == true)' 2>/dev/null) \
        || { what='proxy config' name='the proxy config' added=false; }
    [ "$added" = true ] && group="$ws_group"
    case "$1" in
        failed) notify "$group" "$LOG" "$what reload failed" \
                    "Your edit to $name did not take effect" "$NOTIFY_ALERT_SECS" ;;
        ok)     notify "$group" "$LOG" "$what reloaded" \
                    "Your edit to $name took effect" "$NOTIFY_CONFIRM_SECS" ;;
    esac
}

echo "[$SCRIPT_NAME] relay log: $CADDY_LOG"
echo "[$SCRIPT_NAME] starting the outgoing proxy and the GitHub relays"
# Run chopi-smokescreen with fd 4 for its stderr, which the call below sets aside for it, and the
# GitHub token, if set, in its environment, which it takes out of what Caddy gets. A background job,
# so the export goes no further.
run_smokescreen() {
    export GH_TOKEN GITHUB_TOKEN
    run_chopi_smokescreen "$@" 2>&4 4>&-
}

# chopi-smokescreen opens the listeners, serves the proxy, and starts Caddy on the relays' config.
# It renders that config from the allowlist, and again on each edit to the allowlist, and on a save
# with no edit, which takes up a GitHub token gh replaced.
#
# chopi-smokescreen reports its ports in DIR/ports once up. Until then, its stderr is still the one
# chopi started us with, where chopi shows why it couldn't start. Its log output, on stdout, goes
# through the formatter.
#
# lead_group's stderr goes to the log, as does the formatter's. Both outlive the startup, and chopi
# reads the startup's stderr only during the startup, so the shell's report of how
# chopi-smokescreen ended, such as a crash, would be lost there. What we print once lead_group
# returns still goes to the startup's stderr, where nothing reads it.
#
# We stay running, so that Caddy goes with chopi-smokescreen however chopi-smokescreen ends.
# chopi's stop signal reaches chopi-smokescreen as a TERM from us. chopi-smokescreen's temporaries,
# Caddy's among them, go in our private dir, which we remove once chopi-smokescreen is gone (see the
# EXIT trap above).
#
# chopi-smokescreen's output goes through this to the formatter: a background job of ours, unlike a
# process substitution, which bash 3.2 gives no pid to wait for. Waiting for it, rather than
# exiting while it still writes chopi-smokescreen's last words, lets them reach the log.
LOG_FIFO="$PROXY_DIR/log.fifo"
mkfifo "$LOG_FIFO"
# Opened to read and write, which never blocks, unlike opening one end and waiting for the other:
# no signal sent to us here is in danger of leaving the formatter blocked on its end, so none need
# be held off until lead_group traps it. Should one end us, our end closes with us, and the
# formatter ends with it.
exec 3<>"$LOG_FIFO"
format_smokescreen_log 2>&1 <"$LOG_FIFO" 3>&- &
formatter=$!
status=0
TMPDIR="$PROXY_DIR" lead_group run_smokescreen "$PROXY_DIR" "$PARENT_PID" "$RULES" \
    "$GITHUB_ALLOWLIST" "$CHOPI_DIR/.internal/github-relays-config.sh" "$CADDY_LOG" \
    "$ADD_RULES" "$ADD_GITHUB_ALLOWLIST" 4>&2 2>&1 >&3 3>&- || status=$?
exec 3>&-
# Our end of the FIFO closed, the formatter ends once it reads the rest. A second stop signal while
# it does stops us waiting.
wait "$formatter" || :
# Not a plain `exit "$status"`: shellcheck would take every function only traps and lead_group
# call for unreachable (SC2329).
[ "$status" -eq 0 ] || exit "$status"

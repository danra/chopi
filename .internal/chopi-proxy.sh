#!/usr/bin/env bash
#
# chopi-proxy.sh -- run a chopi session's outgoing network traffic proxy
#
# Not run directly: chopi starts one per session and stops it when the session ends. Its ports are
# the kernel's picks, which it reports in its --dir. What it says before it is up goes to stderr, so
# chopi's terminal shows why a session couldn't start, or a note the user should see as it starts;
# everything else -- the formatted smokescreen log -- goes to the --log file.

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"

. "$SCRIPT_DIR/util.sh"

usage() {
    cat <<EOF
usage: $SCRIPT_NAME --dir DIR --log FILE --parent PID --rules FILE --github-allowlist FILE
                    [--verbose]

The outgoing proxy and the GitHub git relay listen on 127.0.0.1, on ports the kernel picks.

  --dir DIR          keep the proxy's temporaries in DIR, removed once PID exits, serve the
                     GitHub API relay on the unix socket DIR/gh.sock, and report the ports
                     in DIR/ports once the proxy and the relays serve
  --log FILE         append the proxy's log to FILE, and the relays' to FILE's name with
                     .caddy.log for .log
  --parent PID       stop once process PID exits
  --rules FILE       use FILE (absolute) as the proxy rules
  --github-allowlist FILE
                     use FILE (absolute) as the GitHub allowlist
  --verbose          log smokescreen's output verbatim, interleaved with chopi-proxy's
                     own: nothing is dropped or replaced.

Edits to the rules file take effect while the proxy runs; no restart needed.
EOF
}

# Print the value of option $1, given as $2, failing when it is missing.
option_value() {
    arity 2
    if [ -z "$2" ]; then
        echo "error: $1 requires a value" >&2
        usage >&2
        return 1
    fi
    printf '%s' "$2"
}

PROXY_DIR=""
LOG=""
PARENT_PID=""
RULES=""
GITHUB_ALLOWLIST=""
VERBOSE=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --dir)              PROXY_DIR="$(option_value "$1" "${2:-}")"               || exit 1; shift 2 ;;
        --rules)            RULES="$(option_value "$1" "${2:-}")"                   || exit 1; shift 2 ;;
        --github-allowlist) GITHUB_ALLOWLIST="$(option_value "$1" "${2:-}")"        || exit 1; shift 2 ;;
        --log)              LOG="$(option_value "$1" "${2:-}")"                     || exit 1; shift 2 ;;
        --parent)           PARENT_PID="$(option_value "$1" "${2:-}")"              || exit 1; shift 2 ;;
        --verbose) VERBOSE=true; shift ;;
        *) usage >&2; exit 1 ;;
    esac
done

if [ -z "$PROXY_DIR" ] || [ -z "$LOG" ] || [ -z "$PARENT_PID" ] || [ -z "$RULES" ] \
    || [ -z "$GITHUB_ALLOWLIST" ]; then
    echo "error: --dir, --log, --parent, --rules and --github-allowlist are required" >&2
    usage >&2
    exit 1
fi

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

# Check config FILE, the DESCRIPTION passed with FLAG, exists, logging which file it is.
#
# usage: check_config_file DESCRIPTION FLAG FILE
check_config_file() {
    arity 3
    local description="$1" flag="$2" file="$3"
    [ -f "$file" ] || { echo "error: $flag file not found: $file" >&2; return 1; }
    echo "[$SCRIPT_NAME] using $description: $file"
}

check_config_file "proxy rules" --rules "$RULES" || exit 1

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
        echo "repos in config/github-allowlist." >&2
        echo >&2
        echo "To migrate, overwrite your proxy rules with the current template:" >&2
        echo "    cp \"$CHOPI_DIR/config/templates/proxy-rules.template.yaml\" \"$RULES\"" >&2
        echo "or move the domains from allowed_domains to global_deny_list in $RULES." >&2
        echo >&2
        echo "To run anyway, set CHOPI_ALLOW_EXFILTRATION_PRONE_GITHUB_DOMAINS_DESPITE_API_RELAY=1." >&2
        exit 1
    fi
fi

check_config_file "GitHub allowlist" --github-allowlist "$GITHUB_ALLOWLIST" || exit 1

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
#   did NOT take effect) shows as a loud "RULES RELOAD FAILED" line, and notifies
# - Allowed connections and the known noise are dropped
# - Every other line passes through. notify_deny and notify_reload_failed pop the macOS banners.
format_smokescreen_log() {
    # chopi stops the proxy by signalling its whole process group, this formatter included, as
    # soon as the session's command exits -- often right after a denial that made it fail. The
    # formatter, and the notifications it starts, ignore that and finish on their own instead:
    # the formatter once smokescreen's output ends, so the denial still reaches the log, and each
    # notification once it is dismissed or times out, so its banner still shows.
    trap '' INT TERM HUP
    # A formatter that fails takes the rest of the log with it, while the proxy keeps serving: the
    # log says so where it ends, rather than just going quiet.
    trap 'report_formatter_failure $?' EXIT
    classify_log "$SCRIPT_NAME" notify_deny notify_reload_failed "$VERBOSE"
}

report_formatter_failure() {
    arity 1
    [ "$1" -eq 0 ] && return
    echo "[$SCRIPT_NAME] BUG: the log formatter failed (status $1); the proxy keeps serving," \
         "but logs nothing more, and notifies of no more denials"
}

notify_deny() {
    arity 1
    notify 'connection denied' "DENY $1"
}

notify_reload_failed() {
    arity 0
    notify 'rules reload failed' "Your edit to $(basename -- "$RULES") did not take effect"
}

# Pop a macOS banner with SUBTITLE and MESSAGE, in the background. A click on it opens the log,
# which has the event in context, in the user's editor -- or says in the log why it couldn't. Each
# new banner replaces the session's last one, but not another session's, whose log it opens.
#
# usage: notify SUBTITLE MESSAGE
notify() {
    arity 2
    local subtitle="$1" message="$2"
    {
        result=$(alerter --title 'Chopi' \
                         --subtitle "$subtitle" \
                         --message "$message" \
                         --group "chopi-proxy-$PARENT_PID" \
                         --timeout 10 2>/dev/null || true)
        case "$result" in
            @TIMEOUT | @CLOSED | '') ;;
            # The editor gets the signals back the formatter ignores, which it would
            # otherwise inherit -- and pass on to an editor app it starts.
            *) ( trap - INT TERM HUP; open_in_gui_editor "$LOG" >/dev/null ) || true ;;
        esac
    } &
}

# The proxy's temporaries go in its private dir, removed once the parent exits.
export TMPDIR="$PROXY_DIR"

# Render the GitHub relay config. Its log sits beside the proxy's, outliving the session as it does.
CADDY_LOG="${LOG%.log}.caddy.log"
CADDYFILE_TEXT="$("$CHOPI_DIR/.internal/github-relays-caddyfile.sh" "$GITHUB_ALLOWLIST")" \
    || { echo "error: could not render the GitHub relay config from $GITHUB_ALLOWLIST" >&2; exit 1; }
if [[ "$CADDYFILE_TEXT" == *@@CHOPI_AUTH@@* ]]; then
    gh_token="$(resolve_gh_token)"
    if [ -z "$gh_token" ]; then
        echo "[$SCRIPT_NAME] error: the GitHub allowlist has entries but no GitHub token is set." >&2
        echo "              Push and private-repo access to allowlisted repos need one; set GH_TOKEN" >&2
        echo "              or run 'gh auth login' -- or empty the allowlist for anonymous public fetch only." >&2
        exit 1
    fi
    gh_auth="$(gh_basic_auth_header "$gh_token")"
    gh_api_auth="$(gh_bearer_auth_header "$gh_token")"
    gh_token=""
    CADDYFILE_TEXT="${CADDYFILE_TEXT//@@CHOPI_AUTH@@/$gh_auth}"
    CADDYFILE_TEXT="${CADDYFILE_TEXT//@@CHOPI_API_AUTH@@/$gh_api_auth}"
    gh_auth=""
    gh_api_auth=""
else
    # No credential slot: the GitHub allowlist is empty, so the relay proxies anonymous public fetch
    # only. In the log, for the user to find why authenticated GitHub access fails: an empty
    # allowlist can be deliberate, so it is no reason to speak up at every session's start.
    echo "[$SCRIPT_NAME] note: the GitHub allowlist is empty; only public fetch and anonymous public API reads are enabled until you add allowed repos."
fi

# Strip any GitHub token the user exported into our environment to avoid passing it down to more processes
# (if set, resolve_gh_token already read it above).
unset GH_TOKEN GITHUB_TOKEN

echo "[$SCRIPT_NAME] relay log: $CADDY_LOG"
echo "[$SCRIPT_NAME] starting the outgoing proxy and the GitHub relays"
# Run chopi-smokescreen with fd 3 for its stderr, which the call below sets aside for it.
run_smokescreen() {
    exec "$SMOKESCREEN_BIN" "$@" 2>&3 3>&-
}

# chopi-smokescreen opens the listeners, serves the proxy, and starts Caddy on the relays' config,
# handed over stdin: printf is a builtin, so the baked GitHub token doesn't appear in any process's
# argv. It reports its ports in DIR/ports once up; until then, its stderr is still ours as chopi
# started us, where chopi shows why it couldn't start, and its log output, on stdout, goes through
# the formatter. Our own stderr goes to the log from here on, as does the formatter's: both outlive
# the startup, whose stderr chopi reads only then -- the shell's word of how chopi-smokescreen
# ended, a crash's say, would be lost there. We stay, leading the process group chopi stops the
# proxy by, for Caddy to go with chopi-smokescreen however it goes; and chopi-smokescreen keeps the
# logs fresh, for their retention not to take a running session's.
lead_group run_smokescreen --dir "$PROXY_DIR" --parent "$PARENT_PID" --relay-log "$CADDY_LOG" \
    --keep-fresh "$LOG" -- \
    --config-file ./.internal/smokescreen-config.yaml --listen-ip 127.0.0.1 \
    --egress-acl-file "$RULES" \
    3>&2 2>&1 < <(printf '%s' "$CADDYFILE_TEXT") > >(format_smokescreen_log 2>&1)

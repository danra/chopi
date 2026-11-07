#!/usr/bin/env bash
#
# chopi-proxy.sh -- run the outgoing network traffic proxy

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"   # resolve the bin/chopi-proxy symlink
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

. "$SCRIPT_DIR/util.sh"

usage() {
    cat <<EOF
usage: $SCRIPT_NAME [--rules FILE] [--github-allowlist FILE] [--verbose]

The outgoing proxy and the GitHub git relay listen on 127.0.0.1, on the ports of the last run
where free, else on ones the kernel picks, reported in $PROXY_PORTS_FILE once they serve, for
chopi to find them. Running chopi sessions keep the ports they started with, so they survive a
restart only on the same ports.

  --rules FILE       use FILE as the proxy rules instead of the default
                     config/$DEFAULT_PROXY_RULES
  --github-allowlist FILE
                     use FILE as the GitHub allowlist instead of the default
                     config/$DEFAULT_GITHUB_ALLOWLIST
                     A custom FILE must be in $PROXY_CONFIG_DIR, which chopi keeps every
                     sandboxed command from changing.
  --verbose          show smokescreen's output verbatim, interleaved with chopi-proxy's
                     own: nothing is dropped or replaced.

Edits to the rules file and the GitHub allowlist take effect while the proxy runs, on the same
ports; no restart needed. An allowlist edit also takes up a token gh has rotated since.
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

CUSTOM_RULES=""
CUSTOM_GITHUB_ALLOWLIST=""
VERBOSE=false
INVOCATION_DIR="$PWD"
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --rules)            CUSTOM_RULES="$(option_value "$1" "${2:-}")"            || exit 1; shift 2 ;;
        --github-allowlist) CUSTOM_GITHUB_ALLOWLIST="$(option_value "$1" "${2:-}")" || exit 1; shift 2 ;;
        --verbose) VERBOSE=true; shift ;;
        *) usage >&2; exit 1 ;;
    esac
done

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

# Print the config file to use: CUSTOM, as passed with FLAG (relative to where chopi-proxy was
# started), or else config/DEFAULT, which the installer creates from config/templates/TEMPLATE.
# Fails when the file is missing. A custom one must be in PROXY_CONFIG_DIR, which every chopi session
# keeps its command from changing (see write_proxy_config_profile): elsewhere, a session that could
# write it could lift the outgoing limits of them all, as the proxy hot-reloads it. Either is resolved
# once, here, for the proxy to read its real path: no symlink is followed past this point, so none
# can be repointed to change the config it reads.
#
# usage: config_file DESCRIPTION FLAG CUSTOM DEFAULT TEMPLATE
config_file() {
    arity 5
    local description="$1" flag="$2" custom="$3" default="$CHOPI_DIR/config/$4" template="$5"
    if [ -n "$custom" ]; then
        case "$custom" in
            /*) ;;
            *)  custom="$INVOCATION_DIR/$custom" ;;
        esac
        local resolved
        resolved="$(realpath "$custom" 2>/dev/null)" && [ -f "$resolved" ] \
            || { echo "error: $flag file not found: $custom" >&2; return 1; }
        if ! is_path_within "$resolved" "$(realpath_or_self "$PROXY_CONFIG_DIR")"; then
            echo "error: the $flag file must be in $PROXY_CONFIG_DIR, got: $custom" >&2
            echo "Every chopi session keeps its command from changing what is there; elsewhere, one that" >&2
            echo "could write it could lift its own outgoing limits, and every other session's. Move it" >&2
            echo "there, and pass its path there to $flag." >&2
            return 1
        fi
        echo "[$SCRIPT_NAME] using custom $description: $resolved" >&2
        printf '%s' "$resolved"
    elif [ -f "$default" ]; then
        realpath "$default"
    else
        echo "error: no $description at $default" >&2
        echo "Run the installer to create it from the template:  $CHOPI_DIR/install.sh" >&2
        echo "or copy it manually:  cp \"$CHOPI_DIR/config/templates/$template\" \"$default\"" >&2
        return 1
    fi
}

RULES="$(config_file "proxy rules" --rules "$CUSTOM_RULES" \
    "$DEFAULT_PROXY_RULES" proxy-rules.template.yaml)" || exit 1

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

GITHUB_ALLOWLIST="$(config_file "GitHub allowlist" --github-allowlist "$CUSTOM_GITHUB_ALLOWLIST" \
    "$DEFAULT_GITHUB_ALLOWLIST" github-allowlist.template)" || exit 1

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
    # A Ctrl-C reaches this formatter too. It ignores it, and stop signals generally, and finishes
    # on its own instead, once chopi-smokescreen's output ends, so its last words still show.
    trap '' INT TERM HUP
    # A formatter that fails takes the rest of the output with it, while the proxy keeps serving:
    # the output says so where it ends, rather than just going quiet.
    trap 'report_formatter_failure $?' EXIT
    local is_interactive=false
    [ -t 1 ] && is_interactive=true
    classify_log "$is_interactive" "$SCRIPT_NAME" notify_deny notify_reload "$VERBOSE"
}

report_formatter_failure() {
    arity 1
    [ "$1" -eq 0 ] && return
    echo "[$SCRIPT_NAME] BUG: the log formatter failed (status $1); the proxy keeps serving," \
         "but shows nothing more, and notifies of no more denials"
}

notify_deny() {
    arity 1
    notify chopi-proxy-deny 'connection denied' "DENY $1"
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

# Cleanup any temporaries this process generates on exit.
TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/chopi-proxy.XXXXXX")" \
    || { echo "error: could not create a temp dir for chopi-proxy" >&2; exit 1; }
trap 'rm -rf "$TMPDIR"' EXIT

CADDY_LOG="$TMPDIR/caddy.log"

# The GitHub token the user exported, if any, is chopi-smokescreen's alone, which hands it to the
# renders of the relays' config (github-relays-config.sh) only: no other command gets it in its
# environment. The log formatter, a fork of this shell, drops its copy too, as do the banners it
# forks in turn.
export -n GH_TOKEN GITHUB_TOKEN

# The API relay's socket and the ports file: clear the ones a crashed prior run left, but not a
# socket that still answers, a running chopi-proxy's.
if sock_has_listener "$GH_RELAY_SOCK"; then
    echo "error: a running GitHub API relay already owns $GH_RELAY_SOCK" >&2
    exit 1
fi
# The socket serves GitHub with our credential, so its dir is ours alone.
mkdir -p "$CHOPI_RUN_DIR"
make_private_dir "$PROXY_RUN_DIR" || exit 1
rm -f "$GH_RELAY_SOCK" "$PROXY_PORTS_FILE"
# For each session to keep its command from changing the files read, whatever their links point
# at by the time it starts (see proxy_config_paths).
printf '%s\n' "$RULES" "$GITHUB_ALLOWLIST" >"$PROXY_CONFIGS_FILE"

# chopi-smokescreen clears these as it stops, but not if it dies (a SIGKILL, a crash): left, the
# ports would point the next chopi session at whatever later takes them.
trap 'rm -rf "$TMPDIR"; rm -f "$PROXY_PORTS_FILE" "$GH_RELAY_SOCK" "$PROXY_CONFIGS_FILE"' EXIT

# Run chopi-smokescreen with the GitHub token the user exported, if any: exporting an unset
# variable puts nothing in the environment.
run_smokescreen() {
    export GH_TOKEN GITHUB_TOKEN
    run_chopi_smokescreen "$@"
}

echo "[$SCRIPT_NAME] relay log: $CADDY_LOG" >&2
echo "[$SCRIPT_NAME] starting the outgoing proxy and the GitHub relays (Ctrl-C to stop)" >&2
# chopi-smokescreen opens the listeners, serves the proxy, and starts Caddy on the relays' config,
# which it renders from the allowlist, and again on each edit to it. It reports its ports once up,
# and says where it serves. We stay, for Caddy to go with chopi-smokescreen however it goes; a
# Ctrl-C reaches it as a TERM from us.
lead_group run_smokescreen "$RULES" "$GITHUB_ALLOWLIST" \
    "$CHOPI_DIR/.internal/github-relays-config.sh" "$CADDY_LOG" \
    > >(unset GH_TOKEN GITHUB_TOKEN; format_smokescreen_log) 2>&1

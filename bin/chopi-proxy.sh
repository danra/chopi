#!/usr/bin/env bash
#
# chopi-proxy.sh -- run the outgoing network traffic proxy

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"   # resolve the bin/chopi-proxy symlink
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

. "$SCRIPT_DIR/../.internal/util.sh"

usage() {
    cat <<EOF
usage: $SCRIPT_NAME [--rules FILE] [--github-allowlist FILE] [--verbose]   # listens on 127.0.0.1:$PROXY_PORT

  --rules FILE       use FILE as the proxy rules instead of the default
                     config/proxy-rules.yaml
  --github-allowlist FILE
                     use FILE as the GitHub allowlist instead of the default
                     config/github-allowlist
  --verbose          show smokescreen's output verbatim, interleaved with chopi-proxy's
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

if busy_port="$(first_listening_port "$PROXY_PORT" "$GITHUB_RELAY_PORT")"; then
    echo "error: something is already listening on 127.0.0.1:$busy_port" >&2
    exit 1
fi

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
# Fails when the file is missing.
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
        [ -f "$custom" ] || { echo "error: $flag file not found: $custom" >&2; return 1; }
        echo "[$SCRIPT_NAME] using custom $description: $custom" >&2
        printf '%s' "$custom"
    elif [ -f "$default" ]; then
        printf '%s' "$default"
    else
        echo "error: no $description at $default" >&2
        echo "Run the installer to create it from the template:  $CHOPI_DIR/install.sh" >&2
        echo "or copy it manually:  cp \"$CHOPI_DIR/config/templates/$template\" \"$default\"" >&2
        return 1
    fi
}

RULES="$(config_file "proxy rules" --rules "$CUSTOM_RULES" \
    proxy-rules.yaml proxy-rules.template.yaml)" || exit 1

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

GITHUB_ALLOWLIST="$(config_file "GitHub allowlist" --github-allowlist "$CUSTOM_GITHUB_ALLOWLIST" \
    github-allowlist github-allowlist.template)" || exit 1

if [ -n "$CUSTOM_RULES$CUSTOM_GITHUB_ALLOWLIST" ]; then
    # The proxy doesn't know which dirs will be sandboxed later, so it can't enforce no overlap with a custom rules file.
    # Warn instead
    echo "[$SCRIPT_NAME] warning: keep custom config files OUTSIDE any workspace you sandbox with chopi --" >&2
    echo "              a sandboxed command that can write one can lift its own outgoing limits." >&2
fi

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
    local is_interactive=false
    [ -t 1 ] && is_interactive=true
    classify_log "$is_interactive" "$SCRIPT_NAME" notify_deny notify_reload "$VERBOSE"
}

notify_deny() {
    arity 1
    notify chopi-proxy-deny 'connection denied' "DENY $1"
}

# usage: notify_reload ok|failed
notify_reload() {
    arity 1
    case "$1" in
        failed) notify chopi-proxy-reload 'rules reload failed' \
                       "Your edit to ${RULES##*/} did not take effect" ;;
        # The rules now in effect are the user's latest: a failure banner still up is stale.
        ok) { alerter --remove chopi-proxy-reload >/dev/null 2>&1 || true; } & ;;
    esac
}

# Pop a macOS banner with SUBTITLE and MESSAGE, in the background, replacing the last one in
# GROUP -- so each kind of banner gets its own GROUP, lest a frequent kind (denials) bury a rare
# one. A click on it brings the proxy's terminal to focus.
#
# usage: notify GROUP SUBTITLE MESSAGE
notify() {
    arity 3
    local group="$1" subtitle="$2" message="$3"

    # macOS sets __CFBundleIdentifier to the terminal's bundle id; use it to bring the
    # proxy's terminal to focus if the notification is clicked.
    local term_bundle="${__CFBundleIdentifier:-}"

    {
        result=$(alerter --title 'Chopi' \
                         --subtitle "$subtitle" \
                         --message "$message" \
                         --group "$group" \
                         --timeout 10 2>/dev/null || true)
        case "$result" in
            @TIMEOUT | @CLOSED | '') ;;
            *) [ -n "$term_bundle" ] && open -b "$term_bundle" >/dev/null 2>&1 || true ;;
        esac
    } &
}

# Cleanup any temporaries this process generates on exit.
TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/chopi-proxy.XXXXXX")" \
    || { echo "error: could not create a temp dir for chopi-proxy" >&2; exit 1; }
trap 'rm -rf "$TMPDIR"' EXIT

# Render the GitHub relay config.
CADDY_LOG="$TMPDIR/caddy.log"
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
    # only.
    note_marker="NOTE"
    [ -t 2 ] && note_marker=$'\033[33mNOTE\033[0m'
    echo "[$SCRIPT_NAME] $note_marker: the GitHub allowlist is empty; only public fetch and anonymous public API reads are enabled until you add allowed repos." >&2
fi

# Strip any GitHub token the user exported into our environment to avoid passing it down to more processes
# (if set, resolve_gh_token already read it above).
unset GH_TOKEN GITHUB_TOKEN

# The API relay's socket: clear one a crashed prior run left, but not one that still answers, a
# running chopi-proxy's.
if sock_has_listener "$GH_RELAY_SOCK"; then
    echo "error: a running GitHub API relay already owns $GH_RELAY_SOCK" >&2
    exit 1
fi
rm -f "$GH_RELAY_SOCK"

# The run dir, out of the sandbox's reach, is ours alone.
mkdir -p "$CHOPI_RUN_DIR"
make_private_dir "$PROXY_RUN_DIR" || exit 1

echo "[$SCRIPT_NAME] relay log: $CADDY_LOG" >&2
echo "[$SCRIPT_NAME] starting the outgoing proxy and the GitHub relays (Ctrl-C to stop)" >&2
# chopi-smokescreen opens the listeners, serves the proxy, and starts Caddy on the relays' config,
# handed over stdin: printf is a builtin, so the baked GitHub token doesn't appear in any process's
# argv. It says where it serves once up. We stay, for Caddy to go with chopi-smokescreen however
# it goes; a Ctrl-C reaches it as a TERM from us.
lead_group "$SMOKESCREEN_BIN" \
    --relay-log "$CADDY_LOG" --git-port "$GITHUB_RELAY_PORT" --gh-sock "$GH_RELAY_SOCK" -- \
    --config-file ./.internal/smokescreen-config.yaml \
    --listen-ip 127.0.0.1 --listen-port "$PROXY_PORT" \
    --egress-acl-file "$RULES" \
    < <(printf '%s' "$CADDYFILE_TEXT") > >(format_smokescreen_log) 2>&1

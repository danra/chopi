#!/usr/bin/env bash
#
# chopi-proxy.sh -- run the outgoing network traffic proxy

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
CHOPI_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/.." && pwd -P)"

. "$CHOPI_DIR/.internal/util.sh"

usage() {
    cat <<EOF
usage: $SCRIPT_NAME [--allowlist FILE]   # listens on 127.0.0.1:$PROXY_PORT

  --allowlist FILE   use FILE as the outgoing allowlist instead of the default
                     config/proxy-allowlist.yaml
EOF
}

CUSTOM_ACL=""
INVOCATION_DIR="$PWD"
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --allowlist)
            if [ "$#" -lt 2 ]; then
                echo "error: --allowlist requires a file path" >&2
                usage >&2
                exit 1
            fi
            CUSTOM_ACL="$2"; shift 2 ;;
        *) usage >&2; exit 1 ;;
    esac
done

cd "$CHOPI_DIR"

if nc -z 127.0.0.1 "$PROXY_PORT" 2>/dev/null; then
    echo "error: something is already listening on 127.0.0.1:$PROXY_PORT" >&2
    exit 1
fi

if [ ! -x "$SMOKESCREEN_BIN" ]; then
    echo "Can't execute smokescreen. Install it with the installer ($CHOPI_DIR/install.sh)" >&2
    echo "or manually:  go install github.com/stripe/smokescreen@latest" >&2
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

if [ -n "$CUSTOM_ACL" ]; then
    case "$CUSTOM_ACL" in
        /*) ACL="$CUSTOM_ACL" ;;
        *)  ACL="$INVOCATION_DIR/$CUSTOM_ACL" ;;
    esac
    if [ ! -f "$ACL" ]; then
        echo "error: --allowlist file not found: $ACL" >&2
        exit 1
    fi

    # The proxy doesn't know which dirs will be sandboxed later, so it can't enforce no overlap with a custom allowlist.
    # Warn instead
    echo "[$SCRIPT_NAME] using custom outgoing allowlist: $ACL" >&2
    echo "[$SCRIPT_NAME] warning: keep this file OUTSIDE any workspace you sandbox with chopi --" >&2
    echo "              a sandboxed command that can write to its own allowlist can lift its outgoing limits." >&2
else
    ACL="./config/proxy-allowlist.yaml"
    if [ ! -f "$ACL" ]; then
        echo "error: no outgoing allowlist at $CHOPI_DIR/config/proxy-allowlist.yaml" >&2
        echo "Run the installer to create it from the template:  $CHOPI_DIR/install.sh" >&2
        echo "or copy it manually:  cp \"$CHOPI_DIR/config/templates/proxy-allowlist.template.yaml\" \"$CHOPI_DIR/config/proxy-allowlist.yaml\"" >&2
        exit 1
    fi
fi

. "$CHOPI_DIR/.internal/classify-log.sh"
for f in "$CONNECTION_FILTER" "$DENY_HOST_FILTER" "$FORMAT_DENY_FILTER" "$FORMAT_MISC_FILTER"; do
    if [ ! -f "$f" ]; then
        echo "error: missing log filter at $f" >&2
        exit 1
    fi
done

# Stream smokescreen's combined output through the shared classifier:
# - Denied connections show as "DENY host @ time" and trigger notifications
# - Allowed connections and the known noise are dropped
# - Every other line passes through. notify_deny pops the macOS banner on each DENY.
format_smokescreen_log() {
    local is_interactive=false
    [ -t 1 ] && is_interactive=true
    classify_log "$is_interactive" "$SCRIPT_NAME" notify_deny
}

notify_deny() {
    local host="$1"

    # macOS sets __CFBundleIdentifier to the terminal's bundle id; use it to bring the
    # proxy's terminal to focus if the notification is clicked.
    local term_bundle="${__CFBundleIdentifier:-}"

    {
        result=$(alerter --title 'Chopi' \
                         --subtitle 'connection denied' \
                         --message "DENY $host" \
                         --group 'chopi-proxy' \
                         --timeout 10 2>/dev/null || true)
        case "$result" in
            @TIMEOUT | @CLOSED | '') ;;
            *) [ -n "$term_bundle" ] && open -b "$term_bundle" >/dev/null 2>&1 || true ;;
        esac
    } &
}

echo "[$SCRIPT_NAME] starting outgoing proxy on 127.0.0.1:$PROXY_PORT (Ctrl-C to stop)" >&2
exec "$SMOKESCREEN_BIN" --config-file ./.internal/smokescreen-config.yaml \
              --listen-ip 127.0.0.1 --listen-port "$PROXY_PORT" \
              --egress-acl-file "$ACL" \
              > >(format_smokescreen_log) 2>&1

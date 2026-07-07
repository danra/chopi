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
usage: $SCRIPT_NAME [--rules FILE] [--verbose]   # listens on 127.0.0.1:$PROXY_PORT

  --rules FILE       use FILE as the proxy rules instead of the default
                     config/proxy-rules.yaml
  --verbose          show smokescreen's output verbatim, interleaved with chopi-proxy's
                     own: nothing is dropped or replaced.
EOF
}

CUSTOM_RULES=""
VERBOSE=false
INVOCATION_DIR="$PWD"
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --rules)
            if [ "$#" -lt 2 ]; then
                echo "error: --rules requires a file path" >&2
                usage >&2
                exit 1
            fi
            CUSTOM_RULES="$2"; shift 2 ;;
        --verbose) VERBOSE=true; shift ;;
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

if [ -n "$CUSTOM_RULES" ]; then
    case "$CUSTOM_RULES" in
        /*) RULES="$CUSTOM_RULES" ;;
        *)  RULES="$INVOCATION_DIR/$CUSTOM_RULES" ;;
    esac
    if [ ! -f "$RULES" ]; then
        echo "error: --rules file not found: $RULES" >&2
        exit 1
    fi

    # The proxy doesn't know which dirs will be sandboxed later, so it can't enforce no overlap with a custom rules file.
    # Warn instead
    echo "[$SCRIPT_NAME] using custom proxy rules: $RULES" >&2
    echo "[$SCRIPT_NAME] warning: keep this file OUTSIDE any workspace you sandbox with chopi --" >&2
    echo "              a sandboxed command that can write its own allowlist can lift its outgoing limits." >&2
else
    RULES="./config/proxy-rules.yaml"
    if [ ! -f "$RULES" ]; then
        echo "error: no outgoing rules at $CHOPI_DIR/config/proxy-rules.yaml" >&2
        echo "Run the installer to create it from the template:  $CHOPI_DIR/install.sh" >&2
        echo "or copy it manually:  cp \"$CHOPI_DIR/config/templates/proxy-rules.template.yaml\" \"$CHOPI_DIR/config/proxy-rules.yaml\"" >&2
        exit 1
    fi
fi

. "$CHOPI_DIR/.internal/classify-log.sh"
for f in "$CONNECTION_FILTER" "$DENY_HOST_FILTER" "$KNOWN_DENY_FILTER" \
         "$FORMAT_DENY_FILTER" "$FORMAT_MISC_FILTER"; do
    if [ ! -f "$f" ]; then
        echo "error: missing log filter at $f" >&2
        exit 1
    fi
done

# Stream smokescreen's combined output through the shared classifier:
# - Denied connections show as "DENY host @ time" and trigger notifications
# - Denials of hosts matching the configured denylist show as a plain "deny(known)" line,
#   once per host per session -- no notification, repeats dropped
# - Allowed connections and the known noise are dropped
# - Every other line passes through. notify_deny pops the macOS banner on each DENY.
format_smokescreen_log() {
    local is_interactive=false
    [ -t 1 ] && is_interactive=true
    classify_log "$is_interactive" "$SCRIPT_NAME" notify_deny "$VERBOSE"
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
              --egress-acl-file "$RULES" \
              > >(format_smokescreen_log) 2>&1

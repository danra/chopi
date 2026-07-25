#!/usr/bin/env bash
#
# install.sh -- chopi installer script
#
#   * installs dependencies
#   * copies templates to local config (if missing):
#   * offers to add chopi's bin/ to your PATH (in your shell rc)
#
# --uninstall makes a best-effort to undo the installer's effects
#             outside of chopi's own folder.

set -euo pipefail

# macOS-only
if [ "$(uname -s)" != "Darwin" ]; then
    echo "error: chopi relies on macOS Seatbelt (sandbox-exec) and only runs on macOS." >&2
    exit 1
fi

SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"

. "$SCRIPT_DIR/.internal/util.sh"
. "$SCRIPT_DIR/.internal/shell-rc.sh"

usage="usage: ./install.sh [--uninstall]"

usage_error() {
    arity 1
    local message="$1"
    echo "install.sh: $message" >&2
    echo "$usage" >&2
    exit 1
}

# The whole argv is checked before any of it is acted on, so a help flag doesn't mask a
# bad option behind it. Each option is a mode of its own, so anything past the first
# (a repeat of it included) is a mistake, not a refinement.
help=""
uninstall=""
for arg in "$@"; do
    case "$arg" in
        -h|--help)   help=1 ;;
        --uninstall) uninstall=1 ;;
        *)           usage_error "unknown option: $arg" ;;
    esac
done
[ "$#" -le 1 ] || usage_error "expected at most one option, got: $*"

if [ -n "$help" ]; then
    echo "$usage"
    exit 0
fi


# ----------------------------------------------------------------------------
# Uninstall (only what the installer added outside of chopi's own folder)
# ----------------------------------------------------------------------------

uninstall_chopi() {
    arity 0
    local rc_file
    rc_file="$(shell_rc_file)"

    echo "==> Removing chopi from your PATH"
    if [ -z "$rc_file" ]; then
        echo "  couldn't detect your shell's rc file (SHELL=${SHELL:-unset})."
        echo "  If chopi is on your PATH, remove this line from your shell startup file:"
        echo ""
        echo "      $CHOPI_PATH_LINE"
    elif rc_remove_line "$rc_file" "$CHOPI_PATH_LINE"; then
        echo "  removed chopi's PATH line from $rc_file"
    else
        echo "  could not find chopi's PATH line in $rc_file, left as-is"
    fi

    echo ""
    echo "==> Done."
    echo ""
    echo "Left in place:"
    echo "  * chopi's dir (with its local config)"
    echo "  * Homebrew dependencies (go, jq, alerter, safehouse, caddy)"
}

if [ -n "$uninstall" ]; then
    uninstall_chopi
    exit 0
fi

if busy_port="$(first_listening_port "$PROXY_PORT" "$GITHUB_RELAY_PORT")"; then
    echo "error: chopi-proxy (or something else) is currently running and listening on port $busy_port." >&2
    echo "Shut it down, then re-run this script." >&2
    exit 1
fi


# ----------------------------------------------------------------------------
# Dependencies
# ----------------------------------------------------------------------------

if ! command -v brew >/dev/null 2>&1; then
    echo "error: Homebrew is required but was not found on PATH." >&2
    echo "Install it from https://brew.sh, open a new terminal, then re-run this script." >&2
    exit 1
fi

echo "==> Installing dependencies"

ensure_brew() {
    arity 2
    local cmd="$1" formula="$2"
    if command -v "$cmd" >/dev/null 2>&1; then
        echo "  ok: $cmd already installed ($(command -v "$cmd"))"
        return
    fi
    echo "  installing $cmd  (brew install $formula)"
    trace_on; HOMEBREW_NO_AUTO_UPDATE=1 brew install "$formula"; trace_off
}

ensure_brew go        go
ensure_brew jq        jq
ensure_brew alerter   vjeantet/tap/alerter
ensure_brew safehouse eugene1g/safehouse/agent-safehouse
ensure_brew caddy     caddy

# A brew install in this same run may have added go to a bin dir that bash has
# already cached as "not found"; clear the cache before relying on `go` below.
hash -r 2>/dev/null || true

if command -v go >/dev/null 2>&1; then
    echo "  building chopi-smokescreen"
    trace_on; make -C "$CHOPI_DIR" build; trace_off
else
    echo "error: go is needed to build chopi's proxy but isn't on PATH yet." >&2
    echo "Open a new terminal so PATH picks up Homebrew, then re-run this script." >&2
    exit 1
fi


# ----------------------------------------------------------------------------
# Local config files (copied from the checked-in templates, then customized)
# ----------------------------------------------------------------------------

echo "==> Creating local config if missing"

ensure_copy() {
    arity 2
    local template="$1" live="$2"
    local src="$CHOPI_DIR/$template" dst="$CHOPI_DIR/$live"
    if [ -f "$dst" ]; then
        echo "  $live already exists, left as-is"
        return
    fi
    cp "$src" "$dst"
    echo "  created $live  (from $template)"
}

ensure_copy config/templates/proxy-rules.template.yaml config/proxy-rules.yaml
ensure_copy config/templates/github-allowlist.template config/github-allowlist
ensure_copy config/templates/sandbox.template.sh           config/sandbox.sh


# ----------------------------------------------------------------------------
# Shell setup (offer to put bin/ on your PATH)
# ----------------------------------------------------------------------------

echo "==> Shell setup"

RC_FILE="$(shell_rc_file)"

print_manual() {
    echo "  You can add chopi to your PATH by adding this line to ${RC_FILE:-your shell startup file}:"
    echo ""
    echo "      $CHOPI_PATH_LINE"
    echo ""
    echo "  Then open a new terminal (or source that file) to pick it up."
}

if [ -z "$RC_FILE" ]; then
    echo "  couldn't detect your shell's rc file (SHELL=${SHELL:-unset})."
    print_manual
elif file_has_line "$RC_FILE" "$CHOPI_PATH_LINE"; then
    echo "  chopi is already on your PATH."
elif [ -t 0 ]; then
    # Offer to add chopi to PATH
    printf '  Add chopi to your PATH? [Y/n] '
    read -r reply || reply=""
    case "$reply" in
        ""|[Yy]*)
            printf '\n%s\n' "$CHOPI_PATH_LINE" >> "$RC_FILE"
            echo "  added chopi's PATH line to $RC_FILE"
            ;;
        *)
            echo "  left $RC_FILE unchanged."
            print_manual
            ;;
    esac
else
    # Non-interactive install (piped/CI): can't prompt, so just show the line.
    print_manual
fi


# ----------------------------------------------------------------------------
# Done
# ----------------------------------------------------------------------------

echo ""
echo "==> Done."
echo ""
echo "Before first use, review your local setup:"
echo "  * the proxy rules            ($CHOPI_DIR/config/proxy-rules.yaml)"
echo "  * the GitHub allowlist       ($CHOPI_DIR/config/github-allowlist)"
echo "  * the sandbox configuration  ($CHOPI_DIR/config/sandbox.sh)"
echo ""
echo "To use it:"
echo "  1. In one terminal, start the outgoing proxy and leave it running:  chopi-proxy"
echo "  2. From inside the repo you're working on, run a command:           chopi <cmd> [args...]"

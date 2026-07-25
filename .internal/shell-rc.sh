# shellcheck shell=bash
# shellcheck disable=SC2034 # Defines variables that are used by the scripts that source this file
#
# shell-rc.sh -- shell .rc file helpers for install.sh
#
# Sourced (never run directly).

# The PATH line install.sh adds. It PREPENDS chopi's bin, so a later reinstall from a
# different path takes precedence.
CHOPI_PATH_LINE="export PATH=\"$CHOPI_DIR/bin:\$PATH\""

# The startup file for the user's shell, or nothing when the shell isn't one we know.
shell_rc_file() {
    arity 0
    local shell_name
    shell_name="$(basename "${SHELL:-}")"
    case "$shell_name" in
        zsh)  printf '%s' "$HOME/.zshrc" ;;
        bash) printf '%s' "$HOME/.bashrc" ;;
    esac
}

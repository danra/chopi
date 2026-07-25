# shellcheck shell=bash
# shellcheck disable=SC2034 # Defines variables that are used by the scripts that source this file
#
# shell-rc.sh -- shell .rc file helpers for install.sh
#
# Sourced (never run directly).

# The PATH line install.sh adds. It PREPENDS chopi's bin, so a later reinstall from a
# different path takes precedence. The line embeds this clone's path, so an uninstall only
# ever matches the line that installed from here.
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

# Drop FILE's first line reading LINE (modulo trimming whitespace around the line), along with
# a blank line immediately before it: install.sh writes one as a separator, so an
# install/uninstall cycle leaves the file as it was. Fails without touching FILE when it has no
# such line.
#
# The rewrite goes through a temp file in FILE's own directory, so the replacement is an
# atomic rename. The mode is copied over because mktemp's is 0600 and this is the user's
# startup file.
rc_remove_line() {
    arity 2
    local file="$1" line="$2"

    local lineno
    lineno="$(file_line_number "$file" "$line")" || return 1

    local tmp
    tmp="$(mktemp "$file.chopi.XXXXXX")" || return 1

    awk -v drop="$lineno" 'NR == drop || (NR == drop - 1 && $0 == "") { next } { print }' "$file" >"$tmp"

    local mode
    mode="$(stat -f '%Lp' "$file" 2>/dev/null)" && chmod "$mode" "$tmp"
    mv "$tmp" "$file"
}

#!/usr/bin/env bash
#
# git-protect.sh -- write the Seatbelt profiles for chopi's git protections.
#
# Not run directly; `chopi` calls this before invoking safehouse.
#
# usage: git-protect.sh [--verbose]
#
#   --verbose  also print the resolved git layout (the CHOPI_GIT_* globals) to
#              stderr, for debugging
#
# Prints the NUL-terminated generated profile paths to stdout.
#
# Chopi runs this only when the current dir is the root of a git worktree and preflight
# confirmed the repo's layout is supported and can be safely covered by chopi.

set -euo pipefail

SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
. "$SCRIPT_DIR/git-layout.sh"
. "$SCRIPT_DIR/git-isolate.sh"
. "$SCRIPT_DIR/git-harden.sh"

main() {
    local verbose=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --verbose) verbose=1; shift ;;
            *) echo "error: git-protect: unexpected argument: $1" >&2; return 1 ;;
        esac
    done

    collect_layout || return 1
    [ -n "$verbose" ] && print_git_layout

    local isolate_profile
    isolate_profile="$(mktemp "$TMPDIR/chopi-git-isolate.XXXXXX")" || return 1
    isolate_profile="$(realpath "$isolate_profile")" || return 1
    if ! write_isolation_profile "$isolate_profile"; then
        echo "error: could not write the git isolation profile" >&2
        return 1
    fi

    local harden_profile
    harden_profile="$(mktemp "$TMPDIR/chopi-git-harden.XXXXXX")" || return 1
    harden_profile="$(realpath "$harden_profile")" || return 1
    if ! write_hardening_profile "$harden_profile"; then
        echo "error: could not write the git hardening profile" >&2
        return 1
    fi

    # The machine contract for chopi: the profiles to append, in order. NUL-terminated
    # so a path containing a newline survives intact.
    printf '%s\0' "$isolate_profile" "$harden_profile"
}

main "$@"

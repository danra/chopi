#!/usr/bin/env bash
#
# git-protect-wrapper.sh -- wrap the sandboxed command to perform additional
# in-sandbox setup supporting chopi's git protections:
# - appends git config entries to the existing GIT_CONFIG_* environment, if any.
# - on exit, aborts any in-progress git rebase/cherry-pick left behind by the command.
#
# usage: git-protect-wrapper.sh CLEANUP_SCRIPT_PATH [key=value ...] -- <executable> [args...]
#
# Not run directly; Whenever the run dir is a git worktree root, chopi prepends this
# wrapper to the sandboxed command, when its environment is available. Per git rules,
# a later GIT_CONFIG_* pair for the same key wins an earlier one, so because we *append*
# ours to the host's, a value here overrides a forwarded host value for the same key.

set -euo pipefail

_cleanup_script_path=""

_cleanup() {
    local rc=$?
    "$_cleanup_script_path" || true
    exit "$rc"
}

main() {
    local prog="git-protect-wrapper"
    if [ "$#" -eq 0 ] || [ "$1" = "--" ]; then
        echo "$prog: error: invalid args" >&2
        return 2
    fi
    _cleanup_script_path="$1"; shift

    local pairs=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --)  shift; break ;;
            =*)  echo "$prog: key must be non-empty in '$1'" >&2
                 return 2 ;;
            *=*) pairs+=("$1"); shift ;;
            *)   echo "$prog: expected key=value or --, got '$1'" >&2
                 return 2 ;;
        esac
    done
    if [ "$#" -eq 0 ]; then
        echo "$prog: no command given after '--'" >&2
        return 2
    fi

    local count="${GIT_CONFIG_COUNT:-0}"
    if ! [[ "$count" =~ ^[0-9]+$ ]]; then
        echo "$prog: preexisting GIT_CONFIG_COUNT must be a non-negative integer (got '$count')" >&2
        return 2
    fi

    local kv
    for kv in "${pairs[@]+"${pairs[@]}"}"; do
        export "GIT_CONFIG_KEY_${count}=${kv%%=*}" "GIT_CONFIG_VALUE_${count}=${kv#*=}"
        count=$((count + 1))
    done
    export GIT_CONFIG_COUNT="$count"

    # We must outlive the command to run the cleanup -- even if a signal kills the command --
    # while keeping the command itself interruptible. Trap the signals with a handler (NOT ''),
    # so on exec the child resets them to their default disposition; bash defers a trapped signal
    # until the foreground command completes, so the command runs to completion first, then
    # _cleanup (EXIT trap) runs the cleanup.
    trap _cleanup EXIT
    trap 'exit' INT TERM HUP
    set +e
    "$@"
}

main "$@"

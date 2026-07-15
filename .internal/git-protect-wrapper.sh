#!/usr/bin/env bash
#
# git-protect-wrapper.sh -- wrap the sandboxed command to perform additional
# in-sandbox setup supporting chopi's git protections. Currently appends git
# config entries to the existing GIT_CONFIG_* environment, if any.
#
# usage: git-protect-wrapper.sh [key=value ...] -- <executable> [args...]
#
# Not run directly; chopi prepends it to the sandboxed command when its environment
# is available. Per git rules, a later GIT_CONFIG_* pair for the same key wins an earlier
# one, so because we *append* ours to the host's, a value here overrides a forwarded host
# value for the same key.
#
# Deliberately self-contained, so the sandbox profile only needs a single additional
# allow read+exec entry for this specific file.

set -euo pipefail

main() {
    local prog="git-protect-wrapper"
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

    exec "$@"
}

main "$@"

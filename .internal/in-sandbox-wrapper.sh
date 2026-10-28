#!/usr/bin/env bash
#
# in-sandbox-wrapper.sh -- wrap the sandboxed command to perform additional
# in-sandbox setup before launching it:
# - refuses to launch the command when it could write the proxy's config, its rules or GitHub
#   allowlist: one that can rewrite them can lift its own outgoing limits.
# - appends git config entries to the existing GIT_CONFIG_* environment, if any.
# - refuses to launch the command when the resulting config does not route github git to
#   chopi's GitHub relay (a competing user insteadOf overrides the rewrite).
# - refuses to launch `claude` when the sandbox denies reading a Claude context symlink target
#   or @-import, listing the denied paths so the user grants the reads in the config.
# - on exit, aborts any in-progress git rebase/cherry-pick left behind by the command.
#
# usage: in-sandbox-wrapper.sh CLEANUP_SCRIPT_PATH [key=value ...] -- <executable> [args...]
#
# Not run directly; chopi prepends this wrapper to the sandboxed command, running it
# in-sandbox where the command's environment is available. Per git rules,
# a later GIT_CONFIG_* pair for the same key wins an earlier one, so because we *append*
# ours to the host's, a value here overrides a forwarded host value for the same key.

set -euo pipefail

_wrapper_path="$(realpath "${BASH_SOURCE[0]}")"
_wrapper_dir="$(dirname "$_wrapper_path")"
. "$_wrapper_dir/util.sh"
. "$_wrapper_dir/claude-context-check.sh"
unset _wrapper_path _wrapper_dir

_cleanup_script_path=""

# shellcheck disable=SC2329  # invoked via the EXIT trap main sets
_cleanup() {
    local rc=$?
    "$_cleanup_script_path" || true
    exit "$rc"
}

# Where the sandbox lets the command change the proxy's config file FILE, if anywhere: set in VAR, the
# file itself or the first dir on its path the command can write in, which lets it put a file of
# its own in FILE's place. The file's own Unix permissions don't count: the command runs as its
# owner, free to change them, so every probe asks what only the sandbox can refuse.
#
# usage: proxy_config_changeable_at VAR FILE
_unchangeable_dirs=()
proxy_config_changeable_at() {
    arity 2
    local var="$1" file="$2" dir probe
    # The file: opened to append, writing nothing, and its times set to what they already are
    # (touch -r: from the file itself as reference), a change only the sandbox can refuse its owner
    # -- one that could as well make it writable. Either leaves the file as it was, its
    # modification time included, so the proxy doesn't reload it. Neither when the file is
    # missing, as both would create it.
    if [ -f "$file" ] && { { : >>"$file"; } 2>/dev/null || touch -r "$file" "$file" 2>/dev/null; }; then
        printf -v "$var" '%s' "$file"
        return 0
    fi
    # Each dir on its path, asked as the file is: by creating an entry in it, or else by setting its
    # times to what they already are, for one the command could make writable. A dir already found
    # unchangeable for another file ends the walk: so are all above it, as the walk went on past it.
    dir="$file"
    while [ "$dir" != / ]; do
        dir="${dir%/*}"
        dir="${dir:-/}"
        ! is_item_in_list "$dir" "${_unchangeable_dirs[@]+"${_unchangeable_dirs[@]}"}" || return 1
        if { probe="$(mktemp -d "${dir%/}/.chopi-probe.XXXXXX" 2>/dev/null)" && rmdir "$probe"; } \
            || touch -r "$dir" "$dir" 2>/dev/null; then
            printf -v "$var" '%s' "$dir"
            return 0
        fi
        _unchangeable_dirs+=("$dir")
    done
    return 1
}

main() {
    local prog="in-sandbox-wrapper"
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

    # Refuse to run where the command could write the proxy's config (CHOPI_PROXY_CONFIG_FILES, one
    # per line), mid-session even, as the proxy hot-reloads its rules. Asked of the sandbox itself,
    # here in it: every path it lets the command write counts, whichever grant opened it -- chopi's
    # own, the sandbox config's, safehouse's profiles, a trusted .safehouse, SAFEHOUSE_* in the
    # environment.
    if [ -z "${CHOPI_PROXY_CONFIG_FILES:-}" ]; then
        echo "$prog: CHOPI_PROXY_CONFIG_FILES is not set" >&2
        return 2
    fi
    local file at reason
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        proxy_config_changeable_at at "$file" || continue
        if [ "$at" = "$file" ]; then
            reason="the proxy's config file '$file' is writable by the sandboxed command"
        else
            reason="the proxy's config file '$file' is replaceable by the sandboxed command, which can write in '$at'"
        fi
        refuse_or_warn "$reason" \
            "the sandboxed command could lift its own outgoing limits" \
            "Keep the proxy's config out of every path the sandbox lets the command write." \
            || return 1
    done <<< "$CHOPI_PROXY_CONFIG_FILES"
    unset CHOPI_PROXY_CONFIG_FILES CHOPI_ALLOW_SELF

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

    # With the final command-scope config now exported, confirm chopi's GitHub->relay rewrite
    # actually wins it: a competing insteadOf in the user's config takes the longest-prefix tie
    # (earlier-read scopes win it) and would divert github git off the relay onto a transport
    # the sandbox blocks. Checked here, in-sandbox, against exactly the config "$@" will see.
    if [ -z "${CHOPI_GITHUB_RELAY_PORT:-}" ]; then
        echo "$prog: CHOPI_GITHUB_RELAY_PORT is not set" >&2
        return 2
    fi
    local reroute_rc=0 git_err
    git_err="$(is_github_relay_reroute_effective "$CHOPI_GITHUB_RELAY_PORT" 2>&1 >/dev/null)" \
        || reroute_rc=$?
    if [ "$reroute_rc" -eq 2 ]; then
        echo "chopi: error: git fails in the sandbox, so chopi cannot check its GitHub relay routing:" >&2
        printf '%s\n' "$git_err" | sed 's/^/       /' >&2
        return 1
    fi
    if [ "$reroute_rc" -ne 0 ]; then
        echo "chopi: error: a git 'insteadOf' rewrite in your config overrides chopi's GitHub relay routing;" >&2
        echo "       find it with: git config --show-origin --get-regexp 'url\\..*\\.insteadof' github.com" >&2
        echo "       then remove or narrow the rewrite." >&2
        return 1
    fi

    # Refuse to launch claude while any Claude context symlink target or @-import is unreadable.
    if is_claude_command "$1"; then
        local run_dir
        run_dir="$(pwd -P)" \
            || { echo "chopi: error: cannot resolve the sandboxed working directory" >&2; return 1; }
        refuse_unreadable_claude_context "$run_dir" || return 1
    fi

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

{
    main "$@"
    # The braces make bash parse this whole block, exit included, before running it, so a
    # mid-session edit to this file cannot affect it: without the exit, bash would read the
    # file again after main returns, at a stale byte offset that executes garbage.
    exit
}

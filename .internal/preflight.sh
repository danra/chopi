# shellcheck shell=bash
#
# preflight.sh -- pre-run checks for chopi, as functions chopi calls at two points.
#
# Sourced (never run directly). The checks are split by WHEN they can run, because chopi
# only learns the dir the command will actually run in partway through setup:
#   * preflight_initial          -- runnable up front: the workspace doesn't overlap chopi's
#                                   own dir (a confined command must not reach the policy
#                                   that confines it) or chopi-proxy's run dir (whose ports
#                                   aim the holes), the proxy-side services (both loopback
#                                   ports, as chopi-proxy reports them, and the GitHub API relay
#                                   socket) are up, and the safehouse CLI is on PATH.
#   * preflight_config_placement -- deferred until chopi has resolved the workspace (the
#                                   --worktree target), since that is the dir a custom
#                                   --config must stay outside of.

_preflight_dir="$(dirname "${BASH_SOURCE[0]}")"
. "$_preflight_dir/util.sh"
unset _preflight_dir

refuse_or_warn() {
    arity 3
    local reason="$1" detail="$2" hint="$3"
    if [ -n "${CHOPI_ALLOW_SELF:-}" ]; then
        echo "warning: $reason;" >&2
        echo "         $detail." >&2
        echo "         continuing anyway (CHOPI_ALLOW_SELF is set)." >&2
        echo >&2
    else
        echo "error: $reason;" >&2
        echo "       $detail." >&2
        echo "$hint" >&2
        return 1
    fi
}

# check_listener -- confirm something is listening on 127.0.0.1:PORT, else print an error naming
# WHAT (e.g. "no outgoing proxy") and HINT, then fail. Liveness only: it confirms something is
# listening, not that it's ours. We deliberately don't verify the listener's identity because no
# purely-local check can: hijacking the port takes separate local code execution (the sandboxed
# command itself can't bind it), and a same-user attacker who can do that can equally run
# smokescreen/chopi-proxy or forge any pidfile or token we'd check -- same-user processes have equal
# OS authority. An identity check would add cost and a false sense of security without changing what
# such an attacker must do.
check_listener() {
    arity 3
    local port="$1" what="$2" hint="$3"
    if ! port_has_listener "$port"; then
        echo "error: $what on 127.0.0.1:$port" >&2
        echo "$hint" >&2
        return 1
    fi
}

preflight_initial() {
    arity 0

    local workspace_dir
    workspace_dir="$(pwd -P)" || { echo "error: cannot resolve current directory" >&2; return 1; }

    if overlaps_chopi_dir "$workspace_dir"; then
        refuse_or_warn \
            "workspace '$workspace_dir' overlaps chopi's own directory ('$CHOPI_DIR')" \
            "the sandboxed command would get read/write access to its own config" \
            "Run chopi from inside the repo you're working on, not from chopi's own dir, a parent of it, or a subdir of it." \
            || return 1
    fi

    # The ports file in the run dir aims this run's holes and HTTP_PROXY, so the sandboxed command
    # must not reach it. Not a CHOPI_ALLOW_SELF matter: working on chopi needs no access to it.
    if overlaps_proxy_run_dir "$workspace_dir"; then
        echo "error: workspace '$workspace_dir' overlaps chopi-proxy's run directory ('$PROXY_RUN_DIR');" >&2
        echo "       the sandboxed command could rewrite the ports that aim its own network holes." >&2
        echo "Run chopi from a workspace that neither holds nor sits inside $PROXY_RUN_DIR, or point" >&2
        echo "CHOPI_RUN_DIR (for both chopi-proxy and chopi) elsewhere." >&2
        return 1
    fi

    # The outgoing proxy must already be running in its own terminal. We deliberately
    # don't start it here, so it stays in the foreground where you can watch refused
    # connections and stop it to edit the list of allowed domains. It reports the ports the
    # kernel picked for it once it serves.
    if ! read_proxy_ports; then
        echo "error: no outgoing proxy: no ports reported in $PROXY_PORTS_FILE" >&2
        echo "Start it first in a separate terminal, in this same environment (a proxy started" >&2
        echo "under a different CHOPI_RUN_DIR reports them elsewhere):  chopi-proxy" >&2
        return 1
    fi
    check_listener "$PROXY_PORT" "no outgoing proxy" \
        "$PROXY_PORTS_FILE is stale; (re)start it in a separate terminal:  chopi-proxy" || return 1

    check_listener "$GITHUB_RELAY_PORT" "no GitHub relay" \
        "It runs alongside the outgoing proxy; (re)start both in a separate terminal:  chopi-proxy" || return 1

    if ! sock_has_listener "$GH_RELAY_SOCK"; then
        echo "error: no GitHub API relay listening at $GH_RELAY_SOCK" >&2
        echo "Start chopi-proxy in this same environment first (a proxy started under a" >&2
        echo "different CHOPI_RUN_DIR binds a different socket path)." >&2
        return 1
    fi

    # Agent Safehouse builds the sandbox policy and execs the command inside it, so
    # it's a per-run dependency. Fail fast with a pointer rather than a bare
    # "command not found" when chopi calls it.
    if ! command -v safehouse >/dev/null 2>&1; then
        echo "error: safehouse CLI not found on PATH" >&2
        echo "Install it (see README, Prerequisites): https://github.com/eugene1g/agent-safehouse" >&2
        return 1
    fi
}

# preflight_config_placement <config_file> <run_dir>
#
# Refuse a custom --config file inside the workspace run_dir; with CHOPI_ALLOW_SELF non-empty, only
# warn. Also fails when either path can't be resolved, e.g. a missing --config file.
preflight_config_placement() {
    arity 2
    local config_file="$1" run_dir="$2"

    local real_run_dir
    real_run_dir="$(realpath "$run_dir" 2>/dev/null)" \
        || { echo "error: preflight: cannot resolve run dir '$run_dir'" >&2; return 1; }

    local config_abs
    if ! config_abs="$(realpath "$config_file" 2>/dev/null)"; then
        echo "error: cannot resolve --config path '$config_file' (does it exist?)" >&2
        return 1
    fi
    if is_path_within "$config_abs" "$real_run_dir"; then
        refuse_or_warn \
            "--config file '$config_abs' is inside the workspace ('$real_run_dir')" \
            "the sandboxed command would get read/write access to the config that defines its own sandbox" \
            "Keep the sandbox config outside the workspace you're sandboxing." \
            || return 1
    fi
}

# Refuse a proxy config file (proxy_config_paths) with extra hard links: write_proxy_config_profile
# denies changes by path, so the sandboxed command could write the live rules through another link.
# The sandbox keeps the command from making one, but not one made outside it. The proxy refuses a
# change to a file with one made once the session is up (see its applyIfChanged).
#
# usage: preflight_proxy_config_links
preflight_proxy_config_links() {
    arity 0
    local path file existing=()
    while IFS= read -r path; do
        [ -e "$path" ] && existing+=("$path")
    done < <(proxy_config_paths)
    [ "${#existing[@]}" -gt 0 ] || return 0
    # Run to the end before any refusal, for find's status: a file it couldn't check (an unreadable
    # dir) may be one with other hard links.
    local linked
    if ! linked="$(find "${existing[@]}" -type f -links +1)"; then
        echo "error: could not check every proxy config file for other hard links, which the sandboxed" >&2
        echo "       command may write through (see find's error above)." >&2
        echo "Make everything under ${existing[*]} readable to you." >&2
        return 1
    fi
    [ -n "$linked" ] || return 0
    while IFS= read -r file; do
        refuse_or_warn \
            "the proxy's config file '$file' has other hard links, which the sandboxed command may write through" \
            "the sandboxed command could lift its own outgoing limits, and every other session's" \
            "Replace it with a fresh copy, e.g.: cp '$file' '$file.tmp' && mv '$file.tmp' '$file'" \
            || return 1
    done <<<"$linked"
}

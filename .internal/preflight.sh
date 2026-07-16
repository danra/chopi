# shellcheck shell=bash
#
# preflight.sh -- pre-run checks for chopi, as functions chopi calls at two points.
#
# Sourced (never run directly). The checks are split by WHEN they can run, because chopi
# only learns the dir the command will actually run in partway through setup:
#   * preflight_initial          -- runnable up front: the workspace doesn't overlap chopi's
#                                   own dir (a confined command must not reach the policy
#                                   that confines it), the outgoing proxy is up, and the
#                                   safehouse CLI is on PATH.
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
        echo
    else
        echo "error: $reason;" >&2
        echo "       $detail." >&2
        echo "$hint" >&2
        return 1
    fi
}

preflight_initial() {
    arity 0

    local workspace_dir
    workspace_dir="$(pwd -P)" || { echo "error: cannot resolve current directory" >&2; return 1; }

    # chopi's whole promise is that it lives OUTSIDE the tree it sandboxes, so a
    # confined command can't reach chopi's own policy and edit what confines
    # it. Enforce it: refuse when the workspace and chopi's own dir overlap in EITHER
    # direction -- the workspace is chopi's dir, contains it (a parent), or is nested
    # inside it (e.g. run from chopi/config). In any of those the workspace's
    # read/write grant would cover chopi's own config. Setting CHOPI_ALLOW_SELF
    # downgrades the hard error to a warning (for developing chopi itself).
    if is_path_within "$CHOPI_DIR" "$workspace_dir" || is_path_within "$workspace_dir" "$CHOPI_DIR"; then
        refuse_or_warn \
            "workspace '$workspace_dir' overlaps chopi's own directory ('$CHOPI_DIR')" \
            "the sandboxed command would get read/write access to its own config" \
            "Run chopi from inside the repo you're working on, not from chopi's own dir, a parent of it, or a subdir of it." \
            || return 1
    fi

    # The outgoing proxy must already be running in its own terminal. We deliberately
    # don't start it here, so it stays in the foreground where you can watch refused
    # connections and stop it to edit the list of allowed domains.
    #
    # This is a liveness check only -- it confirms something is listening, not that it's
    # our smokescreen. We deliberately don't verify the listener's identity because no
    # purely-local check can: hijacking the port takes separate local code execution (the
    # sandboxed command itself can't bind it), and a same-user attacker who can do that can
    # equally run smokescreen/chopi-proxy or forge any pidfile or token we'd check -- same-user
    # processes have equal OS authority. An identity check would add cost and a false sense of
    # security without changing what such an attacker must do.
    if ! nc -z 127.0.0.1 "$PROXY_PORT" 2>/dev/null; then
        echo "error: no outgoing proxy on 127.0.0.1:$PROXY_PORT" >&2
        echo "Start it first in a separate terminal:  chopi-proxy" >&2
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

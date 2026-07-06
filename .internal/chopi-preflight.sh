#!/usr/bin/env bash
#
# chopi-preflight.sh -- pre-run checks for `chopi`.
#
# Not run directly; `chopi` calls this before invoking safehouse.
#
# Checks, in order:
#   * the workspace doesn't overlap chopi's own dir (a confined command must not be able
#     to reach the policy that confines it),
#   * a custom --config, if given, isn't placed inside the workspace it would sandbox,
#   * the outgoing proxy is already up, and
#   * the safehouse CLI is on PATH.
#
# usage: chopi-preflight.sh [--config FILE]
#   --config FILE  custom sandbox config to verify not placed inside the workspace.

set -euo pipefail

CHOPI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

. "$CHOPI_DIR/.internal/util.sh"

# Is directory $1 the same as, or nested inside, directory $2? Both are absolute and
# normalized (no trailing slash except the root "/").
is_path_within() {
    arity 2
    local inner="$1" outer="$2"
    [ "$inner" = "$outer" ] && return 0
    [ "$outer" = "/" ] && return 0   # every absolute path is inside the root
    case "$inner" in "$outer"/*) return 0 ;; esac
    return 1
}

# self-overlap guard: hard-error, or warn if CHOPI_ALLOW_SELF is set
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

preflight() {
    local workspace_dir
    workspace_dir="$(pwd -P)" || { echo "error: cannot resolve current directory" >&2; return 1; }

    # Optional path to a custom sandbox config (chopi's --config). Empty means the
    # default config/sandbox.sh, which lives under chopi's own dir and is therefore
    # already covered by the chopi-dir overlap check below.
    local config_file=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --config)
                if [ "$#" -lt 2 ]; then echo "error: --config requires a file path" >&2; return 1; fi
                config_file="$2"; shift 2 ;;
            *) echo "error: preflight: unexpected argument: $1" >&2; return 1 ;;
        esac
    done

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

    # Verify a custom --config file doesn't live inside the workspace
    if [ -n "$config_file" ]; then
        local config_abs
        if ! config_abs="$(realpath "$config_file" 2>/dev/null)"; then
            echo "error: cannot resolve --config path '$config_file' (does it exist?)" >&2
            return 1
        fi
        if is_path_within "$config_abs" "$workspace_dir"; then
            refuse_or_warn \
                "--config file '$config_abs' is inside the workspace ('$workspace_dir')" \
                "the sandboxed command would get read/write access to the config that defines its own sandbox" \
                "Keep the sandbox config outside the workspace you're sandboxing." \
                || return 1
        fi
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

# Only dispatch when run as a program. In production this script is always executed (the
# chopi function calls it before invoking safehouse), never sourced, so the guard is a
# no-op there. It exists so the tests can `source` this file to exercise the pure helpers
# (is_path_within) directly without tripping the dispatch.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    preflight "$@"
fi

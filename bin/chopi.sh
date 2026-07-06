#!/usr/bin/env bash
#
# chopi.sh -- run a command under chopi's macOS filesystem+network sandbox.
#
# Usually invoked as `chopi` via the sibling symlink (bin/chopi -> chopi.sh).

set -euo pipefail

CHOPI_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/.." && pwd -P)"

. "$CHOPI_DIR/.internal/util.sh"

usage="usage: chopi [--config FILE] <executable> [args...]

  --config FILE   use FILE as the sandbox config instead of the default
                  config/sandbox.sh"

# Every chopi run gets its own private subfolder under TMPDIR (or /tmp), exported into TMPDIR.
# safehouse forwards TMPDIR to the sandboxed command, so all generated temporaries (for generation
# that respects TMPDIR) are contained in it and cleaned up on exit.
CHOPI_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/chopi.XXXXXX")" \
    || { echo "chopi: could not create a temp dir for the run" >&2; exit 1; }
export TMPDIR="$CHOPI_TMPDIR"
trap 'rm -rf "$CHOPI_TMPDIR"' EXIT

main() {
    local config="$CHOPI_DIR/config/sandbox.sh"
    local config_given=""

    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)  echo "$usage"; return 0 ;;
            --config)
                if [ "$#" -lt 2 ]; then echo "chopi: --config requires a file path" >&2; return 1; fi
                config="$2"; config_given=1; shift 2 ;;
            --)         shift; break ;;
            -*)         echo "chopi: unknown option: $1" >&2; echo "$usage" >&2; return 1 ;;
            *)          break ;;
        esac
    done

    if [ "$#" -eq 0 ]; then echo "$usage" >&2; return 1; fi

    # Empty-array expansions below use the "${a[@]+"${a[@]}"}" form so they stay silent
    # under `set -u` on bash 3.2 (macOS's system bash), where a bare "${a[@]}" on an empty
    # array is an "unbound variable" error.
    local preflight_args=()
    [ -n "$config_given" ] && preflight_args=(--config "$config")
    "$CHOPI_DIR/.internal/chopi-preflight.sh" "${preflight_args[@]+"${preflight_args[@]}"}" || return $?

    local CHOPI_SAFEHOUSE_FLAGS=()
    local CHOPI_EXTRA_ENV=()
    if [ ! -r "$config" ]; then
        if [ -n "$config_given" ]; then
            echo "chopi: cannot read sandbox config '$config'" >&2
        else
            echo "chopi: cannot read $config; re-run install.sh" >&2
        fi
        return 1
    fi
    # shellcheck source=/dev/null  # can't follow user-supplied config path at lint time
    . "$config"

    local proxy="http://127.0.0.1:$PROXY_PORT"

    # chopi's outgoing-pinning network profile is always appended last, so its
    # (deny network*) lands after safehouse's own profile and pins outgoing to the proxy.
    #
    # errexit off around safehouse so a non-zero exit from the sandboxed command is captured
    # and propagated (so `chopi cmd && next` short-circuits) instead of aborting here.
    set +e
    set -x
    safehouse \
        "${CHOPI_SAFEHOUSE_FLAGS[@]+"${CHOPI_SAFEHOUSE_FLAGS[@]}"}" \
        --append-profile "$CHOPI_DIR/.internal/network.sb" \
        -- \
        "${CHOPI_EXTRA_ENV[@]+"${CHOPI_EXTRA_ENV[@]}"}" \
        HTTP_PROXY="$proxy"  HTTPS_PROXY="$proxy" \
        http_proxy="$proxy"  https_proxy="$proxy" \
        NODE_USE_ENV_PROXY=1 \
        "$@"
    { local rc=$?; set +x; } 2>/dev/null
    return "$rc"
}

main "$@"

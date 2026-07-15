#!/usr/bin/env bash
#
# chopi.sh -- run a command under chopi's macOS filesystem+network sandbox.
#
# Usually invoked as `chopi` via the sibling symlink (bin/chopi -> chopi.sh).

set -euo pipefail

SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"   # resolve the bin/chopi symlink
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

. "$SCRIPT_DIR/../.internal/util.sh"
. "$SCRIPT_DIR/../.internal/git-layout.sh"
. "$SCRIPT_DIR/../.internal/context-reads.sh"

usage="usage: chopi [--config FILE] [--verbose] [--worktree NAME] <executable> [args...]

  --config FILE    use FILE as the sandbox config instead of the default
                   config/sandbox.sh
  --verbose        enable verbose output showing chopi's sandbox setup
  --worktree NAME  create (or reuse) a git worktree named NAME under the repo's
                   .worktrees/ directory and run the command isolated to it"

# Every chopi run gets its own private subfolder under TMPDIR (or /tmp), exported into TMPDIR.
# chopi's mktemp calls all resolve "$TMPDIR", and safehouse forwards TMPDIR to the sandboxed
# command, so all generated temporaries (except, potentially, generation that doesn't respect TMPDIR
# in the sandboxed command) are contained in it and cleaned up on exit.
CHOPI_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/chopi.XXXXXX")" \
    || { echo "chopi: could not create a temp dir for the run" >&2; exit 1; }
export TMPDIR="$CHOPI_TMPDIR"
trap 'rm -rf "$CHOPI_TMPDIR"' EXIT

main() {
    local config="$CHOPI_DIR/config/sandbox.sh"
    local config_given=""
    local verbose=""
    local worktree_name=""
    local worktree_dir=""
    local worktree_given=""

    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)  echo "$usage"; return 0 ;;
            --config)
                if [ "$#" -lt 2 ]; then echo "chopi: --config requires a file path" >&2; return 1; fi
                config="$2"; config_given=1; shift 2 ;;
            --verbose)  verbose=1; shift ;;
            --worktree)
                if [ "$#" -lt 2 ]; then echo "chopi: --worktree requires a name" >&2; return 1; fi
                worktree_name="$2"; worktree_given=1; shift 2 ;;
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
    "$CHOPI_DIR/.internal/preflight.sh" "${preflight_args[@]+"${preflight_args[@]}"}" || return $?

    local CHOPI_SAFEHOUSE_FLAGS=()
    local CHOPI_EXTRA_ENV=()
    local CHOPI_GIT_CONFIG=()
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

    if [ -n "$worktree_given" ]; then
        local wt_out_file
        wt_out_file="$(mktemp "$TMPDIR/chopi-wt-out.XXXXXX")" \
            || { echo "chopi: could not create a temp file for the worktree contract" >&2; return 1; }
        "$CHOPI_DIR/.internal/worktree.sh" --config "$config" "$worktree_name" >"$wt_out_file" \
            || return $?
        IFS= read -r -d '' worktree_dir <"$wt_out_file" || true
        if [ -z "$worktree_dir" ]; then
            echo "chopi: the worktree helper returned no worktree path" >&2
            return 1
        fi
    fi

    # Refuse running with git setups that chopi doesn't support.
    local protection_args=()
    [ -n "$worktree_dir" ] && protection_args+=("$worktree_dir")
    "$CHOPI_DIR/.internal/git-preflight.sh" "${protection_args[@]+"${protection_args[@]}"}" || return $?

    # Git protections apply only at the root of a git worktree. Note that safehouse itself
    # (verified against 0.10.1) also only gives its git grants in this case.
    local run_dir
    run_dir="$(pwd -P)"
    [ -n "$worktree_dir" ] && run_dir="$worktree_dir"

    # Let the agent read context files in the workspace's ancestor dirs.
    local context_profile
    context_profile="$(mktemp "$TMPDIR/${CHOPI_CONTEXT_READS_PREFIX}XXXXXX")" \
        || { echo "chopi: could not create a temp file for the context-reads profile" >&2; return 1; }
    write_context_reads_profile "$context_profile" "$run_dir" \
        || { echo "chopi: could not write the context-reads profile" >&2; return 1; }

    local protection_flags=()
    local wrapper_cmd=()
    local wrapper_flags=()
    if is_worktree_root "$run_dir"; then
        # Build chopi's git protection profiles and append them in the order
        # git-protect.sh emits them.
        local protect_args=("${protection_args[@]+"${protection_args[@]}"}")
        [ -n "$verbose" ] && protect_args+=(--verbose)
        local protect_out_file protect_profile
        protect_out_file="$(mktemp "$TMPDIR/chopi-git-protect-out.XXXXXX")" \
            || { echo "chopi: could not create a temp file for the git protection profiles" >&2; return 1; }
        "$CHOPI_DIR/.internal/git-protect.sh" "${protect_args[@]+"${protect_args[@]}"}" >"$protect_out_file" \
            || return $?
        while IFS= read -r -d '' protect_profile; do
            protection_flags+=(--append-profile "$protect_profile")
        done <"$protect_out_file"
        if [ "${#protection_flags[@]}" -eq 0 ]; then
            echo "chopi: the git protection helper returned no profiles" >&2
            return 1
        fi

        # safehouse selects its sandbox profile from the invoked command's basename, e.g.,
        # `claude` loads the claude-code profile. Alias the git-protect wrapper to the same name
        # so safehouse's detection loads the right profile. The symlink lives under TMPDIR,
        # which safehouse grants; exec follows it to wrapper_path, which is allowed by the
        # profile below.
        local command="$1"
        local wrapper_path="$CHOPI_DIR/.internal/git-protect-wrapper.sh"
        local cmd_alias_dir
        cmd_alias_dir="$(mktemp -d "$TMPDIR/${CHOPI_CMD_ALIAS_PREFIX}XXXXXX")" \
            || { echo "chopi: could not create a temp dir for the command alias" >&2; return 1; }
        local cmd_alias
        cmd_alias="$cmd_alias_dir/$(basename -- "$command")"
        ln -s "$wrapper_path" "$cmd_alias" \
            || { echo "chopi: could not create the command-alias symlink" >&2; return 1; }
        wrapper_cmd=("$cmd_alias" "${CHOPI_GIT_CONFIG[@]+"${CHOPI_GIT_CONFIG[@]}"}" --)
        local wrapper_profile
        wrapper_profile="$(mktemp "$TMPDIR/${CHOPI_GIT_PROTECT_WRAPPER_PREFIX}XXXXXX")" \
            || { echo "chopi: could not create a temp file for the git-protect wrapper profile" >&2; return 1; }
        {
            echo ";; chopi: the git-protect wrapper is read and executed in the sandbox."
            rule 'allow file-read* process-exec*' literal "$wrapper_path"
        } > "$wrapper_profile"
        wrapper_flags=(--append-profile "$wrapper_profile")
    elif [ -n "$worktree_given" ]; then
        # Fail closed: isolating the command to the worktree is the mode's whole promise.
        echo "chopi: worktree '$worktree_dir' is not a git worktree root" >&2
        return 1
    elif [ -n "$verbose" ]; then
        echo "chopi: workspace is not a git worktree root; git protections not applied" >&2
    fi

    local proxy="http://127.0.0.1:$PROXY_PORT"

    if [ -n "$worktree_dir" ]; then
        # Enter the worktree only now -- after preflight ran and the (possibly relative)
        # --config was sourced against the invocation dir -- so the command runs inside
        # the worktree without disturbing those invocation-dir-relative resolutions.
        cd "$worktree_dir" || { echo "chopi: cannot enter worktree '$worktree_dir'" >&2; return 1; }
    fi

    # chopi's outgoing-pinning network profile is always appended last, so its
    # (deny network*) lands after safehouse's own profile and pins outgoing to the proxy.
    #
    # errexit off around safehouse so a non-zero exit from the sandboxed command is captured
    # and propagated (so `chopi cmd && next` short-circuits) instead of aborting here.
    set +e
    [ -n "$verbose" ] && { echo; set -x; }
    safehouse \
        "${CHOPI_SAFEHOUSE_FLAGS[@]+"${CHOPI_SAFEHOUSE_FLAGS[@]}"}" \
        --append-profile "$context_profile" \
        "${protection_flags[@]+"${protection_flags[@]}"}" \
        "${wrapper_flags[@]+"${wrapper_flags[@]}"}" \
        --append-profile "$CHOPI_DIR/.internal/network.sb" \
        -- \
        "${CHOPI_EXTRA_ENV[@]+"${CHOPI_EXTRA_ENV[@]}"}" \
        HTTP_PROXY="$proxy"  HTTPS_PROXY="$proxy" \
        http_proxy="$proxy"  https_proxy="$proxy" \
        NODE_USE_ENV_PROXY=1 \
        "${wrapper_cmd[@]+"${wrapper_cmd[@]}"}" \
        "$@"
    { local rc=$?; set +x; } 2>/dev/null
    return "$rc"
}

main "$@"

#!/usr/bin/env bash
#
# chopi.sh -- run a command under chopi's macOS filesystem+network sandbox.
#
# Usually invoked as `chopi` via the sibling symlink (bin/chopi -> chopi.sh).

set -euo pipefail

SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"   # resolve the bin/chopi symlink
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

. "$SCRIPT_DIR/../.internal/util.sh"
. "$SCRIPT_DIR/../.internal/claude-prompt.sh"
. "$SCRIPT_DIR/../.internal/claude-context-reads.sh"
. "$SCRIPT_DIR/../.internal/write-targets.sh"
. "$SCRIPT_DIR/../.internal/preflight.sh"

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

chopi_torn_down=""

# On exit (normal or forced), remove the run's temp dir. The in-progress rebase/cherry-pick
# cleanup runs earlier and INSIDE the sandbox -- in-sandbox-wrapper.sh runs it as its
# CLEANUP_SCRIPT_PATH so anything it triggers stays confined -- so by the time we get here the
# sandboxed run, cleanup and all, is already done.
# shellcheck disable=SC2329  # invoked via the EXIT trap below
chopi_teardown() {
    [ -n "$chopi_torn_down" ] && return 0
    chopi_torn_down=1
    rm -rf "$CHOPI_TMPDIR"
}

# On a signal, tear down then re-raise it under the default handler so chopi exits with the
# conventional signal status. The EXIT trap fires too, but chopi_teardown runs only once.
# shellcheck disable=SC2329  # invoked via the signal traps below
chopi_on_signal() {
    chopi_teardown
    trap - "$1"
    kill -"$1" "$$"
}

trap chopi_teardown EXIT
trap 'chopi_on_signal INT'  INT
trap 'chopi_on_signal TERM' TERM
trap 'chopi_on_signal HUP'  HUP

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

    preflight_initial || return $?

    local CHOPI_SAFEHOUSE_FLAGS=()
    local CHOPI_EXTRA_ENV=()
    local CHOPI_GIT_CONFIG=()
    # shellcheck disable=SC2034 # consumed by validate_write_targets
    local CHOPI_SAFE_WRITE_TARGETS=()
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

    # Refuse running outside a git worktree root, and with git setups that chopi
    # doesn't support.
    local protection_args=()
    [ -n "$worktree_dir" ] && protection_args+=("$worktree_dir")
    "$CHOPI_DIR/.internal/git-preflight.sh" "${protection_args[@]+"${protection_args[@]}"}" || return $?

    # The dir the sandboxed command runs in; git-preflight vetted it as a git worktree
    # root, where the git protections (and safehouse's own git grants, verified against
    # 0.10.1) apply.
    local run_dir
    run_dir="$(pwd -P)"
    [ -n "$worktree_dir" ] && run_dir="$worktree_dir"

    if [ -n "$config_given" ]; then
        preflight_config_placement "$config" "$run_dir" || return $?
    fi

    # The patch queue: where the command drops changes it wants made to a configured
    # write target, for the user to review and apply on the host with chopi-review.
    # A config that can't be honored stops the session before any of it is granted.
    if ! validate_write_targets "$run_dir" chopi; then
        echo "chopi: refusing to run" >&2
        return 1
    fi
    local queue_flags=() queue_env=() queue_dir=""
    # Gated on the enforced targets, not the config: under CHOPI_ALLOW_SAFE_WRITE_TARGET
    # a configured target can drop out, and all dropping out leaves no queue to set up.
    if [ "${#CHOPI_WRITE_TARGET_PATHS[@]}" -gt 0 ]; then
        queue_dir="$(create_patch_queue "$run_dir")" \
            || { echo "chopi: refusing to run" >&2; return 1; }
        local queue_profile
        queue_profile="$(mktemp "$TMPDIR/chopi-patch-queue.XXXXXX")" \
            || { echo "chopi: could not create a temp file for the patch-queue profile" >&2; return 1; }
        write_patch_queue_profile "$queue_profile" "$queue_dir" \
            || { echo "chopi: could not write the patch-queue profile" >&2; return 1; }
        queue_flags=(--append-profile "$queue_profile")
        local targets
        targets="$(printf '%s\n' "${CHOPI_WRITE_TARGET_PATHS[@]}")"
        queue_env=(CHOPI_PATCH_QUEUE="$queue_dir" CHOPI_SAFE_WRITE_TARGETS="$targets")
    fi

    local context_flags=()
    local cmd_argv=("$@")
    if is_claude_command "$1"; then
        local claude_context_profile
        claude_context_profile="$(mktemp "$TMPDIR/${CHOPI_CLAUDE_CONTEXT_READS_PREFIX}XXXXXX")" \
            || { echo "chopi: could not create a temp file for the claude-context-reads profile" >&2; return 1; }
        write_claude_context_reads_profile "$claude_context_profile" "$run_dir" \
            || { echo "chopi: could not write the claude-context-reads profile" >&2; return 1; }
        context_flags=(--append-profile "$claude_context_profile")

        claude_argv_with_chopi_prompt "$run_dir" "$@" || return 1
        cmd_argv=("${CLAUDE_ARGV_WITH_CHOPI_PROMPT[@]}")
    elif [ "$(basename -- "$1")" = codex ]; then
        # Chopi is Codex's external sandbox. Asking Codex to install another macOS
        # Seatbelt policy would make built-in tools such as apply_patch fail with EPERM.
        cmd_argv=("$1" --sandbox danger-full-access "${@:2}")
    fi

    # Build chopi's git protection profiles and append them in the order
    # git-protect.sh emits them.
    local protection_flags=()
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
    # `claude` loads the claude-code profile. Alias the in-sandbox wrapper to the same name
    # so safehouse's detection loads the right profile. The symlink lives under TMPDIR,
    # which safehouse grants; exec follows it to wrapper_path, which is allowed by the
    # profile below.
    local command="$1"
    local wrapper_path="$CHOPI_DIR/.internal/in-sandbox-wrapper.sh"
    local cmd_alias_dir
    cmd_alias_dir="$(mktemp -d "$TMPDIR/${CHOPI_CMD_ALIAS_PREFIX}XXXXXX")" \
        || { echo "chopi: could not create a temp dir for the command alias" >&2; return 1; }
    local cmd_alias
    cmd_alias="$cmd_alias_dir/$(basename -- "$command")"
    ln -s "$wrapper_path" "$cmd_alias" \
        || { echo "chopi: could not create the command-alias symlink" >&2; return 1; }

    # Route GitHub git traffic to the GitHub relay.
    local relay_pair
    while IFS= read -r relay_pair; do
        CHOPI_GIT_CONFIG+=("$relay_pair")
    done < <(github_relay_git_config)

    local cleanup_script_path="$CHOPI_DIR/.internal/git-protect-cleanup.sh"
    local wrapper_cmd=("$cmd_alias" "$cleanup_script_path")
    wrapper_cmd+=("${CHOPI_GIT_CONFIG[@]+"${CHOPI_GIT_CONFIG[@]}"}" --)
    local wrapper_profile
    wrapper_profile="$(mktemp "$TMPDIR/${CHOPI_IN_SANDBOX_WRAPPER_PREFIX}XXXXXX")" \
        || { echo "chopi: could not create a temp file for the in-sandbox wrapper profile" >&2; return 1; }
    {
        echo ";; chopi: the in-sandbox wrapper itself."
        rule 'allow file-read* process-exec' literal "$wrapper_path"
        echo ";; chopi: the in-sandbox teardown cleanup and the libs it and the wrapper source."
        rule 'allow file-read* process-exec' literal "$cleanup_script_path"
        local lib
        for lib in "${CHOPI_IN_SANDBOX_LIBS[@]}"; do
            rule 'allow file-read*' literal "$CHOPI_DIR/.internal/$lib"
        done
        echo ";; chopi: stat-only on chopi's dir chain for in-sandbox CHOPI_DIR resolution."
        local ancestor="$CHOPI_DIR/.internal"
        while :; do
            rule 'allow file-read-metadata' literal "$ancestor"
            [ "$ancestor" = "/" ] && break
            ancestor="$(dirname "$ancestor")"
        done
    } > "$wrapper_profile"
    local wrapper_flags=(--append-profile "$wrapper_profile")

    # Point gh at the API relay socket, via a throwaway config dir of our own that leaves the
    # user's real gh config untouched.
    local gh_config_dir gh_env_text
    gh_config_dir="$(mktemp -d "$TMPDIR/chopi-gh-config.XXXXXX")" \
        || { echo "chopi: could not create a temp dir for the gh relay config" >&2; return 1; }
    gh_env_text="$(github_relay_gh_env "$gh_config_dir")" \
        || { echo "chopi: could not write the gh relay config" >&2; return 1; }
    local gh_env=()
    readarray -t gh_env <<< "$gh_env_text"

    # Open a Seatbelt network hole to the GitHub API relay socket.
    local gh_sock gh_relay_profile
    gh_sock="$(realpath "$GH_RELAY_SOCK")" \
        || { echo "chopi: cannot resolve the GitHub API relay socket path '$GH_RELAY_SOCK'" >&2; return 1; }
    gh_relay_profile="$(mktemp "$TMPDIR/chopi-gh-relay-net.XXXXXX")" \
        || { echo "chopi: could not create a temp file for the GitHub API relay network profile" >&2; return 1; }
    {
        echo ";; chopi: re-open the GitHub API relay's unix socket (network.sb denies unix sockets)."
        rule 'allow network-outbound' literal "$gh_sock"
    } > "$gh_relay_profile"

    local proxy="http://127.0.0.1:$PROXY_PORT"

    if [ -n "$worktree_dir" ]; then
        cd "$worktree_dir" || { echo "chopi: cannot enter worktree '$worktree_dir'" >&2; return 1; }
    fi

    # chopi's network profiles are always appended last so that (deny network*) lands after
    # safehouse's own profile, pinning outgoing traffic to the subsequent holes allowed for the proxy
    # and the GitHub relay servers.
    #
    # errexit off around safehouse so a non-zero exit from the sandboxed command is captured
    # and propagated (so `chopi cmd && next` short-circuits) instead of aborting here.
    set +e
    [ -n "$verbose" ] && { echo; set -x; }
    safehouse \
        "${CHOPI_SAFEHOUSE_FLAGS[@]+"${CHOPI_SAFEHOUSE_FLAGS[@]}"}" \
        "${queue_flags[@]+"${queue_flags[@]}"}" \
        "${context_flags[@]+"${context_flags[@]}"}" \
        "${protection_flags[@]}" \
        "${wrapper_flags[@]}" \
        --append-profile "$CHOPI_DIR/.internal/network.sb" \
        --append-profile "$gh_relay_profile" \
        -- \
        "${CHOPI_EXTRA_ENV[@]+"${CHOPI_EXTRA_ENV[@]}"}" \
        "${queue_env[@]+"${queue_env[@]}"}" \
        CHOPI_DIR="$CHOPI_DIR" \
        HTTP_PROXY="$proxy"  HTTPS_PROXY="$proxy" \
        http_proxy="$proxy"  https_proxy="$proxy" \
        NODE_USE_ENV_PROXY=1 \
        NO_PROXY="127.0.0.1"  no_proxy="127.0.0.1" \
        GIT_TERMINAL_PROMPT=0 \
        "${gh_env[@]}" \
        "${wrapper_cmd[@]}" \
        "${cmd_argv[@]}"
    { local rc=$?; set +x; } 2>/dev/null

    if [ -n "$worktree_dir" ] && [ -t 2 ]; then
        {
            echo
            echo "chopi: worktree ready for inspection:"
            echo "  cd $worktree_dir"
        } >&2
    fi

    # Anything the command proposed is waiting now, with the session it came out of still in
    # view, so offer the review here instead of leaving it for the user to remember. The
    # command has exited, so the terminal is chopi's again and chopi-review can have it.
    #
    # chopi-review's exit status is dropped: reviewing is a separate errand from the command
    # chopi ran, so `chopi cmd && next` still keys off the command.
    # Scoped to this session's workspace queue, since that is what the offer counted: a patch some
    # other workspace has waiting is not what was just proposed, and belongs to a review of its own.
    if offer_reviewing_queued_workspace_patches "$queue_dir"; then
        "$CHOPI_DIR/bin/chopi-review" --config "$config" --queue "$queue_dir" || true
    fi

    return "$rc"
}

{
    main "$@"
    # The braces make bash parse this whole block, exit included, before running it, so a
    # mid-session edit to this file cannot affect it: without the exit, bash would read the
    # file again after main returns, at a stale byte offset that executes garbage.
    exit
}

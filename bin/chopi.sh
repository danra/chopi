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
. "$SCRIPT_DIR/../.internal/codex-prompt.sh"
. "$SCRIPT_DIR/../.internal/claude-context-reads.sh"
. "$SCRIPT_DIR/../.internal/write-targets.sh"
. "$SCRIPT_DIR/../.internal/preflight.sh"
. "$SCRIPT_DIR/../.internal/session-proxy.sh"

usage="usage: chopi [--config FILE] [--verbose] [--worktree NAME] [--serve NAME]...
             <executable> [args...]
       chopi [--config FILE] --config-paths

  --config FILE    use FILE as the sandbox config instead of the default
                   config/sandbox.sh
  --verbose        enable verbose output showing chopi's sandbox setup
  --worktree NAME  create (or reuse) a git worktree named NAME under the repo's
                   .worktrees/ directory and run the command isolated to it
  --serve NAME     let the command listen on the repo's loopback port NAME, one
                   of CHOPI_LOOPBACK_PORTS, which every session may connect to;
                   repeatable
  --config-paths   print the config files a session in this repo reads, for
                   every project and for this repo alone, and exit"

# Every chopi run gets its own private subfolder under TMPDIR (or /tmp), exported into TMPDIR.
# chopi's mktemp calls all resolve "$TMPDIR", and safehouse forwards TMPDIR to the sandboxed
# command, so all generated temporaries (except, potentially, generation that doesn't respect TMPDIR
# in the sandboxed command) are contained in it and cleaned up on exit. The user's own is kept for
# what outlives the run (see launch_session_proxy).
CHOPI_USER_TMPDIR="${TMPDIR:-}"
CHOPI_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/chopi.XXXXXX")" \
    || { echo "chopi: could not create a temp dir for the run" >&2; exit 1; }
export TMPDIR="$CHOPI_TMPDIR"

chopi_torn_down=""

# On exit (normal or forced), stop the session's proxy and remove the run's temp dir. The
# in-progress rebase/cherry-pick cleanup runs earlier and INSIDE the sandbox -- in-sandbox-wrapper.sh
# runs it as its CLEANUP_SCRIPT_PATH so anything it triggers stays confined -- so by the time we
# get here the sandboxed run, cleanup and all, is already done.
# shellcheck disable=SC2329  # invoked via the EXIT trap below
chopi_teardown() {
    [ -n "$chopi_torn_down" ] && return 0
    chopi_torn_down=1
    stop_session_proxy
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

# Set the caller's ws_config_dir to the repo's own config dir for a session at DIR, and its
# ws_sandbox, ws_rules and ws_allowlist to the config files in it.
#
# usage: local ws_config_dir ws_sandbox ws_rules ws_allowlist; set_workspace_config_paths DIR
set_workspace_config_paths() {
    arity 1
    ws_config_dir="$(resolve_workspace_config_dir "$1")" || return 1
    ws_sandbox="$ws_config_dir/$WORKSPACE_SANDBOX_CONFIG"
    ws_rules="$ws_config_dir/$DEFAULT_PROXY_RULES"
    ws_allowlist="$ws_config_dir/$DEFAULT_GITHUB_ALLOWLIST"
}

# Print the config files a session at DIR reads: the base ones -- the sandbox config CONFIG, and the
# proxy's, which it sets -- and the repo's own, noting those not there yet -- in a dir the user
# can't guess, named for the repo.
#
# usage: print_config_paths DIR CONFIG
print_config_paths() {
    arity 2
    local ws_config_dir ws_sandbox ws_rules ws_allowlist
    set_workspace_config_paths "$1" || return 1
    echo "For every project:"
    echo "  sandbox:          $(realpath "$2")"
    echo "  proxy rules:      $CHOPI_PROXY_RULES"
    echo "  GitHub allowlist: $CHOPI_GITHUB_ALLOWLIST"
    echo "For this repo alone, adding to those:"
    echo "  sandbox:          $ws_sandbox$(missing_note "$ws_sandbox")"
    echo "  proxy rules:      $ws_rules$(missing_note "$ws_rules")"
    echo "  GitHub allowlist: $ws_allowlist$(missing_note "$ws_allowlist")"
    echo "  loopback ports:   $ws_config_dir/$LOOPBACK_PORTS_FILE_NAME$(missing_note \
        "$ws_config_dir/$LOOPBACK_PORTS_FILE_NAME")"
}

main() {
    local config="$CHOPI_DIR/config/sandbox.sh"
    local config_given=""
    local verbose=""
    local worktree_name=""
    local worktree_dir=""
    local worktree_given=""
    local config_paths=""
    local serve_names=()

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
            --serve)
                if [ "$#" -lt 2 ]; then echo "chopi: --serve requires a port name" >&2; return 1; fi
                serve_names+=("$2"); shift 2 ;;
            --config-paths) config_paths=1; shift ;;
            --)         shift; break ;;
            -*)         echo "chopi: unknown option: $1" >&2; echo "$usage" >&2; return 1 ;;
            *)          break ;;
        esac
    done

    if [ -n "$config_paths" ] && [ "$#" -gt 0 ]; then
        echo "chopi: --config-paths runs no command, got '$1'" >&2; return 1
    fi
    if [ -z "$config_paths" ] && [ "$#" -eq 0 ]; then echo "$usage" >&2; return 1; fi

    preflight_initial || return $?
    # Made where missing, for every session to deny writes to its real path: Seatbelt matches real
    # paths, and one with a symlink on the way can only be resolved once it exists.
    mkdir -p "$PROXY_CONFIG_DIR" \
        || { echo "chopi: could not create the proxy config dir '$PROXY_CONFIG_DIR'" >&2; return 1; }

    local CHOPI_SAFEHOUSE_FLAGS=()
    local CHOPI_EXTRA_ENV=()
    local CHOPI_GIT_CONFIG=()
    local CHOPI_LOOPBACK_PORTS=()
    # shellcheck disable=SC2034 # consumed by validate_write_targets
    local CHOPI_SAFE_WRITE_TARGETS=()
    local CHOPI_PROXY_RULES=""
    local CHOPI_GITHUB_ALLOWLIST=""
    check_sandbox_config_readable chopi "$config" "$config_given" || return 1
    # shellcheck source=/dev/null  # can't follow user-supplied config path at lint time
    . "$config"

    resolve_proxy_config CHOPI_PROXY_RULES "$DEFAULT_PROXY_RULES" proxy-rules.template.yaml || return 1
    resolve_proxy_config CHOPI_GITHUB_ALLOWLIST "$DEFAULT_GITHUB_ALLOWLIST" github-allowlist.template \
        || return 1

    if [ -n "$config_paths" ]; then
        print_config_paths "$(pwd -P)" "$config"
        return
    fi

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

    # The repo's own config, adding to the base config for its sessions alone. Each file may be
    # missing; the proxy's may be made mid-session, while the sandbox's takes effect as a session
    # starts, as the base one does.
    local ws_config_dir ws_sandbox ws_rules ws_allowlist
    { set_workspace_config_paths "$run_dir" && load_workspace_sandbox_config "$ws_sandbox"; } \
        || { echo "chopi: refusing to run" >&2; return 1; }
    validate_loopback_port_names "${CHOPI_LOOPBACK_PORTS[@]+"${CHOPI_LOOPBACK_PORTS[@]}"}" \
        || { echo "chopi: refusing to run" >&2; return 1; }
    local serve_name
    for serve_name in "${serve_names[@]+"${serve_names[@]}"}"; do
        if ! is_item_in_list "$serve_name" "${CHOPI_LOOPBACK_PORTS[@]+"${CHOPI_LOOPBACK_PORTS[@]}"}"; then
            echo "chopi: --serve $serve_name: not a port name in CHOPI_LOOPBACK_PORTS" >&2
            echo "chopi: refusing to run" >&2
            return 1
        fi
    done
    preflight_proxy_config_links "$CHOPI_PROXY_RULES" "$CHOPI_GITHUB_ALLOWLIST" \
        "$ws_rules" "$ws_allowlist" || return $?

    # The patch queue: where the command drops changes it wants made to a configured
    # write target, for the user to review and apply on the host with chopi-review.
    # A config that can't be honored stops the session before any of it is granted.
    if ! validate_write_targets "$run_dir" chopi; then
        echo "chopi: refusing to run" >&2
        return 1
    fi
    local queue_flags=() queue_env=() queue_dir="" targets=""
    # Gated on the enforced targets, not the config: a target that is the workspace, or
    # contains it under CHOPI_ALLOW_SAFE_WRITE_TARGET, drops out, and all dropping out
    # leaves no queue to set up.
    if [ "${#CHOPI_WRITE_TARGET_PATHS[@]}" -gt 0 ]; then
        queue_dir="$(create_patch_queue "$run_dir")" \
            || { echo "chopi: refusing to run" >&2; return 1; }
        local queue_profile
        queue_profile="$(new_profile patch-queue write_patch_queue_profile "$queue_dir")" || return 1
        queue_flags=(--append-profile "$queue_profile")
        targets="$(printf '%s\n' "${CHOPI_WRITE_TARGET_PATHS[@]}")"
        queue_env=(CHOPI_PATCH_QUEUE="$queue_dir" CHOPI_SAFE_WRITE_TARGETS="$targets")
    fi

    if [ -e "$ws_sandbox" ]; then
        echo "chopi: sandbox: the base config, plus this repo's own in $ws_config_dir" >&2
    fi
    if [ -e "$ws_rules" ] || [ -e "$ws_allowlist" ]; then
        echo "chopi: network: the base config, plus this repo's own in $ws_config_dir" >&2
    fi

    # The repo's loopback ports, each of a name the config gives: every session may connect to
    # them, and those --serve names also listen on them.
    local loopback_specs=() loopback_env=() loopback_note=() port_name port
    if [ "${#CHOPI_LOOPBACK_PORTS[@]}" -gt 0 ]; then
        local ports_out
        ports_out="$(assign_loopback_ports "$ws_config_dir" "${CHOPI_LOOPBACK_PORTS[@]}")" \
            || { echo "chopi: refusing to run" >&2; return 1; }
        while read -r port_name port; do
            if is_item_in_list "$port_name" "${serve_names[@]+"${serve_names[@]}"}"; then
                loopback_specs+=("serve:$port")
                loopback_note+=("$port_name=$port (serving)")
            else
                loopback_specs+=("connect:$port")
                loopback_note+=("$port_name=$port")
            fi
            loopback_env+=("$(loopback_port_var "$port_name")=$port")
        done <<<"$ports_out"
        loopback_env+=(CHOPI_SERVE="${serve_names[*]+"${serve_names[*]}"}")
        echo "chopi: ports: ${loopback_note[*]}" >&2
    fi

    local context_flags=()
    local cmd_argv=("$@")
    if is_claude_command "$1"; then
        local claude_context_profile
        claude_context_profile="$(new_profile "$CHOPI_CLAUDE_CONTEXT_READS_PROFILE" \
            write_claude_context_reads_profile "$run_dir")" || return 1
        context_flags=(--append-profile "$claude_context_profile")

        claude_argv_with_chopi_prompt "$run_dir" "$targets" "$@" || return 1
        cmd_argv=("${CLAUDE_ARGV_WITH_CHOPI_PROMPT[@]}")
    elif is_codex_command "$1"; then
        codex_argv_with_chopi_prompt "$targets" "$@" || return 1
        cmd_argv=("${CODEX_ARGV_WITH_CHOPI_PROMPT[@]}")
    fi

    # The session's own proxy, which the sandboxed command gets as its only way out. Launched
    # once the checks that may refuse the session have passed, so a refused session doesn't wait
    # for it; it starts as chopi goes on with the rest of its setup, and nothing reaches it before
    # the sandbox starts.
    launch_session_proxy "$CHOPI_PROXY_RULES" "$CHOPI_GITHUB_ALLOWLIST" "$verbose" \
        "$CHOPI_USER_TMPDIR" "$ws_rules" "$ws_allowlist" \
        || { echo "chopi: refusing to run without the proxy" >&2; return 1; }
    [ -n "$verbose" ] && echo "chopi: the proxy logs to $SESSION_PROXY_LOG" >&2

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

    local cleanup_script_path="$CHOPI_DIR/.internal/git-protect-cleanup.sh"
    local wrapper_profile
    wrapper_profile="$(new_profile "$CHOPI_IN_SANDBOX_WRAPPER_PROFILE" \
        write_in_sandbox_wrapper_profile "$wrapper_path" "$cleanup_script_path")" || return 1
    local wrapper_flags=(--append-profile "$wrapper_profile")

    local run_dir_profile
    run_dir_profile="$(new_profile proxy-run-dir write_proxy_run_dir_profile "$PROXY_RUN_DIR")" || return 1

    local proxy_config_profile
    proxy_config_profile="$(new_profile proxy-config write_proxy_config_profile)" || return 1

    local gh_config_dir
    gh_config_dir="$(mktemp -d "$TMPDIR/chopi-gh-config.XXXXXX")" \
        || { echo "chopi: could not create a temp dir for the gh relay config" >&2; return 1; }

    # The rest needs the proxy's endpoints.
    await_session_proxy || { echo "chopi: refusing to run without the proxy" >&2; return 1; }

    # Route GitHub git traffic to the GitHub relay.
    local relay_pair
    while IFS= read -r relay_pair; do
        CHOPI_GIT_CONFIG+=("$relay_pair")
    done < <(github_relay_git_config "$SESSION_RELAY_PORT")
    local wrapper_cmd=("$cmd_alias" "$cleanup_script_path")
    wrapper_cmd+=("${CHOPI_GIT_CONFIG[@]+"${CHOPI_GIT_CONFIG[@]}"}" --)

    # Point gh at the API relay socket, via a throwaway config dir of our own that leaves the
    # user's real gh config untouched.
    local gh_env_text
    gh_env_text="$(github_relay_gh_env "$gh_config_dir" "$SESSION_GH_SOCK")" \
        || { echo "chopi: could not write the gh relay config" >&2; return 1; }
    local gh_env=()
    readarray -t gh_env <<< "$gh_env_text"

    # Open Seatbelt network holes to the session's proxy endpoints.
    local proxy_net_profile
    proxy_net_profile="$(new_profile proxy-net write_proxy_network_profile \
        "$SESSION_PROXY_PORT" "$SESSION_RELAY_PORT" "$SESSION_GH_SOCK")" || return 1

    # And to the repo's loopback ports, if any.
    local loopback_flags=()
    if [ "${#loopback_specs[@]}" -gt 0 ]; then
        local loopback_profile
        loopback_profile="$(new_profile loopback-ports write_loopback_ports_profile \
            "${loopback_specs[@]}")" || return 1
        loopback_flags=(--append-profile "$loopback_profile")
    fi

    local proxy="http://127.0.0.1:$SESSION_PROXY_PORT"

    if [ -n "$worktree_dir" ]; then
        cd "$worktree_dir" || { echo "chopi: cannot enter worktree '$worktree_dir'" >&2; return 1; }
    fi

    # chopi's network profiles are always appended last so that (deny network*) lands after
    # safehouse's own profile, pinning outgoing traffic to the subsequent holes allowed for the
    # session's proxy and GitHub relay servers. The run-dir and proxy config profiles go just before
    # them, after every file grant, so their denies outrank them all.
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
        --append-profile "$run_dir_profile" \
        --append-profile "$proxy_config_profile" \
        --append-profile "$CHOPI_DIR/.internal/network.sb" \
        --append-profile "$proxy_net_profile" \
        "${loopback_flags[@]+"${loopback_flags[@]}"}" \
        -- \
        "${CHOPI_EXTRA_ENV[@]+"${CHOPI_EXTRA_ENV[@]}"}" \
        "${queue_env[@]+"${queue_env[@]}"}" \
        "${loopback_env[@]+"${loopback_env[@]}"}" \
        CHOPI_DIR="$CHOPI_DIR" \
        CHOPI_GITHUB_RELAY_PORT="$SESSION_RELAY_PORT" \
        CHOPI_PROXY_LOG="$SESSION_PROXY_LOG" \
        CHOPI_WORKSPACE_SANDBOX_CONFIG="$ws_sandbox" \
        CHOPI_WORKSPACE_PROXY_RULES="$ws_rules" \
        CHOPI_WORKSPACE_GITHUB_ALLOWLIST="$ws_allowlist" \
        HTTP_PROXY="$proxy"  HTTPS_PROXY="$proxy" \
        http_proxy="$proxy"  https_proxy="$proxy" \
        NODE_USE_ENV_PROXY=1 \
        NO_PROXY="127.0.0.1,localhost"  no_proxy="127.0.0.1,localhost" \
        GIT_TERMINAL_PROMPT=0 \
        "${gh_env[@]}" \
        "${wrapper_cmd[@]}" \
        "${cmd_argv[@]}"
    { local rc=$?; set +x; } 2>/dev/null
    stop_session_proxy

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

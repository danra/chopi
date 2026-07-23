#!/usr/bin/env bash
#
# git-preflight.sh -- refuse running outside a git worktree root, and unsupported git setups
#
# Not run directly; `chopi` calls this before generating the git protection profiles.
#
# usage: git-preflight.sh [DIR]
#
#   DIR  the directory the sandboxed command will run in (default: the current dir);
#        chopi passes the worktree for --worktree runs.
#
# Exits non-zero iff the setup is refused.

set -euo pipefail

SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
. "$SCRIPT_DIR/git-layout.sh"

main() {
    local target_dir=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -*) echo "error: git-preflight: unknown option: $1" >&2; return 1 ;;
            *)
                if [ -n "$target_dir" ]; then echo "error: git-preflight: unexpected args" >&2; return 1; fi
                target_dir="$1"; shift ;;
        esac
    done
    if [ -n "$target_dir" ]; then
        local resolved_target
        resolved_target="$(realpath "$target_dir")" || { echo "error: cannot resolve '$target_dir'" >&2; return 1; }
        cd "$resolved_target" || { echo "error: cannot enter '$target_dir'" >&2; return 1; }
    fi

    local run_dir
    run_dir="$(pwd -P)"
    require_worktree_root "$run_dir"

    refuse_git_location_env

    local git_common_dir
    git_common_dir="$(git rev-parse --git-common-dir)"
    git_common_dir="$(realpath "$git_common_dir")"
    refuse_relocated_ref_storage "$git_common_dir"
    refuse_object_alternates "$git_common_dir"

    # An in-progress rebase/sequence would be aborted at teardown (see git-protect-cleanup.sh);
    # refuse to start on top of one so chopi only ever aborts operations the sandboxed run left.
    refuse_inflight_sequencing "$run_dir"

    # Submodule gitdirs can relocate their own ref storage, can read objects through alternates
    # of their own, and can hold their own in-progress sequencing state.
    collect_submodules "$run_dir"
    local i
    for ((i = 0; i < ${#CHOPI_GIT_TARGET_SUB_GITDIRS[@]}; i++)); do
        refuse_relocated_ref_storage "${CHOPI_GIT_TARGET_SUB_GITDIRS[i]}"
        refuse_object_alternates "${CHOPI_GIT_TARGET_SUB_GITDIRS[i]}"
        refuse_inflight_sequencing "${CHOPI_GIT_TARGET_SUB_MAIN_WORKTREES[i]}"
    done
}

main "$@"

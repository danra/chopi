#!/usr/bin/env bash
#
# git-preflight.sh -- refuse unsupported git setups
#
# Not run directly; `chopi` calls this before generating the git protection profiles.
#
# usage: git-preflight.sh
#
# Exits non-zero iff the setup is refused.

set -euo pipefail

SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
. "$SCRIPT_DIR/git-layout.sh"

main() {
    arity 0

    local run_dir
    run_dir="$(pwd -P)"
    if ! is_worktree_root "$run_dir"; then
        refuse_steered_worktree "$run_dir"; return
    fi

    refuse_git_location_env

    local git_common_dir
    git_common_dir="$(git rev-parse --git-common-dir)"
    git_common_dir="$(realpath "$git_common_dir")"
    refuse_relocated_ref_storage "$git_common_dir"
    refuse_object_alternates "$git_common_dir"

    # Submodule gitdirs can relocate their own ref storage, and can read objects through
    # alternates of their own.
    collect_submodules "$run_dir"
    local i
    for ((i = 0; i < ${#CHOPI_GIT_TARGET_SUB_GITDIRS[@]}; i++)); do
        refuse_relocated_ref_storage "${CHOPI_GIT_TARGET_SUB_GITDIRS[i]}"
        refuse_object_alternates "${CHOPI_GIT_TARGET_SUB_GITDIRS[i]}"
    done
}

main "$@"

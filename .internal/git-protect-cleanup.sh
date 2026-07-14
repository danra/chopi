#!/usr/bin/env bash
#
# git-protect-cleanup.sh -- abort any in-progress rebase or cherry-pick/revert sequence left in
# the current git worktree (and its submodules) by the sandboxed command.
#
# usage: git-protect-cleanup.sh
#
# Not run directly. chopi runs it INSIDE the sandbox, right after the sandboxed command exits,
# to abort any in-progress sequenced rebase or cherry-pick: resuming one outside of the sandbox
# could execute rogue `exec` lines injected into the todo list. Running it in-sandbox is
# deliberate, so anything possibly triggered by the cleanup itself stays confined.
#
# Operates on the current directory (the worktree the sandboxed command ran in).
#
# Prints one notice per aborted operation, warning if the abort failed.

set -euo pipefail

SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
. "$SCRIPT_DIR/git-layout.sh"

# Abort the exec-capable sequencing operation in progress in worktree $1, if any, then report
# whether the abort actually cleared it.
abort_inflight() {
    arity 1
    local worktree="$1"

    local op
    op="$(inflight_exec_sequencing "$worktree")"
    [ -n "$op" ] || return 0

    case "$op" in
        rebase)
            git -C "$worktree" rebase --abort >/dev/null 2>&1 || true ;;
        sequencer)
            # `cherry-pick --abort` clears either cherry-pick or revert
            git -C "$worktree" cherry-pick --abort >/dev/null 2>&1 || true ;;
    esac

    local phrase
    phrase="$(sequencing_phrase "$op")"

    if [ -n "$(inflight_exec_sequencing "$worktree")" ]; then
        {
            echo "chopi: WARNING: could not abort the in-progress git $phrase left in"
            echo "           $worktree"
            echo "It may hide 'exec' lines that would run UNSANDBOXED on your next 'git ... --continue'."
            echo "Inspect it (git -C '$worktree' status) before continuing."
        } >&2
    else
        {
            echo "chopi: aborted the in-progress git $phrase left in"
            echo "           $worktree"
            echo "(a sandboxed command can hide 'exec' lines there that would run unsandboxed, unseen in"
            echo "'git status', on a later 'git ... --continue'). The worktree was reset to its state"
            echo "before the aborted $phrase; the commits remain reachable via the reflog."
        } >&2
    fi
}

main() {
    local run_dir
    run_dir="$(pwd -P)"

    abort_inflight "$run_dir"

    # Submodules too; on failure, skip but warn.
    local subs_file sub
    # shellcheck disable=SC2016
    if subs_file="$(mktemp "${TMPDIR:-/tmp}/chopi-abort-subs.XXXXXX")" \
        && git -C "$run_dir" submodule foreach --recursive --quiet 'printf "%s\0" "$PWD"' \
               >"$subs_file" 2>/dev/null; then
        while IFS= read -r -d '' sub || [ -n "$sub" ]; do
            abort_inflight "$sub"
        done < "$subs_file"
    else
        {
            echo "chopi: WARNING: could not enumerate the submodules of"
            echo "           $run_dir"
            echo "so any in-progress rebase or cherry-pick/revert sequence left in a submodule was NOT"
            echo "aborted; it could run 'exec' UNSANDBOXED on a later 'git ... --continue'. Check with:"
            echo "           git -C '$run_dir' submodule foreach --recursive git status"
        } >&2
    fi
}

main "$@"

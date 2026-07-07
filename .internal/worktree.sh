#!/usr/bin/env bash
#
# worktree.sh -- setup for `chopi --worktree NAME`: create (or reuse) a git worktree
# and run the pre-sandbox setup commands in it.
#
# Not run directly; `chopi` calls this before invoking safehouse when --worktree is given.
#
# usage: worktree.sh [--config FILE] NAME
#
# Prints the worktree path (NUL-terminated) to stdout on success, exits non-zero on error.

set -euo pipefail

SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
. "$SCRIPT_DIR/git-layout.sh"

# chopi_record_upstream -- pre-record the checked-out branch's upstream: exactly what
# `git push -u REMOTE BRANCH` would write on first push, which the sandboxed command cannot
# (the hardening profile makes the shared .git/config read-only). The branch is whatever
# the worktree has checked out -- the worktree name for a fresh worktree, but possibly
# different for a reused one.
#
# The remote is the repo's only one, or 'origin' when there are several; several remotes
# with no 'origin' among them is an error, since the choice can't be deduced. A no-op when
# the checkout is detached (no branch to track anything), the repo has no remote at all, or
# the branch already tracks an upstream. Defined here as a helper available to
# CHOPI_WORKTREE_SETUP, which the default one calls.
chopi_record_upstream() {
    arity 0
    local branch
    if ! branch="$(git symbolic-ref --quiet --short HEAD)"; then return 0; fi
    if git config "branch.$branch.remote" >/dev/null 2>&1; then return 0; fi

    local remote_list
    remote_list="$(git remote)"
    if [ -z "$remote_list" ]; then return 0; fi
    local remotes=() line
    while IFS= read -r line; do remotes+=("$line"); done <<< "$remote_list"

    local remote="" r
    if [ "${#remotes[@]}" -eq 1 ]; then
        remote="${remotes[0]}"
    else
        for r in "${remotes[@]}"; do
            if [ "$r" = origin ]; then remote=origin; break; fi
        done
    fi
    if [ -z "$remote" ]; then
        {
            echo "error: cannot deduce which remote branch '$branch' should track:"
            echo "the repo has multiple remotes (${remotes[*]}) and none of them is 'origin'."
        } >&2
        return 1
    fi

    git config "branch.$branch.remote" "$remote" \
        && git config "branch.$branch.merge" "refs/heads/$branch"
}

validate_name() {
    arity 1
    local name="$1"
    case "$name" in
        -*)                 echo "error: worktree NAME must not start with '-': '$name'" >&2; return 1 ;;
        /*)                 echo "error: worktree NAME must be relative, not absolute: '$name'" >&2; return 1 ;;
        ..|../*|*/..|*/../*) echo "error: worktree NAME must not contain '..': '$name'" >&2; return 1 ;;
    esac
    # With '..' already ruled out, a NAME made only of '.' and '/' is effectively empty
    # (or names dot-only dirs that git won't branch on, e.g., '...')
    if [[ "$name" =~ ^[./]*$ ]]; then
        echo "error: --worktree requires a non-empty NAME (got '$name')" >&2
        return 1
    fi
}

# True iff the path at $2 is registered as a worktree that git considers prunable: its
# directory was deleted manually rather than with 'git worktree remove', leaving a stale
# registration. $1 is a file holding 'git worktree list --porcelain -z' output.
is_prunable_worktree() {
    arity 2
    local wt_list="$1" path="$2"
    local line in_target=0
    while IFS= read -r -d '' line || [ -n "$line" ]; do
        case "$line" in
            "worktree $path") in_target=1 ;;
            "worktree "*)     in_target=0 ;;
            "prunable "*)     if [ "$in_target" -eq 1 ]; then return 0; fi ;;
        esac
    done < "$wt_list"
    return 1
}

setup_worktree() {
    arity 1
    local name="$1"
    validate_name "$name"

    # Preflight check which is also enforced by git-preflight.sh, which chopi runs AFTER this
    # script; checked here first so no worktree is created for a run that is bound to be refused.
    #
    # This one must precede the `git rev-parse` calls below to avoid being misdirected.
    refuse_git_location_env

    # Accept only the root of a git worktree, like normal (non-worktree) mode, where git
    # protections apply only at a worktree root. From a subdir, the repo to add the
    # worktree to would be resolved by walking upward, inviting user errors of securing
    # a different repo than intended.
    local invocation_dir
    invocation_dir="$(pwd -P)"
    if ! is_worktree_root "$invocation_dir"; then
        echo "error: --worktree must be run from the root of a git worktree" >&2
        return 1
    fi

    local git_common_dir
    git_common_dir="$(git rev-parse --git-common-dir)"
    git_common_dir="$(realpath "$git_common_dir")"

    # More pre-preflight checks to avoid creating a worktree for a run that is bound to be refused
    # by git-preflight.sh later.
    refuse_relocated_ref_storage "$git_common_dir"
    refuse_object_alternates "$git_common_dir"

    # Try resolving the main worktree. It's almost always the first worktree that
    # `git worktree list` prints; in rare cases it's different, or can't be resolved --
    # in which case there is nowhere to put .worktrees/, so the run is refused.
    local wt_list
    wt_list="$(mktemp "$TMPDIR/chopi-wt-list.XXXXXX")"
    if ! git worktree list --porcelain -z >"$wt_list" 2>/dev/null; then
        echo "error: 'git worktree list --porcelain -z' failed; cannot determine the main worktree" >&2
        return 1
    fi
    local first_listed_worktree="" listed_path line
    while IFS= read -r -d '' line || [ -n "$line" ]; do
        case "$line" in "worktree "*) ;; *) continue ;; esac
        listed_path="${line#worktree }"
        if ! first_listed_worktree="$(realpath "$listed_path")"; then
            echo "error: 'git worktree list' reported '$listed_path' first, but it cannot be resolved" >&2
            return 1
        fi
        break
    done < "$wt_list"
    if [ -z "$first_listed_worktree" ]; then
        echo "error: 'git worktree list --porcelain' returned no entries?! Even a bare repo returns one" >&2
        return 1
    fi
    local main_worktree_dir
    main_worktree_dir="$(resolve_main_worktree "$first_listed_worktree" "$git_common_dir")"
    if [ -z "$main_worktree_dir" ]; then
        {
            echo "error: cannot resolve the repo's main worktree, under which the new worktree"
            echo "would be created (<main worktree>/.worktrees/$name). Create a worktree with"
            echo "'git worktree add' and run chopi inside it instead."
        } >&2
        return 1
    fi

    local chopi_worktree_path="$main_worktree_dir/.worktrees/$name"

    if [ -e "$chopi_worktree_path" ]; then
        local existing_common
        if existing_common="$(git -C "$chopi_worktree_path" rev-parse --git-common-dir 2>/dev/null)" \
            && [ "$(realpath "$existing_common")" = "$git_common_dir" ]; then
            echo "Reusing existing worktree: $chopi_worktree_path" >&2
        else
            echo "error: '$chopi_worktree_path' already exists but is not a worktree of this repo" >&2
            return 1
        fi
    else
        if is_prunable_worktree "$wt_list" "$chopi_worktree_path"; then
            echo "Removing stale registration of manually-deleted worktree: $chopi_worktree_path" >&2
            git worktree remove "$chopi_worktree_path" >&2
        fi
        if ! mkdir -p "$main_worktree_dir/.worktrees"; then
            echo "error: could not create worktree parent dir '$main_worktree_dir/.worktrees'" >&2
            return 1
        fi
        if git show-ref --verify --quiet "refs/heads/$name"; then
            git worktree add "$chopi_worktree_path" "$name" >&2
        else
            git worktree add -b "$name" "$chopi_worktree_path" >&2
        fi
    fi

    chopi_worktree_path="$(realpath "$chopi_worktree_path")"

    # Run the pre-sandbox worktree setup
    export CHOPI_WORKTREE_NAME="$name"
    local setup_cmd
    for setup_cmd in "${CHOPI_WORKTREE_SETUP[@]+"${CHOPI_WORKTREE_SETUP[@]}"}"; do
        if ! (cd "$chopi_worktree_path" && eval "$setup_cmd") >&2; then
            echo "error: worktree setup command failed: $setup_cmd" >&2
            return 1
        fi
    done

    # Output the worktree path for the run
    printf '%s\0' "$chopi_worktree_path"
}

# chopi always executes this script as a subprocess (for `--worktree`); it is never sourced.
config=""
if [ "${1:-}" = "--config" ]; then
    if [ "$#" -lt 2 ]; then echo "error: --config requires a file path" >&2; exit 1; fi
    config="$2"; shift 2
fi
if [ "$#" -ne 1 ]; then echo "error: unexpected args" >&2; exit 1; fi
if [ -n "$config" ]; then
    if [ ! -r "$config" ]; then
        echo "error: cannot read sandbox config '$config'" >&2
        exit 1
    fi
    # Sourced only for CHOPI_WORKTREE_SETUP
    # shellcheck source=/dev/null  # can't follow user-supplied config path at lint time
    . "$config"
    if ! declare -p CHOPI_WORKTREE_SETUP >/dev/null 2>&1; then
        cat >&2 <<EOF
error: --worktree needs CHOPI_WORKTREE_SETUP, but '$config' does not define it.
Copy the default from $CHOPI_DIR/config/templates/sandbox.template.sh into your config,
set your own, or set CHOPI_WORKTREE_SETUP=() for no worktree setup.
EOF
        exit 1
    fi
fi
setup_worktree "$1"

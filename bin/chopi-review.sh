#!/usr/bin/env bash
#
# chopi-review.sh -- apply the changes sandboxed commands proposed for the paths in
# CHOPI_SAFE_WRITE_TARGETS, one commit each, after showing you what they are.
#
# Runs outside of the sandbox.
#
# Usually invoked as `chopi-review` via the sibling symlink (bin/chopi-review -> chopi-review.sh).

set -euo pipefail

SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

# chopi marks its sandbox by exporting CHOPI_DIR, so an inherited one means this is running
# confined. Read before util.sh, which resolves CHOPI_DIR for every run, sandboxed or not.
in_sandbox="${CHOPI_DIR:+1}"

. "$SCRIPT_DIR/../.internal/util.sh"
. "$SCRIPT_DIR/../.internal/git-layout.sh"
. "$SCRIPT_DIR/../.internal/write-targets.sh"

usage="usage: chopi-review [--config FILE]

  --config FILE    take the safe write targets from FILE instead of the default
                   config/sandbox.sh"

# Every review gets its own private subfolder under TMPDIR (or /tmp), exported into TMPDIR, so the
# copies it renders patches off and anything the gits it runs generate are contained in it and
# removed when the review ends.
REVIEW_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/chopi-review.XXXXXX")" \
    || { echo "chopi-review: could not create a temp dir for the review" >&2; exit 1; }
export TMPDIR="$REVIEW_TMPDIR"
trap 'rm -rf "$REVIEW_TMPDIR"' EXIT

applied=0
rejected=0
skipped=0
failed=0

am_in_flight=""
# shellcheck disable=SC2329  # invoked from the traps below, which shellcheck doesn't follow
review_on_signal() {
    arity 1
    local sig="$1"
    # Cleanup in case a signal was received mid-am
    if [ -n "$am_in_flight" ]; then
        git -C "$am_in_flight" am --abort 2>/dev/null || true
        echo "  interrupted; the git worktree is back as it was." >&2
    fi
    rm -rf "$REVIEW_TMPDIR"
    trap - "$sig"
    kill -"$sig" $$
}

trap 'review_on_signal INT'  INT
trap 'review_on_signal TERM' TERM
trap 'review_on_signal HUP'  HUP

slot_review_target() {
    local slot="$1"; shift    # the rest: the allowed target paths
    local target

    target="$(slot_target "$slot")"
    if [ -z "$target" ]; then
        echo "chopi-review: $slot safe write target record is invalid; leaving its patches." >&2
        return 1
    fi
    if is_item_in_list "$target" "$@"; then
        printf '%s' "$target"
        return 0
    fi
    echo "chopi-review: $target is no longer a safe write target; leaving its patches in $slot" >&2
    return 1
}

# Collect into PATCH_PATHS the paths that patch $1 would write to.
PATCH_PATHS=()
collect_patch_paths() {
    arity 1
    local patch="$1" record without_added just_path
    PATCH_PATHS=()
    while IFS= read -r -d '' record; do
        # each entry is added<TAB>deleted<TAB>path
        without_added="${record#*$'\t'}"
        just_path="${without_added#*$'\t'}"
        PATCH_PATHS+=("$just_path")
    done < <(git apply --numstat -z "$patch" 2>/dev/null)
}

# Collect into REFUSED_PATHS which of the paths $3... target $1 refuses, if any. A directory
# target must have all paths nested inside it and outside git's own directory, and a file target
# refuses all paths except its own basename $2.
REFUSED_PATHS=()
collect_refused_patch_paths() {
    local target="$1" single_file_target="$2"; shift 2
    local path
    REFUSED_PATHS=()
    for path in "$@"; do
        if [ -n "$single_file_target" ]; then
            [ "$path" = "$single_file_target" ] || REFUSED_PATHS+=("$path")
        else
            validate_write_patch "$target" "$path" || REFUSED_PATHS+=("$path")
        fi
    done
}

# Collect into DIRTY_PATHS which of the paths $3... already have uncommitted changes in the
# worktree at $1, where the patch applies below prefix $2 (empty when the target is the worktree
# root itself).
DIRTY_PATHS=()
collect_dirty_patch_paths() {
    local worktree_root="$1" write_target_prefix_in_worktree="$2"; shift 2
    local path in_worktree status
    DIRTY_PATHS=()
    for path in "$@"; do
        in_worktree="${write_target_prefix_in_worktree:+$write_target_prefix_in_worktree/}$path"
        status="$(git -C "$worktree_root" status --porcelain -- "$in_worktree" 2>/dev/null)"
        [ -n "$status" ] && DIRTY_PATHS+=("$path")
    done
    return 0
}

# Ask what to do with the patch just shown and print the answer: '[a]pply', '[r]eject' or '[s]kip'.
#
# No default, and an unrecognized key just asks again: all three outcomes are consequential.
# ^C aborts (wanted ESC too but not worth it, makes arrow keys also abort).
review_choice() {
    arity 0
    local answer
    while true; do
        printf '  [a]pply / [r]eject / [s]kip? ' >&2
        answer="$(prompt_read_key)" || { printf 'skip'; return 0; }
        case "$answer" in
            a | A) printf 'apply';  return 0 ;;
            r | R) printf 'reject'; return 0 ;;
            s | S) printf 'skip';   return 0 ;;
        esac
    done
}

leave_patch() {
    arity 2
    local patch="$1" choice="$2"
    case "$choice" in
        reject) rm -f "$patch"; rejected=$((rejected + 1)) ;;
        skip)   skipped=$((skipped + 1)) ;;
        *) echo "BUG: leave_patch: bad choice '$choice'" >&2; exit 2 ;;
    esac
}

# Extract the patch subject which becomes the first line of the commit message
patch_subject() {
    arity 1
    awk '/^Subject: / { sub(/^Subject: (\[PATCH\] )?/, ""); print; exit }' "$1"
}

# Extract the patch body which becomes the rest of the commit message
patch_body() {
    arity 1
    awk 'BEGIN { headers = 1 }
         /^---$/ { exit }
         headers && /^$/ { headers = 0; next }
         headers { next }
         { print }' "$1"
}

raw_patch_diff() {
    arity 1
    awk 'in_diff; /^---$/ { in_diff = 1 }' "$1"
}

# True iff the patch has an empty (whitespace-only) diff section.
# Git skips whatever surrounds a diff header looking for one, so it reads a section carrying no header
# the same as an empty one; it's better UX to loudly reject odd, invalid patches, not silently report
# them as a noop like we do for the empty case.
patch_diff_is_empty() {
    arity 1
    local patch="$1" diff
    grep -q '^---$' "$patch" || return 1
    diff="$(raw_patch_diff "$patch" | tr -d '[:space:]')"
    [ -z "$diff" ]
}

# Print the patch subject quoted and indented (if it has one, which is normally the case)
pretty_patch_subject() {
    arity 1
    local subject
    subject="$(patch_subject "$1")"
    [ -n "$subject" ] && printf '  "%s"\n' "$subject"
    return 0
}

# Format arguments as a bulletlist
bullets() {
    local item
    for item in "$@"; do
        printf '   - %s\n' "${item:-(empty)}"
    done
}

# Handle a patch that had to be skipped (not user's choice)
# Prints its subject and reasons why it had to be skipped, and increments the skip count
forced_skip_patch() {
    local patch="$1"; shift
    pretty_patch_subject "$patch" >&2
    printf '%s\n' "$@" >&2
    skipped=$((skipped + 1))
}

# Skip rest of patches when the target isn't ready for them (dirty working tree, in the middle of
# a git operation, etc.)
forced_skip_remaining_patches_for_target() {
    local target="$1"; shift
    local patch subjects=()
    for patch in "$@"; do
        subjects+=("$(patch_subject "$patch")")
        skipped=$((skipped + 1))
    done
    printf '  %s more patches for %s wait until it is clear:\n' "${#subjects[@]}" "$target" >&2
    bullets "${subjects[@]}" >&2
}

# Make a copy of a worktree index, helper for pretty_patch_diff below
copy_worktree_index() {
    arity 2
    local worktree_root="$1" index="$2"

    if git -C "$worktree_root" rev-parse --verify --quiet HEAD >/dev/null; then
        GIT_INDEX_FILE="$index" git -C "$worktree_root" read-tree HEAD
    else
        GIT_INDEX_FILE="$index" git -C "$worktree_root" read-tree --empty
    fi
}

# Copy the worktree's index and `git apply` a patch to the copy, so we can see the effect
# without touching the real target's git index and worktree. $4... are extra flags for
# git apply. SIMULATED_APPLY_INDEX holds the result.
#
# Returns non-zero when the patch did not apply cleanly, which still leaves an index to read:
# unchanged after a plain apply, which is all or nothing, or holding the conflict after --3way.
# SIMULATED_APPLY_INDEX is empty when the copy itself could not be made (no temp file, unreadable
# HEAD), and then nothing was learned about the patch.
SIMULATED_APPLY_INDEX=""
simulated_apply() {
    local worktree_root="$1" write_target_prefix_in_worktree="$2" patch="$3"; shift 3
    local index
    SIMULATED_APPLY_INDEX=""
    index="$(mktemp "$TMPDIR/simulated.XXXXXX")" || return 1
    copy_worktree_index "$worktree_root" "$index" || return 1
    SIMULATED_APPLY_INDEX="$index"
    GIT_INDEX_FILE="$index" git -C "$worktree_root" apply --cached \
        ${write_target_prefix_in_worktree:+--directory="$write_target_prefix_in_worktree"} \
        "$@" "$patch" 2>/dev/null
}

# Try the patch against a copy of the index and print what applying it for real would do: 'nothing'
# when the target already holds it, 'conflict' when git am would stop with the conflict for the
# reviewer, 'changes' otherwise; 'error' when the copy could not be made, so the trial never ran.
#
# --3way is required, to match the actual `git am --3way` later: Without it, we might ask the
# reviewer about a patch that would change nothing.
simulated_apply_verdict() {
    arity 3
    local worktree_root="$1" write_target_prefix_in_worktree="$2" patch="$3"
    if ! simulated_apply "$worktree_root" "$write_target_prefix_in_worktree" "$patch" --3way; then
        # An index to read means git apply refused the patch, the conflict git am stops on
        if [ -n "$SIMULATED_APPLY_INDEX" ]; then printf 'conflict'; else printf 'error'; fi
        return 0
    fi
    local -x GIT_INDEX_FILE="$SIMULATED_APPLY_INDEX"   # unexported again when this function returns
    if git -C "$worktree_root" diff --cached --quiet; then printf 'nothing'; else printf 'changes'; fi
}

# Show the proposed patch diff using `git diff`
# Git apparently doesn't provide this out-of-the-box, so we diff the index copy the patch was
# applied to against the worktree's own.
#
# A plain apply, deliberately not --3way: under 3-way a patch the target already holds applies to
# nothing, so (before the auto-apply of the noop patch) the reviewer would be shown an empty diff
# instead of the patch diff. with no idea of what the patch actually was. Or, with a patch that
# creates a `git am --3way` conflict that the reviewer then needs to reslve, he would be shown the
# conflict inline instead of the patch contents, which is less helpful (the conflict itself would
# be visible and have to be reviewed at the repo anyway).
pretty_patch_diff() {
    arity 3
    local patch="$1" worktree_root="$2" write_target_prefix_in_worktree="$3"

    [ -n "$worktree_root" ] || return 1
    simulated_apply "$worktree_root" "$write_target_prefix_in_worktree" "$patch" || return 1
    local -x GIT_INDEX_FILE="$SIMULATED_APPLY_INDEX"   # unexported again when this function returns

    # TODO: `--no-pager` keeps the review inline, but it also drops custom diff presentations
    # by delta and the like. We can add targeted support, e.g., delta takes --paging=never, so
    # we don't have to drop it if that's the configured pager.
    git -C "$worktree_root" --no-pager diff --cached --stat
    echo
    git -C "$worktree_root" --no-pager diff --cached
}

# Run git diff between two non-git paths, helper for pretty_patch_diff_no_repo below
# --no-index implies --exit-code, so a status of 1 is just some diff; higher exit codes mean
# some failure.
diff_no_index() {
    local work="$1"; shift
    local status=0

    git -C "$work" --no-pager diff --no-index --no-prefix "$@" || status=$?
    [ "$status" -le 1 ]
}

# Same as pretty_patch_diff, for safe targets not contained in git worktrees (nothing to commit,
# e.g., a change to a user config file); git apply and diff work even with no git, we just copy
# the files to patch instead of a git index.
pretty_patch_diff_no_repo() {
    local patch="$1" dir="$2"; shift 2
    local work path

    work="$(mktemp -d "$TMPDIR/diff.XXXXXX")" || return 1
    mkdir -p "$work/a" "$work/b"
    for path in "$@"; do
        [ -f "$dir/$path" ] || [ -L "$dir/$path" ] || continue # nothing to diff with: the patch creates it
        mkdir -p "$work/a/$(dirname "$path")" "$work/b/$(dirname "$path")"
        cp -P "$dir/$path" "$work/a/$path"
        cp -P "$dir/$path" "$work/b/$path"
    done

    git -C "$work/b" apply "$patch" 2>/dev/null || return 1

    diff_no_index "$work" --stat -- a b || return 1
    echo
    diff_no_index "$work" -- a b || return 1
}

# Show a patch $1 to the reviewer: first the commit message, then a diff stat, then the diff.
# $2 is the safe write target and $3 is the directory the patch applies in.
# $7... are the paths the patch writes to.
#
# Summary and diff both come from git, so they arrive in the reviewer's own diff settings: their
# colors, their whitespace highlighting, their rename detection. Written straight to the terminal,
# never captured, which is what leaves git free to decide about color the way it does everywhere
# else. Only a patch git cannot parse as a diff falls back to the artifact's own text.
#
# Alternative considered: Use `git am` not just for committing, but for the review itself using
# `git am --interactive`. It sort-of worked, but provided a worse UX overall (inexact prompts,
# non-customizable and worse patch presentation).
show_patch() {
    local patch="$1" target="$2" apply_dir="$3" worktree_root="$4" \
          write_target_prefix_in_worktree="$5" workspace="$6"; shift 6

    local in_worktree=""
    [ -n "$write_target_prefix_in_worktree" ] && in_worktree=" (in git worktree $worktree_root)"
    echo
    echo "----------------------------------------------------------------------------"
    printf 'patch for %s%s\n' "$target" "$in_worktree"
    [ -n "$workspace" ] && printf 'generated from %s\n' "$workspace"
    echo "----------------------------------------------------------------------------"

    patch_subject "$patch"
    echo
    patch_body "$patch"

    local rendered=""
    if [ -n "$worktree_root" ]; then
        pretty_patch_diff "$patch" "$worktree_root" "$write_target_prefix_in_worktree" && rendered=1
    else
        pretty_patch_diff_no_repo "$patch" "$apply_dir" "$@" && rendered=1
    fi
    # Fallback to render raw diff if git diff rendering failed for some reason
    if [ -z "$rendered" ]; then
        git apply --stat "$patch" 2>/dev/null || true
        echo
        raw_patch_diff "$patch"
    fi
    echo
}

# Account for a patch that leaves the target as it is, $2 saying which way it does: nothing to
# write and nothing to decide, so it is counted and dropped without putting it to a reviewer whose
# every answer would come to the same thing.
handle_noop_patch() {
    arity 2
    local patch="$1" reason="$2"
    echo "  $reason; nothing to apply."
    rm -f "$patch"
    applied=$((applied + 1))
}

# Whether the worktree is in the middle of an operation that would interrupt applying a patch
worktree_op_inflight() {
    arity 1
    local worktree_root="$1" state dir
    for state in rebase-apply rebase-merge sequencer; do
        dir="$(git -C "$worktree_root" rev-parse --path-format=absolute --git-path "$state")"
        [ -d "$dir" ] && return 0
    done
    return 1
}

# Review a patch, applying it as a commit to the git worktree containing the write target. Returns
# non-zero when the worktree is in no state to take another patch, so that the caller can set the
# rest of them aside together instead of walking each one into the same answer.
review_patch_in_repo() {
    local patch="$1" worktree_root="$2" write_target_prefix_in_worktree="$3"; shift 3

    if worktree_op_inflight "$worktree_root"; then
        forced_skip_patch "$patch" \
            "  skipped: the git worktree containing the safe write target is in the middle of an am, rebase, cherry-pick, or revert." \
            "  finish or abort it in $worktree_root, then run chopi-review again."
        return 1
    fi

    collect_dirty_patch_paths "$worktree_root" "$write_target_prefix_in_worktree" "$@"
    if [ "${#DIRTY_PATHS[@]}" -gt 0 ]; then
        forced_skip_patch "$patch" \
            "  skipped: these paths have uncommitted changes in the git worktree:" \
            "$(bullets "${DIRTY_PATHS[@]}")" \
            "  commit or stash them, then run chopi-review again."
        return 0
    fi

    if ! git -C "$worktree_root" diff --cached --quiet 2>/dev/null; then
        forced_skip_patch "$patch" \
            "  skipped: there is staged work in the git worktree $worktree_root." \
            "  commit or stash it, then run chopi-review again."
        return 0
    fi

    # Last of the checks that must clear before anything is put to the reviewer, and after the
    # guards above, which decide whether the patch can be applied here at all.
    local verdict
    verdict="$(simulated_apply_verdict "$worktree_root" "$write_target_prefix_in_worktree" "$patch")"
    if [ "$verdict" = error ]; then
        # Nothing is known about this patch, and the next one would meet the same wall, so the
        # whole target waits on a reviewer who can see what mktemp or git just complained about.
        pretty_patch_subject "$patch" >&2
        echo "  failed: could not copy the git index of $worktree_root to try the patch against." >&2
        echo "  the error is above; fix it, then run chopi-review again." >&2
        failed=$((failed + 1))
        return 1
    fi
    if [ "$verdict" = nothing ]; then
        handle_noop_patch "$patch" "the patch diff is a noop, already there"
        return 0
    fi
    if [ "$verdict" = conflict ]; then
        echo "  note: this patch conflicts with other committed changes. applying it would require"
        echo "  resolving the conflict in $worktree_root before reviewing more patches for the target."
    fi

    local choice
    choice="$(review_choice)"
    if [ "$choice" != apply ]; then
        leave_patch "$patch" "$choice"
        return 0
    fi

    local before after am_status=0
    before="$(git -C "$worktree_root" rev-parse --verify HEAD 2>/dev/null || printf 'no commits yet')"

    am_in_flight="$worktree_root"
    git -C "$worktree_root" am --3way \
        ${write_target_prefix_in_worktree:+--directory="$write_target_prefix_in_worktree"} "$patch" \
        || am_status=$?
    am_in_flight=""

    after="$(git -C "$worktree_root" rev-parse --verify HEAD 2>/dev/null || printf 'no commits yet')"
    if [ "$after" != "$before" ]; then
        local landed
        landed="$(git -C "$worktree_root" log --format='%h %s' -1)"
        rm -f "$patch"
        echo "  committed $landed"
        applied=$((applied + 1))
        return 0
    fi
    # Didn't commit anything.

    if worktree_op_inflight "$worktree_root"; then
        rm -f "$patch"
        echo "  git am stopped in $worktree_root, needs conflict resolution." >&2
        echo "  resolve it, git add, then git am --continue; or git am --abort to discard." >&2
        applied=$((applied + 1))
        return 1
    fi

    # The trial run before the prompt settles this normally, so reaching here means it could not be
    # made; git am has since found the same thing the long way round.
    if [ "$am_status" -eq 0 ]; then
        handle_noop_patch "$patch" "the patch diff is a noop, already there"
        return 0
    fi

    # Some git am refusal that left nothing behind; git already printed the error.
    echo "  nothing was committed; the git worktree is as it was." >&2
    failed=$((failed + 1))
}

backup_target_paths_no_repo() {
    local target="$1"; shift
    local path
    for path in "$@"; do
        [ -f "$target/$path" ] || [ -L "$target/$path" ] || continue
        cp -P "$target/$path" "$target/$path.orig"
    done
}

# Review a patch for a write target not contained in a git worktree.
# git apply can still be used, but there's no commit history, so leave .orig backups.
review_patch_no_repo() {
    local patch="$1" target="$2"; shift 2

    # The target may already hold what a (non-empty) patch proposes: the patch no longer applies,
    # while reversing it does, which is to say the target already matches what applying it would
    # produce. A patch that is only partly there applies in neither direction, so it stays the failure
    # it is. This is as much as can be read without a repo, there being no index to try the patch
    # against and no 3-way merge to see past lines that have drifted around it.
    if ! git -C "$target" apply --check "$patch" 2>/dev/null; then
        if git -C "$target" apply -R --check "$patch" 2>/dev/null; then
            handle_noop_patch "$patch" "the patch diff is a noop, already there"
        else
            echo "  failed: the patch does not apply to $target (target modified since patch was created?)." >&2
            failed=$((failed + 1))
        fi
        return 0
    fi
    echo "  target not in git repo, [a]pply will rewrite files in place and create backups"
    local choice
    choice="$(review_choice)"
    if [ "$choice" != apply ]; then
        leave_patch "$patch" "$choice"
        return 0
    fi

    backup_target_paths_no_repo "$target" "$@"
    if git -C "$target" apply "$patch"; then
        rm -f "$patch"
        echo "  applied; the previous contents are beside each file as .orig"
        applied=$((applied + 1))
    else
        echo "  failed while applying; check $target" >&2
        failed=$((failed + 1))
    fi
}

review_patch() {
    arity 3
    local patch="$1" target="$2" workspace="$3"

    local apply_dir="$target" single_file_target=""
    if [ -f "$target" ]; then
        # A single file target: applied in its parent directory
        apply_dir="$(dirname "$target")"
        single_file_target="$(basename "$target")"
    fi

    local worktree_root write_target_prefix_in_worktree="" real_apply_dir
    worktree_root="$(scrubbed_toplevel "$apply_dir")" || worktree_root=""
    if [ -n "$worktree_root" ]; then
        real_apply_dir="$(realpath "$apply_dir")"
        write_target_prefix_in_worktree="$(relative_path_within "$real_apply_dir" "$worktree_root")"
    fi

    collect_patch_paths "$patch"
    show_patch "$patch" "$target" "$apply_dir" "$worktree_root" \
        "$write_target_prefix_in_worktree" "$workspace" "${PATCH_PATHS[@]+"${PATCH_PATHS[@]}"}"

    if [ "${#PATCH_PATHS[@]}" -eq 0 ]; then
        if patch_diff_is_empty "$patch"; then
            handle_noop_patch "$patch" "the patch carries no diff"
        else
            pretty_patch_subject "$patch" >&2
            echo "  refused: the patch carries no diff git can parse." >&2
            failed=$((failed + 1))
        fi
        return 0
    fi

    collect_refused_patch_paths "$apply_dir" "$single_file_target" "${PATCH_PATHS[@]}"
    if [ "${#REFUSED_PATHS[@]}" -gt 0 ]; then
        pretty_patch_subject "$patch" >&2
        if [ -n "$single_file_target" ]; then
            echo "  refused: the safe write target is the single file $target, but the patch writes:" >&2
        else
            echo "  refused: the patch writes outside the safe write target $target, or into git's internals:" >&2
        fi
        bullets "${REFUSED_PATHS[@]}" >&2
        failed=$((failed + 1))
        return 0
    fi

    if [ -n "$worktree_root" ]; then
        review_patch_in_repo "$patch" "$worktree_root" "$write_target_prefix_in_worktree" "${PATCH_PATHS[@]}"
    else
        review_patch_no_repo "$patch" "$apply_dir" "${PATCH_PATHS[@]}"
    fi
}

review_workspace_queue() {
    arity 1
    local queue_dir="$1"
    local slot target patch workspace pending_count reviewed

    collect_pending_patches "$queue_dir"
    pending_count="${#PENDING_PATCHES[@]}"
    [ "$pending_count" -gt 0 ] || return 0

    # The queue is named by a digest of its workspace, so the workspace comes from the queue's own
    # record, believed only when it hashes back to that name.
    workspace="$(queue_workspace "$queue_dir")"
    if [ -z "$workspace" ]; then
        echo "chopi-review: $queue_dir workspace record is invalid; leaving its patches." >&2
        echo "              Nothing in the sandbox can write that record, so one that doesn't" >&2
        echo "              hash back to the directory means corruption, or a write protection" >&2
        echo "              that didn't hold." >&2
        failed=$((failed + pending_count))
        return 0
    fi

    # chopi's config is the single source for what the valid safe write targets are
    if ! validate_write_targets "$workspace" chopi-review; then
        echo "chopi-review: invalid safe write targets configuration, leaving patches in place." >&2
        failed=$((failed + pending_count))
        return 0
    fi

    for slot in "$queue_dir"/*; do
        [ -d "$slot" ] || continue
        collect_pending_patches "$slot"
        [ "${#PENDING_PATCHES[@]}" -eq 0 ] && continue

        if ! target="$(slot_review_target "$slot" "${CHOPI_WRITE_TARGET_PATHS[@]+"${CHOPI_WRITE_TARGET_PATHS[@]}"}")"; then
            failed=$((failed + ${#PENDING_PATCHES[@]}))
            continue
        fi

        reviewed=0
        for patch in "${PENDING_PATCHES[@]}"; do
            reviewed=$((reviewed + 1))
            review_patch "$patch" "$target" "$workspace" && continue
            # The target can take no more; the rest of its queue is set aside in one go.
            if [ "$reviewed" -lt "${#PENDING_PATCHES[@]}" ]; then
                forced_skip_remaining_patches_for_target "$target" "${PENDING_PATCHES[@]:$reviewed}"
            fi
            break
        done
    done
}

main() {
    local config="$CHOPI_DIR/config/sandbox.sh"
    local config_given=""

    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help) echo "$usage"; return 0 ;;
            --config)
                if [ "$#" -lt 2 ]; then echo "chopi-review: --config requires a file path" >&2; return 1; fi
                config="$2"; config_given=1; shift 2 ;;
            *) echo "chopi-review: unexpected argument: $1" >&2; echo "$usage" >&2; return 1 ;;
        esac
    done

    # Applying a patch is the write the sandbox denied. Inside a session every one of them
    # fails, so say which side of the sandbox this belongs on rather than let the denials pile up.
    if [ -n "$in_sandbox" ]; then
        echo "chopi-review: this applies changes outside the sandbox, so it has to run on the host." >&2
        echo "              Leave the chopi session (or use another terminal) and run it there." >&2
        return 1
    fi
    if [ ! -t 0 ]; then
        echo "chopi-review: reviewing is interactive; run in a terminal." >&2
        return 1
    fi

    local CHOPI_SAFE_WRITE_TARGETS=()
    if [ ! -r "$config" ]; then
        if [ -n "$config_given" ]; then
            echo "chopi-review: cannot read config '$config'" >&2
        else
            echo "chopi-review: cannot read default config at $config; re-run install.sh" >&2
        fi
        return 1
    fi
    # shellcheck source=/dev/null  # can't follow user-supplied config path at lint time
    . "$config"

    if [ "${#CHOPI_SAFE_WRITE_TARGETS[@]}" -eq 0 ]; then
        echo "chopi-review: no safe write targets configured; add one to CHOPI_SAFE_WRITE_TARGETS in $config"
        return 0
    fi

    local queue_dir
    for queue_dir in "$CHOPI_PATCH_QUEUE_ROOT"/*; do
        [ -d "$queue_dir" ] || continue
        review_workspace_queue "$queue_dir"
    done

    if [ "$((applied + rejected + skipped + failed))" -eq 0 ]; then
        echo "chopi-review: nothing pending."
        return 0
    fi

    echo
    printf 'chopi-review: %s applied, %s rejected, %s skipped, %s failed\n' \
        "$applied" "$rejected" "$skipped" "$failed"
    [ "$failed" -eq 0 ]
}

{
    main "$@"
    # The braces make bash parse this whole block, exit included, before running it, so a
    # mid-session edit to this file cannot affect it: without the exit, bash would read the
    # file again after main returns, at a stale byte offset that executes garbage.
    exit
}

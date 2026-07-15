# shellcheck shell=bash
#
# git-isolate.sh -- Sourced by git-protect.sh to build the Seatbelt profile that isolates
# work to a single git worktree, keeping an agent from wandering outside its assigned
# worktree into others in the same repo.

write_isolation_profile() {
    arity 1
    local profile_path="$1"

    # shellcheck disable=SC2094  # we embed the profile's own path in a deny rule below
    {
        echo ";; chopi: isolate the command to the worktree at $CHOPI_GIT_TARGET_WORKTREE"

        local wt
        if [ -n "$CHOPI_GIT_TARGET_IS_MAIN" ]; then
            # Main worktree case
            #
            # The main worktree is already allowed by safehouse, no need to re-allow it

            # Take the other worktrees away (undoing safehouse's allowance).
            for wt in "${CHOPI_GIT_OTHER_WORKTREES[@]+"${CHOPI_GIT_OTHER_WORKTREES[@]}"}"; do
                rule 'deny file-read* file-write*' subpath "$wt"
            done

            # Allow the shared git dir; safehouse doesn't handle all cases itself
            if ! is_path_within "$CHOPI_GIT_COMMON_DIR" "$CHOPI_GIT_TARGET_WORKTREE"; then
                rule 'allow file-read* file-write*'  subpath "$CHOPI_GIT_COMMON_DIR"
            fi
        else
            # Linked worktree case

            # Deny the entire main worktree folder (in case we were able to resolve it)
            if [ -n "${CHOPI_GIT_MAIN_WORKTREE:-}" ]; then
                rule 'deny file-read* file-write*' subpath "$CHOPI_GIT_MAIN_WORKTREE"
            fi
            # ... and re-allow the shared git dir
            rule 'allow file-read* file-write*'  subpath "$CHOPI_GIT_COMMON_DIR"

            # Deny other worktrees.
            # Doing this ahead of allowing the target handles the edge-case of a sibling
            # CONTAINING the target, which is denied before the target's re-allow below.
            for wt in "${CHOPI_GIT_OTHER_WORKTREES[@]+"${CHOPI_GIT_OTHER_WORKTREES[@]}"}"; do
                # Skip ones the main-repo deny already covers
                [ -n "${CHOPI_GIT_MAIN_WORKTREE:-}" ] && is_path_within "$wt" "$CHOPI_GIT_MAIN_WORKTREE" && continue

                # A sibling worktree CONTAINED in the target is denied only after the target's
                # allow below.
                is_path_within "$wt" "$CHOPI_GIT_TARGET_WORKTREE" && continue

                rule 'deny file-read* file-write*' subpath "$wt"
            done

            # Obviously allow read/write in our designated worktree
            rule 'allow file-read* file-write*'  subpath "$CHOPI_GIT_TARGET_WORKTREE"

            # ...and then deny any sibling nested worktrees that we skipped before
            for wt in "${CHOPI_GIT_OTHER_WORKTREES[@]+"${CHOPI_GIT_OTHER_WORKTREES[@]}"}"; do
                is_path_within "$wt" "$CHOPI_GIT_TARGET_WORKTREE" || continue
                rule 'deny file-read* file-write*' subpath "$wt"
            done

            # Allow lookup (metadata only) on all ancestor folders of the worktree up to
            # the main worktree; some git operations (e.g. `git stash`) internally
            # traverse these dirs to resolve absolute paths into the worktree. With no
            # resolved main worktree nothing above the target was denied, so there is
            # nothing to re-allow.
            if [ -n "${CHOPI_GIT_MAIN_WORKTREE:-}" ]; then
                local ancestor="$CHOPI_GIT_TARGET_WORKTREE"
                while [ "$ancestor" != "$CHOPI_GIT_MAIN_WORKTREE" ]; do
                    ancestor="$(dirname "$ancestor")"
                    is_path_within "$ancestor" "$CHOPI_GIT_MAIN_WORKTREE" || break
                    rule 'allow file-read-metadata'  literal "$ancestor"
                done
            fi
        fi

        # Deny the command any access to this appended profile itself.
        # Belt-and-suspenders: The profile is temporary, only used for this run, and
        # safehouse compiles it into the live policy before, so writes to it don't matter
        # (safehouse>=0.11.0 also added file-write-deny on appended profiles, which matters
        # for non-temporary profiles). Reading the profile reveals absolute paths of sibling
        # worktrees, but those are mostly discoverable from the shared git dir anyway.
        rule 'deny file-read* file-write*'   literal "$profile_path"
    } > "$profile_path"
}

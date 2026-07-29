# shellcheck shell=bash
#
# git-harden.sh -- Sourced by git-protect.sh to build the Seatbelt profile that hardens
# the repo's git internals for the sandboxed command.
#
# .git stays readable, but only git's data paths (objects, refs, index, etc.) are writable.
# Everything else (config, hooks, etc.) stays read-only, so the sandboxed command can't
# plant code that could later run *unsandboxed* on some git operation. Submodules
# (recursive) get the same treatment.


# The three helpers below poke write holes into the blanket write-deny on the shared git
# dir (which also covers the worktree admin dirs and the submodule gitdirs inside it).
# They're grouped by the kind of git dir that stores them, so each call site takes
# exactly what it needs and nothing more.

# Ref storage: Every kind of git dir has one
allow_ref_writes() {
    arity 1
    local dir="$1"
    rule 'allow file-write*'         subpath "$dir/refs"
    rule 'allow file-write*'         subpath "$dir/logs"
    rule 'allow file-write*'         subpath "$dir/reftable"
}

# Object storage and other whole-repo data: Only in a full git dir (the shared dir and
# submodule gitdirs)
allow_repo_data_writes() {
    arity 1
    local dir="$1"
    rule 'allow file-write*'         subpath "$dir/objects"
    rule 'allow file-write*'         subpath "$dir/rr-cache"
    rule 'allow file-write*'         subpath "$dir/lfs"
    # prefix (not literal): each of these files comes with lock/tempfile siblings
    rule 'allow file-write*'         prefix  "$dir/packed-refs"
    rule 'allow file-write*'         prefix  "$dir/shallow"
    rule 'allow file-write*'         prefix  "$dir/gc."
    rule 'allow file-write*'         prefix  "$dir/info/refs"
}

# Checkout state, stored in whichever git dir governs a working tree: a worktree admin
# dir, a submodule's gitdir, or -- for the main worktree -- the shared git dir itself.
#
# info_scope selects how much of info/ opens up: 'info-dir' for per-worktree admin dirs
# (their info/ holds only sparse-checkout state -- git resolves exclude and attributes
# to the SHARED info/ -- and doesn't exist until sparse-checkout mkdirs it, which needs
# the whole-dir grant), or 'info-sparse-only' for full git dirs -- the shared dir and
# submodule gitdirs, each its own common dir -- whose info/ also holds more
# information that we want to keep denied (e.g. info/attributes allows hiding files
# from the developer's later `git status`).
allow_checkout_state_writes() {
    arity 2
    local dir="$1" info_scope="$2"
    case "$info_scope" in
        info-dir)         rule 'allow file-write*' subpath "$dir/info" ;;
        info-sparse-only) rule 'allow file-write*' prefix  "$dir/info/sparse-checkout" ;;
        *) echo "BUG: allow_checkout_state_writes: bad info_scope '$info_scope'" >&2; exit 2 ;;
    esac
    rule 'allow file-write*'         subpath "$dir/rebase-merge"
    rule 'allow file-write*'         subpath "$dir/rebase-apply"
    rule 'allow file-write*'         prefix  "$dir/rebased-patches"
    rule 'allow file-write*'         subpath "$dir/sequencer"
    rule 'allow file-write*'         subpath "$dir/subtree-cache"
    rule 'allow file-write*'         prefix  "$dir/index"
    rule 'allow file-write*'         prefix  "$dir/next-index-"
    rule 'allow file-write*'         prefix  "$dir/sharedindex"
    rule 'allow file-write*'         prefix  "$dir/HEAD"
    rule 'allow file-write*'         prefix  "$dir/ORIG_HEAD"
    rule 'allow file-write*'         prefix  "$dir/FETCH_HEAD"
    rule 'allow file-write*'         prefix  "$dir/MERGE_"
    rule 'allow file-write*'         prefix  "$dir/AUTO_MERGE"
    rule 'allow file-write*'         prefix  "$dir/CHECKOUT_AUTOSTASH"
    rule 'allow file-write*'         prefix  "$dir/CHERRY_PICK_HEAD"
    rule 'allow file-write*'         prefix  "$dir/REVERT_HEAD"
    rule 'allow file-write*'         prefix  "$dir/REBASE_HEAD"
    rule 'allow file-write*'         prefix  "$dir/BISECT_"
    rule 'allow file-write*'         prefix  "$dir/COMMIT_EDITMSG"
    rule 'allow file-write*'         prefix  "$dir/SQUASH_MSG"
    rule 'allow file-write*'         prefix  "$dir/TAG_EDITMSG"
    rule 'allow file-write*'         prefix  "$dir/EDIT_DESCRIPTION"
    rule 'allow file-write*'         prefix  "$dir/NOTES_"
    rule 'allow file-write*'         prefix  "$dir/ADD_EDIT"
}

# Harden the git internals reachable from CHOPI_GIT_TARGET_WORKTREE: the
# shared git dir stays readable, but writable ONLY on git's data paths; the
# exec surface (config, hooks, ...) stays read-only.
write_hardening_profile() {
    arity 1
    local profile="$1"

    # shellcheck disable=SC2094  # we embed the profile's own path in a deny rule below
    {
        echo ";; chopi: harden the git internals of the worktree at $CHOPI_GIT_TARGET_WORKTREE"

        # The shared-git-dir lockdown: writable ONLY on git's data paths -- allowing hooks/
        # or config would let the confined command plant code that runs UNSANDBOXED on the
        # developer's next git operation. The blanket deny also covers the worktree admin dirs
        # and submodule gitdirs; holes are poked later.
        rule 'deny file-write*'  subpath "$CHOPI_GIT_COMMON_DIR"
        allow_ref_writes       "$CHOPI_GIT_COMMON_DIR"
        allow_repo_data_writes "$CHOPI_GIT_COMMON_DIR"

        # The target's own checkout state. For the main worktree it lives directly in the
        # shared dir; for a linked worktree, in its admin dir (.git/worktrees/<id>).
        if [ -n "$CHOPI_GIT_TARGET_IS_MAIN" ]; then
            allow_checkout_state_writes "$CHOPI_GIT_COMMON_DIR" info-sparse-only
        else
            allow_ref_writes            "$CHOPI_GIT_DIR"
            allow_checkout_state_writes "$CHOPI_GIT_DIR" info-dir
        fi

        # Each submodule's gitdir is a full gitdir (repo data plus checkout state), so
        # we apply the same holes as we do for a main worktree.
        local sub_gitdir
        for sub_gitdir in "${CHOPI_GIT_TARGET_SUB_GITDIRS[@]+"${CHOPI_GIT_TARGET_SUB_GITDIRS[@]}"}"; do
            allow_ref_writes            "$sub_gitdir"
            allow_repo_data_writes      "$sub_gitdir"
            allow_checkout_state_writes "$sub_gitdir" info-sparse-only
        done

        # Deny write for the worktree's top-level .git, intentionally after allowances
        # just in case something accidentally opens it up in the future.
        #
        # For a linked worktree (and a main worktree that is itself a submodule, or uses
        # a separate git dir) this is a pointer file that git reads to find the governing
        # git dir -- repointing it can exercise arbitrary config + hooks (also by later
        # unsandboxed git). For the standard case of the main worktree of a standard repo,
        # this harmlessly re-denies writing the common git dir (just the dir itself).
        rule 'deny file-write*'                  literal "$CHOPI_GIT_TARGET_WORKTREE/.git"

        # Pin the worktree's own node and every node above it to prevent bypassing denies by
        # renaming a parent dir.
        pin_ancestries / "$CHOPI_GIT_TARGET_WORKTREE"

        # Also pin submodule worktrees the same way.
        pin_ancestries "$CHOPI_GIT_TARGET_WORKTREE" \
            "${CHOPI_GIT_TARGET_SUB_MAIN_WORKTREES[@]+"${CHOPI_GIT_TARGET_SUB_MAIN_WORKTREES[@]}"}"

        # Re-deny known vectors; They're not included in the grants above, but just in case
        # something accidentally opens them up in the future.
        if [ -z "$CHOPI_GIT_TARGET_IS_MAIN" ]; then
            rule 'deny file-write*'          literal "$CHOPI_GIT_DIR/config.worktree"
            rule 'deny file-write*'          literal "$CHOPI_GIT_DIR/commondir"
        fi
        rule 'deny file-write*'  literal "$CHOPI_GIT_COMMON_DIR/config"
        rule 'deny file-write*'  literal "$CHOPI_GIT_COMMON_DIR/config.worktree"
        rule 'deny file-write*'  subpath "$CHOPI_GIT_COMMON_DIR/hooks"
        local i sub_main_worktree
        for ((i = 0; i < ${#CHOPI_GIT_TARGET_SUB_GITDIRS[@]}; i++)); do
            sub_main_worktree="${CHOPI_GIT_TARGET_SUB_MAIN_WORKTREES[i]}"
            sub_gitdir="${CHOPI_GIT_TARGET_SUB_GITDIRS[i]}"
            rule 'deny file-write*'  literal "$sub_main_worktree/.git"
            rule 'deny file-write*'  literal "$sub_gitdir/config"
            rule 'deny file-write*'  subpath "$sub_gitdir/hooks"
        done

        # Deny the command any access to this appended profile itself.
        # Belt-and-suspenders: safehouse compiles the file into the live policy before
        # the command runs, and the file dies with the run, so writes to it don't matter. The
        # read half is the working part, and a minor one: it keeps the command from reading the
        # profile text, whose absolute paths (submodule gitdirs) are mostly discoverable from
        # the readable shared git dir anyway.
        rule 'deny file-read* file-write*'   literal "$profile"
    } > "$profile"
}

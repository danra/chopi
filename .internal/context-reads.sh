# shellcheck shell=bash
#
# context-reads.sh -- Sourced by chopi to build the Seatbelt profile that lets the
# sandboxed agent read context files (e.g. CLAUDE.md) from the workspace's ANCESTOR
# directories.
#
# Chopi appends this profile before the git-protection profiles, so worktree isolation still
# wins inside a repo and only ancestors above it become readable; linked worktrees likely have
# identical copies of any context file in the main worktree, so reading the main worktree's
# is usually just wasteful LLM-context-wise; or worse, if the linked worktree *did* make
# changes, we only want to read its modified copy.

write_context_reads_profile() {
    arity 2
    local profile_path="$1" run_dir="$2"

    # The context files an agent looks for while walking up from the workspace. Extend
    # this list to add more (e.g. AGENTS.md).
    local context_filenames=(CLAUDE.md)

    local real_run_dir
    real_run_dir="$(realpath "$run_dir")" \
        || { echo "error: context-reads: cannot resolve '$run_dir'" >&2; return 1; }

    local dir parent name
    {
        printf ';; chopi: let the sandboxed agent read its context files (%s) in the workspace ancestors\n' \
            "${context_filenames[*]}"
        dir="$real_run_dir"
        while [ "$dir" != "/" ]; do
            dir="$(dirname "$dir")"
            parent="$dir"
            [ "$parent" = "/" ] && parent=""
            for name in "${context_filenames[@]}"; do
                local context_path target
                context_path="$parent/$name"
                rule 'allow file-read*' literal "$context_path"
                # Allow reading through symlinks for context files
                if [ -L "$context_path" ]; then
                    target="$(realpath "$context_path")"
                    [ -n "$target" ] && rule 'allow file-read*' literal "$target"
                fi
            done
        done
    } > "$profile_path"
}

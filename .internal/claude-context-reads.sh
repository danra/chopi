# shellcheck shell=bash
#
# claude-context-reads.sh -- Sourced by chopi to build the Seatbelt profile that lets the
# sandboxed agent read Claude context files (currently CLAUDE.md, optionally under .claude/)
# from the workspace's ANCESTOR directories.
#
# The profile deliberately grants neither the files' @-imports nor the targets of symlinked
# context files (or symlinked .claude dirs) -- only the literal ancestor paths, plus
# file-read-metadata on the in-path intermediate nodes (so a symlinked .claude is still
# resolvable), without exposing target data. Especially for an in-repo, writable CLAUDE.md,
# it is too insecure to allow an arbitrary symlink or a CLAUDE.md import to open up read
# permissions out of the workspace; It's better to let the user explicitly grant missing
# read permissions.
#
# Chopi appends this profile before the git-protection profiles, so worktree isolation still
# wins inside a repo and only ancestors above it become readable; linked worktrees likely have
# identical copies of any context file in the main worktree, so reading the main worktree's
# is usually just wasteful LLM-context-wise; or worse, if the linked worktree *did* make
# changes, we only want to read its modified copy.

_context_reads_dir="$(dirname "${BASH_SOURCE[0]}")"
. "$_context_reads_dir/claude-common.sh"
unset _context_reads_dir

# Grant reading relative path rpath ($2) of context under ancestor dir PARENT ($1, "" for
# the root), when something is actually there: full read on the literal path, and metadata
# on every rpath component so any symlinked component (e.g. a shared .claude dir) can be
# resolved (all PARENT path components are assumed already metadata-readable).
#
# Symlinks are NOT followed: their target stays unreadable until the user grants it.
# Dangling ones are intentionally not granted (no additional `[-L $path]`); there's no
# point.
grant_context_file_path() {
    arity 2
    local parent="$1" rpath="$2"
    local path="$parent/$rpath"
    [ -e "$path" ] || return 0
    local rest="$rpath" node="$parent"
    while [ "${rest#*/}" != "$rest" ]; do
        node="$node/${rest%%/*}"
        rest="${rest#*/}"
        rule 'allow file-read-metadata' literal "$node"
    done
    rule 'allow file-read*' literal "$path"
}

write_claude_context_reads_profile() {
    arity 2
    local profile_path="$1" run_dir="$2"

    local real_run_dir
    real_run_dir="$(realpath "$run_dir")" \
        || { echo "error: claude-context-reads: cannot resolve '$run_dir'" >&2; return 1; }

    {
        printf ';; chopi: let the sandboxed agent read its Claude context files (%s) in the workspace ancestors\n' \
            "${CLAUDE_CONTEXT_FILENAMES[*]}"
        for_each_ancestor_context_file "$real_run_dir" grant_context_file_path
    } > "$profile_path"
}

# shellcheck shell=bash
# shellcheck disable=SC2034 # Defines variables that are used by the scripts that source this file
#
# claude-common.sh -- common functionality shared by chopi's Claude context handling
#
# Sourced (never run directly).

# The context files Claude Code looks for while walking up from the workspace. Extend
# this list to add more.
CLAUDE_CONTEXT_FILENAMES=(CLAUDE.md .claude/CLAUDE.md)

# Invoke callback $2 as `callback PARENT NAME` for every context-file candidate in the
# ancestor dirs of dir $1 (PARENT is "" for the filesystem root, so "$PARENT/$NAME" always
# composes). The single walk shape shared by the granting profile and the in-sandbox check,
# which must visit the same candidates: the check classifies a denial assuming the profile
# granted the candidate's literal path.
for_each_ancestor_context_file() {
    arity 2
    local dir="$1" callback="$2"
    case "$dir" in
        /*) ;;
        *)  printf 'BUG: for_each_ancestor_context_file called with a non-absolute dir\n' >&2
            exit 2 ;;
    esac
    local parent name
    while [ "$dir" != "/" ]; do
        dir="$(dirname "$dir")"
        parent="$dir"
        [ "$parent" = "/" ] && parent=""
        for name in "${CLAUDE_CONTEXT_FILENAMES[@]}"; do
            "$callback" "$parent" "$name"
        done
    done
}

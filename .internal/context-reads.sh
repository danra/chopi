# shellcheck shell=bash
#
# context-reads.sh -- Sourced by chopi to build the Seatbelt profile that lets the
# sandboxed agent read context files (e.g. CLAUDE.md) from the workspace's ANCESTOR
# directories, plus everything the context files @-import, wherever that resolves.
#
# Chopi appends this profile before the git-protection profiles, so worktree isolation still
# wins inside a repo and only ancestors above it become readable; linked worktrees likely have
# identical copies of any context file in the main worktree, so reading the main worktree's
# is usually just wasteful LLM-context-wise; or worse, if the linked worktree *did* make
# changes, we only want to read its modified copy.

# Print each @-import declared in context file $1, one per line. An import is a
# whitespace-delimited token beginning with '@' (so an email like a@b.c never matches), skipping
# tokens inside fenced code blocks -- matching how the agent itself reads them. Paths resolve
# against the importing file's own directory and '~' expands to $HOME, but they are NOT
# canonicalized or filtered for existence -- that is the granting layer's concern.
context_file_imports() {
    arity 1
    local file="$1" dir tokens token
    dir="$(dirname "$file")"
    tokens="$(awk '
        /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
        fence                    { next }
        {
            for (i = 1; i <= NF; i++)
                if (substr($i, 1, 1) == "@" && length($i) > 1)
                    print substr($i, 2)
        }
    ' "$file")"
    while IFS= read -r token; do
        [ -z "$token" ] && continue
        # shellcheck disable=SC2088  # the '~' here is literal pattern text, not a tilde expansion
        case "$token" in
            '~/'*) printf '%s/%s\n' "$HOME" "${token:2}" ;;
            /*)    printf '%s\n' "$token" ;;
            *)     printf '%s/%s\n' "$dir" "$token" ;;
        esac
    done <<< "$tokens"
}

# Record $1 in the profile-wide _seen set and succeed; fail when it was already recorded.
first_visit() {
    arity 1
    case "$_seen" in *"$NL$1$NL"*) return 1 ;; esac
    _seen="$_seen$1$NL"
}

# Recursively grant read on every @-import reachable from context file $1 (a path the caller
# has already granted and recorded), resolving each import against $1's own directory.
#
# When a context file is a symlink, "its own directory" is ambiguous, and the agent's answer
# depends on per-project state (verified against Claude Code 2.1.218): imports that resolve
# outside the workspace are "external includes", gated behind a one-time approval dialog. With
# no decision recorded, the agent reads the file through the link and resolves its imports
# beside the LINK; once approved, it loads the canonical file and resolves them beside the
# TARGET; declined disables them entirely. The profile cannot know that per-project state, so
# the caller walks both sides.
#
# Nested hops are not ambiguous: the agent canonicalizes every import before recursing into
# it, so an imported file's own imports always resolve beside its REAL location, and the
# recursion below follows suit.
#
# Example: pkg/CLAUDE.md -> shared/CLAUDE.md whose content imports '@a.md'. Depending on the
# approval state the agent reads pkg/a.md or shared/a.md, so both sides are granted. If
# pkg/a.md is itself a symlink to lib/a.md whose content imports '@b.md', that nested hop
# resolves only to lib/b.md -- never pkg/b.md.
#
# Imports are canonicalized here, right before granting: Seatbelt matches kernel-resolved
# paths, and _seen's dedup (which also terminates import cycles) is only sound on canonical
# paths. Ones that don't resolve to a file are dropped.
grant_context_imports() {
    arity 1
    local file="$1" imports import real
    imports="$(context_file_imports "$file")"
    while IFS= read -r import; do
        [ -z "$import" ] && continue
        real="$(realpath "$import" 2>/dev/null)" || continue
        [ -f "$real" ] || continue
        first_visit "$real" || continue
        rule 'allow file-read*' literal "$real"
        grant_context_imports "$real"
    done <<< "$imports"
}

# Grant the reads context file $1 needs beyond its own literal path: the kernel-resolved target
# when the literal resolves elsewhere (a symlink, which the caller's literal rule doesn't cover),
# and its @-imports. The literal path itself is the caller's concern: ancestors get an explicit
# rule, while the workspace's own context file is already covered by the workspace grant.
grant_context_target_and_imports() {
    arity 1
    local context_path="$1" real_context
    real_context="$(realpath "$context_path" 2>/dev/null)" || return 0
    [ -f "$real_context" ] || return 0
    first_visit "$real_context" || return 0
    # Which side of a symlink the agent resolves the file's own imports against depends on
    # the external-includes approval state (see grant_context_imports), so walk both.
    grant_context_imports "$context_path"
    if [ "$real_context" != "$context_path" ]; then
        rule 'allow file-read*' literal "$real_context"
        grant_context_imports "$real_context"
    fi
}

write_context_reads_profile() {
    arity 2
    local profile_path="$1" run_dir="$2"

    # The context files an agent looks for while walking up from the workspace. Extend
    # this list to add more (e.g. AGENTS.md).
    local context_filenames=(CLAUDE.md)

    local real_run_dir
    real_run_dir="$(realpath "$run_dir")" \
        || { echo "error: context-reads: cannot resolve '$run_dir'" >&2; return 1; }

    # Newline-delimited set (mutated via first_visit) of the real paths already granted, so a
    # file reachable several ways -- from several ancestors, or via an import cycle -- is
    # granted (and walked for its own imports) only once.
    local NL=$'\n' _seen=$'\n'

    local dir parent name
    {
        printf ';; chopi: let the sandboxed agent read its context files (%s) in the workspace ancestors, and their @-imports\n' \
            "${context_filenames[*]}"
        for name in "${context_filenames[@]}"; do
            grant_context_target_and_imports "$real_run_dir/$name"
        done
        dir="$real_run_dir"
        while [ "$dir" != "/" ]; do
            dir="$(dirname "$dir")"
            parent="$dir"
            [ "$parent" = "/" ] && parent=""
            for name in "${context_filenames[@]}"; do
                rule 'allow file-read*' literal "$parent/$name"
                grant_context_target_and_imports "$parent/$name"
            done
        done
    } > "$profile_path"
}

# shellcheck shell=bash
#
# claude-context-check.sh -- the Claude-context follow-and-refuse check, sourced by the
# in-sandbox wrapper.
#
# The sandbox profile grants the Claude context files' literal paths but deliberately NOT
# their symlink targets or @-imports (see claude-context-reads.sh); the wrapper probes them
# here, in-sandbox -- where every readability verdict is exactly the launched command's --
# and refuses to launch while any is denied, listing them so the user adds the read grants
# himself (CHOPI_SAFEHOUSE_FLAGS).
#
# The hard refusal is not for extra protection, but for better UX given the protections:
# Avoid letting the user run chopi unaware of any context that is expected to be readable,
# but isn't.

_context_check_dir="$(dirname "${BASH_SOURCE[0]}")"
. "$_context_check_dir/claude-common.sh"
unset _context_check_dir

# Record path $1 in the walk-wide _seen set and succeed; fail when it was already recorded.
try_record_first_visit() {
    arity 1
    local path="$1"
    case "$_seen" in *"$NL$path$NL"*) return 1 ;; esac
    _seen="$_seen$path$NL"
}

# Print each @-import declared in file $1, one per line.
# Paths resolve against the importing file's own directory and '~' expands to $HOME, but they
# are NOT canonicalized to resolve symbolic links or filtered for existence -- that is the
# caller's concern.
claude_md_imports() {
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

PROBE_READ_OK=0      # a readable regular file
PROBE_READ_SKIP=1    # unreadable for a mundane reason (nonexistent, a directory, ...)
PROBE_READ_DENIED=2  # seatbelt denial
probe_read() {
    arity 1
    local path="$1" err
    if err="$( { : < "$path"; } 2>&1 )"; then
        [ -f "$path" ] && return "$PROBE_READ_OK"
        return "$PROBE_READ_SKIP" # directory, device, etc.
    fi
    case "$err" in
        *'Operation not permitted'*) return "$PROBE_READ_DENIED" ;; # seatbelt denial
    esac
    return "$PROBE_READ_SKIP" # any other error
}

# Follow every @-import declared in readable file $1, printing a message line for each one
# the sandbox denies reading.
check_claude_md_imports() {
    arity 1
    local file="$1" imports import real verdict
    imports="$(claude_md_imports "$file")"
    while IFS= read -r import; do
        [ -z "$import" ] && continue
        verdict="$PROBE_READ_OK"; probe_read "$import" || verdict=$?
        case "$verdict" in
            "$PROBE_READ_OK")
                real="$(realpath_or_self "$import")"
                # For our purpose here, as long the file contents are readable, it's OK if
                # the real path can't be resolved (e.g. due to a denied symbolic link
                # component in the full path).
                try_record_first_visit "$real" || continue
                check_claude_md_imports "$real"
                ;;
            "$PROBE_READ_DENIED")
                try_record_first_visit "$import" || continue
                printf '%s  (imported by %s)\n' "$import" "$file"
                ;;
        esac
    done <<< "$imports"
    return 0
}

# Print the first visible symlink node of path $1 and its single-hop target (joined onto
# the node's directory when relative) on two lines, failing when no link node is visible.
# readlink doubles as the link probe, so a link is never found without its target in hand
# (the node's lstat and readlink fall under the same metadata grant).
# Helper for check_claude_context_file below, see the rationale there.
first_visible_link() {
    arity 1
    local abspath=$1
    local rest="${abspath#/}" node="" target
    while [ -n "$rest" ]; do
        node="$node/${rest%%/*}"
        case "$rest" in
            */*) rest="${rest#*/}" ;;
            *)   rest="" ;;
        esac
        if target="$(readlink "$node" 2>/dev/null)"; then
            case "$target" in
                /*) ;;
                *)  target="${node%/*}/$target" ;;
            esac
            printf '%s\n%s\n' "$node" "$target"
            return 0
        fi
    done
    return 1
}

# Print the message line for denied context path $1, whose first symlink node $2 has
# target $3: lead with the actual unreadable path -- the one the user must grant -- and
# name the link it came from. Resolving PAST the first substitution needs metadata the
# sandbox denies, so any further links in the printed path stay as written.
denied_symlink_line() {
    arity 3
    local context_path="$1" link="$2" target="$3" rest
    rest="${context_path#"$link"}"
    if [ -z "$rest" ]; then
        printf '%s  (symlink target of %s)\n' "$target" "$context_path"
    else
        printf '%s%s  (via the symlink at %s)\n' "$target" "$rest" "$link"
    fi
}

# Follow the @-imports of the context file at relative path rpath ($2) under dir PARENT
# ($1, "" for the root) when it is readable.
#
# When reading it is denied through a symlink, it is listed for refusal at its link-side
# path: resolving the link and granting its target's read is the user's to do. A denial
# with no link involved is chopi's own design at work (worktree isolation denies context
# files inside the enclosing repo, e.g. the repo root's CLAUDE.md from a linked worktree),
# and Claude simply runs without the file.
check_claude_context_file() {
    arity 2
    local parent="$1" rpath="$2"
    local context_path="$parent/$rpath"
    local real pair link target verdict="$PROBE_READ_OK"
    probe_read "$context_path" || verdict=$?
    case "$verdict" in
        "$PROBE_READ_SKIP")
            return 0 ;;
        "$PROBE_READ_DENIED")
            # A visible link node separates the denial's two possible causes: context files'
            # literal paths are granted readable, so either 1) a symlink was resolved into
            # an ungranted target, in which case we should refuse to run and tell the user
            # why; or 2) chopi's isolation denied the file intentionally, metadata included
            # (e.g. to prevent a --worktree run from observing the root repo's CLAUDE.md), in
            # which case no link node is visible, and we just proceed without that file
            # since that's what we *wanted* to do.
            pair="$(first_visible_link "$context_path")" || return 0
            link="${pair%%$'\n'*}"
            target="${pair#*$'\n'}"
            if try_record_first_visit "$context_path"; then
                denied_symlink_line "$context_path" "$link" "$target"
            fi
            return 0 ;;
    esac
    # When an imported relative path is a symlink, whether Claude resolves it relative to the link
    # or the target depends on the project (verified against Claude Code 2.1.218): imports that resolve
    # outside the workspace are "external includes", gated behind a one-time approval dialog. With no
    # decision recorded, the agent reads the file through the link and resolves its imports beside the
    # LINK; once approved, it loads the canonical file and resolves them beside the TARGET. The check
    # cannot know that per-project state, so it walks both sides (which could, conceivably, cause some
    # false-positive refusals; NBD).
    # Each side is recorded under the path it is walked at, since relative imports resolve
    # beside their importer: two links to one target share the target-side walk, but each
    # still needs its own.
    real="$(realpath_or_self "$context_path")"
    if try_record_first_visit "$context_path"; then
        check_claude_md_imports "$context_path"
    fi
    if [ "$real" != "$context_path" ] && try_record_first_visit "$real"; then
        check_claude_md_imports "$real"
    fi
}

# Print a message line for every path the sandbox denies reading across run_dir $1's
# Claude context files: their symlink targets and CLAUDE.md @-imports.
unreadable_claude_context_paths() {
    arity 1
    local run_dir="$1"

    # Newline-delimited set (mutated via try_record_first_visit) of the paths already handled,
    # so one reachable several ways is walked recursively (if allowed) or listed (if denied)
    # only once.
    local NL=$'\n' _seen=$'\n'

    local name
    for name in "${CLAUDE_CONTEXT_FILENAMES[@]}"; do
        check_claude_context_file "$run_dir" "$name"
    done
    for_each_ancestor_context_file "$run_dir" check_claude_context_file
    return 0
}

# Refuse when the sandbox denies reading any symlink target or @-import of run_dir $1's Claude
# context files, listing them so they are not quietly ignored on one hand, and so the user is
# aware of the read holes he would be adding on the other hand.
refuse_unreadable_claude_context() {
    arity 1
    local run_dir="$1" denied
    denied="$(unreadable_claude_context_paths "$run_dir")"
    [ -z "$denied" ] && return 0
    local line
    {
        echo "chopi: error: the sandbox cannot read these Claude context files:"
        while IFS= read -r line; do
            printf '   - %s\n' "$line"
        done <<< "$denied"
        echo
        echo "Add read grants for them to CHOPI_SAFEHOUSE_FLAGS in chopi's config (default at config/sandbox.sh), e.g.:"
        echo "   --add-dirs-ro '/dir/to/allow'"
        case "$denied" in
            *'(imported by '*)
                echo "Note: a grant cannot cover an @-import inside a repo chopi isolates"
                echo "(e.g. the enclosing repo during a --worktree run); such imports only"
                echo "work from outside the isolation zone."
                ;;
        esac
    } >&2
    return 1
}

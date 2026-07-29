# shellcheck shell=bash
# shellcheck disable=SC2034 # Defines layout variables that are used by the generators that source this file
#
# git-layout.sh -- helpers for resolving a git repo's layout and refusing unsupported ones
#
# Sourced (never run directly).

_layout_dir="$(dirname "${BASH_SOURCE[0]}")"
. "$_layout_dir/util.sh"
unset _layout_dir

# Environment vars that override git's lookups. Chopi refuses with these set rather than
# accommodating them to avoid additional complexity for now. Some can potentially break
# chopi's guarantees; for others, it's just better UX to refuse up-front rather than defer
# errors to runtime. Some of these have config/file-based equivalent redirections which are
# also refused.
CHOPI_GIT_LOCATION_ENV_VARS=(
    GIT_ALTERNATE_OBJECT_DIRECTORIES
    GIT_COMMON_DIR
    GIT_DIR
    GIT_INDEX_FILE
    GIT_OBJECT_DIRECTORY
    GIT_REFERENCE_BACKEND
    GIT_WORK_TREE
)

refuse_git_location_env() {
    local var offending=()
    for var in "${CHOPI_GIT_LOCATION_ENV_VARS[@]}"; do
        if [ -n "${!var+set}" ]; then offending+=("$var"); fi
    done
    if [ "${#offending[@]}" -eq 0 ]; then return 0; fi
    {
        echo "error: refusing to run with git overrides set in environment vars:"
        printf '           %s\n' "${offending[@]}"
        echo "These are currently unsupported."
    } >&2
    return 1
}

# Refuse a (non-empty) file-equivalent of GIT_ALTERNATE_OBJECT_DIRECTORIES.
# $1 is the git dir whose object store to check (the shared git dir, or a submodule
# gitdir).
refuse_object_alternates() {
    arity 1
    local gitdir="$1"
    local alt_file="$gitdir/objects/info/alternates"
    [ -s "$alt_file" ] || return 0
    {
        echo "error: refusing to run: this repo reads objects through an alternates file, which is not supported:"
        echo "           $alt_file"
    } >&2
    return 1
}

# Refuse the config-equivalent of GIT_REFERENCE_BACKEND
refuse_relocated_ref_storage() {
    arity 1
    local gitdir="$1"
    local ref_storage
    ref_storage="$(git config --file "$gitdir/config" --get extensions.refstorage 2>/dev/null)" || ref_storage=""
    case "$ref_storage" in *://*) ;; *) return 0 ;; esac
    {
        echo "error: refusing to run: this repo relocates its ref storage, which is not supported:"
        echo "           extensions.refStorage = $ref_storage"
        echo "           (set in $gitdir/config)"
    } >&2
    return 1
}

# Refuse a submodule whose gitdir $2 is embedded inside its worktree $1 instead of absorbed
# under the superproject's git dir, as git has kept it since 1.7.8. The hardening profile's
# blanket write-deny covers absorbed gitdirs; an embedded one sits in the writable
# workspace, its config and hooks open to the sandboxed command.
refuse_embedded_submodule_gitdir() {
    arity 2
    local worktree="$1" gitdir="$2"
    is_path_within "$gitdir" "$worktree" || return 0
    {
        echo "error: refusing to run: the submodule at '$worktree' embeds its git dir inside its worktree:"
        echo "           $gitdir"
        echo "chopi's git hardening covers submodule git dirs absorbed under the superproject's .git;"
        echo "an embedded one would stay writable (config, hooks). Absorb it with:"
        echo "           git submodule absorbgitdirs"
    } >&2
    return 1
}

# Report the exec-capable git sequencing operation in progress in worktree $1, if any:
# prints 'rebase' or 'sequencer' (a cherry-pick/revert sequence), else nothing.
#
# The apply/`git am` backend and a single (non-sequence) cherry-pick/revert have no `exec`
# support, so they are deliberately not reported.
inflight_exec_sequencing() {
    arity 1
    local worktree="$1"
    (
        cd "$worktree" || exit 0
        local marker
        if marker="$(git rev-parse --git-path rebase-merge 2>/dev/null)" && [ -d "$marker" ]; then
            printf 'rebase'; exit 0
        fi
        if marker="$(git rev-parse --git-path sequencer 2>/dev/null)" && [ -d "$marker" ]; then
            printf 'sequencer'; exit 0
        fi
    )
}

# Map an operation token from inflight_exec_sequencing ('rebase'|'sequencer') to the human
# phrase used in the refuse/abort messages, so the two callers state it identically.
sequencing_phrase() {
    arity 1
    case "$1" in
        rebase) printf 'rebase' ;;
        *)      printf 'cherry-pick/revert sequence' ;;
    esac
}

# Refuse to start when worktree $1 already has an exec-capable sequencing op in progress.
# Chopi aborts such an op when it exits, so refusing up front guarantees it never aborts
# one the developer began outside chopi.
refuse_inflight_sequencing() {
    arity 1
    local worktree="$1" op
    op="$(inflight_exec_sequencing "$worktree")"
    [ -n "$op" ] || return 0
    local phrase
    phrase="$(sequencing_phrase "$op")"
    {
        echo "error: refusing to run: a git $phrase is already in progress in:"
        echo "           $worktree"
        echo "chopi aborts an in-progress rebase or cherry-pick/revert sequence when it exits, because a"
        echo "sandboxed command can plant 'exec' lines in it that would then run unsandboxed if the sequence"
        echo "is --continued. Finish or abort it before running chopi."
    } >&2
    return 1
}

# Print the physical root of the git worktree enclosing dir $1, or fail if
# the dir is not inside a git worktree.
scrubbed_toplevel() {
    arity 1

    # Unset env location-overrides to avoid being misled.
    local var scrubbed_env
    scrubbed_env=(env)
    for var in "${CHOPI_GIT_LOCATION_ENV_VARS[@]}"; do scrubbed_env+=(-u "$var"); done

    local dir="$1" toplevel
    toplevel="$("${scrubbed_env[@]}" git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || return 1
    [ -n "$toplevel" ] || return 1
    realpath "$toplevel"
}

# Refuse unless $1 (a physical path, as from `pwd -P`) is the root of a git worktree.
# The refusal covers two separate cases:
# - Unsupported git setup
# - Just not a git worktree (no .git)
require_worktree_root() {
    arity 1
    local dir="$1" toplevel
    toplevel="$(scrubbed_toplevel "$dir")" || toplevel=""
    if [ "$toplevel" = "$dir" ]; then return 0; fi
    {
        if [ -e "$dir/.git" ] || [ -L "$dir/.git" ]; then   # -L: a dangling .git symlink is still an entry
            echo "error: refusing to run: found .git, but worktree root not at '$dir'"
            echo "The directory has a .git entry, but git doesn't resolve it as the root of its worktree"
            echo "(with sanitized env). This could be due to a custom-configured repo or worktree, and"
            echo "isn't supported."
        else
            echo "error: refusing to run: '$dir' is not the root of a git worktree"
            echo "chopi runs only at a worktree root, where its git protections apply."
            if [ -n "$toplevel" ]; then
                echo "This directory is inside the worktree rooted at:"
                echo "           $toplevel"
            else
                echo "Run it from the root of the repo (or worktree) you're working on."
            fi
        fi
    } >&2
    return 1
}

# ---------------------------------------------------------------------------
# Layout, resolved by collect_layout into the script-level variables below.
#
#   CHOPI_GIT_DIR                    the target worktree's governing git dir: the admin
#                                    dir .git/worktrees/<id> for a linked worktree,
#                                    CHOPI_GIT_COMMON_DIR itself for the main worktree
#   CHOPI_GIT_COMMON_DIR             the shared git dir (usually <repo>/.git)
#   CHOPI_GIT_MAIN_WORKTREE          the main worktree (usually <repo>); unset when it
#                                    can't be resolved (see resolve_main_worktree)
#   CHOPI_GIT_TARGET_WORKTREE        the worktree the command runs in == the current dir
#   CHOPI_GIT_TARGET_IS_MAIN         non-empty iff the target worktree is the main worktree
#   CHOPI_GIT_OTHER_WORKTREES[]      every worktree except the target
#   CHOPI_GIT_TARGET_SUB_MAIN_WORKTREES[] / CHOPI_GIT_TARGET_SUB_GITDIRS[]
#                                    the target worktree's submodules (recursive):
#                                    each one's main worktree and gitdir
# ---------------------------------------------------------------------------

CHOPI_GIT_DIR=""
CHOPI_GIT_COMMON_DIR=""
CHOPI_GIT_MAIN_WORKTREE=""
CHOPI_GIT_TARGET_WORKTREE=""
CHOPI_GIT_TARGET_IS_MAIN=""
CHOPI_GIT_OTHER_WORKTREES=()
CHOPI_GIT_TARGET_SUB_MAIN_WORKTREES=()
CHOPI_GIT_TARGET_SUB_GITDIRS=()

# Resolve the main worktree path
# 99.9% of the cases it is just $1, the first record returned by `git worktree list`
# Also correctly handles the 0.1% edge-cases:
#   - In a submodule (or a linked worktree thereof...), $1 is the submodule's gitdir when it should
#     just be the worktree's dir; The gitdir does have core.worktree correctly pointing to the main
#     worktree of the submodule, but `worktree list` doesn't resolve it (git 2.55).
#   - In a repo initialized with `--separate-git-dir`, $1 is the separate gitdir, and it has
#     no core.worktree back-pointer; only the worktree's .git points to the gitdir (git 2.55).
# There are also edge-cases in which we genuinely can't resolve the main worktree, so we print
# nothing and let downstream deal with that case:
#   - a bare repo: there is just no main worktree
#   - a linked worktree of a separate-git-dir repo: nothing in the gitdir points to the main
#     worktree (git 2.55).
resolve_main_worktree() {
    arity 2
    local first_listed_worktree="$1" common_dir="$2"

    if [ "$first_listed_worktree" != "$common_dir" ]; then
        # normal case
        printf '%s' "$first_listed_worktree"
        return 0
    fi

    local configured
    configured="$(git config --file "$common_dir/config" --get core.worktree 2>/dev/null)" || configured=""
    if [ -n "$configured" ]; then
        # submodule case
        case "$configured" in
            /*) ;;
            *)  configured="$common_dir/$configured" ;;
        esac
        realpath "$configured"
        return
    fi

    # No errors expected: if we got here, it means we'd already verified we're at the root of a git worktree
    local own_gitdir toplevel
    own_gitdir="$(git rev-parse --absolute-git-dir 2>/dev/null)"
    toplevel="$(git rev-parse --show-toplevel 2>/dev/null)"

    own_gitdir="$(realpath "$own_gitdir")" || return 1
    if [ "$own_gitdir" = "$common_dir" ]; then
        # separate-git-dir case
        realpath "$toplevel"
        return
    fi

    # No main worktree or can't resolve
}

# Fill the layout globals above.
# Run only after refuse_git_location_env has confirmed no location overrides are set
# (chopi runs git-preflight.sh first).
collect_layout() {
    CHOPI_GIT_COMMON_DIR="$(git rev-parse --git-common-dir)" || return 1
    CHOPI_GIT_COMMON_DIR="$(realpath "$CHOPI_GIT_COMMON_DIR")" || return 1

    # Enumerate the repo's worktrees.
    local wt_list
    wt_list="$(mktemp "$TMPDIR/chopi-gitlayout-wtlist.XXXXXX")" || return 1
    if ! git worktree list --porcelain -z >"$wt_list" 2>/dev/null; then
        echo "error: 'git worktree list --porcelain -z' failed; cannot reliably enumerate worktrees" >&2
        return 1
    fi
    local all_worktrees=() line wt_path
    while IFS= read -r -d '' line || [ -n "$line" ]; do
        case "$line" in "worktree "*) ;; *) continue ;; esac
        wt_path="${line#worktree }"
        wt_path="$(realpath_or_self "$wt_path")"
        all_worktrees+=("$wt_path")
    done < "$wt_list"
    if [ "${#all_worktrees[@]}" -eq 0 ]; then
        echo "error: 'git worktree list --porcelain' returned no entries?! Even a bare repo returns one" >&2
        return 1
    fi

    # Try resolving the main worktree. It's almost always the first worktree that
    # `git worktree list` prints; in rare cases it's different or can't be resolved.
    local resolved_main
    resolved_main="$(resolve_main_worktree "${all_worktrees[0]}" "$CHOPI_GIT_COMMON_DIR")" || return 1
    if [ -n "$resolved_main" ]; then
        CHOPI_GIT_MAIN_WORKTREE="$resolved_main"
        all_worktrees[0]="$CHOPI_GIT_MAIN_WORKTREE"
    else
        unset CHOPI_GIT_MAIN_WORKTREE
        unset 'all_worktrees[0]'
    fi

    CHOPI_GIT_TARGET_WORKTREE="$(pwd -P)"

    CHOPI_GIT_TARGET_IS_MAIN=""
    [ "$CHOPI_GIT_TARGET_WORKTREE" = "${CHOPI_GIT_MAIN_WORKTREE:-}" ] && CHOPI_GIT_TARGET_IS_MAIN=1

    local wt
    for wt in "${all_worktrees[@]+"${all_worktrees[@]}"}"; do
        [ "$wt" = "$CHOPI_GIT_TARGET_WORKTREE" ] && continue
        CHOPI_GIT_OTHER_WORKTREES+=("$wt")
    done

    CHOPI_GIT_DIR="$(resolve_worktree_gitdir "$CHOPI_GIT_TARGET_WORKTREE")" || return 1
    collect_submodules "$CHOPI_GIT_TARGET_WORKTREE" || return 1
}

# Print one aligned "name = value" line per value in $2.., or a "(none)" placeholder
# when no values follow.
print_layout_var() {
    local name="$1"; shift
    if [ "$#" -eq 0 ]; then set -- "(none)"; fi
    local val
    for val in "$@"; do
        printf '           %-35s = %s\n' "$name" "$val"
    done
}

print_git_layout() {
    {
        echo "chopi: git layout:"
        print_layout_var CHOPI_GIT_DIR              "$CHOPI_GIT_DIR"
        print_layout_var CHOPI_GIT_COMMON_DIR       "$CHOPI_GIT_COMMON_DIR"
        print_layout_var CHOPI_GIT_MAIN_WORKTREE    "${CHOPI_GIT_MAIN_WORKTREE:-(unresolved)}"
        print_layout_var CHOPI_GIT_TARGET_WORKTREE  "$CHOPI_GIT_TARGET_WORKTREE"
        print_layout_var CHOPI_GIT_OTHER_WORKTREES  "${CHOPI_GIT_OTHER_WORKTREES[@]+"${CHOPI_GIT_OTHER_WORKTREES[@]}"}"
        print_layout_var CHOPI_GIT_TARGET_SUB_MAIN_WORKTREES "${CHOPI_GIT_TARGET_SUB_MAIN_WORKTREES[@]+"${CHOPI_GIT_TARGET_SUB_MAIN_WORKTREES[@]}"}"
        print_layout_var CHOPI_GIT_TARGET_SUB_GITDIRS        "${CHOPI_GIT_TARGET_SUB_GITDIRS[@]+"${CHOPI_GIT_TARGET_SUB_GITDIRS[@]}"}"
    } >&2
}

# Resolve the gitdir for worktree and ensure it's in its expected location
resolve_worktree_gitdir() {
    arity 1
    local worktree_root="$1"

    local gitdir
    gitdir="$(git -C "$worktree_root" rev-parse --absolute-git-dir)" || return 1
    gitdir="$(realpath "$gitdir")" || return 1
    if [ "$worktree_root" = "${CHOPI_GIT_MAIN_WORKTREE:-}" ]; then
        if [ "$gitdir" != "$CHOPI_GIT_COMMON_DIR" ]; then
            echo "error: the main worktree's git dir '$gitdir' is not the shared git dir '$CHOPI_GIT_COMMON_DIR'; refusing" >&2
            return 1
        fi
    elif ! is_path_within "$gitdir" "$CHOPI_GIT_COMMON_DIR/worktrees"; then
        {
            echo "error: '$worktree_root' is not the main worktree ('${CHOPI_GIT_MAIN_WORKTREE:-unresolved}'), so its git dir"
            echo "must be a linked worktree's admin dir under '$CHOPI_GIT_COMMON_DIR/worktrees',"
            echo "but it is '$gitdir'; refusing (a protection profile built from it could grant"
            echo "write access outside the worktree)"
        } >&2
        return 1
    fi
    printf '%s' "$gitdir"
}

# Collect info on submodules in the target worktree
# Done unsandboxed: the sandboxed command can't add a submodule later, so this snapshot is complete.
collect_submodules() {
    arity 1
    local worktree_root="$1"

    CHOPI_GIT_TARGET_SUB_MAIN_WORKTREES=()
    CHOPI_GIT_TARGET_SUB_GITDIRS=()

    local submodules
    submodules="$(mktemp "$TMPDIR/chopi-gitlayout-sub.XXXXXX")" || return 1
    # shellcheck disable=SC2016
    if ! git -C "$worktree_root" submodule foreach --recursive --quiet \
            'printf "%s\0" "$PWD"' >"$submodules" 2>/dev/null; then
        echo "error: could not enumerate the submodules of '$worktree_root'" >&2
        return 1
    fi

    local sub_raw sub_main_worktree sub_gitdir error_sub=""
    while IFS= read -r -d '' sub_raw || [ -n "$sub_raw" ]; do
        if ! sub_main_worktree="$(realpath "$sub_raw")" \
            || ! sub_gitdir="$(git -C "$sub_main_worktree" rev-parse --absolute-git-dir)" \
            || ! sub_gitdir="$(realpath "$sub_gitdir")"; then
            error_sub="$sub_raw"
            break
        fi
        CHOPI_GIT_TARGET_SUB_MAIN_WORKTREES+=("$sub_main_worktree")
        CHOPI_GIT_TARGET_SUB_GITDIRS+=("$sub_gitdir")
    done < "$submodules"
    if [ -n "$error_sub" ]; then
        echo "error: could not resolve submodule '$error_sub' or its gitdir" >&2
        return 1
    fi
}

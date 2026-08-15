# shellcheck shell=bash
#
# write-targets.sh -- enable queuing reviewable changes for configured safe out-of-sandbox targets
#
# The sandboxed command can write patches into per-target slots in the workspace's queue, and
# chopi-review lets the user review and apply them on the host.
#
# Chopi's config is the single source of trust for which slots are real, so it can't be injected
# with patches for non-configured targets.
#
# Sourced (never run directly) by chopi, which creates and grants the workspace queue, and by
# chopi-review, which walks it.

_script_dir="$(dirname "${BASH_SOURCE[0]}")"
. "$_script_dir/util.sh"
unset _script_dir

CHOPI_PATCH_QUEUE_ROOT="$HOME/.chopi/patch-queue"

# Print the canonical path of configured target $1, resolving a relative one against workspace $2.
target_real_path() {
    arity 2
    local target_path="$1" workspace="$2"
    case "$target_path" in
        /*) ;;
        *)  target_path="$workspace/$target_path" ;;
    esac
    realpath_or_self "$target_path"
}

# Print the queue or slot name for canonical path $1: 16 hex digits of its digest.
#
# A queue and a slot are both named this way -- a queue per workspace, a slot per target
# inside it. Each records its own path, in WORKSPACE or TARGET, so it can be checked back
# against the expected name.
path_id() {
    arity 1
    local digest
    digest="$(printf '%s' "$1" | shasum)" \
        || { echo "chopi: cannot digest the path '$1'" >&2; return 1; }
    printf '%s' "${digest:0:16}"
}

# Print the slot under queue $1 that holds the patches for target $2. Composed in one place,
# since chopi creates the slot and the profile below grants write inside exactly it.
slot_dir() {
    arity 2
    local queue_dir="$1" path="$2" id
    id="$(path_id "$path")" || return 1
    printf '%s/%s' "$queue_dir" "$id"
}

has_dotdot_component() {
    arity 1
    case "/$1/" in */../*) return 0 ;; esac
    return 1
}

has_git_component() {
    arity 1
    case "/$1/" in */.git/*) return 0 ;; esac
    return 1
}

# Handles cases with no visible .git component (bare repo, separate git dir)
is_git_dir() {
    arity 1
    git rev-parse --resolve-git-dir "$1" >/dev/null 2>&1
}

# Prints the git dir (usually .git) that path $1 is in, if there is one: the path itself, or the
# nearest directory above it that is one, up to and including limit $2. Both are absolute, and
# $1 is at or under $2.
enclosing_git_dir() {
    arity 2
    local path="$1" limit="$2"
    if ! is_path_within "$path" "$limit"; then
        printf 'BUG: enclosing_git_dir called with %s outside its limit %s\n' "$path" "$limit" >&2
        exit 2
    fi

    local node="$path"
    while :; do
        if is_git_dir "$node"; then
            printf '%s' "$node"
            return 0
        fi
        [ "$node" = "$limit" ] && return 1
        node="${node%/*}"
        [ -n "$node" ] || node=/    # a top-level path strips to nothing, which is the root
    done
}

# Validates a patch path is safe to write: doesn't try to escape the safe write target bounds
# via '..', and doesn't touch git internals.
validate_write_patch() {
    arity 2
    local target="$1" patch="$2"
    has_dotdot_component "$patch" && return 1
    has_git_component "$patch" && return 1
    enclosing_git_dir "$target/$patch" "$target" >/dev/null && return 1
    return 0
}

# Validates a safe write target in chopi's config
# chopi validates at launch, and chopi-review validates again at review time.
validate_write_target() {
    arity 3
    local path="$1" workspace="$2" prog="$3"

    if [ ! -d "$path" ] && [ ! -f "$path" ]; then
        echo "$prog: safe write target is not a directory or regular file $path" >&2
        return 1
    fi
    case "$path" in
        *$'\n'*)
            echo "$prog: safe write target has a newline in its path: $path" >&2
            return 1 ;;
    esac
    if overlaps_chopi_dir "$path"; then
        echo "$prog: safe write target overlaps chopi's directory $path" >&2
        return 1
    fi
    if is_path_within "$workspace" "$path"; then
        echo "$prog: safe write target contains the workspace $path" >&2
        echo "$prog: set CHOPI_ALLOW_SAFE_WRITE_TARGET=1 to continue anyway, leaving that target unenforced" >&2
        return 1
    fi
    if overlapping_dirs "$path" "$CHOPI_PATCH_QUEUE_ROOT"; then
        echo "$prog: safe write target overlaps the patch queue: $path" >&2
        return 1
    fi
    if has_git_component "$path"; then
        echo "$prog: safe write target has a .git component: $path" >&2
        return 1
    fi
    local git_dir
    if git_dir="$(enclosing_git_dir "$path" /)"; then
        echo "$prog: safe write target reaches the git directory at $git_dir: $path" >&2
        return 1
    fi
    return 0
}

# Validate the safe write targets config. Succeeds and fills CHOPI_WRITE_TARGET_PATHS with
# their canonical paths if they are ALL valid; otherwise fails, empties CHOPI_WRITE_TARGET_PATHS
# and prints the errors.
#
# chopi validates at launch, and chopi-review validates again per workspace queue.
CHOPI_WRITE_TARGET_PATHS=()
validate_write_targets() {
    arity 2
    local workspace="$1" prog="$2"

    CHOPI_WRITE_TARGET_PATHS=()
    local configured path paths=() ok=1
    for configured in "${CHOPI_SAFE_WRITE_TARGETS[@]+"${CHOPI_SAFE_WRITE_TARGETS[@]}"}"; do
        if [ -z "$configured" ]; then
            echo "$prog: CHOPI_SAFE_WRITE_TARGETS has an empty entry" >&2
            ok=""; continue
        fi

        # Before the resolve below normalizes the '..' away
        if has_dotdot_component "$configured"; then
            echo "$prog: safe write target has a '..' component: $configured" >&2
            ok=""; continue
        fi
        path="$(target_real_path "$configured" "$workspace")"

        # Compared after resolving, so two spellings of one directory are caught as duplicates
        if is_item_in_list "$path" "${paths[@]+"${paths[@]}"}"; then
            echo "$prog: two safe write targets resolve to the same path: $path" >&2
            ok=""; continue
        fi

        # Launching chopi inside a safe write target is normally refused (below): the
        # target's write-deny would cover every file the session writes. The override
        # admits the launch by leaving the containing target unenforced for this run.
        if [ -n "${CHOPI_ALLOW_SAFE_WRITE_TARGET:-}" ] && is_path_within "$workspace" "$path"; then
            echo "$prog: warning: safe write target contains the workspace $path;" >&2
            echo "$prog: not enforcing it for this run (CHOPI_ALLOW_SAFE_WRITE_TARGET is set)" >&2
            continue
        fi

        validate_write_target "$path" "$workspace" "$prog" || { ok=""; continue; }
        paths+=("$path")
    done

    [ -n "$ok" ] || return 1
    CHOPI_WRITE_TARGET_PATHS=("${paths[@]+"${paths[@]}"}")
}

# Create queue or slot dir $1 holding its $2 (WORKSPACE/TARGET) record naming path $3, or check
# the record of one already there.
ensure_recorded_dir() {
    arity 3
    local dir="$1" name="$2" path="$3"
    local record="$dir/$name"

    # Create the dir if doesn't already exist, along with its record
    if mkdir "$dir" 2>/dev/null; then
        printf '%s\0' "$path" > "$record" \
            || { echo "chopi: cannot write the $name record at '$record'" >&2; return 1; }
        return 0
    fi

    if [ -L "$dir" ]; then
        echo "chopi: refusing '$dir' in the patch queue: it is a symlink, and nothing chopi" >&2
        echo "       grants can cause that. To repair, delete it." >&2
        return 1
    fi
    if [ ! -d "$dir" ]; then
        echo "chopi: cannot create '$dir' in the patch queue" >&2
        return 1
    fi

    if [ -L "$record" ] || { [ -e "$record" ] && [ ! -f "$record" ]; }; then
        echo "chopi: refusing the $name record at '$record': it is not a regular file, and" >&2
        echo "       nothing chopi grants can cause that. To repair, delete the directory it sits in." >&2
        return 1
    fi
    if [ ! -f "$record" ]; then
        echo "chopi: '$dir' has no $name record, and nothing chopi grants can remove one." >&2
        echo "       To repair, delete that directory." >&2
        return 1
    fi
    [ "$(verified_record "$dir" "$name")" = "$path" ] && return 0
    echo "chopi: the $name record at '$record' does not name '$path':" >&2
    echo "       it was likely corrupted. To repair, delete the directory it sits in." >&2
    return 1
}

# Refuse a symlink at the queue root or any dir chopi makes above it, up to HOME. The profile
# grants paths under those nodes and Seatbelt resolves them for real, so a link there hands the
# grants to what it points at, and the queue chopi speaks of is not the one the command gets.
validate_queue_root() {
    arity 0
    local node="$CHOPI_PATCH_QUEUE_ROOT"
    while :; do
        if [ -L "$node" ]; then
            echo "chopi: refusing the patch queue at '$CHOPI_PATCH_QUEUE_ROOT': '$node' is a" >&2
            echo "       symlink, and nothing chopi grants can cause that. To repair, delete it." >&2
            return 1
        fi
        node="$(dirname "$node")"
        case "$node" in "$HOME" | / | .) return 0 ;; esac
    done
}

# Creates the workspace's queue, one slot per configured target, and prints its dir.
#
# Both the queue and its slots are named using the digests of their paths, with WORKSPACE and
# TARGET under them spelling out the full paths. The queue is synced to the config on every
# launch, creating any missing slots and removing empty/refusing non-empty existing ones for
# targets that were removed from the config.
create_patch_queue() {
    arity 1
    local run_dir="$1"

    local real_run_dir id queue_dir
    real_run_dir="$(realpath "$run_dir" 2>/dev/null)" \
        || { echo "chopi: cannot resolve the workspace '$run_dir'" >&2; return 1; }
    id="$(path_id "$real_run_dir")" || return 1
    queue_dir="$CHOPI_PATCH_QUEUE_ROOT/$id"

    validate_queue_root || return 1
    mkdir -p "$CHOPI_PATCH_QUEUE_ROOT" \
        || { echo "chopi: cannot create the patch queue at '$CHOPI_PATCH_QUEUE_ROOT'" >&2; return 1; }

    ensure_recorded_dir "$queue_dir" WORKSPACE "$real_run_dir" || return 1

    local path slot slots=()
    for path in "${CHOPI_WRITE_TARGET_PATHS[@]+"${CHOPI_WRITE_TARGET_PATHS[@]}"}"; do
        slot="$(slot_dir "$queue_dir" "$path")" || return 1
        ensure_recorded_dir "$slot" TARGET "$path" || return 1
        slots+=("$slot")
    done

    clear_retired_slots "$queue_dir" "${slots[@]+"${slots[@]}"}" || return 1
    printf '%s' "$queue_dir"
}

clear_retired_slots() {
    local queue_dir="$1"; shift    # the rest: the slots the config names
    # An empty queue would glob to the root's own directories, and the removal below is real.
    if [ -z "$queue_dir" ]; then
        printf 'BUG: clear_retired_slots called with an empty queue\n' >&2
        exit 2
    fi
    local slot stranded=()
    for slot in "$queue_dir"/*/; do
        slot="${slot%/}"
        [ -d "$slot" ] || continue    # a queue with no slots at all, the glob left unexpanded
        is_item_in_list "$slot" "$@" && continue
        collect_pending_patches "$slot"
        if [ "${#PENDING_PATCHES[@]}" -gt 0 ]; then
            stranded+=("$slot")
        else
            rm -rf "$slot"
        fi
    done
    [ "${#stranded[@]}" -eq 0 ] && return 0

    # Minor note: refusal on patched queued for missing safe targets means switching between
    # configs naming different safe targets is not supported
    local target count
    echo "chopi: patches are queued for safe write targets the config no longer names:" >&2
    for slot in "${stranded[@]}"; do
        collect_pending_patches "$slot"
        count="${#PENDING_PATCHES[@]}"
        target="$(slot_target "$slot")"
        printf '   - %s patch(es) in %s\n' "$count" "$slot" >&2
        [ -n "$target" ] && printf '     proposed for %s\n' "$target" >&2
    done
    echo "chopi: put the safe write target back in CHOPI_SAFE_WRITE_TARGETS and run chopi-review to" >&2
    echo "       apply or reject them, or delete the slot to discard them." >&2
    return 1
}

# Print the path recorded in WORKSPACE/TARGET, file $2 of queue or slot directory $1,
# or nothing when there is no record or it doesn't belong to that directory.
#
# Every such directory is named using a digest of the path it represents, and that's verified
# against the path in WORKSPACE/TARGET.
#
# Checked rather than trusted as defense-in-depth (the profile denies writing these records in
# the sandbox).
#
# Even verified, only the config decides which records are real.
verified_record() {
    arity 2
    local dir="$1" name="$2"
    local record="$dir/$name" line
    [ -r "$record" ] || return 0
    IFS= read -r -d '' line < "$record" || return 0
    [ -n "$line" ] || return 0

    local recorded_id expected_id
    recorded_id="$(path_id "$line" 2>/dev/null)" || return 0
    expected_id="$(basename "$dir")"
    [ "$recorded_id" = "$expected_id" ] || return 0
    printf '%s' "$line"
}

# The workspace a queue belongs to, and the target a slot patches.
queue_workspace() { arity 1; verified_record "$1" WORKSPACE; }
slot_target()     { arity 1; verified_record "$1" TARGET; }

# Seatbelt profile making the queue readable, slots writable except for TARGETs, and the
# in-session queueing helper script
write_patch_queue_profile() {
    arity 2
    local profile_path="$1" queue_dir="$2"

    local path slot slots=()
    for path in "${CHOPI_WRITE_TARGET_PATHS[@]+"${CHOPI_WRITE_TARGET_PATHS[@]}"}"; do
        slot="$(slot_dir "$queue_dir" "$path")" || return 1
        slots+=("$slot")
    done

    {
        echo ";; chopi: the workspace patch queue and safe write target slots"
        rule 'allow file-read*' subpath "$queue_dir"
        for slot in "${slots[@]+"${slots[@]}"}"; do
            rule 'allow file-write*' subpath "$slot"
            rule 'deny file-write*' literal "$slot/TARGET"
        done
        pin_ancestries "$queue_dir" "${slots[@]+"${slots[@]}"}"

        echo ";; chopi: stat-only on the queue's dir chain below HOME"
        local node="$queue_dir"
        while :; do
            node="$(dirname "$node")"
            case "$node" in "$HOME" | / | .) break ;; esac
            rule 'allow file-read-metadata' literal "$node"
        done
        echo ";; chopi: the safe write targets: read-only so the review is the only way to write"
        local scope parents=()
        for path in "${CHOPI_WRITE_TARGET_PATHS[@]+"${CHOPI_WRITE_TARGET_PATHS[@]}"}"; do
            # A file target gets literal rules: subpath would also match a descendant of a
            # directory later swapped in at the same path. Not-a-file can only mean directory:
            # validate_write_target admits nothing else.
            scope=subpath
            [ -f "$path" ] && scope=literal
            rule 'allow file-read*' "$scope" "$path"
            rule 'deny file-write*' "$scope" "$path"
            parents+=("$(dirname "$path")")
        done
        pin_ancestries / ${parents[@]+"${parents[@]}"}

        echo ";; chopi: chopi-queue-patch.sh, so the session can author and queue patches with it"
        rule 'allow file-read* process-exec' literal "$CHOPI_DIR/.internal/chopi-queue-patch.sh"
        echo ";; chopi: the lib it sources beyond the wrapper's"
        rule 'allow file-read*' literal "$CHOPI_DIR/.internal/write-targets.sh"
    } > "$profile_path"
}

# Collect the pending patches under queue or slot dir $1 into PENDING_PATCHES, oldest first.
PENDING_PATCHES=()
collect_pending_patches() {
    arity 1
    local dir="$1" entry
    PENDING_PATCHES=()
    [ -d "$dir" ] || return 0
    while IFS= read -r -d '' entry; do
        PENDING_PATCHES+=("${entry#* }")
    done < <(
        find "$dir" -type f -name '*.patch' -print0 2>/dev/null \
            | while IFS= read -r -d '' patch; do
                  mtime="$(stat -f '%Fm' "$patch" 2>/dev/null)" || continue
                  printf '%s %s\0' "$mtime" "$patch"
              done \
            | sort -zn
    )
}

# Offer to review the patches queue for the workspace the sandboxed command ran in, succeeding
# if the user accepted.
# Asked once the command has exited, while the session it came out of is still in view and the
# terminal is chopi's again.
offer_reviewing_queued_workspace_patches() {
    arity 1
    local queue_dir="$1"
    [ -z "$queue_dir" ] && return 1
    # Must be an interactive terminal
    { [ -t 0 ] && [ -t 2 ]; } || return 1

    collect_pending_patches "$queue_dir"
    local pending="${#PENDING_PATCHES[@]}"
    [ "$pending" -eq 0 ] && return 1

    local answer
    {
        echo
        printf 'chopi: %s patch(es) for review. Review now? [Y/n] ' "$pending"
    } >&2
    answer="$(prompt_read_key)" || return 1
    case "$answer" in
        '' | y | Y) return 0 ;;
    esac
    echo "chopi: left for later; apply them with chopi-review" >&2
    return 1
}

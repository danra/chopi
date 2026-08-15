#!/usr/bin/env bash
#
# chopi-queue-patch.sh -- author a change to a file a safe write target covers, and queue
# it for review.
#
# Not run directly; the sandboxed agent invokes it. Writing a target is denied there, so a
# change to one is proposed as a patch in the queue chopi exports as CHOPI_PATCH_QUEUE, and
# the user applies it on the host with chopi-review.

set -euo pipefail

SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

. "$SCRIPT_DIR/util.sh"
. "$SCRIPT_DIR/write-targets.sh"

usage="usage: chopi-queue-patch.sh -s SUBJECT [-m BODY] FILE DRAFT

Queue a change to FILE, a file a safe write target covers, for the user to
review and apply outside the sandbox. The change is FILE taking DRAFT's
content: copy FILE aside, edit the copy, and pass the copy as DRAFT. A FILE
that doesn't exist yet under a directory target is created by the patch.

  -s SUBJECT   what the change does, in one line; becomes the commit subject
  -m BODY      more details on the change; becomes the commit message body

  -h, --help   show this help"

# Print FILE's real path. A FILE not there yet (a patch can create one) resolves through
# its nearest existing ancestor, with the missing tail kept as written.
resolve_file() {
    arity 1
    local path="$1"
    case "$path" in
        /*) ;;
        *)  path="$(pwd -P)/$path" ;;
    esac
    local node="$path" tail=""
    while [ ! -e "$node" ]; do
        if [ -L "$node" ]; then
            echo "chopi-queue-patch: cannot resolve '$1': '$node' is a broken symlink" >&2
            return 1
        fi
        tail="${node##*/}${tail:+/}${tail}"
        node="${node%/*}"
        [ -n "$node" ] || node=/
    done
    if has_dotdot_component "$tail"; then
        echo "chopi-queue-patch: cannot resolve '$1': a '..' component past where the path exists" >&2
        return 1
    fi
    local real
    real="$(realpath "$node" 2>/dev/null)" \
        || { echo "chopi-queue-patch: cannot resolve '$1'" >&2; return 1; }
    [ -n "$tail" ] && real="${real%/}/$tail"
    printf '%s' "$real"
}

# Find the slot whose target covers real PATH: SLOT holds it, PATCH_ROOT the directory
# its patches apply in, and PATCH_REL the path inside it. Fails quietly when no target
# covers the path.
SLOT="" PATCH_ROOT="" PATCH_REL=""
find_covering_slot() {
    arity 1
    local path="$1" slot target rel
    SLOT="" PATCH_ROOT="" PATCH_REL=""
    for slot in "$CHOPI_PATCH_QUEUE"/*/; do
        slot="${slot%/}"
        [ -d "$slot" ] || continue
        target="$(slot_target "$slot")"
        [ -n "$target" ] || continue
        if [ -d "$target" ]; then
            rel="$(relative_path_within "$path" "$target")" || continue
        elif [ -f "$target" ] && [ "$path" = "$target" ]; then
            rel="$(basename "$target")"
            target="$(dirname "$target")"
        else
            continue
        fi
        SLOT="$slot" PATCH_ROOT="$target" PATCH_REL="$rel"
        return 0
    done
    return 1
}

# A readable file name for the patch, derived from its subject
patch_slug() {
    arity 1
    local slug
    slug="$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -cs 'a-z0-9' '-')"
    slug="${slug#-}"
    slug="${slug:0:40}"; slug="${slug%-}"
    printf '%s' "${slug:-change}"
}

queue_change() {
    arity 4
    local subject="$1" body="$2" file="$3" draft="$4"

    if [ ! -f "$draft" ] || [ ! -r "$draft" ]; then
        echo "chopi-queue-patch: DRAFT '$draft' is not a readable file" >&2
        return 1
    fi

    local real
    real="$(resolve_file "$file")" || return 1
    if [ -d "$real" ]; then
        echo "chopi-queue-patch: '$file' is a directory; name a file to change" >&2
        return 1
    fi

    if ! find_covering_slot "$real"; then
        echo "chopi-queue-patch: no safe write target covers $real" >&2
        return 1
    fi

    # Same check as chopi-review, fail fast for better UX
    if ! validate_write_patch "$PATCH_ROOT" "$PATCH_REL"; then
        echo "chopi-queue-patch: refusing '$PATCH_REL': it escapes the target or reaches git internals" >&2
        return 1
    fi

    local work rel_dir
    work="$(mktemp -d "${TMPDIR:-/tmp}/chopi-queue-patch.XXXXXX")" \
        || { echo "chopi-queue-patch: could not create a temporary work dir" >&2; return 1; }
    rel_dir="$(dirname "$PATCH_REL")"
    mkdir -p "$work/a/$rel_dir" "$work/b/$rel_dir"

    cp "$draft" "$work/b/$PATCH_REL"
    local old=/dev/null
    if [ -e "$real" ]; then
        cp "$real" "$work/a/$PATCH_REL"
        old="a/$PATCH_REL"
        # The draft was made fresh, so its permission bits say nothing; keep the file's own,
        # or the diff would carry a mode change nobody proposed.
        local mode
        mode="$(stat -f '%Lp' "$real")"
        chmod "$mode" "$work/b/$PATCH_REL"
    fi

    # --no-index exits 1 when the files differ, which is the case with something to queue;
    # --binary keeps a non-text file appliable instead of diffing to a "files differ" stub.
    local diff_status=0
    git -C "$work" diff --no-index --no-prefix --binary -- "$old" "b/$PATCH_REL" \
        > "$work/body.diff" || diff_status=$?
    if [ "$diff_status" -eq 0 ]; then
        echo "chopi-queue-patch: draft matches the current content of $real; nothing to queue" >&2
        return 1
    fi
    if [ "$diff_status" -ne 1 ]; then
        echo "chopi-queue-patch: git could not diff '$real' against the draft" >&2
        return 1
    fi

    if ! git -C "$PATCH_ROOT" apply --check -p1 "$work/body.diff"; then
        echo "chopi-queue-patch: the change does not apply cleanly in $PATCH_ROOT; nothing queued" >&2
        return 1
    fi

    # The From: header becomes the commit's author. git var, rather than user.name and
    # user.email, resolves the identity git itself would commit with, fails exactly when
    # a commit would, and strips the crud a header can't carry (angle brackets, newlines).
    local author
    author="$(git var GIT_AUTHOR_IDENT)" \
        || { echo "chopi-queue-patch: cannot resolve the git author identity;" >&2
             echo "                   configure git user.name and user.email" >&2
             return 1; }
    author="${author% * *}"    # drop the timestamp and timezone

    {
        printf 'From: %s\n' "$author"
        printf 'Subject: [PATCH] %s\n\n' "$subject"
        if [ -n "$body" ]; then printf '%s\n\n' "$body"; fi
        printf -- '---\n'
        cat "$work/body.diff"
    } > "$work/queued.patch"

    local slug dest n=2
    slug="$(patch_slug "$subject")"
    dest="$SLOT/$slug.patch"
    while [ -e "$dest" ] || [ -L "$dest" ]; do dest="$SLOT/$slug-$n.patch"; n=$((n + 1)); done
    mv "$work/queued.patch" "$dest" \
        || { echo "chopi-queue-patch: could not write the patch into its queue slot" >&2; return 1; }

    printf 'queued "%s" for %s\n' "$subject" "$real"
    printf '  at %s (delete to withdraw)\n' "$dest"
    printf '  the user reviews and applies it with chopi-review, offered when the session ends\n'
}

main() {
    local subject="" body=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)  echo "$usage"; return 0 ;;
            -s)
                if [ "$#" -lt 2 ]; then echo "chopi-queue-patch: -s requires the subject" >&2; return 1; fi
                subject="$2"; shift 2 ;;
            -m)
                if [ "$#" -lt 2 ]; then echo "chopi-queue-patch: -m requires the body" >&2; return 1; fi
                body="$2"; shift 2 ;;
            --)         shift; break ;;
            -*)         echo "chopi-queue-patch: unknown option: $1" >&2; echo "$usage" >&2; return 1 ;;
            *)          break ;;
        esac
    done

    if [ ! -d "${CHOPI_PATCH_QUEUE:-}" ]; then
        echo "chopi-queue-patch: CHOPI_PATCH_QUEUE is not set." >&2
        return 1
    fi

    if [ -z "$subject" ]; then
        echo "chopi-queue-patch: a subject is required: -s 'what the change does, in one line'" >&2
        echo "$usage" >&2
        return 1
    fi
    if [ "$#" -ne 2 ]; then
        echo "chopi-queue-patch: expected FILE and DRAFT" >&2
        echo "$usage" >&2
        return 1
    fi
    queue_change "$subject" "$body" "$1" "$2"
}

{
    main "$@"
    # The braces make bash parse this whole block, exit included, before running it, so a
    # mid-session edit to this file cannot affect it: without the exit, bash would read the
    # file again after main returns, at a stale byte offset that executes garbage.
    exit
}

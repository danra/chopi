#!/usr/bin/env bash
#
# test/write-targets.sh -- unit tests for the patch queue's config and grants

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
. "$repo/.internal/util.sh"
. "$repo/test/lib.sh"

header "test/write-targets.sh -- unit tests for the patch queue's config and grants"

TMPDIR="$(mktemp -d)"; export TMPDIR
# The sandbox resolves paths through the /var symlink, so canonicalize before comparing.
TMPDIR="$(cd "$TMPDIR" && pwd -P)"
trap 'rm -rf "$TMPDIR"' EXIT

# The queue root is $HOME-derived, so point HOME into the temp dir: the tests must never
# touch the developer's real ~/.chopi. The lib under test is sourced after, for the same reason.
HOME="$TMPDIR/home"; export HOME
mkdir -p "$HOME"
. "$repo/.internal/write-targets.sh"

# The dev environment may set the override; the refusal tests need it off.
unset CHOPI_ALLOW_SAFE_WRITE_TARGET

# A git worktree root to stand in for the workspace, with a target dir in it and one outside.
work="$TMPDIR/work"
make_repo "$work"
mkdir -p "$work/docs"
guidelines="$TMPDIR/guidelines"
mkdir -p "$guidelines"

# Captured exit codes below rely on errexit being off.
set +e


# ---------------------------------------------------------------------------
echo "path_id"
# ---------------------------------------------------------------------------
id="$(path_id "$work")"
assert_eq "${#id}" 16 "a path is named by a 16-hex digest of itself"
assert_eq "$(path_id "$work")" "$id" "the id is stable across calls, so a queue persists across runs"
assert_not_eq "$(path_id "$TMPDIR/elsewhere/work")" "$id" \
    "a same-named path elsewhere gets its own id, and so its own queue"


# ---------------------------------------------------------------------------
echo "enclosing_git_dir"
# ---------------------------------------------------------------------------
assert_eq "$(enclosing_git_dir "$work/.git" /)" "$work/.git" "a git dir is answered with itself"
assert_eq "$(enclosing_git_dir "$work/.git/hooks/pre-commit" /)" "$work/.git" \
    "  -> as is a path inside one, whether or not it exists yet"

enclosing_git_dir "$work/README.md" / >/dev/null; st=$?
assert_eq "$st" 1 "a path in a repo's worktree is not in a gitdir (or no target could sit inside a repo)"

git init -q --bare "$work/.git/modules/sub"
assert_eq "$(enclosing_git_dir "$work/.git/modules/sub/hooks" /)" "$work/.git/modules/sub" \
    "nested git dirs answer with the innermost, which is the one the path is in"

assert_eq "$(enclosing_git_dir "$work/.git/hooks" "$work/.git")" "$work/.git" "the limit is walked too"
enclosing_git_dir "$work/.git/hooks/pre-commit" "$work/.git/hooks" >/dev/null; st=$?
assert_eq "$st" 1 "  -> and nothing above it is (even when a gitdir is clearly there)"

out="$(enclosing_git_dir "$work/.git/hooks" "$guidelines" 2>&1)"; st=$?
assert_eq       "$st" 2       "a path outside the limit is a caller bug"
assert_contains "$out" "BUG:" "  -> saying so"


# ---------------------------------------------------------------------------
echo "validate_write_targets"
# ---------------------------------------------------------------------------
accepts() {
    local desc="$1"; shift
    CHOPI_SAFE_WRITE_TARGETS=("$@")
    out="$(validate_write_targets "$work" chopi 2>&1)"; st=$?
    if [ "$st" -eq 0 ] && [ -z "$out" ]; then ok "$desc"; else
        bad "$desc"; printf '         exit %s, said: %q\n' "$st" "$out"
    fi
}

refuses() {
    local desc="$1" reason="$2"; shift 2
    CHOPI_SAFE_WRITE_TARGETS=("$@")
    out="$(validate_write_targets "$work" chopi 2>&1)"; st=$?
    if [ "$st" -eq 1 ]; then assert_contains "$out" "$reason" "$desc"; else
        bad "$desc"; printf '         exit %s (want 1)\n' "$st"
    fi
}

accepts "no targets configured is fine -- the feature is opt-in"
accepts "an absolute path to an existing directory outside the workspace is accepted" "$guidelines"
refuses "an empty entry is refused rather than skipped" "empty" "" "$guidelines"

refuses "the same path twice is refused, since one slot can't hold two targets" \
    "resolve to the same path" "$guidelines" "$guidelines"
ln -s "$guidelines" "$TMPDIR/guidelines-link"
refuses "  -> including two spellings that resolve to the same directory" \
    "resolve to the same path" "$guidelines" "$TMPDIR/guidelines-link"

nl_dir="$TMPDIR/holds"$'\n'"newline"
mkdir -p "$nl_dir"
refuses "a path holding a newline is refused" "newline" "$nl_dir"

# A '..' spelling is refused: what it names shifts with the workspace (from a linked
# worktree it reaches into the containing repo's .worktrees), so the user can't have vetted it.
mkdir -p "$TMPDIR/shared-notes"
refuses "a relative target with a '..' component is refused" "'..'" ../shared-notes
refuses "  -> an absolute spelling too, which resolves fine but reads as a mistake" \
    "'..'" "$TMPDIR/shared-notes/../shared-notes"

refuses "a path that isn't there is refused rather than created" "not a directory" "$TMPDIR/nope"
refuses "  -> and a relative one still has to exist once resolved" "not a directory" "$TMPDIR/no/such/dir"

refuses "chopi's own directory is refused as a target" \
    "overlaps chopi's directory" "$CHOPI_DIR"
refuses "  -> and so is a directory inside it, which is where the sandbox config lives" \
    "overlaps chopi's directory" "$CHOPI_DIR/config"

# Inside the workspace is allowed: the profile denies writing to the target to enforce review
mkdir -p "$work/sub"
accepts "a target inside the workspace is accepted" "$work/sub"
# ...but not git internals
refuses "a target inside the git dir is refused" "has a .git component" "$work/.git/hooks"
refuses "  -> and so is the git dir itself, reached relatively" "has a .git component" .git
# ...and not the workspace itself or any parent folder: that deny would cover every file
# the command legitimately writes, leaving a session that can't work.
refuses "the workspace itself is refused as a target" "contains the workspace" .
refuses "  -> and so is a directory enclosing it" "contains the workspace" "$TMPDIR"

# CHOPI_ALLOW_SAFE_WRITE_TARGET admits launching chopi inside a safe write target,
# leaving the containing target unenforced for the run instead of refusing.
CHOPI_SAFE_WRITE_TARGETS=("$TMPDIR" "$guidelines")
CHOPI_ALLOW_SAFE_WRITE_TARGET=1 validate_write_targets "$work" chopi 2>"$TMPDIR/warn.err"; st=$?
out="$(cat "$TMPDIR/warn.err")"
assert_zero     "$st"                  "CHOPI_ALLOW_SAFE_WRITE_TARGET admits a target containing the workspace"
assert_contains "$out" "warning:"      "  -> downgraded to a warning"
assert_contains "$out" "not enforcing" "  -> that says the target is not enforced"
assert_eq "${CHOPI_WRITE_TARGET_PATHS[*]-}" "$guidelines" "  -> and the other targets stay enforced"

CHOPI_SAFE_WRITE_TARGETS=(.)
CHOPI_ALLOW_SAFE_WRITE_TARGET=1 validate_write_targets "$work" chopi 2>/dev/null; st=$?
assert_zero "$st"                             "  -> a config naming only the workspace validates too"
assert_eq "${#CHOPI_WRITE_TARGET_PATHS[@]}" 0 "  -> enforcing nothing"

# A single file in the workspace is a valid safe write target too
printf 'x\n' > "$work/CLAUDE.md"
accepts "a single file is accepted as a target" CLAUDE.md

# git internals anywhere are refused, not just in the workspace
mkdir -p "$TMPDIR/unrelated/.git/hooks"
refuses "  -> and a git dir belonging to some other repo entirely" \
    "has a .git component" "$TMPDIR/unrelated/.git/hooks"
# The name has to be the whole component, or every path with 'git' in it would be refused.
mkdir -p "$TMPDIR/workflows/.github"
accepts "a .github directory is not a git directory, and is accepted" "$TMPDIR/workflows/.github"
# The name is only half the rule: a bare repo or a --separate-git-dir gitdir carries no .git
# component, and is recognized by asking git what it is.
mkdir -p "$TMPDIR/mirror.git"
accepts "a directory merely named like a bare repo is accepted -- content decides" "$TMPDIR/mirror.git"
git init -q --bare "$TMPDIR/mirror.git"
refuses "  -> and refused once it is one, no .git component in sight" \
    "git directory" "$TMPDIR/mirror.git"

git init -q --separate-git-dir "$TMPDIR/detached-gitdir" "$TMPDIR/detached-work"
refuses "  -> a --separate-git-dir gitdir the same" "git directory" "$TMPDIR/detached-gitdir"
refuses "  -> and a directory inside one" "git directory" "$TMPDIR/detached-gitdir/hooks"

# Refuse a target that reaches the patch queue, its write-deny would break queueing itself.
mkdir -p "$CHOPI_PATCH_QUEUE_ROOT"
refuses "a target reaching the patch queue is refused" "queue" "$CHOPI_PATCH_QUEUE_ROOT"
refuses "  -> and one enclosing the queue" "queue" "$HOME/.chopi"


# ---------------------------------------------------------------------------
echo "CHOPI_WRITE_TARGET_PATHS"
# ---------------------------------------------------------------------------
CHOPI_SAFE_WRITE_TARGETS=("$TMPDIR/guidelines-link" docs)
validate_write_targets "$work" chopi; st=$?
assert_zero "$st" "a config with a symlinked and a relative target validates"
assert_eq "${CHOPI_WRITE_TARGET_PATHS[*]}" "$guidelines $work/docs" \
    "  -> leaving each entry canonical and resolved, in the order they were configured"

CHOPI_SAFE_WRITE_TARGETS=("$guidelines" "$TMPDIR/not-there")
validate_write_targets "$work" chopi 2>/dev/null; st=$?
assert_eq "$st" 1 "one unusable entry fails the whole config"
assert_eq "${#CHOPI_WRITE_TARGET_PATHS[@]}" 0 "  -> and leaves no paths behind, not even the good one"


# ---------------------------------------------------------------------------
echo "create_patch_queue"
# ---------------------------------------------------------------------------
mkdir -p "$TMPDIR/notes"
CHOPI_SAFE_WRITE_TARGETS=("$guidelines" "$TMPDIR/notes" "$work/docs" "$work/CLAUDE.md")
validate_write_targets "$work" chopi
queue="$(create_patch_queue "$work")"
guidelines_slot="$queue/$(path_id "$guidelines")"
notes_slot="$queue/$(path_id "$TMPDIR/notes")"
assert_eq "$queue" "$CHOPI_PATCH_QUEUE_ROOT/$id" "the queue lives under the workspace's own id"
assert_present "$guidelines_slot" "  -> with a slot per target, named by a digest of its path"
assert_present "$notes_slot"      "  -> every configured target"
assert_absent "$queue/$(path_id "$TMPDIR/invented")" "  -> and nothing for a target that isn't configured"
assert_eq "$(slot_target "$guidelines_slot")" "$guidelines" \
    "  -> each recording the path it patches, which its digest name can't say"
assert_eq "$(queue_workspace "$queue")" "$work" "  -> and the queue recording its workspace"

# Creating twice is normal: the queue persists across runs and must survive a reused one.
assert_eq "$(create_patch_queue "$work")" "$queue" "creating an existing queue succeeds, at the same path"
ln -s "$work" "$TMPDIR/work-link"
assert_eq "$(create_patch_queue "$TMPDIR/work-link")" "$queue" \
    "  -> including one reached through a symlink, which is the same workspace"

# A record that disagrees with the name of the directory it sits in is not to be believed: a slot
# is writable by the sandboxed command, so the digest is what ties a record to its directory.
printf '%s\0' "$TMPDIR/notes" > "$guidelines_slot/TARGET"
assert_eq "$(slot_target "$guidelines_slot")" "" "a record naming some other path reads as nothing"
# Nor is it repaired, so it remains untrusted
out="$(create_patch_queue "$work" 2>&1 >/dev/null)"; st=$?
assert_eq       "$st" 1                   "a slot whose record names some other path stops the launch"
assert_contains "$out" "$guidelines_slot" "  -> naming the slot, which is what there is to settle"
assert_eq "$(cat "$guidelines_slot/TARGET")" "$TMPDIR/notes" "  -> the record left as it is, not repaired"
# Missing record is also rejected
rm -f "$guidelines_slot/TARGET"
out="$(create_patch_queue "$work" 2>&1 >/dev/null)"; st=$?
assert_eq       "$st" 1                   "a slot whose record is gone stops the launch"
assert_contains "$out" "$guidelines_slot" "  -> naming the slot, which is what there is to delete"
# After removing the slot altogether, it can be recreated
rm -rf "$guidelines_slot"
create_patch_queue "$work" >/dev/null; st=$?
assert_zero "$st" "a slot that isn't there at all is created, with its record"
assert_eq "$(slot_target "$guidelines_slot")" "$guidelines" "  -> naming the target it patches"

# A slot which is a symlink is not chopi's doing. Left alone, the profile grants write to
# whatever path is pointed at.
victim_dir="$TMPDIR/victim-dir"
mkdir -p "$victim_dir"
printf '%s\0' "$guidelines" > "$victim_dir/TARGET"
rm -rf "$guidelines_slot"
ln -s "$victim_dir" "$guidelines_slot"
out="$(create_patch_queue "$work" 2>&1 >/dev/null)"; st=$?
assert_eq       "$st" 1                   "a slot that is a symlink stops the launch, record and all"
assert_contains "$out" "$guidelines_slot" "  -> naming the slot, which is what there is to delete"

# Restore normal slot for following tests
rm -f "$guidelines_slot"
create_patch_queue "$work" >/dev/null

# The queue's own WORKSPACE record is similarly validated.
printf '%s\0' "$TMPDIR/notes" > "$queue/WORKSPACE"
out="$(create_patch_queue "$work" 2>&1 >/dev/null)"; st=$?
assert_eq       "$st" 1         "a queue whose record names some other path stops the launch"
assert_contains "$out" "$queue" "  -> naming the queue"

: > "$queue/WORKSPACE"
create_patch_queue "$work" >/dev/null 2>&1; st=$?
assert_eq "$st" 1 "  -> and so does one that reads back as nothing at all"

rm -f "$queue/WORKSPACE"
out="$(create_patch_queue "$work" 2>&1 >/dev/null)"; st=$?
assert_eq       "$st" 1         "a queue whose record is gone stops the launch too"
assert_contains "$out" "$queue" "  -> naming the queue"

rm -rf "$queue"
create_patch_queue "$work" >/dev/null; st=$?
assert_zero "$st" "a queue that isn't there at all is created, with its record"
assert_eq "$(queue_workspace "$queue")" "$work" "  -> naming this workspace"

# Neither record is written through a symlink: the contents would land on whatever it points to,
# outside the queue and unsandboxed.
victim="$TMPDIR/victim"
rm -f "$queue/WORKSPACE"
ln -s "$victim" "$queue/WORKSPACE"
out="$(create_patch_queue "$work" 2>&1 >/dev/null)"; st=$?
assert_eq       "$st" 1                     "a record that is a symlink stops the launch"
assert_absent   "$victim"                   "  -> with nothing written where it pointed"
assert_contains "$out" "not a regular file" "  -> named for what it is, not read as corrupted"
rm -f "$queue/WORKSPACE"

mkdir "$queue/WORKSPACE"
create_patch_queue "$work" >/dev/null 2>&1; st=$?
assert_eq "$st" 1 "  -> as does one that is a directory"

# Restore to normal for following tests
rm -rf "$queue"
create_patch_queue "$work" >/dev/null

# Reject unexpected symlinks in the queue root as well
elsewhere="$TMPDIR/elsewhere-queue"
mkdir -p "$elsewhere"
linked_queue="$elsewhere/$(path_id "$work")"
mv "$CHOPI_PATCH_QUEUE_ROOT" "$TMPDIR/real-root"
ln -s "$elsewhere" "$CHOPI_PATCH_QUEUE_ROOT"
out="$(create_patch_queue "$work" 2>&1 >/dev/null)"; st=$?
assert_eq       "$st" 1                          "a patch queue root that is a symlink stops the launch"
assert_contains "$out" "$CHOPI_PATCH_QUEUE_ROOT" "  -> naming it"
assert_absent   "$linked_queue"                  "  -> with no queue made through it"
rm -f "$CHOPI_PATCH_QUEUE_ROOT"
mv "$TMPDIR/real-root" "$CHOPI_PATCH_QUEUE_ROOT"

# And also in its parent dir ~/.chopi
mv "$HOME/.chopi" "$TMPDIR/real-chopi"
ln -s "$TMPDIR/real-chopi" "$HOME/.chopi"
out="$(create_patch_queue "$work" 2>&1 >/dev/null)"; st=$?
assert_eq       "$st" 1               "  -> as does one at the dir above it, which chopi makes too"
assert_contains "$out" "$HOME/.chopi" "  -> naming the node that is the link, not just the root"
rm -f "$HOME/.chopi"
mv "$TMPDIR/real-chopi" "$HOME/.chopi"


# ---------------------------------------------------------------------------
echo "clear_retired_slots"
# ---------------------------------------------------------------------------
CHOPI_SAFE_WRITE_TARGETS=("$guidelines")
validate_write_targets "$work" chopi
create_patch_queue "$work" >/dev/null; st=$?
assert_zero "$st"                 "a target dropped from the config takes its empty slot with it"
assert_absent  "$notes_slot"      "  -> the slot gone"
assert_present "$guidelines_slot" "  -> and the configured one left alone"

CHOPI_SAFE_WRITE_TARGETS=("$guidelines" "$TMPDIR/notes")
validate_write_targets "$work" chopi
create_patch_queue "$work" >/dev/null
printf 'x\n' > "$notes_slot/stranded.patch"
# Drop a safe target
CHOPI_SAFE_WRITE_TARGETS=("$guidelines")
validate_write_targets "$work" chopi
out="$(create_patch_queue "$work" 2>&1 >/dev/null)"; st=$?
assert_eq "$st" 1 "a slot still holding patches of dropped targets stops the launch rather than losing them"
assert_present "$notes_slot/stranded.patch" "  -> the patch left where it is"
assert_contains "$out" "$notes_slot"   "  -> the slot named, which is what there is to delete"
assert_contains "$out" "$TMPDIR/notes" "  -> and the target it was proposed for, which is what there is to restore"
# Restore it along with a couple more
CHOPI_SAFE_WRITE_TARGETS=("$guidelines" "$TMPDIR/notes" "$work/docs" "$work/CLAUDE.md")
validate_write_targets "$work" chopi
queue="$(create_patch_queue "$work")"; st=$?
assert_zero "$st" "putting the target back in the config lets the launch through"
assert_present "$notes_slot/stranded.patch" "  -> with what was queued for it still there"
rm -f "$notes_slot/stranded.patch"

# Robust against a patch with a newline in its name
printf 'x\n' > "$notes_slot/two"$'\n'"lines.patch"
CHOPI_SAFE_WRITE_TARGETS=("$guidelines" "$work/docs" "$work/CLAUDE.md")
validate_write_targets "$work" chopi
out="$(create_patch_queue "$work" 2>&1 >/dev/null)"; st=$?
assert_eq "$st" 1 "a slot holding only a patch whose name holds a newline strands it too"
assert_present "$notes_slot/two"$'\n'"lines.patch" "  -> the patch left where it is"
assert_contains "$out" "1 patch(es)" "  -> and counted in what the message reports"
rm -rf "$notes_slot"

# Restore to normal for following tests
CHOPI_SAFE_WRITE_TARGETS=("$guidelines" "$TMPDIR/notes" "$work/docs" "$work/CLAUDE.md")
validate_write_targets "$work" chopi
queue="$(create_patch_queue "$work")"


# ---------------------------------------------------------------------------
echo "write_patch_queue_profile"
# ---------------------------------------------------------------------------
profile_path="$TMPDIR/queue.sb"
write_patch_queue_profile "$profile_path" "$queue"
profile="$(cat "$profile_path")"

assert_contains "$profile" '(allow file-read* (subpath "'"$queue"'"))' \
    "the queue is granted read, so the command can find the slot of a target it wants to change"
assert_contains "$profile" '(allow file-write* (subpath "'"$guidelines_slot"'"))' \
    "  -> and write inside a slot, which is where a patch goes"
assert_contains "$profile" '(allow file-write* (subpath "'"$notes_slot"'"))' "  -> for every slot"

assert_not_contains "$profile" '(allow file-write* (subpath "'"$queue"'"))' \
    "the queue itself is not writable, so a sandboxed command can't invent a slot"
assert_contains "$profile" '(deny file-write* (literal "'"$guidelines_slot"'/TARGET"))' \
    "a slot's own record is denied write, so it stays what chopi wrote"
assert_rule_order "$profile_path" \
    '(allow file-write* (subpath "'"$guidelines_slot"'"))' \
    '(deny file-write* (literal "'"$guidelines_slot"'/TARGET"))' \
    "  -> after the grant that would otherwise cover it, so the deny is what lands"
assert_contains "$profile" '(deny file-write* (literal "'"$guidelines_slot"'"))' \
    "the slot node itself is pinned, so the record can't be carried out from under its deny"
assert_rule_order "$profile_path" \
    '(allow file-write* (subpath "'"$guidelines_slot"'"))' \
    '(deny file-write* (literal "'"$guidelines_slot"'"))' \
    "  -> after the grant, which leaves the patches inside it writable"
assert_not_contains "$profile" '(deny file-write* (literal "'"$queue"'"))' \
    "  -> the queue itself doesn't have a write grant, so it doesn't need a similar deny"

assert_contains "$profile" '(allow file-read-metadata (literal "'"$CHOPI_PATCH_QUEUE_ROOT"'"))' \
    "  -> but does need stat"
assert_contains "$profile" '(allow file-read-metadata (literal "'"$HOME/.chopi"'"))' "  -> and so does its parent dir"
assert_not_contains "$profile" '(allow file-read-metadata (literal "'"$HOME"'"))' \
    "  -> No-need to grant HOME, already granted by safehouse"

assert_contains "$profile" '(allow file-read* (subpath "'"$guidelines"'"))' \
    "a directory target is granted read, so a patch can be diffed against it"
assert_contains "$profile" '(deny file-write* (subpath "'"$guidelines"'"))' "  -> and is denied write outright"
assert_contains "$profile" '(deny file-write* (subpath "'"$work/docs"'"))' \
    "  -> including a target inside the workspace, which the workspace grant would otherwise cover"
assert_not_contains "$profile" "$CHOPI_DIR" "nothing in chopi's own directory is granted"
assert_not_contains "$profile" '(deny file-write* (subpath "'"$work"'"))' \
    "the workspace is never write-denied as a whole, which would deny the session itself"

assert_contains "$profile" '(allow file-read* (literal "'"$work/CLAUDE.md"'"))' \
    "a file target is granted read as a literal"
assert_contains "$profile" '(deny file-write* (literal "'"$work/CLAUDE.md"'"))' \
    "  -> and denied write the same as a directory target"

# Every node above a target is pinned, preventing bypassing the Seatbelt policy by moving a parent,
# writing, and moving the parent back.
assert_contains "$profile" '(deny file-write* (literal "'"$work"'"))' \
    "the nodes above an in-workspace target are pinned, the workspace's own included"
assert_contains "$profile" '(deny file-write* (literal "'"$TMPDIR"'"))' "  -> all the way up"
assert_not_contains "$profile" '(deny file-write* (literal "/"))' "  -> stopping short of the root"
assert_eq "$(printf '%s\n' "$profile" | grep -cF '(deny file-write* (literal "'"$TMPDIR"'"))')" 1 \
    "  -> each node once, however many targets share it"


# ---------------------------------------------------------------------------
echo "collect_pending_patches"
# ---------------------------------------------------------------------------
PENDING_PATCHES=(stale)
collect_pending_patches "$queue"
assert_eq "${#PENDING_PATCHES[@]}" 0 "a fresh queue has nothing pending, clearing what a previous collect left"

printf 'x\n' > "$guidelines_slot/first.patch"
printf 'x\n' > "$guidelines_slot/second.patch"
collect_pending_patches "$queue"
assert_eq "${#PENDING_PATCHES[@]}" 2 "queued patches are collected"
assert_eq "${PENDING_PATCHES[0]-}" "$guidelines_slot/first.patch" \
    "  -> oldest first, so review order matches the order they were queued"

printf 'x\n' > "$guidelines_slot/notes.txt"
collect_pending_patches "$queue"
assert_eq "${#PENDING_PATCHES[@]}" 2 "a file that isn't a .patch is not a patch"

# Robust to newlines in the patch name (which an evil sandboxed command might introduce)
printf 'x\n' > "$guidelines_slot/two"$'\n'"lines.patch"
collect_pending_patches "$queue"
assert_eq "${#PENDING_PATCHES[@]}" 3 "a name holding a newline is a patch like any other"
assert_eq "${PENDING_PATCHES[2]-}" "$guidelines_slot/two"$'\n'"lines.patch" "  -> carried whole"


# ---------------------------------------------------------------------------
echo "paths holding a newline"
# ---------------------------------------------------------------------------
# Robust to newlines in the path of the workspace
nl_work="$TMPDIR/nl"$'\n'"work"
mkdir -p "$nl_work"
CHOPI_SAFE_WRITE_TARGETS=("$guidelines")
validate_write_targets "$nl_work" chopi
nl_queue="$(create_patch_queue "$nl_work")"
assert_eq "$(queue_workspace "$nl_queue")" "$nl_work" \
    "a workspace holding a newline records and reads back whole"


# ---------------------------------------------------------------------------
summary

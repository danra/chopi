#!/usr/bin/env bash
#
# test/claude-context-check.sh -- unit tests for the in-sandbox Claude-context
# follow-and-refuse walk: follow the imports, list what the sandbox denies.
#
# These tests run unsandboxed, where a Seatbelt EPERM cannot be provoked, so probe_read is
# redefined to deny exactly the paths in $deny_paths; the rest of the walk is the real code.
# The real probe's errno classification is exercised by test/integration.sh under the real
# sandbox.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
. "$repo/.internal/util.sh"
. "$repo/.internal/claude-context-check.sh"
. "$repo/test/lib.sh"

header "test/claude-context-check.sh -- unit tests for the in-sandbox Claude-context check"

# Exported so any temporaries land here too.
TMPDIR="$(mktemp -d)"; export TMPDIR
trap 'rm -rf "$TMPDIR"' EXIT

NL=$'\n'

deny() {
    deny_paths=$NL
    local p
    for p in "$@"; do deny_paths="$deny_paths$p$NL"; done
}
deny

probe_read() {
    arity 1
    case "$deny_paths" in *"$NL$1$NL"*) return "$PROBE_READ_DENIED" ;; esac
    [ -f "$1" ] && return "$PROBE_READ_OK"
    return "$PROBE_READ_SKIP"
}

# Captured exit codes below rely on errexit being off.
set +e


# ---------------------------------------------------------------------------
echo "with every import readable, the check finds nothing and the run is not refused"
# ---------------------------------------------------------------------------
make_workspace allok
printf '@guide.md\n' > "$mono_real/CLAUDE.md"
printf 'g\n'         > "$mono_real/guide.md"
deny

out="$(unreadable_claude_context_paths "$work_real")"
assert_zero "$?" "the check exits zero"
assert_eq   "$out" "" "  -> and reports no denials"
refuse_unreadable_claude_context "$work_real" >/dev/null 2>&1
assert_zero "$?" "the refusal gate passes"


# ---------------------------------------------------------------------------
echo "a denied @-import is listed with its importer, and the refusal shows a grant example"
# ---------------------------------------------------------------------------
make_workspace denied
notes="$TMPDIR/denied-notes"; mkdir -p "$notes"
printf 's\n' > "$notes/style.md"
printf '@%s/style.md\n' "$notes" > "$mono_real/CLAUDE.md"
deny "$notes/style.md"

out="$(unreadable_claude_context_paths "$work_real")"
assert_contains "$out" "$notes/style.md  (imported by $mono_real/CLAUDE.md)" "the denied import is listed with its importer"

err="$(refuse_unreadable_claude_context "$work_real" 2>&1)"; rc=$?
assert_nonzero  "$rc" "the refusal gate fails"
assert_contains "$err" "$notes/style.md"                  "  -> the message lists the denied path"
assert_contains "$err" "(imported by $mono_real/CLAUDE.md)" "  -> and its importer"
assert_contains "$err" "CHOPI_SAFEHOUSE_FLAGS"            "  -> and names CHOPI_SAFEHOUSE_FLAGS"
assert_contains "$err" "--add-dirs-ro"                    "  -> with an example --add-dirs-ro grant"
assert_contains "$err" "a grant cannot cover an @-import" "  -> and the note that isolation-zone imports can't be granted"


# ---------------------------------------------------------------------------
echo "an @-token that names no existing file is skipped, not refused"
# ---------------------------------------------------------------------------
make_workspace ghost
printf 'Use @anthropic-ai/claude-code for agents\n' > "$mono_real/CLAUDE.md"
deny

out="$(unreadable_claude_context_paths "$work_real")"
assert_eq "$out" "" "a nonexistent import token reports nothing"


# ---------------------------------------------------------------------------
echo "imports are followed recursively; a denied transitive import is listed against ITS importer"
# ---------------------------------------------------------------------------
make_workspace rec
printf '@a.md\n' > "$mono_real/CLAUDE.md"
printf '@b.md\n' > "$mono_real/a.md"
printf 'x\n'     > "$mono_real/b.md"
deny "$mono_real/b.md"

out="$(unreadable_claude_context_paths "$work_real")"
assert_contains "$out" "$mono_real/b.md  (imported by $mono_real/a.md)" "the transitive denial is listed with the mid-chain importer"


# ---------------------------------------------------------------------------
echo "a denied mid-chain file is listed itself; what IT imports cannot be followed"
# ---------------------------------------------------------------------------
deny "$mono_real/a.md"

out="$(unreadable_claude_context_paths "$work_real")"
assert_contains     "$out" "$mono_real/a.md  (imported by $mono_real/CLAUDE.md)" "the denied mid-chain import is listed"
assert_not_contains "$out" "b.md"                                                  "  -> and its own imports are not reached (they surface once it is granted)"


# ---------------------------------------------------------------------------
echo "a symlinked ancestor CLAUDE.md has BOTH sides' imports checked"
# ---------------------------------------------------------------------------
# Which side the agent resolves a symlinked CLAUDE.md's own imports against depends on
# per-project approval state (see check_claude_context_file), so both must be followed.
make_workspace ancsym
target_dir="$TMPDIR/ancsym/shared/common"; mkdir -p "$target_dir"
printf '@Guidelines.md\n'  > "$target_dir/CLAUDE.md"
printf 'target side\n'     > "$target_dir/Guidelines.md"
printf 'link side\n'       > "$mono_real/Guidelines.md"
ln -s "$target_dir/CLAUDE.md" "$mono_real/CLAUDE.md"
target_dir_real="$(realpath "$target_dir")"
deny "$mono_real/Guidelines.md" "$target_dir_real/Guidelines.md"

out="$(unreadable_claude_context_paths "$work_real")"
assert_contains "$out" "$mono_real/Guidelines.md  (imported by $mono_real/CLAUDE.md)"           "the denied import beside the link is listed"
assert_contains "$out" "$target_dir_real/Guidelines.md  (imported by $target_dir_real/CLAUDE.md)" "the denied import beside the resolved target is listed"


# ---------------------------------------------------------------------------
echo "an imported file that is a symlink resolves ITS imports beside its real target"
# ---------------------------------------------------------------------------
# Nested hops are not ambiguous: Claude Code canonicalizes each import before recursing into
# it (verified on 2.1.218), so the decoy beside the link must not even be probed.
make_workspace nestsym
elsewhere="$TMPDIR/nestsym/elsewhere"; mkdir -p "$elsewhere"
printf '@sub.md\n'  > "$mono_real/CLAUDE.md"
printf '@deep.md\n' > "$elsewhere/sub.md"
printf 'd\n'        > "$elsewhere/deep.md"
printf 'decoy\n'    > "$mono_real/deep.md"
ln -s "$elsewhere/sub.md" "$mono_real/sub.md"
elsewhere_real="$(realpath "$elsewhere")"
deny "$elsewhere_real/deep.md" "$mono_real/deep.md"

out="$(unreadable_claude_context_paths "$work_real")"
assert_contains     "$out" "$elsewhere_real/deep.md  (imported by $elsewhere_real/sub.md)" "the nested import beside the real target is checked"
assert_not_contains "$out" "$mono_real/deep.md"                                              "the same-named file beside the mid-chain link is not probed"


# ---------------------------------------------------------------------------
echo "a denied path reachable from two context files is listed once"
# ---------------------------------------------------------------------------
make_workspace dup
shared_notes="$TMPDIR/dup-shared"; mkdir -p "$shared_notes" "$mono_real/.claude"
printf 'g\n' > "$shared_notes/g.md"
printf '@%s/g.md\n' "$shared_notes" > "$mono_real/CLAUDE.md"
printf '@%s/g.md\n' "$shared_notes" > "$mono_real/.claude/CLAUDE.md"
deny "$shared_notes/g.md"

out="$(unreadable_claude_context_paths "$work_real")"
listed="$(printf '%s\n' "$out" | grep -c 'dup-shared/g.md')"
assert_eq "$listed" "1" "the shared denied import is listed once"


# ---------------------------------------------------------------------------
echo "each of two links to one context file has its own side's imports checked"
# ---------------------------------------------------------------------------
# A relative import resolves beside the importing link, so two links to one target still
# have two distinct link-side import sets to check.
make_workspace twolinks
shared_ctx_dir="$TMPDIR/twolinks-shared"; mkdir -p "$shared_ctx_dir" "$mono_real/.claude"
printf '@notes.md\n' > "$shared_ctx_dir/CLAUDE.md"
printf 'n\n'         > "$mono_real/notes.md"
printf 'n\n'         > "$mono_real/.claude/notes.md"
ln -s "$shared_ctx_dir/CLAUDE.md" "$mono_real/CLAUDE.md"
ln -s "$shared_ctx_dir/CLAUDE.md" "$mono_real/.claude/CLAUDE.md"
deny "$mono_real/notes.md" "$mono_real/.claude/notes.md"

out="$(unreadable_claude_context_paths "$work_real")"
assert_contains "$out" "$mono_real/notes.md  (imported by $mono_real/CLAUDE.md)" "the first link's denied import is listed"
assert_contains "$out" "$mono_real/.claude/notes.md  (imported by $mono_real/.claude/CLAUDE.md)" "the second link's denied import is listed too"


# ---------------------------------------------------------------------------
echo "the workspace's own CLAUDE.md imports are checked too"
# ---------------------------------------------------------------------------
# safehouse covers the file itself, but its imports may resolve outside the workspace.
make_workspace own
printf '@../shared.md\n' > "$work_real/CLAUDE.md"
printf 's\n' > "$mono_real/shared.md"
deny "$work_real/../shared.md"

out="$(unreadable_claude_context_paths "$work_real")"
assert_contains "$out" "$work_real/../shared.md  (imported by $work_real/CLAUDE.md)" "the workspace CLAUDE.md's denied outside-the-workspace import is listed"


# ---------------------------------------------------------------------------
echo "a symlinked context file with an unreadable target has that target named"
# ---------------------------------------------------------------------------
make_workspace symdeny
shared_ctx="$TMPDIR/symdeny-shared"; mkdir -p "$shared_ctx"
printf 'x\n' > "$shared_ctx/CLAUDE.md"
ln -s "$shared_ctx/CLAUDE.md" "$mono_real/CLAUDE.md"
deny "$mono_real/CLAUDE.md"

out="$(unreadable_claude_context_paths "$work_real")"
assert_contains "$out" "$shared_ctx/CLAUDE.md  (symlink target of $mono_real/CLAUDE.md)" "the denied file is listed by its target, naming the link"

err="$(refuse_unreadable_claude_context "$work_real" 2>&1)"; rc=$?
assert_nonzero  "$rc" "the refusal gate fails"
assert_contains "$err" "$shared_ctx/CLAUDE.md  (symlink target of $mono_real/CLAUDE.md)" "  -> the message names the target, and the link it came from"
assert_not_contains "$err" "a grant cannot cover an @-import" "  -> without the import-only isolation-zone note"


# ---------------------------------------------------------------------------
echo "a relative link target is joined onto the link's directory"
# ---------------------------------------------------------------------------
make_workspace relsym
mkdir -p "$mono_real/common"
printf 'x\n' > "$mono_real/common/CLAUDE.md"
ln -s common/CLAUDE.md "$mono_real/CLAUDE.md"
deny "$mono_real/CLAUDE.md"

out="$(unreadable_claude_context_paths "$work_real")"
assert_contains "$out" "$mono_real/common/CLAUDE.md  (symlink target of $mono_real/CLAUDE.md)" "the target is named as an absolute path"


# ---------------------------------------------------------------------------
echo "a denied file behind a symlinked .claude dir is listed at its joined target path"
# ---------------------------------------------------------------------------
make_workspace dirsym
shared_dir="$TMPDIR/dirsym-shared"; mkdir -p "$shared_dir"
printf 'x\n' > "$shared_dir/CLAUDE.md"
ln -s "$shared_dir" "$mono_real/.claude"
deny "$mono_real/.claude/CLAUDE.md"

out="$(unreadable_claude_context_paths "$work_real")"
assert_contains "$out" "$shared_dir/CLAUDE.md  (via the symlink at $mono_real/.claude)" "the denied path is rebased onto the link's target, naming the link"


# ---------------------------------------------------------------------------
echo "a context file the sandbox itself denies is skipped, not refused"
# ---------------------------------------------------------------------------
# Such a denial is chopi's own design at work -- worktree isolation denies context files
# inside the enclosing repo (e.g. the repo root's CLAUDE.md from a linked worktree). The
# agent runs without the file, so it must not refuse the run, and its imports are moot.
# Every context filename gets the same treatment, so .claude/CLAUDE.md is covered too.
make_workspace ctx
mkdir -p "$mono_real/.claude"
printf '@notes.md\n'     > "$mono_real/CLAUDE.md"
printf 'n\n'             > "$mono_real/notes.md"
printf '@dot-notes.md\n' > "$mono_real/.claude/CLAUDE.md"
printf 'n\n'             > "$mono_real/.claude/dot-notes.md"
deny "$mono_real/CLAUDE.md" "$mono_real/notes.md" \
     "$mono_real/.claude/CLAUDE.md" "$mono_real/.claude/dot-notes.md"

out="$(unreadable_claude_context_paths "$work_real")"
assert_eq "$out" "" "neither the denied context files nor their imports are reported"


# ---------------------------------------------------------------------------
summary

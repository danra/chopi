#!/usr/bin/env bash
#
# test/claude-context-reads.sh -- unit tests for the Claude context read profile

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
. "$repo/.internal/util.sh"
. "$repo/.internal/claude-context-reads.sh"
. "$repo/test/lib.sh"

header "test/claude-context-reads.sh -- unit tests for the Claude context read profile"

# Exported so any temporaries land here too.
TMPDIR="$(mktemp -d)"; export TMPDIR
trap 'rm -rf "$TMPDIR"' EXIT

# Emit the profile for RUN_DIR and print its contents.
claude_context_reads_profile() {
    arity 1
    local run_dir="$1"
    local out="$TMPDIR/profile.sb"
    write_claude_context_reads_profile "$out" "$run_dir" || return 1
    cat "$out"
}

make_workspace() {
    arity 1
    work="$TMPDIR/$1/mono/pkg"; mkdir -p "$work"
    work_real="$(realpath "$work")"
    mono_real="$(dirname "$work_real")"
}

build_profile() {
    arity 1
    profile="$(claude_context_reads_profile "$work")"
    assert_zero "$?" "writing the profile exits zero ($1)"
}

# Captured exit codes below rely on errexit being off.
set +e


# ---------------------------------------------------------------------------
echo "a nested workspace grants CLAUDE.md reads on every ancestor, not the workspace"
# ---------------------------------------------------------------------------
make_workspace real
real_real="$(dirname "$mono_real")"
tmp_real="$(dirname "$real_real")"
printf 'x\n' > "$work_real/CLAUDE.md"
printf 'x\n' > "$mono_real/CLAUDE.md"
printf 'x\n' > "$real_real/CLAUDE.md"

build_profile "a nested workspace"

assert_contains     "$profile" '(allow file-read* (literal "'"$mono_real"'/CLAUDE.md"))' "the immediate parent's CLAUDE.md is granted"
assert_contains     "$profile" '(allow file-read* (literal "'"$real_real"'/CLAUDE.md"))' "a grandparent's CLAUDE.md is granted"
assert_not_contains "$profile" '(allow file-read* (literal "'"$tmp_real"'/CLAUDE.md"))'  "an ancestor with no CLAUDE.md gets no rule -- only files actually there are granted"
assert_not_contains "$profile" '(allow file-read* (literal "'"$work_real"'/CLAUDE.md"))' "the workspace's OWN CLAUDE.md is not (re)granted -- the workspace subpath already covers it"
assert_not_contains "$profile" 'file-write'                                              "the grants never open a write hole"


# ---------------------------------------------------------------------------
echo "a symlinked ancestor CLAUDE.md grants only the link path, NOT its real target"
# ---------------------------------------------------------------------------
make_workspace link
mkdir -p "$TMPDIR/link/shared"
target="$TMPDIR/link/shared/CLAUDE.md"; printf 'x\n' > "$target"
target_real="$(realpath "$target")"
ln -s "$target" "$mono_real/CLAUDE.md"

build_profile "a symlinked ancestor CLAUDE.md"
assert_contains     "$profile" '(allow file-read* (literal "'"$mono_real"'/CLAUDE.md"))' "the symlink path itself is still granted"
assert_not_contains "$profile" '(allow file-read* (literal "'"$target_real"'"))'         "the symlink's real target is NOT granted"


# ---------------------------------------------------------------------------
echo "a symlinked workspace CLAUDE.md does NOT get its real target granted"
# ---------------------------------------------------------------------------
# The workspace CLAUDE.md is agent-plantable: auto-granting a symlink's target would let
# one run mint read access anywhere for the next.
make_workspace ownsym
target_dir="$TMPDIR/ownsym/shared"; mkdir -p "$target_dir"
printf 'x\n' > "$target_dir/CLAUDE.md"
target_real="$(realpath "$target_dir/CLAUDE.md")"
ln -s "$target_dir/CLAUDE.md" "$work_real/CLAUDE.md"

build_profile "a symlinked workspace CLAUDE.md"
assert_not_contains "$profile" "$target_real"         "the symlinked workspace CLAUDE.md's real target is NOT granted"
assert_not_contains "$profile" "$work_real/CLAUDE.md" "the workspace's own CLAUDE.md gets no rule at all -- the workspace grant already covers it"


# ---------------------------------------------------------------------------
echo ".claude/CLAUDE.md is discovered at every ancestor"
# ---------------------------------------------------------------------------
make_workspace dot
mkdir -p "$mono_real/.claude"
printf 'x\n' > "$mono_real/.claude/CLAUDE.md"

build_profile "a .claude/CLAUDE.md ancestor"
assert_contains     "$profile" '(allow file-read* (literal "'"$mono_real"'/.claude/CLAUDE.md"))' "an ancestor's .claude/CLAUDE.md is granted"
assert_not_contains "$profile" '(allow file-read* (literal "/.claude/CLAUDE.md"))'               "a nonexistent .claude/CLAUDE.md gets no rule"


# ---------------------------------------------------------------------------
echo "when BOTH .claude AND its CLAUDE.md are symlinks, only the IN-PATH link node is granted"
# ---------------------------------------------------------------------------
# Only nodes sitting on the ancestry path get grants; anything past the first resolution is
# the in-sandbox check's business, where denials surface one user grant at a time.
make_workspace bothsym
shared="$TMPDIR/bothsym/shared-claude"; elsewhere="$TMPDIR/bothsym/elsewhere"
mkdir -p "$shared" "$elsewhere"
printf 'x\n' > "$elsewhere/CLAUDE.md"
shared_real="$(realpath "$shared")"
elsewhere_real="$(realpath "$elsewhere")"
ln -s "$elsewhere/CLAUDE.md" "$shared/CLAUDE.md"
ln -s "$shared" "$mono_real/.claude"

build_profile "a symlinked .claude directory holding a symlinked CLAUDE.md"
assert_contains     "$profile" '(allow file-read-metadata (literal "'"$mono_real"'/.claude"))' "resolving the .claude link node is granted"
assert_not_contains "$profile" "$shared_real/CLAUDE.md"                                        "the chain is NOT followed: the inner link node (past the ancestry path) gets no grant"
assert_not_contains "$profile" '(allow file-read* (literal "'"$elsewhere_real"'/CLAUDE.md"))'  "the canonical CLAUDE.md is NOT granted"


# ---------------------------------------------------------------------------
summary

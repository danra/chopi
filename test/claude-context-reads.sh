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

build_profile "a nested workspace"

assert_contains     "$profile" '(allow file-read* (literal "'"$mono_real"'/CLAUDE.md"))'  "the immediate parent's CLAUDE.md is granted"
assert_contains     "$profile" '(allow file-read* (literal "'"$real_real"'/CLAUDE.md"))'  "a grandparent's CLAUDE.md is granted"
assert_contains     "$profile" '(allow file-read* (literal "/CLAUDE.md"))'                "the filesystem root's CLAUDE.md is granted"
assert_not_contains "$profile" '(allow file-read* (literal "'"$work_real"'/CLAUDE.md"))'  "the workspace's OWN CLAUDE.md is not (re)granted -- the workspace subpath already covers it"
assert_contains     "$profile" 'allow file-read*'                                         "the grants are read-only"
assert_not_contains "$profile" 'file-write'                                               "  -> and never open a write hole"


# ---------------------------------------------------------------------------
echo "a symlinked ancestor CLAUDE.md also grants a read on the link's real target"
# ---------------------------------------------------------------------------
# Seatbelt matches the kernel-resolved real path, so granting only the symlink literal
# leaves the actual file it points at denied; the profile must grant the target too.
make_workspace link
mkdir -p "$TMPDIR/link/shared"
target="$TMPDIR/link/shared/CLAUDE.md"; printf 'x\n' > "$target"
target_real="$(realpath "$target")"
ln -s "$target" "$mono_real/CLAUDE.md"

build_profile "a symlinked ancestor CLAUDE.md"
assert_contains "$profile" '(allow file-read* (literal "'"$mono_real"'/CLAUDE.md"))' "the symlink path itself is still granted"
assert_contains "$profile" '(allow file-read* (literal "'"$target_real"'"))'         "the symlink's real target file is granted"


# ---------------------------------------------------------------------------
echo "an ancestor CLAUDE.md's @-import is granted (plain file, path relative to it)"
# ---------------------------------------------------------------------------
# A CLAUDE.md may pull in sibling files with @-import syntax; the agent must be able to read
# those too, resolved relative to the importing file's own directory.
make_workspace imp
printf '@shared/guide.md\n' > "$mono_real/CLAUDE.md"
mkdir -p "$mono_real/shared"; printf 'g\n' > "$mono_real/shared/guide.md"

build_profile "an @-importing ancestor CLAUDE.md"
assert_contains "$profile" '(allow file-read* (literal "'"$mono_real"'/CLAUDE.md"))'       "the ancestor CLAUDE.md itself is still granted"
assert_contains "$profile" '(allow file-read* (literal "'"$mono_real"'/shared/guide.md"))' "its @-import is granted, resolved relative to the CLAUDE.md's directory"


# ---------------------------------------------------------------------------
echo "an @-import that is itself a symlink grants a read on the link's real target"
# ---------------------------------------------------------------------------
make_workspace impsym
printf '@link.md\n' > "$mono_real/CLAUDE.md"
mkdir -p "$TMPDIR/impsym/elsewhere"
target="$TMPDIR/impsym/elsewhere/actual.md"; printf 'a\n' > "$target"
target_real="$(realpath "$target")"
ln -s "$target" "$mono_real/link.md"

build_profile "a symlinked @-import"
assert_contains "$profile" '(allow file-read* (literal "'"$target_real"'"))' "the symlinked @-import's real target is granted"
assert_contains "$profile" '(allow file-read-metadata (literal "'"$mono_real"'/link.md"))' "resolving the import's own link node is granted"


# ---------------------------------------------------------------------------
echo "@-imports are followed recursively (an import that imports another)"
# ---------------------------------------------------------------------------
make_workspace imprec
printf '@a.md\n'   > "$mono_real/CLAUDE.md"
printf '@b.md\n'   > "$mono_real/a.md"
printf 'deepest\n' > "$mono_real/b.md"

build_profile "a recursive @-import chain"
assert_contains "$profile" '(allow file-read* (literal "'"$mono_real"'/a.md"))' "the first-level @-import is granted"
assert_contains "$profile" '(allow file-read* (literal "'"$mono_real"'/b.md"))' "the transitive @-import (import-of-an-import) is granted"


# ---------------------------------------------------------------------------
echo "@-imports are granted regardless of location (absolute path outside the ancestor tree)"
# ---------------------------------------------------------------------------
make_workspace impabs
mkdir -p "$TMPDIR/impabs-elsewhere"
far="$TMPDIR/impabs-elsewhere/notes.md"; printf 'n\n' > "$far"
far_real="$(realpath "$far")"
printf '@%s\n' "$far_real" > "$mono_real/CLAUDE.md"

build_profile "an absolute-path @-import"
assert_contains "$profile" '(allow file-read* (literal "'"$far_real"'"))' "an @-import pointing outside the ancestor tree is granted"


# ---------------------------------------------------------------------------
echo "a symlinked ancestor CLAUDE.md gets its @-imports granted beside the link AND the target"
# ---------------------------------------------------------------------------
# Which side the agent resolves a symlinked CLAUDE.md's own imports against depends on
# per-project approval state (see grant_claude_md_imports), so the profile must grant both.
make_workspace ancsym
target_dir="$TMPDIR/ancsym/shared/common"; mkdir -p "$target_dir"
printf '@Guidelines.md\n'  > "$target_dir/CLAUDE.md"
printf 'target side\n'     > "$target_dir/Guidelines.md"
target_guide_real="$(realpath "$target_dir/Guidelines.md")"
printf 'link side\n'       > "$mono_real/Guidelines.md"
ln -s "$target_dir/CLAUDE.md" "$mono_real/CLAUDE.md"

build_profile "a symlinked ancestor CLAUDE.md with imports on both sides"
assert_contains "$profile" '(allow file-read* (literal "'"$mono_real"'/Guidelines.md"))' "the import beside the link is granted"
assert_contains "$profile" '(allow file-read* (literal "'"$target_guide_real"'"))'       "the import beside the real target is granted"


# ---------------------------------------------------------------------------
echo "the workspace's own CLAUDE.md gets its @-imports granted too"
# ---------------------------------------------------------------------------
# safehouse covers the file itself, but its imports may resolve outside.
make_workspace own
printf '@../shared.md\n' > "$work_real/CLAUDE.md"
printf 's\n' > "$mono_real/shared.md"

build_profile "an @-importing workspace CLAUDE.md"
assert_contains     "$profile" '(allow file-read* (literal "'"$mono_real"'/shared.md"))'  "the workspace CLAUDE.md's outside-the-workspace import is granted"
assert_not_contains "$profile" '(allow file-read* (literal "'"$work_real"'/CLAUDE.md"))'  "the workspace's OWN CLAUDE.md is still not (re)granted"


# ---------------------------------------------------------------------------
echo "a symlinked workspace CLAUDE.md walks its @-imports beside the link and the target"
# ---------------------------------------------------------------------------
# The link-side walk matters even though link-side paths sit under the workspace grant: an
# import that is itself a symlink pointing outside the workspace needs its real target granted.
make_workspace ownsym
target_dir="$TMPDIR/ownsym/shared"; mkdir -p "$target_dir"
printf '@sub.md\n'     > "$target_dir/CLAUDE.md"
printf 'target side\n' > "$target_dir/sub.md"
target_real="$(realpath "$target_dir/CLAUDE.md")"
target_sub_real="$(realpath "$target_dir/sub.md")"
mkdir -p "$TMPDIR/ownsym/elsewhere"
sub_target="$TMPDIR/ownsym/elsewhere/actual.md"; printf 'a\n' > "$sub_target"
sub_target_real="$(realpath "$sub_target")"
ln -s "$target_dir/CLAUDE.md" "$work_real/CLAUDE.md"
ln -s "$sub_target" "$work_real/sub.md"

build_profile "a symlinked workspace CLAUDE.md"
assert_contains "$profile" '(allow file-read* (literal "'"$target_real"'"))'     "the symlinked workspace CLAUDE.md's real target is granted"
assert_contains "$profile" '(allow file-read* (literal "'"$sub_target_real"'"))' "the real target of the import beside the link is granted"
assert_contains "$profile" '(allow file-read* (literal "'"$target_sub_real"'"))' "the import beside the CLAUDE.md's real target is granted"


# ---------------------------------------------------------------------------
echo "an imported file that is a symlink resolves ITS imports beside its real target"
# ---------------------------------------------------------------------------
# Unlike a CLAUDE.md's own imports, nested hops resolve beside the importing file's REAL
# location: the agent canonicalizes each import before recursing into it (verified against
# Claude Code 2.1.218).
make_workspace nestsym
elsewhere="$TMPDIR/nestsym/elsewhere"; mkdir -p "$elsewhere"
printf '@sub.md\n'  > "$mono_real/CLAUDE.md"
printf '@deep.md\n' > "$elsewhere/sub.md"
printf 'd\n'        > "$elsewhere/deep.md"
printf 'decoy\n'    > "$mono_real/deep.md"
deep_real="$(realpath "$elsewhere/deep.md")"
ln -s "$elsewhere/sub.md" "$mono_real/sub.md"

build_profile "a symlinked mid-chain @-import"
assert_contains     "$profile" '(allow file-read* (literal "'"$deep_real"'"))'           "the nested import beside the mid-chain file's real target is granted"
assert_contains     "$profile" '(allow file-read-metadata (literal "'"$mono_real"'/sub.md"))' "resolving the mid-chain import's own link node is granted"
assert_not_contains "$profile" '(allow file-read* (literal "'"$mono_real"'/deep.md"))'   "the same-named file beside the mid-chain link is not granted"


# ---------------------------------------------------------------------------
summary

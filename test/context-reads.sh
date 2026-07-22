#!/usr/bin/env bash
#
# test/context-reads.sh -- unit tests for the ancestor context-file read profile

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
. "$repo/.internal/util.sh"
. "$repo/.internal/context-reads.sh"
. "$repo/test/lib.sh"

header "test/context-reads.sh -- unit tests for the ancestor context-file read profile"

# Exported so any temporaries land here too.
TMPDIR="$(mktemp -d)"; export TMPDIR
trap 'rm -rf "$TMPDIR"' EXIT

# Emit the profile for RUN_DIR and print its contents.
context_reads_profile() {
    arity 1
    local run_dir="$1"
    local out="$TMPDIR/profile.sb"
    write_context_reads_profile "$out" "$run_dir" || return 1
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
    profile="$(context_reads_profile "$work")"
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
summary

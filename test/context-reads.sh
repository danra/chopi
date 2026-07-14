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

# Captured exit codes below rely on errexit being off.
set +e


# ---------------------------------------------------------------------------
echo "a nested workspace grants CLAUDE.md reads on every ancestor, not the workspace"
# ---------------------------------------------------------------------------
work="$TMPDIR/real/mono/pkg"; mkdir -p "$work"
work_real="$(realpath "$work")"
mono_real="$(dirname "$work_real")"
real_real="$(dirname "$mono_real")"

profile="$(context_reads_profile "$work")"; st=$?
assert_zero "$st" "writing the profile exits zero"

assert_contains     "$profile" '(allow file-read* (literal "'"$mono_real"'/CLAUDE.md"))'  "the immediate parent's CLAUDE.md is granted"
assert_contains     "$profile" '(allow file-read* (literal "'"$real_real"'/CLAUDE.md"))'  "a grandparent's CLAUDE.md is granted"
assert_contains     "$profile" '(allow file-read* (literal "/CLAUDE.md"))'                "the filesystem root's CLAUDE.md is granted"
assert_not_contains "$profile" '(allow file-read* (literal "'"$work_real"'/CLAUDE.md"))'  "the workspace's OWN CLAUDE.md is not (re)granted -- the workspace subpath already covers it"
assert_contains     "$profile" 'allow file-read*'                                         "the grants are read-only"
assert_not_contains "$profile" 'file-write'                                               "  -> and never open a write hole"


# ---------------------------------------------------------------------------
summary

#!/usr/bin/env bash
#
# test/git-protect-cleanup.sh -- unit tests for the teardown abort of in-progress rebases and
# cherry-pick/revert sequences. Runs real git operations in scratch repos; no sandbox needed.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
. "$repo/.internal/util.sh"
. "$repo/test/lib.sh"

header "test/git-protect-cleanup.sh -- unit tests for the in-progress-op teardown abort"

command -v git >/dev/null 2>&1 || { echo "error: git not on PATH" >&2; exit 1; }

cleanup_sh="$repo/.internal/git-protect-cleanup.sh"

# The cleanup script acts on its current directory, so run it from the target worktree.
run_cleanup() { ( cd "$1" && "$cleanup_sh" ); }

TMPDIR="$(mktemp -d)"; export TMPDIR
trap 'rm -rf "$TMPDIR"' EXIT

# Isolate git from the developer's config so the fixtures are reproducible.
isolate_git_config

# Captured exit codes below rely on errexit being off.
set +e


# ---------------------------------------------------------------------------
echo "a clean worktree: the abort is a silent no-op"
# ---------------------------------------------------------------------------
clean="$TMPDIR/clean"; make_repo "$clean"
out="$(run_cleanup "$clean" 2>&1)"; st=$?
assert_zero "$st" "exits zero on a clean repo"
assert_eq "$out" "" "  -> printing nothing (no operation to abort)"


# ---------------------------------------------------------------------------
echo "a stopped rebase is aborted and the worktree restored"
# ---------------------------------------------------------------------------
r="$TMPDIR/rebasing"; make_repo "$r"
stop_a_rebase_in "$r"
assert_eq "$(in_progress "$r")" "rebase" "fixture: a rebase is in progress"
out="$(run_cleanup "$r" 2>&1)"; st=$?
assert_zero "$st" "the abort script exits zero"
assert_eq "$(in_progress "$r")" "" "  -> no rebase remains in progress"
assert_contains "$out" "aborted" "  -> it reports what it did"
assert_contains "$out" "rebase" "  -> naming the operation"
assert_eq "$(git -C "$r" symbolic-ref --short HEAD)" "_sideB" "  -> back on the pre-rebase branch"


# ---------------------------------------------------------------------------
echo "a stopped cherry-pick sequence is aborted"
# ---------------------------------------------------------------------------
c="$TMPDIR/cherrypicking"; make_repo "$c"
stop_a_cherry_pick_in "$c"
assert_eq "$(in_progress "$c")" "sequencer" "fixture: a cherry-pick sequence is in progress"
out="$(run_cleanup "$c" 2>&1)"; st=$?
assert_zero "$st" "the abort script exits zero"
assert_eq "$(in_progress "$c")" "" "  -> no sequence remains in progress"
assert_contains "$out" "sequence" "  -> reporting the aborted sequence"


# ---------------------------------------------------------------------------
echo "a stopped revert sequence is aborted (cherry-pick --abort tears a revert down too)"
# ---------------------------------------------------------------------------
v="$TMPDIR/reverting"; make_repo "$v"
stop_a_revert_in "$v"
assert_eq "$(in_progress "$v")" "sequencer" "fixture: a revert sequence is in progress"
out="$(run_cleanup "$v" 2>&1)"; st=$?
assert_zero "$st" "the abort script exits zero"
assert_eq "$(in_progress "$v")" "" "  -> no sequence remains in progress"
assert_contains "$out" "sequence" "  -> reporting the aborted sequence"


# ---------------------------------------------------------------------------
echo "a rebase stopped in a LINKED worktree is aborted when run from it"
# ---------------------------------------------------------------------------
lw="$TMPDIR/linked_repo"; make_repo "$lw"
wt="$TMPDIR/linked_wt"
git -C "$lw" worktree add -q "$wt" -b wtb >/dev/null 2>&1
stop_a_rebase_in "$wt"
assert_eq "$(in_progress "$wt")" "rebase" "fixture: a rebase is in progress in the linked worktree"
out="$(run_cleanup "$wt" 2>&1)"; st=$?
assert_zero "$st" "the abort script exits zero"
assert_eq "$(in_progress "$wt")" "" "  -> the linked worktree's rebase is aborted"


# ---------------------------------------------------------------------------
echo "a rebase left inside a SUBMODULE is aborted from the superproject"
# ---------------------------------------------------------------------------
sub_src="$TMPDIR/sub_src"; make_repo "$sub_src"
super="$TMPDIR/super"; make_repo "$super"
env "${allow_git_file_protocol[@]}" git -C "$super" submodule add -q "$sub_src" thesub 2>/dev/null
git -C "$super" commit -q -m 'add submodule'
stop_a_rebase_in "$super/thesub"
assert_eq "$(in_progress "$super/thesub")" "rebase" "fixture: a rebase is in progress in the submodule"
out="$(run_cleanup "$super" 2>&1)"; st=$?
assert_zero "$st" "the abort script exits zero"
assert_eq "$(in_progress "$super/thesub")" "" "  -> the submodule's rebase is aborted too"


# ---------------------------------------------------------------------------
echo "if submodule enumeration fails, the top-level op is still aborted and a warning is shown"
# ---------------------------------------------------------------------------
sub_src2="$TMPDIR/sub_src2"; make_repo "$sub_src2"
super2="$TMPDIR/super2"; make_repo "$super2"
env "${allow_git_file_protocol[@]}" git -C "$super2" submodule add -q "$sub_src2" thesub 2>/dev/null
git -C "$super2" commit -q -m 'add submodule'
stop_a_rebase_in "$super2"                # a rebase paused in the superproject itself
rm -rf "$super2/.git/modules/thesub"      # break the submodule so `submodule foreach` fails
assert_eq "$(in_progress "$super2")" "rebase" "fixture: a rebase is in progress in the superproject"
out="$(run_cleanup "$super2" 2>&1)"; st=$?
assert_zero "$st" "the abort script still exits zero (best-effort)"
assert_eq "$(in_progress "$super2")" "" "  -> the superproject's rebase is still aborted (checked before submodules)"
assert_contains "$out" "WARNING" "  -> and it warns"
assert_contains "$out" "could not enumerate the submodules" "  -> that submodules could not be enumerated"


# ---------------------------------------------------------------------------
summary

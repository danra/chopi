#!/usr/bin/env bash
#
# test/git-preflight.sh -- unit tests for the git refusal checks

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
. "$repo/.internal/util.sh"
. "$repo/test/lib.sh"

header "test/git-preflight.sh -- unit tests for the git refusal checks"

command -v git >/dev/null 2>&1 || { echo "error: git not on PATH" >&2; exit 1; }

git_preflight_sh="$repo/.internal/git-preflight.sh"

# Exported so the scripts under test leave their temporaries here too.
TMPDIR="$(mktemp -d)"; export TMPDIR
trap 'rm -rf "$TMPDIR"' EXIT

# Isolate git from the developer's config so the fixtures are reproducible.
isolate_git_config

run_preflight_in_dir() {
    local dir="$1"; shift
    (cd "$dir" && "$git_preflight_sh" "$@" 2>&1)
}

# Captured exit codes below rely on errexit being off.
set +e


# ---------------------------------------------------------------------------
echo "only a git worktree root is accepted; a supported repo at its root passes"
# ---------------------------------------------------------------------------
plain="$TMPDIR/plain"; mkdir -p "$plain"
out="$(run_preflight_in_dir "$plain")"; st=$?
assert_nonzero "$st" "a non-git dir is refused"
assert_contains "$out" "not the root of a git worktree" "  -> naming the cause"

repo_with_subdir="$TMPDIR/repo_with_subdir"; make_repo "$repo_with_subdir"
mkdir -p "$repo_with_subdir/sub/deep"
out="$(run_preflight_in_dir "$repo_with_subdir/sub/deep")"; st=$?
assert_nonzero "$st" "a subdir of a worktree is refused"
assert_has_line "$out" "$(realpath "$repo_with_subdir")" "  -> pointing at the enclosing worktree root"

standard_repo="$TMPDIR/standard_repo"; make_repo "$standard_repo"
gitdir="$(realpath "$standard_repo/.git")"
out="$(run_preflight_in_dir "$standard_repo")"; st=$?
assert_zero "$st" "a supported repo exits zero"
assert_eq "$out" "" "  -> silently (nothing is printed on success)"


# ---------------------------------------------------------------------------
echo "an inherited git-location env is refused inside a repo, never followed outside"
# ---------------------------------------------------------------------------
out="$(cd "$standard_repo" && \
    GIT_DIR="$gitdir" \
    GIT_COMMON_DIR="$TMPDIR/bogus-common" \
    GIT_REFERENCE_BACKEND="reftable://$TMPDIR/bogus-refs" \
    "$git_preflight_sh" 2>&1)"; st=$?
assert_nonzero "$st" "an inherited git env is refused (non-zero exit)"
assert_contains "$out" "GIT_DIR"               "  -> GIT_DIR is named in the error"
assert_contains "$out" "GIT_COMMON_DIR"        "  -> GIT_COMMON_DIR is named in the error"
assert_contains "$out" "GIT_REFERENCE_BACKEND" "  -> GIT_REFERENCE_BACKEND is named in the error"

# Set-but-empty is refused too: git treats an empty and an unset location var differently
out="$(cd "$standard_repo" && env GIT_DIR= "$git_preflight_sh" 2>&1)"; st=$?
assert_nonzero "$st" "a set-but-empty GIT_DIR is refused too"

# Outside of a repo the location vars are never followed: the worktree-root check scrubs
# them, so the dir is refused as non-root rather than resolved through GIT_DIR.
out="$(cd "$plain" && env GIT_DIR="$gitdir" "$git_preflight_sh" 2>&1)"; st=$?
assert_nonzero "$st" "GIT_DIR pointing at a repo from a non-git dir is still refused"
assert_contains "$out" "not the root of a git worktree" "  -> as non-root (GIT_DIR is not followed)"


# ---------------------------------------------------------------------------
echo "repo-file location overrides are refused, not silently skipped"
# ---------------------------------------------------------------------------

# Refuse on main worktree steered by core.worktree config
steer_target="$TMPDIR/steer-target"; mkdir -p "$steer_target"
repo_steered="$TMPDIR/repo_steered"; make_repo "$repo_steered"
steered_wt="$TMPDIR/steered_wt"
git -C "$repo_steered" worktree add -q -b steered_wt "$steered_wt"
git -C "$repo_steered" config core.worktree "$steer_target"
out="$(run_preflight_in_dir "$repo_steered")"; st=$?
assert_nonzero "$st" "a core.worktree-steered main worktree is refused (non-zero exit)"
outp="$(cd "$repo_steered" && "$git_preflight_sh" 2>/dev/null)"
assert_eq "$outp" "" "  -> and the error goes to stderr, not stdout"

# Linked worktrees are unaffected by the main config's core.worktree entry
got_core_worktree="$(git -C "$steered_wt" config --get core.worktree)"
assert_eq "$got_core_worktree" "$steer_target" "fixture sanity: the steering value IS visible from the linked worktree"
out="$(run_preflight_in_dir "$steered_wt")"; st=$?
assert_zero "$st" "the steered repo's linked worktree still passes (git ignores the shared core.worktree there)"

repo_bare="$TMPDIR/repo_bare"; make_repo "$repo_bare"
git -C "$repo_bare" config core.bare true
out="$(run_preflight_in_dir "$repo_bare")"; st=$?
assert_nonzero "$st" "core.bare=true with a worktree is refused"

# With extensions.worktreeConfig, the same steering can hide per-worktree in
# config.worktree
repo_worktree_config="$TMPDIR/repoWC"; make_repo "$repo_worktree_config"
git -C "$repo_worktree_config" config extensions.worktreeConfig true
worktree_with_config="$TMPDIR/worktree_with_config"
git -C "$repo_worktree_config" worktree add -q -b wclink "$worktree_with_config"
git -C "$worktree_with_config" config --worktree core.worktree "$steer_target"
out="$(run_preflight_in_dir "$worktree_with_config")"; st=$?
assert_nonzero "$st" "a config.worktree-steered linked worktree is refused"
out="$(run_preflight_in_dir "$repo_worktree_config")"; st=$?
assert_zero "$st" "  -> while the repo's untouched main worktree still passes"

# A .git entry git can't make sense of is refused, whatever the corruption:
# a garbage .git file, a stray non-repo .git dir, a dangling .git symlink.
stray_gitfile="$TMPDIR/stray_gitfile"; mkdir -p "$stray_gitfile"
printf 'not a gitfile\n' > "$stray_gitfile/.git"
out="$(run_preflight_in_dir "$stray_gitfile")"; st=$?
assert_nonzero "$st" "a garbage .git file is refused"
assert_contains "$out" ".git entry" "  -> naming the .git entry"

stray="$repo_with_subdir/stray"
mkdir -p "$stray/.git"
out="$(run_preflight_in_dir "$stray")"; st=$?
assert_nonzero "$st" "a stray non-repo .git dir inside a larger repo is refused (not a silent subdir skip)"
rm -rf "$stray"

stray_gitfile_symlink="$TMPDIR/stray_gitfile_symlink"; mkdir -p "$stray_gitfile_symlink"
ln -s "$TMPDIR/nonexistent-gitdir" "$stray_gitfile_symlink/.git"
out="$(run_preflight_in_dir "$stray_gitfile_symlink")"; st=$?
assert_nonzero "$st" "a dangling .git symlink is refused"


# ---------------------------------------------------------------------------
echo "a non-empty objects/info/alternates is refused; an empty one passes"
# ---------------------------------------------------------------------------
repo_with_alternates="$TMPDIR/repo_with_alternates"; make_repo "$repo_with_alternates"
alternates="$repo_with_alternates/.git/objects/info/alternates"
: > "$alternates"
out="$(run_preflight_in_dir "$repo_with_alternates")"; st=$?
assert_zero "$st" "an EMPTY alternates file is not refused"
printf '%s\n' "$TMPDIR/external-store/objects" > "$alternates"
out="$(run_preflight_in_dir "$repo_with_alternates")"; st=$?
assert_nonzero "$st" "a non-empty alternates file is refused"
assert_contains "$out" "alternates" "  -> naming the alternates file"


# ---------------------------------------------------------------------------
echo "a repo with relocated ref storage (extensions.refStorage URI payload) is refused"
# ---------------------------------------------------------------------------
repo_relocated_refs="$TMPDIR/repo_relocated_refs"; make_repo "$repo_relocated_refs" --ref-format reftable
git -C "$repo_relocated_refs" config extensions.refstorage "reftable://$TMPDIR/elsewhere-refs"
out="$(run_preflight_in_dir "$repo_relocated_refs")"; st=$?
if git -C "$repo_relocated_refs" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    assert_nonzero "$st" "a refStorage reftable with URI payload is refused"
else
    # This git predates the payload syntax and cannot open the repo: discovery fails
    # while the .git entry exists, so the steered-root guard refuses (fail closed).
    assert_nonzero "$st" "a refStorage URI payload on a git predating it is refused via the unresolvable .git"
fi

# A plain reftable is supported
repo_reftable="$TMPDIR/repo_reftable"; make_repo "$repo_reftable" --ref-format reftable
out="$(run_preflight_in_dir "$repo_reftable")"; st=$?
assert_zero "$st" "a plain extensions.refStorage reftable format value is not refused"


# ---------------------------------------------------------------------------
echo "submodules: the location-override sweeps cover the submodule gitdirs"
# ---------------------------------------------------------------------------
submod="$TMPDIR/submod"; make_repo "$submod"
repo_with_submod="$TMPDIR/repo_with_submod"; make_repo "$repo_with_submod"
env "${allow_git_file_protocol[@]}" git -C "$repo_with_submod" submodule add -q "$submod" thesub 2>/dev/null
git -C "$repo_with_submod" commit -q -m 'add submodule'
submod_gitdir="$(realpath "$(git -C "$repo_with_submod/thesub" rev-parse --absolute-git-dir)")"

sub_alternates="$submod_gitdir/objects/info/alternates"
printf '%s\n' "$TMPDIR/external-store/objects" > "$sub_alternates"
out="$(run_preflight_in_dir "$repo_with_submod")"; st=$?
assert_nonzero "$st" "a submodule-gitdir alternates file is refused"
assert_contains "$out" "$submod_gitdir" "  -> naming the submodule's alternates file"
rm -f "$sub_alternates"

git config --file "$submod_gitdir/config" core.repositoryformatversion 1
git config --file "$submod_gitdir/config" extensions.refstorage "reftable://$TMPDIR/elsewhere-sub-refs"
out="$(run_preflight_in_dir "$repo_with_submod")"; st=$?
if git -C "$repo_with_submod/thesub" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    assert_nonzero "$st" "a submodule-gitdir refStorage URI payload is refused"
else
    assert_nonzero "$st" "a submodule refStorage URI payload on a git predating it is refused via enumeration"
fi
git config --file "$submod_gitdir/config" --unset extensions.refstorage
git config --file "$submod_gitdir/config" core.repositoryformatversion 0
out="$(run_preflight_in_dir "$repo_with_submod")"; st=$?
assert_zero "$st" "with the fixtures reverted, the submodule repo passes again"


# ---------------------------------------------------------------------------
echo "the DIR argument selects the checked worktree (as --worktree runs use)"
# ---------------------------------------------------------------------------
out="$(run_preflight_in_dir "$plain" "$repo_with_alternates")"; st=$?
assert_nonzero "$st" "an unsupported repo passed as DIR is refused (the check runs there, not in the cwd)"
out="$(run_preflight_in_dir "$repo_with_alternates" "$standard_repo")"; st=$?
assert_zero "$st" "a supported repo passed as DIR exits zero (whatever the cwd)"


# ---------------------------------------------------------------------------
echo "an in-progress rebase or cherry-pick/revert sequence is refused up front"
# ---------------------------------------------------------------------------
repo_rebasing="$TMPDIR/repo_rebasing"; make_repo "$repo_rebasing"
stop_a_rebase_in "$repo_rebasing"
assert_eq "$(in_progress "$repo_rebasing")" "rebase" "fixture: a rebase is in progress"
out="$(run_preflight_in_dir "$repo_rebasing")"; st=$?
assert_nonzero "$st" "an in-progress rebase is refused"
assert_contains "$out" "rebase" "  -> naming the operation"
git -C "$repo_rebasing" rebase --abort >/dev/null 2>&1
out="$(run_preflight_in_dir "$repo_rebasing")"; st=$?
assert_zero "$st" "  -> and once it's aborted, the repo passes again"

repo_sequencing="$TMPDIR/repo_sequencing"; make_repo "$repo_sequencing"
stop_a_cherry_pick_in "$repo_sequencing"
assert_eq "$(in_progress "$repo_sequencing")" "sequencer" "fixture: a cherry-pick sequence is in progress"
out="$(run_preflight_in_dir "$repo_sequencing")"; st=$?
assert_nonzero "$st" "an in-progress cherry-pick sequence is refused"
assert_contains "$out" "sequence" "  -> naming the operation"

repo_reverting="$TMPDIR/repo_reverting"; make_repo "$repo_reverting"
stop_a_revert_in "$repo_reverting"
assert_eq "$(in_progress "$repo_reverting")" "sequencer" "fixture: a revert sequence is in progress"
out="$(run_preflight_in_dir "$repo_reverting")"; st=$?
assert_nonzero "$st" "an in-progress revert sequence is refused"
assert_contains "$out" "sequence" "  -> naming the operation"

stop_a_rebase_in "$repo_with_submod/thesub"
assert_eq "$(in_progress "$repo_with_submod/thesub")" "rebase" "fixture: a rebase is in progress in the submodule"
out="$(run_preflight_in_dir "$repo_with_submod")"; st=$?
assert_nonzero "$st" "an in-progress rebase inside a submodule is refused"
git -C "$repo_with_submod/thesub" rebase --abort >/dev/null 2>&1
out="$(run_preflight_in_dir "$repo_with_submod")"; st=$?
assert_zero "$st" "  -> and with it aborted, the submodule repo passes again"


# ---------------------------------------------------------------------------
summary

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
echo "a submodule gitdir embedded in its worktree (unabsorbed) is refused"
# ---------------------------------------------------------------------------
embedded_src="$TMPDIR/embedded_src"; make_repo "$embedded_src"
repo_embedded_sub="$TMPDIR/repo_embedded_sub"; make_repo "$repo_embedded_sub"
env "${allow_git_file_protocol[@]}" git -C "$repo_embedded_sub" submodule add -q "$embedded_src" thesub 2>/dev/null
git -C "$repo_embedded_sub" commit -q -m 'add submodule'
# De-absorb the gitdir back into the worktree: the old-style layout absorbgitdirs migrates.
embedded_gitdir="$(realpath "$(git -C "$repo_embedded_sub/thesub" rev-parse --absolute-git-dir)")"
rm "$repo_embedded_sub/thesub/.git"
mv "$embedded_gitdir" "$repo_embedded_sub/thesub/.git"
git config --file "$repo_embedded_sub/thesub/.git/config" --unset core.worktree
out="$(run_preflight_in_dir "$repo_embedded_sub")"; st=$?
assert_nonzero "$st" "an embedded submodule gitdir is refused"
assert_contains "$out" "embeds its git dir" "  -> naming the cause"
assert_contains "$out" "absorbgitdirs" "  -> and the way out"


# ---------------------------------------------------------------------------
echo "the DIR argument selects the checked worktree (as --worktree runs use)"
# ---------------------------------------------------------------------------
out="$(run_preflight_in_dir "$plain" "$repo_with_alternates")"; st=$?
assert_nonzero "$st" "an unsupported repo passed as DIR is refused (the check runs there, not in the cwd)"
out="$(run_preflight_in_dir "$repo_with_alternates" "$standard_repo")"; st=$?
assert_zero "$st" "a supported repo passed as DIR exits zero (whatever the cwd)"


# ---------------------------------------------------------------------------
echo "an in-progress rebase or cherry-pick/revert sequence is refused up front (non-interactive)"
# ---------------------------------------------------------------------------
repo_rebasing="$TMPDIR/repo_rebasing"; make_repo "$repo_rebasing"
stop_a_rebase_in "$repo_rebasing"
assert_eq "$(in_progress "$repo_rebasing")" "rebase" "fixture: a rebase is in progress"
out="$(run_preflight_in_dir "$repo_rebasing")"; st=$?
assert_nonzero "$st" "an in-progress rebase is refused"
assert_contains "$out" "a git rebase is already in progress" "  -> naming the operation"
git -C "$repo_rebasing" rebase --abort >/dev/null 2>&1
out="$(run_preflight_in_dir "$repo_rebasing")"; st=$?
assert_zero "$st" "  -> and once it's aborted, the repo passes again"

repo_sequencing="$TMPDIR/repo_sequencing"; make_repo "$repo_sequencing"
stop_a_cherry_pick_in "$repo_sequencing"
assert_eq "$(in_progress "$repo_sequencing")" "sequencer" "fixture: a cherry-pick sequence is in progress"
out="$(run_preflight_in_dir "$repo_sequencing")"; st=$?
assert_nonzero "$st" "an in-progress cherry-pick sequence is refused"
assert_contains "$out" "a git cherry-pick/revert sequence is already in progress" "  -> naming the operation"

repo_reverting="$TMPDIR/repo_reverting"; make_repo "$repo_reverting"
stop_a_revert_in "$repo_reverting"
assert_eq "$(in_progress "$repo_reverting")" "sequencer" "fixture: a revert sequence is in progress"
out="$(run_preflight_in_dir "$repo_reverting")"; st=$?
assert_nonzero "$st" "an in-progress revert sequence is refused"
assert_contains "$out" "a git cherry-pick/revert sequence is already in progress" "  -> naming the operation"

stop_a_rebase_in "$repo_with_submod/thesub"
assert_eq "$(in_progress "$repo_with_submod/thesub")" "rebase" "fixture: a rebase is in progress in the submodule"
out="$(run_preflight_in_dir "$repo_with_submod")"; st=$?
assert_nonzero "$st" "an in-progress rebase inside a submodule is refused"
git -C "$repo_with_submod/thesub" rebase --abort >/dev/null 2>&1
out="$(run_preflight_in_dir "$repo_with_submod")"; st=$?
assert_zero "$st" "  -> and with it aborted, the submodule repo passes again"


# ---------------------------------------------------------------------------
echo "interactively, the in-progress refusal becomes a [y/N] prompt"
# ---------------------------------------------------------------------------

# Run the preflight in DIR under a pty (so it sees a terminal and prompts), typing ANSWER
# at any prompt; the answer repeats forever so the pty never runs dry mid-ask. The
# preflight's exit status comes back as a "pty-status=N" line in the output: the
# pipeline's own status is useless (`yes` dies of SIGPIPE under pipefail).
preflight_under_pty() {
    arity 2
    local dir="$1" answer="$2"
    # shellcheck disable=SC2016  # $1/$2/$? are for the inner sh, not this shell
    yes "$answer" 2>/dev/null \
        | script -q /dev/null sh -c 'cd "$1" && "$2"; echo "pty-status=$?"' pty "$dir" "$git_preflight_sh" 2>&1 \
        | tr -d '\r'
}

repo_prompting="$TMPDIR/repo_prompting"; make_repo "$repo_prompting"
stop_a_rebase_in "$repo_prompting"

out="$(preflight_under_pty "$repo_prompting" y)"
assert_contains "$out" "a git rebase is already in progress" "an interactive run states the situation"
assert_contains "$out" "[y/N]" "  -> and asks instead of refusing outright"
assert_contains "$out" "pty-status=0" "  -> answering y lets the run proceed"

out="$(preflight_under_pty "$repo_prompting" n)"
assert_contains "$out" "pty-status=1" "answering n refuses"
assert_contains "$out" "error: refusing to run" "  -> saying so"
assert_eq "$(printf '%s\n' "$out" | grep -c 'chopi aborts an in-progress')" 1 \
    "  -> without repeating the rationale the prompt already gave"

out="$(preflight_under_pty "$repo_prompting" '')"
assert_contains "$out" "pty-status=1" "a bare return takes the default and refuses"

out="$(preflight_under_pty "$standard_repo" y)"
assert_contains "$out" "pty-status=0" "a repo with nothing in progress never prompts"
assert_not_contains "$out" "[y/N]" "  -> no prompt appears"


# ---------------------------------------------------------------------------
summary

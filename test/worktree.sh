#!/usr/bin/env bash
#
# test/worktree.sh -- unit tests for the --worktree setup helper

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
. "$repo/.internal/util.sh"
. "$repo/test/lib.sh"

header "test/worktree.sh -- unit tests for the --worktree setup helper"

command -v git >/dev/null 2>&1 || { echo "error: git not on PATH" >&2; exit 1; }

worktree_sh="$repo/.internal/worktree.sh"
default_sandbox_cfg="$repo/config/templates/sandbox.template.sh"

# Exported so the scripts under test leave their temporaries here too.
TMPDIR="$(mktemp -d)"; export TMPDIR
trap 'rm -rf "$TMPDIR"' EXIT

# Outputs worktree path after running
run_worktree_in_dir() {
    local dir="$1"; shift
    (cd "$dir" && "$worktree_sh" "$@" 2>/dev/null | tr -d '\0')
}

# Redirect the run's stderr to stdout
run_worktree_in_dir_err() {
    local dir="$1"; shift
    (cd "$dir" && "$worktree_sh" "$@" 2>&1)
}

# Captured exit codes below rely on errexit being off.
set +e


# ---------------------------------------------------------------------------
echo "NAME validation and the worktree-root requirement"
# ---------------------------------------------------------------------------
repoA="$TMPDIR/repoA"; make_repo "$repoA"

out="$(run_worktree_in_dir_err "$repoA")"; st=$?
assert_contains "$out" "error:" "missing NAME triggers error"
assert_nonzero "$st" "  -> and exits non-zero"

out="$(run_worktree_in_dir_err "$repoA" -x)"; st=$?
assert_contains "$out" "must not start with '-'" "leading-dash NAME is rejected"
assert_nonzero "$st" "  -> and exits non-zero"

out="$(run_worktree_in_dir_err "$repoA" ../escape)"; st=$?
assert_contains "$out" "must not contain '..'" "'..'-escaping NAME is rejected"

out="$(run_worktree_in_dir_err "$repoA" /abs)"; st=$?
assert_contains "$out" "must be relative" "absolute NAME is rejected"

out="$(run_worktree_in_dir_err "$repoA" .)"; st=$?
assert_contains "$out" "non-empty NAME" "'.' NAME is rejected as effectively empty"
assert_nonzero "$st" "  -> and exits non-zero"

out="$(run_worktree_in_dir_err "$repoA" ./)"; st=$?
assert_contains "$out" "non-empty NAME" "'./' NAME is rejected as effectively empty"

plain="$TMPDIR/plain"; mkdir -p "$plain"
out="$(run_worktree_in_dir_err "$plain" foo)"; st=$?
assert_contains "$out" "root of a git worktree" "running outside a git repo is rejected"
assert_nonzero "$st" "  -> and exits non-zero"


# ---------------------------------------------------------------------------
echo "create, reuse, and the stdout contract"
# ---------------------------------------------------------------------------
repoB="$TMPDIR/repoB"; make_repo "$repoB"
root="$(realpath "$repoB")"
feat_wt="$root/.worktrees/feat"

out="$(run_worktree_in_dir "$repoB" feat)"; st=$?
assert_zero "$st" "create exits zero"
assert_eq "$out" "$feat_wt"                       "stdout is the worktree path (NUL-terminated)"
if [ -d "$feat_wt" ]; then ok "the worktree dir is created"; else bad "the worktree dir is missing"; fi
if [ "$(git -C "$feat_wt" rev-parse --abbrev-ref HEAD)" = "feat" ]; then
    ok "the worktree is checked out on the new branch 'feat'"
else
    bad "the worktree is not on branch 'feat'"
fi

out="$(run_worktree_in_dir "$repoB" feat)"; st=$?
assert_zero "$st" "reuse exits zero"
assert_eq "$out" "$feat_wt" "re-running the same NAME reuses it (same worktree path)"


# ---------------------------------------------------------------------------
echo "a manually-deleted worktree (stale registration) is recreated"
# ---------------------------------------------------------------------------
gone_wt="$root/.worktrees/gone"
run_worktree_in_dir "$repoB" gone >/dev/null
rm -rf "$gone_wt"
err="$(cd "$repoB" && "$worktree_sh" gone 2>&1 >/dev/null)"; st=$?
assert_zero "$st" "re-run after 'rm -rf' of the worktree dir exits zero"
assert_contains "$err" "stale registration" "  -> reporting the stale-registration removal"
if [ -d "$gone_wt" ]; then ok "  -> and the worktree dir is recreated"; else bad "  -> the worktree dir is not recreated"; fi
assert_eq "$(git -C "$gone_wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" "gone" \
    "  -> checked out on the pre-existing branch 'gone'"


# ---------------------------------------------------------------------------
echo "a nested NAME (subdir under .worktrees/) is supported"
# ---------------------------------------------------------------------------
deep_wt="$root/.worktrees/nested/deep"
out="$(run_worktree_in_dir "$repoB" nested/deep)"; st=$?
assert_zero "$st" "nested-NAME create exits zero"
assert_eq "$out" "$deep_wt" "stdout is the nested worktree path"
if [ -d "$deep_wt" ]; then ok "the nested worktree dir is created"; else bad "the nested worktree dir is missing"; fi
if [ "$(git -C "$deep_wt" rev-parse --abbrev-ref HEAD)" = "nested/deep" ]; then
    ok "the worktree is checked out on the new branch 'nested/deep'"
else
    bad "the worktree is not on branch 'nested/deep'"
fi


# ---------------------------------------------------------------------------
echo "a subdir invocation is refused"
# ---------------------------------------------------------------------------
mkdir -p "$repoB/sub/deep"
out="$(run_worktree_in_dir_err "$repoB/sub/deep" fromsub)"; st=$?
assert_nonzero "$st" "running from a subdir of a worktree is refused"
assert_contains "$out" "root of a git worktree" "  -> naming the worktree-root requirement"
assert_absent "$root/.worktrees/fromsub" "  -> and no worktree is created"


# ---------------------------------------------------------------------------
echo "existing branches are honored"
# ---------------------------------------------------------------------------
git -C "$repoB" branch preexisting >/dev/null 2>&1
out="$(run_worktree_in_dir "$repoB" preexisting)"; st=$?
assert_zero "$st" "existing-branch create exits zero"
if [ "$(git -C "$repoB/.worktrees/preexisting" rev-parse --abbrev-ref HEAD)" = "preexisting" ]; then
    ok "an existing branch NAME is checked out into the worktree"
else
    bad "the worktree is not on the pre-existing branch"
fi


# ---------------------------------------------------------------------------
echo "from a submodule, the worktree lands under the SUBMODULE root"
# ---------------------------------------------------------------------------
submod_src="$TMPDIR/submod_src"; make_repo "$submod_src"
super="$TMPDIR/super"; make_repo "$super"
env "${allow_git_file_protocol[@]}" git -C "$super" submodule add -q "$submod_src" thesub 2>/dev/null
git -C "$super" commit -q -m 'add submodule'
submod_root="$(realpath "$super/thesub")"

out="$(run_worktree_in_dir "$super/thesub" subfeat)"; st=$?
assert_zero "$st" "create from a submodule root exits zero"
assert_eq "$out" "$submod_root/.worktrees/subfeat" "the worktree lands under the submodule root (not the module gitdir)"
assert_absent "$super/.git/modules/thesub/.worktrees" "nothing is created inside the superproject's .git/modules/"
if [ "$(git -C "$super/thesub/.worktrees/subfeat" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "subfeat" ]; then
    ok "the worktree is checked out on the new branch 'subfeat'"
else
    bad "the worktree is not on branch 'subfeat'"
fi


# ---------------------------------------------------------------------------
echo "from a --separate-git-dir repo, the worktree lands under its root"
# ---------------------------------------------------------------------------
sgd_root="$TMPDIR/sgd-root"; sgd_git="$TMPDIR/sgd-git"
make_repo "$sgd_root" --separate-git-dir "$sgd_git"
sgd_root_real="$(realpath "$sgd_root")"

out="$(run_worktree_in_dir "$sgd_root" sgdfeat)"; st=$?
assert_zero "$st" "create from a separate-git-dir root exits zero"
assert_eq "$out" "$sgd_root_real/.worktrees/sgdfeat" "the worktree lands under the repo root (not the detached gitdir)"
assert_absent "$sgd_git/.worktrees" "nothing is created inside the detached gitdir"


# ---------------------------------------------------------------------------
echo "an unresolvable main worktree is refused (nowhere to put .worktrees/)"
# ---------------------------------------------------------------------------
sgdlinked="$TMPDIR/sgdlinked"
git -C "$sgd_root" worktree add -q -b sgdlinked "$sgdlinked" >/dev/null 2>&1
out="$(run_worktree_in_dir_err "$sgdlinked" orphan)"; st=$?
assert_nonzero "$st" "a linked worktree of a separate-git-dir repo is refused"
assert_contains "$out" "cannot resolve the repo's main worktree" "  -> naming the unresolvable main worktree"
if [ -e "$sgdlinked/.worktrees" ] || [ -e "$sgd_git/.worktrees" ]; then
    bad "  -> and nothing is created (neither in the linked worktree nor the gitdir)"
else
    ok  "  -> and nothing is created (neither in the linked worktree nor the gitdir)"
fi

bare_gd="$TMPDIR/bare.git"
git clone -q --bare "$repoA" "$bare_gd"
barelinked="$TMPDIR/barelinked"
git -C "$bare_gd" worktree add -q -b barelinked "$barelinked" >/dev/null 2>&1
out="$(run_worktree_in_dir_err "$barelinked" orphan)"; st=$?
assert_nonzero "$st" "a bare repo's linked worktree is refused"
assert_contains "$out" "cannot resolve the repo's main worktree" "  -> naming the unresolvable main worktree"
assert_absent "$bare_gd/.worktrees" "  -> and nothing is created inside the bare gitdir"


# ---------------------------------------------------------------------------
echo "a pre-existing non-worktree directory is refused"
# ---------------------------------------------------------------------------
mkdir -p "$repoB/.worktrees/bogus"; : > "$repoB/.worktrees/bogus/afile"
out="$(run_worktree_in_dir_err "$repoB" bogus)"; st=$?
assert_contains "$out" "not a worktree of this repo" "refuses a pre-existing dir that isn't a worktree"
assert_nonzero "$st" "  -> and exits non-zero"


# ---------------------------------------------------------------------------
echo "an inherited git-location env is refused, naming the offenders"
# ---------------------------------------------------------------------------
gitdir="$(realpath "$repoB/.git")"
out="$(cd "$repoB" && \
    GIT_DIR="$gitdir" \
    GIT_COMMON_DIR="$TMPDIR/bogus-common" \
    GIT_REFERENCE_BACKEND="reftable://$TMPDIR/bogus-refs" \
    "$worktree_sh" envsafe 2>&1)"; st=$?
assert_nonzero "$st" "a hostile inherited git env is refused (non-zero exit)"
assert_contains "$out" "GIT_DIR"               "  -> GIT_DIR is named in the error"
assert_contains "$out" "GIT_COMMON_DIR"        "  -> GIT_COMMON_DIR is named in the error"
assert_contains "$out" "GIT_REFERENCE_BACKEND" "  -> GIT_REFERENCE_BACKEND is named in the error"
assert_absent "$repoB/.worktrees/envsafe" "  -> and no worktree is created"

for v in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE \
         GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR \
         GIT_REFERENCE_BACKEND; do
    out="$(cd "$repoB" && env "$v=$TMPDIR/bogus" "$worktree_sh" envone 2>&1)"; st=$?
    assert_nonzero "$st" "$v alone is refused"
    assert_contains "$out" "$v" "  -> and named in the error"
done

# Set-but-EMPTY is refused too: git treats an empty and an unset location var differently
out="$(cd "$repoB" && env GIT_DIR= "$worktree_sh" envempty 2>&1)"; st=$?
assert_nonzero "$st" "a set-but-empty GIT_DIR is refused too"


# ---------------------------------------------------------------------------
echo "a repo with relocated ref storage (extensions.refStorage URI payload) is refused"
# ---------------------------------------------------------------------------
repo_relocated_refs="$TMPDIR/repo_relocated_refs"; make_repo "$repo_relocated_refs" --ref-format reftable
git -C "$repo_relocated_refs" config extensions.refstorage "reftable://$TMPDIR/elsewhere-refs"
out="$(run_worktree_in_dir_err "$repo_relocated_refs" rs)"; st=$?
if git -C "$repo_relocated_refs" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    assert_nonzero "$st" "a refStorage reftable with URI payload is refused"
else
    # This git predates the payload syntax and cannot open the repo: discovery fails
    # while the .git entry exists, so the steered-root guard refuses (fail closed).
    assert_nonzero "$st" "a refStorage URI payload on a git predating it is refused via the unresolvable .git"
fi
assert_absent "$repo_relocated_refs/.worktrees/rs" "  -> and no worktree is created"

# A plain reftable is supported
repo_reftable="$TMPDIR/repo_reftable"; make_repo "$repo_reftable" --ref-format reftable
out="$(run_worktree_in_dir "$repo_reftable" plainfmt)"; st=$?
assert_zero "$st" "a plain extensions.refStorage reftable format value is not refused"


# ---------------------------------------------------------------------------
echo "a repo reading objects through an alternates file is refused (no worktree created)"
# ---------------------------------------------------------------------------
repo_with_alternates="$TMPDIR/repoAW"; make_repo "$repo_with_alternates"
alternates="$repo_with_alternates/.git/objects/info/alternates"
: > "$alternates"
out="$(run_worktree_in_dir "$repo_with_alternates" altok)"; st=$?
if [ "$st" -eq 0 ] && [ -d "$repo_with_alternates/.worktrees/altok" ]; then ok "an EMPTY alternates file is not refused (worktree created)"; else bad "an empty alternates file should pass (got $st)"; fi
printf '%s\n' "$TMPDIR/external-store/objects" > "$alternates"
out="$(run_worktree_in_dir_err "$repo_with_alternates" altbad)"; st=$?
assert_nonzero "$st" "a non-empty alternates file is refused"
assert_contains "$out" "alternates" "  -> naming the alternates file"
assert_absent "$repo_with_alternates/.worktrees/altbad" "  -> and no worktree is created"


# ---------------------------------------------------------------------------
echo "a .worktrees occupied by a regular file is refused"
# ---------------------------------------------------------------------------
repoC="$TMPDIR/repoC"; make_repo "$repoC"
: > "$repoC/.worktrees"   # occupy the parent path with a plain file so mkdir -p can't create it
out="$(run_worktree_in_dir_err "$repoC" feat)"; st=$?
assert_contains "$out" "could not create worktree parent dir" "refuses when .worktrees is a regular file"
assert_nonzero "$st" "  -> and exits non-zero"


# ---------------------------------------------------------------------------
echo "a symlinked .worktrees emits the canonical (physical) worktree path"
# ---------------------------------------------------------------------------
repoD="$TMPDIR/repoD"; make_repo "$repoD"
storage="$TMPDIR/wt-storage"; mkdir -p "$storage"
ln -s "$storage" "$repoD/.worktrees"
symlinked_wt="$(realpath "$storage")/symlinked"
out="$(run_worktree_in_dir "$repoD" symlinked)"; st=$?
assert_zero "$st" "create through a symlinked .worktrees exits zero"
assert_eq "$out" "$symlinked_wt" "the emitted path is the physical location, not the symlink"

out="$(run_worktree_in_dir "$repoD" symlinked)"; st=$?
assert_zero "$st" "reuse through a symlinked .worktrees exits zero"
assert_eq "$out" "$symlinked_wt" "reuse emits the same physical path"


# ---------------------------------------------------------------------------
echo "a manually-deleted worktree is recreated through a symlinked .worktrees"
# ---------------------------------------------------------------------------
gone_symlinked="$(realpath "$storage")/gonesym"
run_worktree_in_dir "$repoD" gonesym >/dev/null
rm -rf "$gone_symlinked"
err="$(cd "$repoD" && "$worktree_sh" gonesym 2>&1 >/dev/null)"; st=$?
assert_zero "$st" "recreate after 'rm -rf' through a symlinked .worktrees exits zero"
assert_contains "$err" "stale registration" "  -> reporting the stale-registration removal"
if [ -d "$gone_symlinked" ]; then ok "  -> and the worktree dir is recreated"; else bad "  -> the worktree dir is not recreated"; fi
assert_eq "$(git -C "$gone_symlinked" rev-parse --abbrev-ref HEAD 2>/dev/null)" "gonesym" \
    "  -> checked out on the pre-existing branch 'gonesym'"


# ---------------------------------------------------------------------------
echo "the branch upstream is pre-recorded from the repo's remotes"
# ---------------------------------------------------------------------------
nonexistent_origin="$TMPDIR/nonexistent-origin.git"
repoE="$TMPDIR/repoE"; make_repo "$repoE"
git -C "$repoE" remote add origin "$nonexistent_origin"
out="$(run_worktree_in_dir "$repoE" --config "$default_sandbox_cfg" up)"; st=$?
assert_zero "$st" "create with an origin remote exits zero"
assert_eq "$(git -C "$repoE" config branch.up.remote 2>/dev/null)" "origin"        "branch.NAME.remote is pre-recorded"
assert_eq "$(git -C "$repoE" config branch.up.merge  2>/dev/null)" "refs/heads/up" "branch.NAME.merge is pre-recorded"

# A branch that already tracks something keeps its upstream.
git -C "$repoE" branch tracked
git -C "$repoE" config branch.tracked.remote elsewhere
git -C "$repoE" config branch.tracked.merge  refs/heads/other
out="$(run_worktree_in_dir "$repoE" --config "$default_sandbox_cfg" tracked)"
assert_eq "$(git -C "$repoE" config branch.tracked.remote 2>/dev/null)" "elsewhere" "a pre-existing upstream is not clobbered"

# no upstream pre-recorded when there are no remotes
out="$(run_worktree_in_dir "$repoB" --config "$default_sandbox_cfg" feat)"
if git -C "$repoB" config branch.feat.remote >/dev/null 2>&1; then
    bad "no upstream is recorded when the repo has no remotes"
else
    ok  "no upstream is recorded when the repo has no remotes"
fi

# A single remote is the only candidate, so it's recorded even when it isn't 'origin'.
repoE2="$TMPDIR/repoE2"; make_repo "$repoE2"
git -C "$repoE2" remote add fork "$TMPDIR/nonexistent-fork.git"
out="$(run_worktree_in_dir "$repoE2" --config "$default_sandbox_cfg" solo)"; st=$?
assert_zero "$st" "create with a single non-origin remote exits zero"
assert_eq "$(git -C "$repoE2" config branch.solo.remote 2>/dev/null)" "fork" "the sole remote is recorded even when it isn't 'origin'"
assert_eq "$(git -C "$repoE2" config branch.solo.merge  2>/dev/null)" "refs/heads/solo" "  -> along with branch.NAME.merge"

# Among multiple remotes, 'origin' wins when present.
git -C "$repoE2" remote add origin "$nonexistent_origin"
out="$(run_worktree_in_dir "$repoE2" --config "$default_sandbox_cfg" multi)"; st=$?
assert_zero "$st" "create with multiple remotes including 'origin' exits zero"
assert_eq "$(git -C "$repoE2" config branch.multi.remote 2>/dev/null)" "origin" "'origin' is picked from among multiple remotes"

# Multiple remotes and none is 'origin': the choice can't be deduced, refuse
repoE3="$TMPDIR/repoE3"; make_repo "$repoE3"
git -C "$repoE3" remote add alpha "$TMPDIR/nonexistent-alpha.git"
git -C "$repoE3" remote add beta  "$TMPDIR/nonexistent-beta.git"
out="$(run_worktree_in_dir_err "$repoE3" --config "$default_sandbox_cfg" torn)"; st=$?
assert_nonzero "$st" "multiple remotes without 'origin' exit non-zero"
assert_contains "$out" "cannot deduce"                 "  -> the error says the remote couldn't be deduced"
assert_contains "$out" "alpha beta"                    "  -> and names the candidate remotes"
if git -C "$repoE3" config branch.torn.remote >/dev/null 2>&1; then
    bad "  -> and no upstream is recorded"
else
    ok  "  -> and no upstream is recorded"
fi

# ...once the upstream is recorded manually as instructed, the re-run succeeds.
git -C "$repoE3" config branch.torn.remote alpha
git -C "$repoE3" config branch.torn.merge  refs/heads/torn
out="$(run_worktree_in_dir "$repoE3" --config "$default_sandbox_cfg" torn)"; st=$?
assert_zero "$st" "re-run after manually recording the upstream exits zero"
assert_eq "$(git -C "$repoE3" config branch.torn.remote 2>/dev/null)" "alpha" "  -> and the manual choice is kept"


# ---------------------------------------------------------------------------
echo "a reused worktree records the upstream for the CHECKED-OUT branch"
# ---------------------------------------------------------------------------
# A pre-existing worktree may have switched branches since it was created, so the
# worktree name and the checked-out branch need not agree.
repoH="$TMPDIR/repoH"; make_repo "$repoH"
git -C "$repoH" remote add origin "$nonexistent_origin"
git -C "$repoH" worktree add -q -b sidebranch "$repoH/.worktrees/wtname" >/dev/null 2>&1
out="$(run_worktree_in_dir "$repoH" --config "$default_sandbox_cfg" wtname)"; st=$?
assert_zero "$st" "reuse with a differing checked-out branch exits zero"
assert_eq "$(git -C "$repoH" config branch.sidebranch.remote 2>/dev/null)" "origin" \
    "the upstream is recorded for the checked-out branch, not the worktree name"
assert_eq "$(git -C "$repoH" config branch.sidebranch.merge 2>/dev/null)" "refs/heads/sidebranch" \
    "  -> along with branch.BRANCH.merge for the checked-out branch"
if git -C "$repoH" config branch.wtname.remote >/dev/null 2>&1; then
    bad "  -> and nothing is recorded under the worktree name"
else
    ok  "  -> and nothing is recorded under the worktree name"
fi


# ---------------------------------------------------------------------------
echo "a detached-HEAD worktree records no upstream and consults no remote state"
# ---------------------------------------------------------------------------
repoI="$TMPDIR/repoI"; make_repo "$repoI"
git -C "$repoI" remote add alpha "$TMPDIR/nonexistent-alpha.git"
git -C "$repoI" remote add beta  "$TMPDIR/nonexistent-beta.git"
git -C "$repoI" worktree add -q --detach "$repoI/.worktrees/loose" >/dev/null 2>&1
out="$(run_worktree_in_dir "$repoI" --config "$default_sandbox_cfg" loose)"; st=$?
assert_zero "$st" "reuse with a detached checkout exits zero (even with undeducible remotes)"
if git -C "$repoI" config branch.loose.remote >/dev/null 2>&1; then
    bad "  -> and no upstream is recorded under the worktree name"
else
    ok  "  -> and no upstream is recorded under the worktree name"
fi


# ---------------------------------------------------------------------------
echo "submodules (including nested) come up initialized in the worktree"
# ---------------------------------------------------------------------------
leaf="$TMPDIR/leafmod"; make_repo "$leaf"
printf 'LEAF_MARKER\n' > "$leaf/leaf-file.txt"
git -C "$leaf" add leaf-file.txt
git -C "$leaf" commit -q -m leaf

sub="$TMPDIR/submod"; make_repo "$sub"
printf 'SUB_MARKER\n' > "$sub/sub-file.txt"
git -C "$sub" add sub-file.txt
env "${allow_git_file_protocol[@]}" git -C "$sub" submodule add -q "$leaf" leafsub 2>/dev/null
git -C "$sub" commit -q -m 'sub + nested submodule'

repoF="$TMPDIR/repoF"; make_repo "$repoF"
env "${allow_git_file_protocol[@]}" git -C "$repoF" submodule add -q "$sub" thesub 2>/dev/null
git -C "$repoF" commit -q -m 'add submodule'

out="$(cd "$repoF" && env "${allow_git_file_protocol[@]}" "$worktree_sh" --config "$default_sandbox_cfg" feat 2>/dev/null | tr -d '\0')"; st=$?
assert_zero "$st" "create with a nested submodule exits zero"
sub_wt="$repoF/.worktrees/feat"
assert_eq "$(cat "$sub_wt/thesub/sub-file.txt" 2>/dev/null)" "SUB_MARKER" \
    "the submodule working dir is populated in the worktree"
assert_eq "$(cat "$sub_wt/thesub/leafsub/leaf-file.txt" 2>/dev/null)" "LEAF_MARKER" \
    "the NESTED submodule working dir is populated too"

sub_gitdir="$(git -C "$sub_wt/thesub" rev-parse --absolute-git-dir 2>/dev/null)"
leaf_gitdir="$(git -C "$sub_wt/thesub/leafsub" rev-parse --absolute-git-dir 2>/dev/null)"
own_admin="$(realpath "$repoF/.git/worktrees/feat")"
assert_prefix "$(realpath "$sub_gitdir" 2>/dev/null || echo MISSING)" "$own_admin" \
    "the submodule's gitdir lives under the worktree's own admin dir"
assert_prefix "$(realpath "$leaf_gitdir" 2>/dev/null || echo MISSING)" "$own_admin" \
    "the nested submodule's gitdir also lives under the worktree's own admin dir"


# ---------------------------------------------------------------------------
echo "CHOPI_WORKTREE_SETUP (--config) customizes the pre-sandbox setup"
# ---------------------------------------------------------------------------
repoG="$TMPDIR/repoG"; make_repo "$repoG"
git -C "$repoG" remote add origin "$nonexistent_origin"
rootG="$(realpath "$repoG")"

cfg_custom="$TMPDIR/cfg-custom.sh"
cat > "$cfg_custom" <<'EOF'
CHOPI_WORKTREE_SETUP=(
    'pwd > setup-pwd.txt'
    'echo "$CHOPI_WORKTREE_NAME" > setup-name.txt'
)
EOF
custom_wt="$rootG/.worktrees/custom"
out="$(run_worktree_in_dir "$repoG" --config "$cfg_custom" custom)"; st=$?
assert_zero "$st" "create with a custom setup exits zero"
assert_eq "$(cat "$custom_wt/setup-pwd.txt" 2>/dev/null)" "$custom_wt" \
    "setup commands run with the worktree as the working directory"
assert_eq "$(cat "$custom_wt/setup-name.txt" 2>/dev/null)" "custom" \
    "setup commands see CHOPI_WORKTREE_NAME"
if git -C "$repoG" config branch.custom.remote >/dev/null 2>&1; then
    bad "only the configured commands run (no upstream gets recorded)"
else
    ok  "only the configured commands run (no upstream gets recorded)"
fi

# A config that doesn't mention CHOPI_WORKTREE_SETUP is refused rather than silently skipped
cfg_plain="$TMPDIR/cfg-plain.sh"
cat > "$cfg_plain" <<'EOF'
CHOPI_SAFEHOUSE_FLAGS=( --enable xcode )
CHOPI_EXTRA_ENV=( PATH=/usr/bin:/bin )
EOF
out="$(run_worktree_in_dir_err "$repoG" --config "$cfg_plain" plain)"; st=$?
assert_contains "$out" "does not define" "a config without CHOPI_WORKTREE_SETUP is refused"
assert_contains "$out" "sandbox.template.sh" "  -> and the error points at the template default"
assert_contains "$out" "CHOPI_WORKTREE_SETUP=()" "  -> and shows the empty-array opt-out"
assert_nonzero "$st" "  -> and exits non-zero"
assert_absent "$repoG/.worktrees/plain" "  -> and no worktree is created"

# An explicitly empty CHOPI_WORKTREE_SETUP is OK
cfg_empty="$TMPDIR/cfg-empty.sh"
printf 'CHOPI_WORKTREE_SETUP=()\n' > "$cfg_empty"
out="$(run_worktree_in_dir "$repoG" --config "$cfg_empty" bare)"; st=$?
assert_zero "$st" "an explicitly empty setup array exits zero"
if git -C "$repoG" config branch.bare.remote >/dev/null 2>&1; then
    bad "  -> and runs no setup at all (no upstream recorded)"
else
    ok  "  -> and runs no setup at all (no upstream recorded)"
fi

# The chopi_record_upstream helper stays callable from a custom setup.
cfg_helper="$TMPDIR/cfg-helper.sh"
printf "CHOPI_WORKTREE_SETUP=( 'chopi_record_upstream' )\n" > "$cfg_helper"
out="$(run_worktree_in_dir "$repoG" --config "$cfg_helper" helped)"; st=$?
assert_zero "$st" "a custom setup can call the chopi_record_upstream helper"
assert_eq "$(git -C "$repoG" config branch.helped.remote 2>/dev/null)" "origin" \
    "  -> and it records the upstream"

# A failing setup command aborts the run and names the command.
cfg_fail="$TMPDIR/cfg-fail.sh"
printf "CHOPI_WORKTREE_SETUP=( 'true' 'false' )\n" > "$cfg_fail"
out="$(cd "$repoG" && "$worktree_sh" --config "$cfg_fail" failing 2>&1 >/dev/null)"; st=$?
assert_contains "$out" "worktree setup command failed: false" "a failing setup command reports which command failed"
assert_nonzero "$st" "  -> and exits non-zero"

# An unreadable --config is refused
out="$(run_worktree_in_dir_err "$repoG" --config "$TMPDIR/no-such-config.sh" nope)"; st=$?
assert_contains "$out" "cannot read sandbox config" "an unreadable --config is refused"
assert_nonzero "$st" "  -> and exits non-zero"


# ---------------------------------------------------------------------------
summary

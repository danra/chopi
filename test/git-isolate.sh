#!/usr/bin/env bash
#
# test/git-isolate.sh -- unit tests for the worktree-isolation profile

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
. "$repo/.internal/util.sh"
. "$repo/test/lib.sh"

header "test/git-isolate.sh -- unit tests for the worktree-isolation profile"

command -v git >/dev/null 2>&1 || { echo "error: git not on PATH" >&2; exit 1; }

protect_sh="$repo/.internal/git-protect.sh"

# Exported so the scripts under test leave their temporaries here too.
TMPDIR="$(mktemp -d)"; export TMPDIR
trap 'rm -rf "$TMPDIR"' EXIT

# Gets isolation profile path
isolate_in() {
    local dir="$1"; shift
    (cd "$dir" && "$protect_sh" "$@" 2>/dev/null | nul_record 1)
}

# Redirect stderr to stdout
isolate_in_err() {
    local dir="$1"; shift
    (cd "$dir" && { "$protect_sh" "$@" >/dev/null; } 2>&1)
}

# Captured exit codes below rely on errexit being off.
set +e


# ---------------------------------------------------------------------------
echo "the main worktree's isolation profile (a bare run from a repo root)"
# ---------------------------------------------------------------------------
main_repo="$TMPDIR/main_repo"; make_repo "$main_repo"
root="$(realpath "$main_repo")"
gitdir="$(realpath "$main_repo/.git")"
sibling_worktree="$root/.worktrees/sib"
git -C "$main_repo" worktree add -q -b sib "$sibling_worktree"
ext_worktree="$TMPDIR/ext_worktree"
git -C "$main_repo" worktree add -q -b ext "$ext_worktree"
ext_worktree_real="$(realpath "$ext_worktree")"

profile_path="$(isolate_in "$main_repo")"; st=$?
assert_zero "$st" "isolating the main worktree exits zero"
assert_present "$profile_path" "the emitted path is a profile file that exists"
profile="$(cat "$profile_path" 2>/dev/null)"

assert_contains "$profile" '(deny file-read* file-write* (subpath "'"$sibling_worktree"'"))'                 "the nested sibling worktree is denied"
assert_contains "$profile" '(deny file-read* file-write* (subpath "'"$ext_worktree_real"'"))'          "the external sibling worktree is denied"

# The nodes between the workspace root and a nested sibling are pinned
ext_worktree_parent="$(dirname "$ext_worktree_real")"
assert_contains "$profile" '(deny file-write* (literal "'"$root/.worktrees"'"))'                "the node on the way to the nested sibling is pinned against rename"
assert_not_contains "$profile" '(deny file-write* (literal "'"$root"'"))'                       "  -> not the workspace root itself (git-harden's job)"
assert_not_contains "$profile" '(deny file-write* (literal "'"$ext_worktree_parent"'"))'        "  -> nor the external sibling's parent (outside the workspace)"
assert_not_contains "$profile" '(deny file-read* file-write* (subpath "'"$root"'"))'            "the main worktree itself is NOT denied"
assert_not_contains "$profile" '(allow file-read* file-write* (subpath "'"$root"'"))'           "  -> and NOT re-allowed (in case safehouse denied anything)"
assert_not_contains "$profile" '(allow file-read* (subpath "'"$gitdir"'"))'                     "no read grant is added on .git (the workspace grant already covers it)"

# Isolation deliberately leaves the git internals alone -- locking them down is git-harden's
# job, applied by a separate profile appended after this one.
assert_not_contains "$profile" '(deny file-write* (subpath "'"$gitdir"'"))'                     "the shared git dir is left writable (isolation adds no hardening)"
assert_contains "$profile" '(deny file-read* file-write* (literal "'"$profile_path"'"))'             "the profile denies access to itself"


# ---------------------------------------------------------------------------
echo "--verbose prints the resolved git layout"
# ---------------------------------------------------------------------------
# The CHOPI_GIT_* layout globals drive every rule in the profile, so chopi's --verbose
# forwards --verbose here to surface them (on stderr; the stdout contract stays clean).
err="$(isolate_in_err "$main_repo" --verbose)"; st=$?
assert_zero "$st" "a --verbose run exits zero"
assert_contains "$err" "CHOPI_GIT_DIR                       = $gitdir"              "the target's governing git dir is printed"
assert_contains "$err" "CHOPI_GIT_COMMON_DIR                = $gitdir"              "the shared git dir is printed"
assert_contains "$err" "CHOPI_GIT_MAIN_WORKTREE             = $root"                "the main worktree is printed"
assert_contains "$err" "CHOPI_GIT_TARGET_WORKTREE           = $root"                "the target worktree is printed"
assert_contains "$err" "CHOPI_GIT_OTHER_WORKTREES           = $sibling_worktree"                 "each other worktree is printed..."
assert_contains "$err" "CHOPI_GIT_OTHER_WORKTREES           = $ext_worktree_real"          "  -> ...on a line of its own"
assert_contains "$err" "CHOPI_GIT_TARGET_SUB_MAIN_WORKTREES = (none)"               "a repo without submodules prints (none)..."
assert_contains "$err" "CHOPI_GIT_TARGET_SUB_GITDIRS        = (none)"               "  -> ...for both submodule arrays"

err="$(isolate_in_err "$main_repo")"
assert_not_contains "$err" "CHOPI_GIT_" "without --verbose the layout is not printed"


# ---------------------------------------------------------------------------
echo "a linked worktree's isolation profile (DIR argument, as --worktree runs use)"
# ---------------------------------------------------------------------------
feat="$root/.worktrees/feat"
git -C "$main_repo" worktree add -q -b feat "$feat"

profile_path="$(isolate_in "$main_repo" "$feat")"; st=$?
assert_zero "$st" "isolating a linked worktree via DIR exits zero"
profile="$(cat "$profile_path" 2>/dev/null)"

assert_contains "$profile" '(deny file-read* file-write* (subpath "'"$root"'"))'                  "profile denies the main repo tree"
assert_contains "$profile" '(allow file-read-metadata (literal "'"$root"'"))'                     "profile grants lookup on the main worktree (literal)"
assert_contains "$profile" '(allow file-read-metadata (literal "'"$root/.worktrees"'"))'          "profile grants lookup on the .worktrees spine dir (literal)"
assert_not_contains "$profile" '(allow file-read-metadata (subpath "'"$root"'"))'                 "  -> but NOT stat metadata on the whole main tree (no subpath grant)"
assert_contains "$profile" '(deny file-read* file-write* (subpath "'"$ext_worktree_real"'"))'            "the external sibling worktree is denied"
assert_contains "$profile" '(allow file-read* file-write* (subpath "'"$gitdir"'"))'               "the shared git dir is re-allowed read-write so git keeps working"
assert_not_contains "$profile" '(deny file-write* (subpath "'"$gitdir"'"))'                       "  -> and NOT locked down (that is git-harden's job)"
assert_contains "$profile" '(allow file-read* file-write* (subpath "'"$feat"'"))'                 "profile re-allows this worktree"
assert_not_contains "$profile" '(deny file-write* (literal "'"$feat/.git"'"))'                    "  -> and does NOT pin the worktree's .git pointer (git-harden's job)"
assert_contains "$profile" '(deny file-read* file-write* (literal "'"$profile_path"'"))'               "profile denies access to itself"

profile_path="$(isolate_in "$feat")"; st=$?
assert_zero "$st" "a bare run from inside a linked worktree exits zero"
profile="$(cat "$profile_path" 2>/dev/null)"
assert_contains "$profile" '(deny file-read* file-write* (subpath "'"$root"'"))'                  "  -> it denies the main repo tree"
assert_contains "$profile" '(allow file-read* file-write* (subpath "'"$feat"'"))'                 "  -> and re-allows the current worktree"

inner="$feat/nest/inner"
git -C "$main_repo" worktree add -q -b inner "$inner"
profile_path="$(isolate_in "$main_repo" "$feat")"; st=$?
assert_zero "$st" "a sibling nested inside the target worktree exits zero"
assert_rule_order "$profile_path" \
    '(allow file-read* file-write* (subpath "'"$feat"'"))' \
    '(deny file-read* file-write* (subpath "'"$inner"'"))' \
    "  -> and its deny follows the target's allow (so the allow can't reopen it)"
assert_rule_order "$profile_path" \
    '(allow file-read* file-write* (subpath "'"$feat"'"))' \
    '(deny file-write* (literal "'"$feat/nest"'"))' \
    "  -> and so does the pin of the node on the way to it"
git -C "$main_repo" worktree remove --force "$inner" >/dev/null 2>&1
git -C "$main_repo" branch -D inner >/dev/null 2>&1


# ---------------------------------------------------------------------------
echo "a submodule root is the repo's main worktree (gitdir outside the worktree)"
# ---------------------------------------------------------------------------
submodule_src="$TMPDIR/submodule_src"; make_repo "$submodule_src"
repo_with_submodule="$TMPDIR/repo_with_submodule"; make_repo "$repo_with_submodule"
env "${allow_git_file_protocol[@]}" git -C "$repo_with_submodule" submodule add -q "$submodule_src" thesub 2>/dev/null
git -C "$repo_with_submodule" commit -q -m 'add submodule'
thesub="$repo_with_submodule/thesub"
submodule_root="$(realpath "$thesub")"
submodule_gitdir="$(realpath "$(git -C "$thesub" rev-parse --absolute-git-dir)")"

err="$(isolate_in_err "$thesub" --verbose)"; st=$?
assert_zero "$st" "isolating a submodule root exits zero"
assert_contains "$err" "CHOPI_GIT_MAIN_WORKTREE             = $submodule_root" "the submodule root itself is the main worktree (record corrected)"
assert_contains "$err" "CHOPI_GIT_OTHER_WORKTREES           = (none)"    "  -> and the module gitdir is not mistaken for a sibling worktree"

err="$(isolate_in_err "$repo_with_submodule" --verbose)"
assert_contains "$err" "CHOPI_GIT_TARGET_SUB_MAIN_WORKTREES = $submodule_root"   "from the superproject, the submodule's main worktree is printed"
assert_contains "$err" "CHOPI_GIT_TARGET_SUB_GITDIRS        = $submodule_gitdir" "  -> and its gitdir"

profile_path="$(isolate_in "$thesub")"
profile="$(cat "$profile_path" 2>/dev/null)"
assert_contains     "$profile" '(allow file-read* file-write* (subpath "'"$submodule_gitdir"'"))'  "the module gitdir (outside the worktree) is granted read-write"
assert_not_contains "$profile" '(deny file-read* file-write* (subpath "'"$submodule_gitdir"'"))'   "  -> not denied as a sibling worktree"
assert_not_contains "$profile" '(deny file-read* file-write* (subpath "'"$submodule_root"'"))' "the submodule root itself is NOT denied"

# A linked worktree OF the submodule isolates like any linked worktree: the
# main checkout is denied, the target and the module gitdir are re-allowed.
submod_worktree="$TMPDIR/submod_worktree"
git -C "$thesub" worktree add -q -b subfeat "$submod_worktree" >/dev/null 2>&1
submodule_linked_worktree_path="$(realpath "$submod_worktree")"
profile_path="$(isolate_in "$submod_worktree")"; st=$?
assert_zero "$st" "isolating a linked worktree of a submodule exits zero"
profile="$(cat "$profile_path" 2>/dev/null)"
assert_contains "$profile" '(deny file-read* file-write* (subpath "'"$submodule_root"'"))'    "the submodule's main checkout is denied"
assert_contains "$profile" '(allow file-read* file-write* (subpath "'"$submodule_linked_worktree_path"'"))' "  -> the target worktree is re-allowed"
assert_contains "$profile" '(allow file-read* file-write* (subpath "'"$submodule_gitdir"'"))'     "  -> and so is the module gitdir, read-write"


# ---------------------------------------------------------------------------
echo "a --separate-git-dir root is the repo's main worktree"
# ---------------------------------------------------------------------------
sgd_root="$TMPDIR/sgd-root"; sgd_git="$TMPDIR/sgd-git"
make_repo "$sgd_root" --separate-git-dir "$sgd_git"
sgd_root_real="$(realpath "$sgd_root")"
sgd_git_real="$(realpath "$sgd_git")"

err="$(isolate_in_err "$sgd_root" --verbose)"; st=$?
assert_zero "$st" "isolating a separate-git-dir root exits zero"
assert_contains "$err" "CHOPI_GIT_MAIN_WORKTREE             = $sgd_root_real" "the root itself is the main worktree"
assert_contains "$err" "CHOPI_GIT_OTHER_WORKTREES           = (none)"         "  -> and the detached gitdir is not mistaken for a sibling worktree"

profile_path="$(isolate_in "$sgd_root")"
profile="$(cat "$profile_path" 2>/dev/null)"
assert_contains     "$profile" '(allow file-read* file-write* (subpath "'"$sgd_git_real"'"))' "the detached gitdir (outside the worktree) is granted read-write"
assert_not_contains "$profile" '(deny file-read* file-write* (subpath "'"$sgd_root_real"'"))' "the root itself is NOT denied"

# For a LINKED worktree of such a repo, the target and the shared gitdir stay usable.
sgdwt="$TMPDIR/sgdwt"
git -C "$sgd_root" worktree add -q -b sgdfeat "$sgdwt" >/dev/null 2>&1
sgdwt_real="$(realpath "$sgdwt")"
profile_path="$(isolate_in "$sgdwt")"; st=$?
assert_zero    "$st" "isolating a linked worktree of a separate-git-dir repo exits zero"
assert_present "$profile_path" "  -> and a profile is built"
profile="$(cat "$profile_path" 2>/dev/null)"
assert_contains "$profile" '(allow file-read* file-write* (subpath "'"$sgdwt_real"'"))'       "  -> the target worktree is re-allowed"
assert_contains "$profile" '(allow file-read* file-write* (subpath "'"$sgd_git_real"'"))'     "  -> and the shared gitdir stays usable, read-write"
assert_not_contains "$profile" '(deny file-read* file-write* (subpath "'"$sgd_git_real"'"))'  "  -> without first being denied as a pseudo main worktree"


# ---------------------------------------------------------------------------
echo "a bare repo's linked worktrees (no main worktree exists at all)"
# ---------------------------------------------------------------------------
bare_source="$TMPDIR/bareSRC"; make_repo "$bare_source"
bare_repo="$TMPDIR/bare.git"
git clone -q --bare "$bare_source" "$bare_repo"
bare_repo_real="$(realpath "$bare_repo")"
barewt1="$TMPDIR/barewt1"; barewt2="$TMPDIR/barewt2"
git -C "$bare_repo" worktree add -q -b bw1 "$barewt1" >/dev/null 2>&1
git -C "$bare_repo" worktree add -q -b bw2 "$barewt2" >/dev/null 2>&1
barewt1_real="$(realpath "$barewt1")"
barewt2_real="$(realpath "$barewt2")"

profile_path="$(isolate_in "$barewt1")"; st=$?
assert_zero    "$st" "isolating a bare repo's linked worktree exits zero"
assert_present "$profile_path" "  -> and a profile is built"
profile="$(cat "$profile_path" 2>/dev/null)"
assert_contains     "$profile" '(allow file-read* file-write* (subpath "'"$barewt1_real"'"))' "the target worktree is re-allowed"
assert_contains     "$profile" '(deny file-read* file-write* (subpath "'"$barewt2_real"'"))'  "the sibling worktree is still denied"
assert_contains     "$profile" '(allow file-read* file-write* (subpath "'"$bare_repo_real"'"))' "the bare gitdir is granted read-write"
assert_not_contains "$profile" '(deny file-read* file-write* (subpath "'"$bare_repo_real"'"))'  "  -> without first being denied as a pseudo main worktree"

err="$(isolate_in_err "$barewt1" --verbose)"
assert_contains     "$err" "CHOPI_GIT_MAIN_WORKTREE             = (unresolved)"  "--verbose reports the main worktree as unresolved"
assert_not_contains "$err" "CHOPI_GIT_OTHER_WORKTREES           = $bare_repo_real" "  -> and the bare gitdir is not listed as a sibling worktree"

# Test the lovely edge-case of a target worktree nested inside a sibling worktree
barewt1_nested="$barewt1/nested"
git -C "$bare_repo" worktree add -q -b bw1nest "$barewt1_nested" >/dev/null 2>&1
barewt1_nested_real="$(realpath "$barewt1_nested")"
profile_path="$(isolate_in "$barewt1_nested")"; st=$?
assert_zero "$st" "a target nested inside a sibling worktree exits zero"
assert_rule_order "$profile_path" \
    '(deny file-read* file-write* (subpath "'"$barewt1_real"'"))' \
    '(allow file-read* file-write* (subpath "'"$barewt1_nested_real"'"))' \
    "  -> the containing sibling's deny precedes the target's allow (so the deny can't close it)"


# ---------------------------------------------------------------------------
echo "a sibling worktree whose path contains a newline survives into the profile"
# ---------------------------------------------------------------------------
repo_newline="$TMPDIR/repo_newline"; make_repo "$repo_newline"
newline_worktree="$TMPDIR/nl_$(printf 'a\nb')"
git -C "$repo_newline" worktree add -q -b nlsib "$newline_worktree" >/dev/null 2>&1
generated_profiles_paths_file="$TMPDIR/nl-profile"
( cd "$repo_newline" && "$protect_sh" >"$generated_profiles_paths_file" 2>/dev/null ); st=$?
assert_zero "$st" "isolation with a newline-path sibling exits zero"
profile_path="$(nul_record 1 <"$generated_profiles_paths_file")"
newline_worktree_path="$(realpath "$newline_worktree")"
profile="$(cat "$profile_path" 2>/dev/null)"
assert_contains "$profile" '(deny file-read* file-write* (subpath "'"$newline_worktree_path"'"))' \
    "the newline-containing sibling path reaches the profile intact"


# ---------------------------------------------------------------------------
summary

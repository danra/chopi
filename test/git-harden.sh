#!/usr/bin/env bash
#
# test/git-harden.sh -- unit tests for the git-internals hardening profile

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
. "$repo/.internal/util.sh"
. "$repo/test/lib.sh"

header "test/git-harden.sh -- unit tests for the git-internals hardening profile"

command -v git >/dev/null 2>&1 || { echo "error: git not on PATH" >&2; exit 1; }

protect_sh="$repo/.internal/git-protect.sh"

# Exported so the scripts under test leave their temporaries here too.
TMPDIR="$(mktemp -d)"; export TMPDIR
trap 'rm -rf "$TMPDIR"' EXIT

# Gets hardening profile path
harden_in() {
    local dir="$1"; shift
    (cd "$dir" && "$protect_sh" "$@" 2>/dev/null | nul_record 2)
}

# Redirect stderr to stdout
harden_in_err() {
    local dir="$1"; shift
    (cd "$dir" && { "$protect_sh" "$@" >/dev/null; } 2>&1)
}

# Captured exit codes below rely on errexit being off.
set +e


# ---------------------------------------------------------------------------
echo "the main worktree's hardening profile (a standard run from a repo root)"
# ---------------------------------------------------------------------------
main_repo="$TMPDIR/main_repo"; make_repo "$main_repo"
root="$(realpath "$main_repo")"
gitdir="$(realpath "$main_repo/.git")"
# A sibling worktree, purely so the no-isolation boundary assert below has something real to
# check the profile does NOT deny.
sib="$root/.worktrees/sib"
git -C "$main_repo" worktree add -q -b sib "$sib"

profile_path="$(harden_in "$main_repo")"; st=$?
assert_zero "$st" "hardening the main worktree exits zero"
assert_present "$profile_path" "the emitted path is a profile file that exists"
profile="$(cat "$profile_path" 2>/dev/null)"

# Hardening is purely a lockdown layer: it removes NO worktrees (that's git-isolate's job).
assert_not_contains "$profile" '(deny file-read* file-write* (subpath "'"$sib"'"))' "hardening does NOT deny the sibling worktree (no isolation here)"

# The shared .git: generally denied with specific holes for data and checkout state
assert_contains "$profile" '(deny file-write* (subpath "'"$gitdir"'"))'                  "writing the shared git dir is denied by default"
assert_contains "$profile" '(allow file-write* (subpath "'"$gitdir/objects"'"))'         "the object database is re-allowed"
assert_contains "$profile" '(allow file-write* (subpath "'"$gitdir/refs"'"))'            "refs are re-allowed"
# ... more allow holes not listed explicitly

# The exec surface is set last as read-only
assert_contains "$profile" '(deny file-write* (literal "'"$gitdir/config"'"))'           "the shared config is read-only"
assert_contains "$profile" '(deny file-write* (literal "'"$gitdir/config.worktree"'"))'  "  -> and config.worktree"
assert_contains "$profile" '(deny file-write* (subpath "'"$gitdir/hooks"'"))'            "  -> and hooks/"
assert_contains "$profile" '(deny file-write* (literal "'"$root/.git"'"))'               "the worktree's top-level .git is read-only"
assert_contains "$profile" '(deny file-read* file-write* (literal "'"$profile_path"'"))'      "the profile denies access to itself"

# The worktree node and its ancestry are pinned.
assert_contains "$profile" '(deny file-write* (literal "'"$root"'"))'   "the worktree's own node is pinned against rename and delete"
unpinned=""
node="$(dirname "$root")"
while [ "$node" != / ]; do
    case "$profile" in
        *'(deny file-write* (literal "'"$node"'"))'*) ;;
        *) unpinned="$unpinned $node" ;;
    esac
    node="$(dirname "$node")"
done
assert_eq "$unpinned" "" "  -> and every node above it"
assert_not_contains "$profile" '(deny file-write* (literal "/"))'       "  -> stopping short of the root"

# Rule order: First blanket deny, then data-path allow holes, then deny exec surface
objects_allow='(allow file-write* (subpath "'"$gitdir/objects"'"))'
assert_rule_order "$profile_path" '(deny file-write* (subpath "'"$gitdir"'"))' "$objects_allow" \
    "the blanket write-deny precedes the data-path write allows"
assert_rule_order "$profile_path" "$objects_allow" '(deny file-write* (literal "'"$gitdir/config"'"))' \
    "the config pin follows the write allows (denied LAST)"
assert_rule_order "$profile_path" "$objects_allow" '(deny file-write* (literal "'"$root/.git"'"))' \
    "the top-level .git pin follows the write allows (denied LAST)"


# ---------------------------------------------------------------------------
echo "a linked worktree's hardening profile (DIR argument, as --worktree runs use)"
# ---------------------------------------------------------------------------
feat="$root/.worktrees/feat"
git -C "$main_repo" worktree add -q -b feat "$feat"
admin="$gitdir/worktrees/feat"

profile_path="$(harden_in "$main_repo" "$feat")"; st=$?
assert_zero "$st" "hardening a linked worktree via DIR exits zero"
profile="$(cat "$profile_path" 2>/dev/null)"

assert_contains "$profile" '(deny file-write* (subpath "'"$gitdir"'"))'                           "profile denies writing the shared git dir by default"
assert_contains "$profile" '(allow file-write* (subpath "'"$gitdir/objects"'"))'                  "profile re-allows writing the object database"
assert_not_contains "$profile" '(allow file-write* (subpath "'"$admin"'"))'                       "no blanket write grant on the worktree's own admin dir"
assert_contains "$profile" '(allow file-write* (subpath "'"$admin/refs"'"))'                      "  -> its per-worktree refs are re-allowed"
# ... more allow holes not listed explicitly

assert_contains "$profile" '(deny file-write* (literal "'"$admin/config.worktree"'"))'            "  -> but its config.worktree stays read-only"
assert_contains "$profile" '(deny file-write* (literal "'"$admin/commondir"'"))'                  "  -> and so does its commondir shared-dir pointer"
assert_contains "$profile" '(deny file-write* (literal "'"$gitdir/config"'"))'                    "the shared config is read-only"
assert_contains "$profile" '(deny file-write* (subpath "'"$gitdir/hooks"'"))'                     "  -> and the shared hooks/"
assert_contains "$profile" '(deny file-write* (literal "'"$feat/.git"'"))'                        "the worktree's own .git pointer file is read-only"
assert_contains "$profile" '(deny file-read* file-write* (literal "'"$profile_path"'"))'               "profile denies access to itself"
assert_contains "$profile" '(deny file-write* (literal "'"$feat"'"))'                             "the linked worktree's own node is pinned against rename and delete"

# Running WITHOUT the DIR argument from inside the linked worktree hardens the same way.
profile_path="$(harden_in "$feat")"; st=$?
assert_zero "$st" "a bare run from inside a linked worktree exits zero"
profile="$(cat "$profile_path" 2>/dev/null)"
assert_contains "$profile" '(allow file-write* (subpath "'"$admin/refs"'"))'                      "  -> its per-worktree refs are re-allowed"
assert_contains "$profile" '(deny file-write* (literal "'"$admin/config.worktree"'"))'            "  -> and its config.worktree stays pinned"


# ---------------------------------------------------------------------------
echo "submodules: poke holes to allow data, exec surface set to read-only"
# ---------------------------------------------------------------------------
submod_src="$TMPDIR/submod"; make_repo "$submod_src"
printf 'SUB_MARKER\n' > "$submod_src/sub-file.txt"
git -C "$submod_src" add sub-file.txt
git -C "$submod_src" commit -q -m sub

repo_with_submod="$TMPDIR/repo_with_submod"; make_repo "$repo_with_submod"
env "${allow_git_file_protocol[@]}" git -C "$repo_with_submod" submodule add -q "$submod_src" thesub 2>/dev/null
git -C "$repo_with_submod" commit -q -m 'add submodule'
submod="$repo_with_submod/thesub"
sub_main_worktree="$(realpath "$submod")"
sub_gitdir="$(realpath "$(git -C "$submod" rev-parse --absolute-git-dir)")"

# A standard run from the main worktree: the submodule's gitdir gets the full hole set, its
# exec surface stays read-only.
profile_path="$(harden_in "$repo_with_submod")"; st=$?
assert_zero "$st" "main-worktree hardening with a submodule exits zero"
profile="$(cat "$profile_path" 2>/dev/null)"
assert_contains "$profile" '(allow file-write* (subpath "'"$sub_gitdir/objects"'"))'  "the submodule's object database is re-allowed"
assert_contains "$profile" '(allow file-write* (prefix "'"$sub_gitdir/index"'"))'     "  -> and its index"
# A module gitdir is its own common dir: unlike a worktree admin dir, ITS info/exclude
# and info/attributes are what git reads inside the submodule, so set same narrow scope
# as the shared dir's info/.
assert_contains "$profile" '(allow file-write* (prefix "'"$sub_gitdir/info/sparse-checkout"'"))' "  -> and its sparse-checkout state"
assert_not_contains "$profile" '(allow file-write* (subpath "'"$sub_gitdir/info"'"))'            "  -> but NOT its whole info/ (its exclude/attributes are live)"
assert_contains "$profile" '(deny file-write* (literal "'"$sub_main_worktree/.git"'"))'      "its .git pointer file is read-only"
assert_contains "$profile" '(deny file-write* (literal "'"$sub_gitdir/config"'"))'    "  -> and its gitdir's config"
assert_contains "$profile" '(deny file-write* (subpath "'"$sub_gitdir/hooks"'"))'     "  -> and its gitdir's hooks/"
# The submodule's node is pinned like the worktree's own (see above): renaming it would
# carry its pinned .git pointer out from under the deny.
assert_contains "$profile" '(deny file-write* (literal "'"$sub_main_worktree"'"))'    "the submodule's own node is pinned against rename and delete"

# A submodule that fails to resolve aborts the run (no silently weakened profile)
shimdir="$TMPDIR/rp-shim"; mkdir -p "$shimdir"
real_rp="$(command -v realpath)"
cat > "$shimdir/realpath" <<EOF
#!/bin/sh
for a in "\$@"; do [ "\$a" = "$sub_main_worktree" ] && exit 1; done
exec "$real_rp" "\$@"
EOF
chmod +x "$shimdir/realpath"
out="$(PATH="$shimdir:$PATH" harden_in_err "$repo_with_submod")"; st=$?
assert_nonzero "$st" "a submodule resolution failure aborts the run"
assert_contains "$out" "could not resolve submodule" "  -> with the loud per-submodule error"
assert_contains "$out" "thesub"                      "  -> naming the submodule"

# The enumeration is not gated on a .gitmodules file in the worktree: git reads the
# submodule mapping from the index when the file isn't checked out (e.g. a sparse
# checkout), so a worktree can hold POPULATED submodules without it. Skipping them would
# leave each submodule's .git pointer writable in the writable tree.
rm "$repo_with_submod/.gitmodules"
profile_path="$(harden_in "$repo_with_submod")"; st=$?
assert_zero "$st" "hardening without a checked-out .gitmodules exits zero"
profile="$(cat "$profile_path" 2>/dev/null)"
assert_contains "$profile" '(deny file-write* (literal "'"$sub_main_worktree/.git"'"))'  "the populated submodule is still locked down"
assert_contains "$profile" '(deny file-write* (subpath "'"$sub_gitdir/hooks"'"))' "  -> including its gitdir's hooks"
git -C "$repo_with_submod" checkout -q -- .gitmodules


# ---------------------------------------------------------------------------
echo "a worktree whose admin dir escapes .git/worktrees is refused"
# ---------------------------------------------------------------------------
# How a sandbox reaches this: a `chopi --worktree host` command is isolated to
# .worktrees/host but may write anywhere INSIDE it -- including .worktrees/host/nested,
# itself a valid nested worktree name. So the host sandbox can plant a nested "worktree"
# whose .git points at a fake admin dir it also controls (adm/, here placed in host's tree
# but OUTSIDE host/nested). adm carries a commondir resolving back to the real shared
# .git. Were a profile built from it, the admin-dir write holes would hand host/nested's
# sandbox write access OUTSIDE its own tree, into the host worktree. The guard refuses:
# that admin dir isn't under .git/worktrees.
host="$main_repo/.worktrees/host"; nested="$host/nested"; nadm="$host/adm"
mkdir -p "$nested" "$nadm"
printf 'gitdir: %s\n' "$nadm"     > "$nested/.git"
printf 'ref: refs/heads/main\n'   > "$nadm/HEAD"
printf '%s\n' "$gitdir"           > "$nadm/commondir"
printf '%s\n' "$nested/.git"      > "$nadm/gitdir"
# Sanity-check the forge itself: git must accept it (common-dir matches) with an admin dir
# that escapes .git/worktrees, or the test would be asserting against some earlier failure.
forged_common="$(realpath "$(git -C "$nested" rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null || echo NONE)"
forged_gitdir="$(realpath "$(git -C "$nested" rev-parse --absolute-git-dir 2>/dev/null)" 2>/dev/null || echo NONE)"
assert_eq "$forged_common" "$gitdir"                          "forge sanity: its common dir resolves to the real shared .git"
is_path_within "$forged_gitdir" "$gitdir/worktrees"
assert_nonzero "$?" "forge sanity: its admin dir escapes .git/worktrees ($forged_gitdir)"
out="$(harden_in_err "$main_repo" "$nested")"; st=$?
assert_contains "$out" "must be a linked worktree's admin dir under" "the escaping admin dir is refused"
assert_nonzero "$st" "  -> and exits non-zero"
rm -rf "$host"


# ---------------------------------------------------------------------------
echo "isolation + hardening compose (harden appended after isolate narrows its grant)"
# ---------------------------------------------------------------------------
# chopi appends the two profiles isolation-first, hardening-second. For a LINKED worktree,
# isolation re-grants the shared git dir READ-WRITE (so git works); hardening, appended
# after, re-denies the write and pokes the data-path holes, with the exec surface set
# last as read-only. Concatenate them in chopi's order and assert last-match-wins yields
# the intended effect: broad rw -> write-denied -> objects re-allowed -> config denied.
protected_worktree="$root/.worktrees/compose"
git -C "$main_repo" worktree add -q -b compose "$protected_worktree"
profiles_paths_file="$TMPDIR/profiles_paths_file"
(cd "$protected_worktree" && "$protect_sh" >"$profiles_paths_file" 2>/dev/null)
iso_profile_path="$(nul_record 1 <"$profiles_paths_file")"
hard_profile_path="$(nul_record 2 <"$profiles_paths_file")"
combined_profile="$TMPDIR/combined.sb"
cat "$iso_profile_path" "$hard_profile_path" > "$combined_profile"
write_deny='(deny file-write* (subpath "'"$gitdir"'"))'
assert_rule_order "$combined_profile" '(allow file-read* file-write* (subpath "'"$gitdir"'"))' "$write_deny" \
    "isolation's shared-dir read-write grant precedes hardening's write-deny"
assert_rule_order "$combined_profile" "$write_deny" "$objects_allow" \
    "  -> and the write-deny precedes the objects re-allow"
assert_rule_order "$combined_profile" "$objects_allow" '(deny file-write* (literal "'"$gitdir/config"'"))' \
    "  -> and the config pin comes last (so config ends denied, objects allowed)"


# ---------------------------------------------------------------------------
echo "submodules: a submodule ROOT hardens as the main worktree of its own repo"
# ---------------------------------------------------------------------------
# A submodule's gitdir config sets core.worktree (git writes it), legitimately resolving
# to the submodule's own root. The submodule root hardens as its main worktree, with the
# module gitdir as the shared, hardened git dir.
got_cw="$(git -C "$submod" config --get core.worktree)"
if [ -n "$got_cw" ]; then ok "fixture sanity: the submodule's core.worktree is set ($got_cw)"; else bad "fixture sanity: expected core.worktree in the submodule gitdir config"; fi
profile_path="$(harden_in "$submod")"; st=$?
assert_zero "$st" "hardening a submodule root exits zero"
profile="$(cat "$profile_path" 2>/dev/null)"
assert_contains "$profile" '(deny file-write* (subpath "'"$sub_gitdir"'"))'                      "the module gitdir is write-denied by default"
assert_contains "$profile" '(allow file-write* (subpath "'"$sub_gitdir/objects"'"))'             "  -> with its object database re-allowed"
assert_contains "$profile" '(allow file-write* (prefix "'"$sub_gitdir/index"'"))'                "  -> and its index (checkout state lives in the module gitdir)"
assert_contains "$profile" '(allow file-write* (prefix "'"$sub_gitdir/info/sparse-checkout"'"))' "  -> and sparse-checkout state"
assert_not_contains "$profile" '(allow file-write* (subpath "'"$sub_gitdir/info"'"))'            "  -> but NOT the whole info/ (attributes/exclude stay denied)"
assert_contains "$profile" '(deny file-write* (literal "'"$sub_main_worktree/.git"'"))'                 "the submodule's .git pointer file is read-only"
assert_contains "$profile" '(deny file-write* (literal "'"$sub_gitdir/config"'"))'               "  -> and the module config"
assert_contains "$profile" '(deny file-write* (subpath "'"$sub_gitdir/hooks"'"))'                "  -> and the module hooks/"


# ---------------------------------------------------------------------------
echo "a --separate-git-dir root hardens as the main worktree"
# ---------------------------------------------------------------------------
sgd_root="$TMPDIR/sgd-root"; sgd_git="$TMPDIR/sgd-git"
make_repo "$sgd_root" --separate-git-dir "$sgd_git"
sgd_root_real="$(realpath "$sgd_root")"
sgd_git_real="$(realpath "$sgd_git")"

profile_path="$(harden_in "$sgd_root")"; st=$?
assert_zero "$st" "hardening a separate-git-dir root exits zero"
profile="$(cat "$profile_path" 2>/dev/null)"
assert_contains "$profile" '(deny file-write* (subpath "'"$sgd_git_real"'"))'          "the detached gitdir is write-denied by default"
assert_contains "$profile" '(allow file-write* (subpath "'"$sgd_git_real/objects"'"))' "  -> with its object database re-allowed"
assert_contains "$profile" '(allow file-write* (prefix "'"$sgd_git_real/index"'"))'    "  -> and its index (checkout state lives in the detached gitdir)"
assert_contains "$profile" '(deny file-write* (literal "'"$sgd_root_real/.git"'"))'    "the root's .git pointer file is read-only"
assert_contains "$profile" '(deny file-write* (literal "'"$sgd_git_real/config"'"))'   "  -> and the gitdir's config"
assert_contains "$profile" '(deny file-write* (subpath "'"$sgd_git_real/hooks"'"))'    "  -> and its hooks/"

# From a LINKED worktree of such a repo the main worktree is unresolvable
# (CHOPI_GIT_MAIN_WORKTREE stays empty). Hardening doesn't need it: the target's admin
# dir lives under the shared gitdir's worktrees/ either way, so the linked treatment
# applies unchanged.
sgd_worktree="$TMPDIR/sgd_worktree"
git -C "$sgd_root" worktree add -q -b sgd_feat "$sgd_worktree" >/dev/null 2>&1
sgd_admin="$sgd_git_real/worktrees/sgd_worktree"
profile_path="$(harden_in "$sgd_worktree")"; st=$?
assert_zero    "$st" "hardening a linked worktree of a separate-git-dir repo exits zero"
assert_present "$profile_path" "  -> and a profile is built"
profile="$(cat "$profile_path" 2>/dev/null)"
assert_contains "$profile" '(deny file-write* (subpath "'"$sgd_git_real"'"))'               "  -> the detached gitdir is write-denied by default"
assert_contains "$profile" '(allow file-write* (subpath "'"$sgd_admin/refs"'"))'            "  -> with the admin dir's refs re-allowed"
assert_contains "$profile" '(deny file-write* (literal "'"$sgd_admin/config.worktree"'"))'  "  -> and its config.worktree read-only"

# ---------------------------------------------------------------------------
summary

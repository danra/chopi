#!/usr/bin/env bash
#
# test/chopi-review.sh -- unit tests for reviewing and applying queued patches
#
# chopi-review is interactive: it refuses a non-terminal, and its apply/reject/skip prompt is
# the review. So the suite drives the real command through a pty (script -q /dev/null), feeding
# the answers a reviewer would type -- see answers() for why the last one repeats forever.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
. "$repo/.internal/util.sh"
. "$repo/.internal/write-targets.sh"
. "$repo/test/lib.sh"

header "test/chopi-review.sh -- unit tests for reviewing and applying queued patches"

TMPDIR="$(mktemp -d)"; export TMPDIR
TMPDIR="$(cd "$TMPDIR" && pwd -P)"
trap 'rm -rf "$TMPDIR"' EXIT

# chopi-review resolves the queue from $HOME, so keep it away from the developer's own: for the
# command under test through its environment, and for this suite's own calls through the root
# the lib resolved when it was sourced.
home="$TMPDIR/home"
mkdir -p "$home"
CHOPI_PATCH_QUEUE_ROOT="$home/.chopi/patch-queue"

target="$TMPDIR/guidelines"
config="$TMPDIR/config.sh"

# Write a sandbox config at $1 whose safe write targets are the remaining arguments.
write_config() {
    local file="$1"; shift
    {
        printf 'CHOPI_SAFEHOUSE_FLAGS=(); CHOPI_EXTRA_ENV=(); CHOPI_GIT_CONFIG=()\n'
        printf 'CHOPI_SAFE_WRITE_TARGETS=('
        if [ "$#" -gt 0 ]; then printf ' "%s"' "$@"; fi
        printf ' )\n'
    } > "$file"
}
write_config "$config" "$target"

# The workspace whose queue the patches land in.
work="$TMPDIR/work"
make_repo "$work"

# Build workspace $1's queue the way chopi does: source config $2, validate it, then create the
# queue from the paths validation left. The config is the whole input, landing in a local of its
# own, so the slots are always what the review is later given; a case that wants them to differ
# plants its slot by hand. A config that doesn't validate says so rather than failing further down.
build_queue() {
    arity 2
    local workspace="$1" cfg="$2"
    local CHOPI_SAFE_WRITE_TARGETS=()
    # shellcheck source=/dev/null  # can't follow a path each case builds at runtime
    . "$cfg"
    validate_write_targets "$workspace" chopi || echo "BUG: this case's config does not validate" >&2
    create_patch_queue "$workspace"
}

# Rebuild the target repo and an empty queue, so each case starts from the same state.
reset_fixture() {
    arity 0
    rm -rf "$target" "$home/.chopi"
    make_repo "$target"
    printf '# Guidelines\n\n## Comments\nBe brief.\n' > "$target/Guidelines.md"
    git -C "$target" add -A
    git -C "$target" commit -qm "add guidelines"
    queue="$(build_queue "$work" "$config")"
    slot="$queue/$(path_id "$target")"
}
# Number of commits in the fresh fixture: make_repo's init commit, and "add guidelines".
fixture_num_commits=2

# Queue a patch named $1 into slot $2, whose diff appends line $3 to file $4 of target $5, the way
# the sandboxed command is told to build one: edit a copy, diff it against the target, wrap it in
# a message.
queue_patch_into() {
    arity 5
    local slug="$1" into="$2" line="$3" file="$4" against="$5"
    local scratch="$TMPDIR/scratch-$slug" subdir
    subdir="$(dirname "$file")"
    rm -rf "$scratch"; mkdir -p "$scratch/a/$subdir" "$scratch/b/$subdir"
    cp "$against/$file" "$scratch/a/$file"
    cp "$against/$file" "$scratch/b/$file"
    printf '%s\n' "$line" >> "$scratch/b/$file"
    ( cd "$scratch" && git diff --no-index --no-prefix -- "a/$file" "b/$file" ) \
        | queue_raw_patch "$slug" "$into" "$slug"
}

# The common case: a patch for the suite's own target.
queue_patch() {
    arity 2
    queue_patch_into "$1" "$slot" "$2" Guidelines.md "$target"
}

# Queue a patch named $1 into slot $2 under subject $3, its diff read from stdin. For the shapes
# a diff against the target cannot produce: a file it doesn't have yet, a patch with no diff.
# The From: is an identity no fixture repo carries, so a commit's author observably came from
# the patch.
queue_raw_patch() {
    arity 3
    local slug="$1" into="$2" subject="$3"
    {
        printf 'From: Claude <noreply@anthropic.com>\n'
        printf 'Subject: [PATCH] %s\n\n' "$subject"
        printf 'Because the user said so twice.\n\n'
        printf -- '---\n'
        cat
    } > "$into/$slug.patch"
}

# A diff creating file $1 holding the single line $2.
creating_diff() {
    arity 2
    local path="$1" line="$2"
    printf 'diff --git a/%s b/%s\n' "$path" "$path"
    printf 'new file mode 100644\n'
    printf -- '--- /dev/null\n'
    printf '+++ b/%s\n' "$path"
    printf '@@ -0,0 +1 @@\n'
    printf '+%s\n' "$line"
}

# Feed the given answers in order, then repeat the last one forever: they must not run out while
# the command is still asking, or a prompt that refuses to guess reads EOF and the case ends
# somewhere no reviewer would recognize. The default 's' answers both prompts -- skip this patch,
# decline the offer -- which also keeps the pty fed for a command that never asks at all.
answers() {
    local given=("$@") last="s"
    [ "$#" -gt 0 ] && last="${given[$# - 1]}"
    { [ "$#" -eq 0 ] || printf '%s\n' "${given[@]}"; yes "$last"; } 2>/dev/null
}

# Run a command with the suite's HOME. CHOPI_DIR is unset explicitly, since the suite itself may
# be running inside a chopi session, where refusing is the right behavior and is asserted below.
with_test_env() {
    env -u CHOPI_DIR HOME="$home" "$@"
}

# The same, under a pty, with the pty's CRs stripped.
under_pty() {
    with_test_env script -q /dev/null "$@" 2>&1 | tr -d '\r'
}

# Output $1 with git's diff colors dropped, for assertions about what a review says rather than
# about how it looks. Kept out of under_pty so that the coloring itself can still be asserted on.
uncolored() {
    arity 1
    printf '%s' "$1" | sed $'s/\033\[[0-9;]*m//g'
}
esc="$(printf '\033')"

# Review against config $1, typing answers $2... run_review is the same against the suite's own.
review_with() {
    local cfg="$1"; shift
    answers "$@" | under_pty "$repo/bin/chopi-review" --config "$cfg"
}

run_review() {
    review_with "$config" "$@"
}

target_log()  { arity 0; git -C "$target" log --format='%s' -1; }
target_num_commits(){ arity 0; git -C "$target" rev-list --count HEAD; }

# Captured exit codes below rely on errexit being off.
set +e


# ---------------------------------------------------------------------------
echo "top-level refusals"
# ---------------------------------------------------------------------------
out="$(CHOPI_DIR="$repo" HOME="$home" "$repo/bin/chopi-review" --config "$config" 2>&1)"; st=$?
assert_eq       "$st" 1              "inside the sandbox it refuses"
assert_contains "$out" "on the host" "  -> pointing at the side of the sandbox that can apply a change"

out="$(with_test_env "$repo/bin/chopi-review" --config "$config" < /dev/null 2>&1)"; st=$?
assert_eq       "$st" 1              "without a terminal it refuses"
assert_contains "$out" "interactive" "  -> saying why"

out="$(review_with "$TMPDIR/absent.sh")"
assert_contains "$out" "absent.sh" "an unreadable config is an error naming the file"

out="$(answers | under_pty "$repo/bin/chopi-review" --config "$config" --queue "$TMPDIR/absent-queue")"
assert_contains "$out" "no patch queue" "a queue that was asked for by name and isn't there is an error"


# ---------------------------------------------------------------------------
echo "applying a patch"
# ---------------------------------------------------------------------------
reset_fixture
queue_patch only "Prefer semantics over technicalities."
out="$(run_review a)"

assert_contains "$out" "patch for $target" "the patch is announced with the target it would change"
assert_contains "$out" "generated from $work" \
    "  -> and the workspace it came from"
assert_contains "$(uncolored "$out")" "+Prefer semantics over technicalities." \
    "  -> and the diff is shown without being asked for"
assert_eq "$(target_log)" "only" "an approved patch becomes a commit in the target"
assert_eq "$(target_num_commits)" "$((fixture_num_commits + 1))" "  -> exactly one"
assert_eq "$(git -C "$target" log --format='%an <%ae> / %cn <%ce>' -1)" "Claude <noreply@anthropic.com> / t <t@t.t>" \
    "  -> committed by the reviewer, authored as the patch's From: header credits"
assert_eq "$(git -C "$target" log --format='%b' -1 | head -1)" "Because the user said so twice." \
    "  -> keeping the rationale as the commit body"
assert_eq "$(printf '%s\n' "$out" | grep -c 'Because the user said so twice.')" "1" \
    "  -> showing the rationale once in review"
assert_eq "$(git -C "$target" status --porcelain)" "" "  -> and leaving the target clean"

assert_absent "$slot/only.patch" "the applied patch leaves the queue"
assert_contains "$out" "1 applied" "the run reports what it did"

# A path git has to quote is a path like any other, and the commit has to record the one the patch
# names rather than git's rendering of it.
reset_fixture
awkward="two"$'\n'"lines.md"
printf 'a rule\n' > "$target/$awkward"
git -C "$target" add -A
git -C "$target" commit -qm "add a file under an awkward name"
queue_patch_into awkward_commit "$slot" "A rule to add." "$awkward" "$target"
out="$(run_review a)"

assert_eq "$(target_log)" "awkward_commit" "a patch for a path git reports quoted is committed"
assert_contains "$(git -C "$target" show "HEAD:$awkward")" "A rule to add." \
    "  -> to the path the patch names, not to git's spelling of it"
assert_eq "$(find "$target" -maxdepth 1 -name '*\\*' | wc -l | tr -d ' ')" 0 \
    "  -> leaving no file behind under that spelling"
assert_eq "$(git -C "$target" status --porcelain)" "" "  -> and the target clean"


# ---------------------------------------------------------------------------
echo "showing the diff the way git shows one"
# ---------------------------------------------------------------------------
reset_fixture
queue_patch colored "A rule to look at."
out="$(run_review s)"

assert_contains "$out" "${esc}[" "the diff is colored, a terminal being what a review is read on"
stat_line="$(printf '%s\n' "$out" | grep -m1 'Guidelines.md |')"
assert_contains "$stat_line" "${esc}[" "  -> as is the summary above it, rendered off the same index"

# Rendering off an index of the review's own keeps the target's staged work out of the display and
# its index untouched. Such a patch cannot land, but the diff is still what the reviewer came for,
# so the refusal follows it rather than replacing it.
reset_fixture
queue_patch alongside "A rule to look at while other work is staged."
printf 'unrelated staged work\n' > "$target/Other.md"
git -C "$target" add Other.md
out="$(run_review)"
assert_contains     "$out" "${esc}[" "a target with staged work is rendered all the same"
assert_not_contains "$out" "unrelated staged work" \
    "  -> showing the patch alone, not what the target happened to have staged"
assert_contains     "$out" "staged work in " "  -> and only then refusing, naming the reason"
assert_eq "$(git -C "$target" diff --cached --name-only)" "Other.md" \
    "  -> whose staging the rendering leaves as it found it"

reset_fixture
rm -rf "$target"
git init -q "$target"
creating_diff Guidelines.md "A rule proposed before there is any history." \
    | queue_raw_patch unborn "$slot" unborn
out="$(run_review s)"
assert_contains "$out" "${esc}[" "a target with no previous commits still has the diff rendered by git"
assert_contains "$(uncolored "$out")" "Guidelines.md | 1 +" "  -> summarized as the addition it is"

# Fallback to show raw patch diff if git diff fails
reset_fixture
queue_patch broken "A rule shown the hard way."
out="$(GIT_EXTERNAL_DIFF=/nonexistent run_review s)"
assert_contains "$(uncolored "$out")" "+A rule shown the hard way." \
    "a rendering git dies in falls back to the patch's own text"
rm -rf "$target/.git"
out="$(run_review s)"
assert_contains "$(uncolored "$out")" "+A rule shown the hard way." \
    "  -> and so does one for a target not contained in a worktree"


# ---------------------------------------------------------------------------
echo "more than one configured target"
# ---------------------------------------------------------------------------
second="$TMPDIR/second-target"
make_repo "$second"
printf '# Second\n' > "$second/Notes.md"
git -C "$second" add -A
git -C "$second" commit -qm "add notes"
write_config "$TMPDIR/two.sh" "$target" "$second"
reset_fixture
queue="$(build_queue "$work" "$TMPDIR/two.sh")"
second_slot="$queue/$(path_id "$second")"
queue_patch_into second "$second_slot" "A second-target rule." Notes.md "$second"
out="$(review_with "$TMPDIR/two.sh" a)"

assert_contains "$out" "patch for $second" "a patch for the second of two targets is recognized"
assert_eq "$(git -C "$second" log --format='%s' -1)" "second" "  -> and applied to it"
assert_not_contains "$out" "no longer a safe write target" "  -> with neither target read as unconfigured"


# ---------------------------------------------------------------------------
echo "the recipe the sandbox document ships"
# ---------------------------------------------------------------------------
reset_fixture
recipe="$(awk '/^```sh$/ { in_block = 1; next } /^```$/ { in_block = 0 } in_block' \
    "$repo/.internal/claude-sandbox-prompt.md")"
assert_contains "$recipe" 'chopi-queue-patch' "the extracted recipe queues through chopi-queue-patch"

# Pin the edit instruction in the recipe so we test the same thing we tell the agent to do
# shellcheck disable=SC2016
edit='printf "%s\\n" "$added" >> "$TMPDIR/draft"'
runnable="$(printf '%s\n' "$recipe" | sed "s|^# edit .*|$edit|")"
if [ "$runnable" != "$recipe" ]; then
    ok "  -> with an edit step this suite can stand in for"
else
    bad "  -> the recipe's 'edit ...' marker line is gone, so nothing was substituted"
fi

# Run it in a subshell, from the workspace, where the sandboxed command runs.
# shellcheck disable=SC2034  # the eval'd recipe reads these
(
    export CHOPI_PATCH_QUEUE="$queue"
    cd "$work"
    file="$target/Guidelines.md"
    subject="A rule built by the documented recipe"
    body="Because the recipe has to keep producing something appliable."
    added="Follow the recipe."
    eval "$runnable"
) >/dev/null 2>&1
collect_pending_patches "$slot"
recipe_patch="${PENDING_PATCHES[0]-/dev/null}"
assert_eq "${#PENDING_PATCHES[@]}" 1 "running it queues a patch"
assert_eq "$(head -1 "$recipe_patch")" "From: t <t@t.t>" \
    "  -> crediting the git ident the workspace resolves, time fields stripped"

out="$(run_review a)"
assert_eq "$(target_log)" "A rule built by the documented recipe" "  -> which chopi-review applies as a commit"
assert_eq "$(git -C "$target" log --format='%an' -1)" "t" "  -> authored as the recipe's From: header credits"
assert_contains "$(cat "$target/Guidelines.md")" "Follow the recipe." "  -> landing the change"


# ---------------------------------------------------------------------------
echo "not committing a patch"
# ---------------------------------------------------------------------------
reset_fixture
queue_patch unwanted "Something the user does not want."
out="$(run_review s)"
assert_eq "$(target_num_commits)" "$fixture_num_commits" "a skipped patch makes no commit"
assert_present "$slot/unwanted.patch" "  -> staying queued for the next review to ask about"
assert_contains "$out" "0 applied, 0 rejected, 1 skipped, 0 failed" \
    "  -> counted in the summary"

out="$(run_review r)"
assert_absent   "$slot/unwanted.patch" "a rejected patch is dropped from the queue"
assert_eq "$(target_num_commits)" "$fixture_num_commits" "  -> still without touching the target"
assert_contains "$out" "0 applied, 1 rejected, 0 skipped, 0 failed" "  -> and counted separately"

# Only a, r or s moves the prompt on, and until one arrives it comes back.
reset_fixture
queue_patch insisted "Something answered carelessly."
out="$(printf '\nx\033 s' | under_pty "$repo/bin/chopi-review" --config "$config")"
prompts="$(printf '%s\n' "$out" | grep -c '\[a\]pply')"
assert_eq "$(( prompts > 1 ))" 1 "return, an unknown key, ESC and space ask again"


# ---------------------------------------------------------------------------
echo "a target that moved under the patch"
# ---------------------------------------------------------------------------
reset_fixture
queue_patch stale "A rule that will conflict."
# Rewrite the same region the patch appends to, so it cannot apply.
printf '# Guidelines\n\n## Comments\nCompletely rewritten.\n' > "$target/Guidelines.md"
git -C "$target" commit -qam "rewrite"
before="$(git -C "$target" rev-parse HEAD)"
out="$(run_review a)"

assert_contains "$out" "conflicts with other committed changes" \
    "a conflicting patch says so before the reviewer answers"
assert_eq "$(git -C "$target" rev-parse HEAD)" "$before" "  -> and commits nothing itself"
assert_present "$target/.git/rebase-apply" \
    "  -> leaving git am stopped, the conflict there to be resolved rather than thrown away"
assert_contains "$out" "git am --continue" "  -> saying how to finish it"
assert_contains "$out" "git am --abort"    "  -> and how to back out"
assert_absent "$slot/stale.patch" "  -> and letting the queue go of it, the am holding it now"
assert_contains "$out" "+A rule that will conflict." \
    "  -> having still shown what was proposed, which git cannot render as a diff it cannot apply"

# A later review finds the worktree still mid-am and waits on it.
queue_patch behind "A rule queued behind the conflict."
out="$(run_review a)"
assert_contains "$out" "middle of an am" "a later review waits on the stopped am"
assert_present "$slot/behind.patch"      "  -> staying queued"

# And so does the rest of the same pass
reset_fixture
queue_patch a_conflicts "A rule that will conflict."
queue_patch b_behind    "A rule queued behind the conflict."
printf '# Guidelines\n\n## Comments\nCompletely rewritten.\n' > "$target/Guidelines.md"
git -C "$target" commit -qam "rewrite"
out="$(run_review a)"
assert_present "$target/.git/rebase-apply" "the first patch of a pass stops on its conflict"
assert_contains "$out" "wait until it is clear" \
    "  -> and the ones behind it in that same pass are set aside together"
assert_contains "$out" "- b_behind"        "  -> named, so it is clear what was left"
assert_not_contains "$out" "+A rule queued behind the conflict." \
    "  -> rather than each walked through a review that could only reach the same answer"
assert_present "$slot/b_behind.patch"      "  -> staying queued"
assert_contains "$out" "1 applied, 0 rejected, 1 skipped, 0 failed" \
    "  -> the conflict handed over, the one behind it stays queued"

# Finishing the am in the worktree lands the change, under the patch's own subject
printf '# Guidelines\n\n## Comments\nCompletely rewritten.\nA rule that will conflict.\n' \
    > "$target/Guidelines.md"
git -C "$target" add Guidelines.md
GIT_EDITOR=true git -C "$target" am --continue >/dev/null 2>&1
assert_absent "$target/.git/rebase-apply" "  -> who resolves it there and continues"
assert_eq "$(target_log)" "a_conflicts"   "  -> landing it under the patch's own subject"
assert_contains "$(cat "$target/Guidelines.md")" "A rule that will conflict." \
    "  -> with the change the patch proposed in the file"


# ---------------------------------------------------------------------------
echo "a change that arrived some other way"
# ---------------------------------------------------------------------------
# The patch is already in the target, so there is nothing left to apply and nothing to decide:
# it is accounted for and dropped without asking, rather than put to a reviewer whose every answer
# leaves the target exactly as it is.
reset_fixture
queue_patch already "A rule that arrived first."
printf 'A rule that arrived first.\n' >> "$target/Guidelines.md"
git -C "$target" commit -qam "the same rule, by hand"
before="$(git -C "$target" rev-parse HEAD)"
out="$(run_review a)"

assert_contains "$out" "noop, already there" "a patch whose diff the target already holds is a no-op"
assert_not_contains "$out" "[a]pply"  "  -> without asking"
assert_eq "$(git -C "$target" rev-parse HEAD)" "$before" "  -> making no commit of its own"
assert_absent "$slot/already.patch"   "  -> and is dropped from the queue"
assert_contains "$out" "1 applied, 0 rejected, 0 skipped, 0 failed" "  -> counted as applied"
assert_contains "$out" "+A rule that arrived first." \
    "  -> with what it proposed still on screen, though it proposes nothing new"

reset_fixture
printf '# Guidelines\n\n## Comments\nBe brief.\nBe kind.\nBe clear.\nBe precise.\n' \
    > "$target/Guidelines.md"
git -C "$target" commit -qam "guidelines long enough to carry context"
queue_patch drifted "A rule that arrived first."
printf '# Guidelines\n\n## Comments\nBe brief.\nBe KIND.\nBe clear.\nBe precise.\nA rule that arrived first.\n' \
    > "$target/Guidelines.md"
git -C "$target" commit -qam "the same rule by hand, and a reword within its context"
before="$(git -C "$target" rev-parse HEAD)"
out="$(run_review a)"
assert_contains "$out" "noop, already there" "a change that arrived with its context drifting is a no-op too"
assert_not_contains "$out" "[a]pply"        "  -> and is settled before the reviewer is asked"
assert_eq "$(git -C "$target" rev-parse HEAD)" "$before" "  -> making no commit of its own"
assert_absent "$slot/drifted.patch"          "  -> and is dropped from the queue"


# ---------------------------------------------------------------------------
echo "a target with uncommitted work on the path"
# ---------------------------------------------------------------------------
reset_fixture
queue_patch wip "A rule to add."
printf 'local work in progress\n' >> "$target/Guidelines.md"
out="$(run_review)"

assert_eq "$(target_num_commits)" "$fixture_num_commits" "nothing is committed while the path has uncommitted changes"
assert_contains "$out" "uncommitted"     "  -> refusing before git am starts, naming the reason"
assert_contains "$out" '"wip"'           "  -> and the patch, which git am never got to name"
assert_contains "$out" "Guidelines.md"   "  -> and the path"
assert_contains "$out" "commit or stash" "  -> with the way out"
assert_contains "$(git -C "$target" status --porcelain)" "Guidelines.md" "  -> and the local work is left alone"

reset_fixture
queue_patch arrived "A rule that arrived first."
printf 'A rule that arrived first.\n' >> "$target/Guidelines.md"
out="$(run_review a)"
assert_contains "$out" "uncommitted" "a change sitting uncommitted is not taken for one the target holds"
assert_present "$slot/arrived.patch" "  -> keeping the patch queued"
assert_eq "$(target_num_commits)" "$fixture_num_commits" "  -> and committing nothing"

# Robust to a path git reports quoted (here a path with a newline)
reset_fixture
awkward="two"$'\n'"lines.md"
printf 'a rule\n' > "$target/$awkward"
git -C "$target" add -A
git -C "$target" commit -qm "add a file under an awkward name"
queue_patch_into quoted_wip "$slot" "A rule to add." "$awkward" "$target"
printf 'local work in progress\n' >> "$target/$awkward"
out="$(run_review)"

assert_contains "$out" "uncommitted" "uncommitted work is found on a path git reports quoted"
assert_eq "$(target_num_commits)" "$((fixture_num_commits + 1))" "  -> so nothing is committed over it"


# ---------------------------------------------------------------------------
echo "a target with staged work"
# ---------------------------------------------------------------------------
# git am refuses any dirty index, whatever the patch touches, so the review says so itself rather
# than let it surface as a patch that failed.
reset_fixture
queue_patch staged "A rule to add."
printf 'unrelated staged work\n' > "$target/Other.md"
git -C "$target" add Other.md
out="$(run_review a)"

assert_eq "$(target_num_commits)" "$fixture_num_commits" "nothing is committed while the target has staged work"
assert_contains "$out" "staged work in " "  -> refusing with the reason and the repo it is in"
assert_contains "$out" '"staged"'        "  -> and which patch waits on it"
assert_contains "$out" "0 applied, 0 rejected, 1 skipped, 0 failed" \
    "  -> counted as waiting rather than as a bad patch"
assert_eq "$(git -C "$target" diff --cached --name-only)" "Other.md" \
    "  -> leaving the staged work as it found it"
assert_present "$slot/staged.patch"      "  -> and the patch queued"


# ---------------------------------------------------------------------------
echo "a trial run that could not be set up"
# ---------------------------------------------------------------------------
# Every verdict comes from applying the patch to a copy of the target's index, so a copy that
# cannot be made leaves nothing known about the patch. Here the temp file for it is refused.
reset_fixture
queue_patch a_untried "A rule that never gets tried."
queue_patch b_behind  "A rule queued behind it."
shimdir="$TMPDIR/mktemp-shim"; mkdir -p "$shimdir"
real_mktemp="$(command -v mktemp)"
cat > "$shimdir/mktemp" <<EOF
#!/bin/sh
for a in "\$@"; do case "\$a" in *simulated.XXXXXX) exit 1 ;; esac; done
exec "$real_mktemp" "\$@"
EOF
chmod +x "$shimdir/mktemp"
out="$(PATH="$shimdir:$PATH" run_review a)"

assert_contains "$out" "could not copy the git index" "a trial run that cannot be set up says so"
assert_contains "$out" '"a_untried"'   "  -> naming the patch it could not answer for"
assert_not_contains "$out" "[a]pply"   "  -> and not asking about a patch nothing is known about"
assert_eq "$(target_num_commits)" "$fixture_num_commits" "  -> committing nothing"
assert_contains "$out" "wait until it is clear" \
    "  -> the rest of the target's patches set aside, the next one meeting the same wall"
assert_contains "$out" "- b_behind"    "  -> named, so it is clear what was left"
assert_present "$slot/a_untried.patch" "the patches stay queued for a review that can try them"
assert_present "$slot/b_behind.patch"  "  -> both of them"
assert_contains "$out" "0 applied, 0 rejected, 1 skipped, 1 failed" \
    "  -> the untried patch counted as a failure, so the run doesn't come out clean"
assert_contains "$(uncolored "$out")" "+A rule that never gets tried." \
    "  -> having still shown what was proposed, off the patch's own text"


# ---------------------------------------------------------------------------
echo "a review interrupted during git am leaves a clean state"
# ---------------------------------------------------------------------------
walk_away_from() {
    arity 1
    local dir="$1" waited=0
    printf 'c\n'
    while [ ! -d "$dir/.git/rebase-apply" ] && [ "$waited" -lt 200 ]; do
        sleep 0.05
        waited=$((waited + 1))
    done
    printf '\003'
    answers s
}

reset_fixture
queue_patch abandoned "A rule the reviewer walks away from."
# An am that stays open long enough to be interrupted on purpose: pre-applypatch runs with the
# patch applied and the commit not yet made.
printf '#!/bin/sh\nsleep 10\n' > "$target/.git/hooks/pre-applypatch"
chmod +x "$target/.git/hooks/pre-applypatch"
out="$(walk_away_from "$target" | under_pty "$repo/bin/chopi-review" --config "$config")"
rm -f "$target/.git/hooks/pre-applypatch"

# Without this the case could pass on an answered prompt rather than an interrupted one: the
# summary is the last thing a run that finishes prints.
assert_not_contains "$out" "0 applied" "^C partway through the am cuts the review short"
assert_absent  "$target/.git/rebase-apply" "  -> leaving no half-finished am behind"
assert_eq      "$(target_num_commits)" "$fixture_num_commits" "  -> and no commit"
assert_eq      "$(git -C "$target" status --porcelain)" "" "  -> on a target as clean as it found it"
assert_present "$slot/abandoned.patch"     "  -> with the patch still queued"

out="$(run_review a)"
assert_eq "$(target_log)" "abandoned" "  -> and the way clear for the next review to apply it"


# ---------------------------------------------------------------------------
echo "a target already in the middle of something"
# ---------------------------------------------------------------------------
stop_an_am_in() {
    arity 1
    local dir="$1" mbox="$TMPDIR/foreign-mbox"
    rm -rf "$mbox"
    git -C "$dir" checkout -q -b foreign
    printf 'first\n' > "$dir/Foreign.md"
    git -C "$dir" add Foreign.md
    git -C "$dir" commit -qm "a patch of the reviewer's own"
    printf 'second\n' >> "$dir/Guidelines.md"
    git -C "$dir" commit -qam "one that will not apply"
    git -C "$dir" format-patch -2 -o "$mbox" -q
    git -C "$dir" checkout -q -
    # Diverge, so the second of the two patches stops the am
    printf 'diverged\n' >> "$dir/Guidelines.md"
    git -C "$dir" commit -qam "work of the reviewer's own"
    git -C "$dir" am "$mbox"/*.patch >/dev/null 2>&1 || true
}

reset_fixture
queue_patch waiting "A rule that has to wait its turn."
stop_an_am_in "$target"
before="$(git -C "$target" rev-parse HEAD)"
# Answer [a]pply to prove the prompt doesn't actually appear (patch is force-skipped)
out="$(run_review a)"

assert_present  "$target/.git/rebase-apply" "an am of the reviewer's own is left in progress"
assert_eq       "$(git -C "$target" rev-parse HEAD)" "$before" "  -> at the commit it had reached"
assert_eq       "$(target_log)" "a patch of the reviewer's own" "  -> keeping what it had already applied"
assert_contains "$out" "in the middle of"   "  -> with the review saying what is in the way"
assert_contains "$out" '"waiting"'          "  -> for which patch"
assert_contains "$out" "chopi-review again" "  -> and what to do about it"
assert_present  "$slot/waiting.patch" "  -> leaving the patch queued for once the way is clear"

reset_fixture
queue_patch queuing "A rule behind a rebase."
git -C "$target" rebase --quiet --exec false HEAD~1 >/dev/null 2>&1 || true
out="$(run_review a)"

assert_contains "$out" "in the middle of" "a target mid-rebase is recognized as in the middle of something"
assert_present  "$target/.git/rebase-merge" "  -> and left in it"
assert_present  "$slot/queuing.patch"       "  -> with its patch still queued"


# ---------------------------------------------------------------------------
echo "a patch that would write outside its target"
# ---------------------------------------------------------------------------
reset_fixture
queue_patch escape "Innocuous."
# '..' is the only spelling that leaves the target: git resolves an absolute header path into a
# relative one. git would refuse this too, but only after the reviewer had answered.
sed -i '' 's|Guidelines.md|../escape.md|g' "$slot/escape.patch"
out="$(run_review a)"

assert_contains "$out" "refused"        "a patch reaching outside the target is refused"
assert_contains "$out" "../escape.md"   "  -> naming the path"
assert_contains "$out" "+Innocuous."    "  -> having still shown what it proposed"
assert_not_contains "$out" "[a]pply"   "  -> but never asking: a refusal is not the reviewer's to override"
assert_eq "$(target_num_commits)" "$fixture_num_commits" "  -> without committing anything"
assert_absent "$TMPDIR/escape.md"       "  -> and nothing written beside the target"

# An absolute header path is not a way out.
reset_fixture
queue_patch shown "A rule to add."
sed -i '' 's|^--- a/Guidelines.md|--- /etc/passwd|; s|^+++ b/Guidelines.md|+++ /etc/passwd|' \
    "$slot/shown.patch"
out="$(run_review s)"
assert_contains     "$out" "Guidelines.md" "an absolute path in a diff header is summarized as the path git resolves"
assert_not_contains "$out" " /etc/passwd |" "  -> not as the absolute one the header claims"

# No '.git' allowed in path, regardless of whether a git dir is detected
reset_fixture
rm -rf "$target/.git" # remove git dir so it's not detected
creating_diff ".git/hooks/pre-commit" "echo pwned" | queue_raw_patch hook "$slot" hook
out="$(run_review a)"
assert_contains "$out" "refused"               "a patch writing into a path containing .git is refused"
assert_contains "$out" ".git/hooks/pre-commit" "  -> naming the path"
assert_absent "$target/.git/hooks/pre-commit"  "  -> and the hook is never written"

# The name is only half the rule, also ask git
reset_fixture
git init -q --bare "$target/backup.git"
queue_patch_into cross "$slot" "sneak = true" backup.git/config "$target"
out="$(run_review a)"
assert_contains "$out" "refused"           "a patch into a bare repo below the target is refused, no .git component in sight"
assert_contains "$out" "backup.git/config" "  -> naming the path"
assert_not_contains "$(cat "$target/backup.git/config")" "sneak" "  -> and the gitdir is never written"

# Robust to paths git quotes in patches, here one with a newline. Asserted on both apply paths:
# the refusal comes before the dispatch between them, and each renders the patch its own way.
quoted_escape_diff() {
    printf 'diff --git "a/../es\\ncaped.md" "b/../es\\ncaped.md"\n'
    printf 'new file mode 100644\n'
    printf -- '--- /dev/null\n'
    printf '+++ "b/../es\\ncaped.md"\n'
    printf '@@ -0,0 +1 @@\n'
    printf '+planted\n'
}

reset_fixture
quoted_escape_diff | queue_raw_patch quoted "$slot" quoted
out="$(run_review a)"
assert_contains "$out" "refused" "an escaping path is refused whether or not git had to quote it"
assert_eq "$(target_num_commits)" "$fixture_num_commits" "  -> without committing anything"
assert_eq "$(find "$TMPDIR" -maxdepth 1 -name '*caped.md*' | wc -l | tr -d ' ')" 0 \
    "  -> and nothing is written beside the target, under any spelling of the name"

reset_fixture
rm -rf "$target/.git"
quoted_escape_diff | queue_raw_patch quoted "$slot" quoted
out="$(run_review a)"
assert_contains "$out" "refused" "the same with the target a plain directory, applied without git am"
assert_eq "$(find "$TMPDIR" -maxdepth 1 -name '*caped.md*' | wc -l | tr -d ' ')" 0 \
    "  -> and nothing written beside it there either"


# ---------------------------------------------------------------------------
echo "a patch with no diff"
# ---------------------------------------------------------------------------
reset_fixture
queue_raw_patch noop "$slot" "a no-op edit" < /dev/null
out="$(run_review a)"
assert_contains "$out" "carries no diff; nothing to apply" "a patch carrying no diff is a no-op"
assert_not_contains "$out" "[a]pply"   "  -> without asking"
assert_eq "$(target_num_commits)" "$fixture_num_commits" "  -> or committing anything"
assert_absent "$slot/noop.patch"        "  -> and is dropped from the queue"
assert_contains "$out" "1 applied, 0 rejected, 0 skipped, 0 failed" "  -> counted as applied"

reset_fixture
printf 'No changes were needed; the rule is already in Guidelines.md.\n' \
    | queue_raw_patch unreadable "$slot" "an explanation instead of a diff"
out="$(run_review a)"
assert_contains "$out" "no diff git can parse" "a diff section git cannot read is refused"
assert_contains "$out" '"an explanation instead of a diff"' "  -> naming the patch"
assert_not_contains "$out" "[a]pply"   "  -> without asking either"
assert_present "$slot/unreadable.patch" "  -> keeping it for a human to look at"
assert_contains "$out" "0 applied, 0 rejected, 0 skipped, 1 failed" "  -> counted as a failure"

reset_fixture
printf 'From: C <n@a.z>\nSubject: [PATCH] no separator\n\nA note, and no diff section.\n' \
    > "$slot/noseparator.patch"
out="$(run_review a)"
assert_contains "$out" "no diff git can parse" "a file with no diff section at all is refused"
assert_present "$slot/noseparator.patch"      "  -> and kept, rather than dropped as a noop"


# ---------------------------------------------------------------------------
echo "a slot the config does not allow"
# ---------------------------------------------------------------------------
# A coherent slot for a path that is no longer configured. The config is the gate, so this is
# refused.
reset_fixture
retired="$TMPDIR/retired-target"
mkdir -p "$retired"
retired_slot="$queue/$(path_id "$retired")"
mkdir -p "$retired_slot"
printf '%s\0' "$retired" > "$retired_slot/TARGET"
cp "$target/Guidelines.md" "$retired/Guidelines.md"
queue_patch orphan "A rule for a target that went away."
mv "$slot/orphan.patch" "$retired_slot/orphan.patch"
out="$(run_review)"
assert_contains "$out" "no longer a safe write target" "a slot for an unconfigured path is refused"
assert_contains "$out" "$retired"  "  -> named by the path its own record gives, not by a digest"
assert_present "$retired_slot/orphan.patch" "  -> and its patches are left alone rather than applied somewhere"
assert_absent "$retired/Guidelines.md.orig" "  -> with nothing written where it pointed"
assert_contains "$out" "1 failed"           "  -> counted, so the run doesn't come out clean"

# A slot that disagrees with its own name is not believed at all, allowed or not: the record is
# write-denied to the sandboxed command, so one that doesn't hash back means corruption, or a
# protection that didn't hold.
reset_fixture
queue_patch bent "A rule from a slot whose record went bad."
printf '%s\0' "$TMPDIR/somewhere-else" > "$slot/TARGET"
out="$(run_review a)"
assert_contains "$out" "safe write target record is invalid" \
    "a slot whose record doesn't hash back is refused"
assert_eq "$(target_num_commits)" "$fixture_num_commits" "  -> committing nothing"
assert_present "$slot/bent.patch" "  -> and leaving the patch queued"

# Similarly validate the queue's own WORKSPACE record
reset_fixture
queue_patch adrift "A rule from a queue that cannot say where it came from."
printf '%s\0' "$TMPDIR/elsewhere" > "$queue/WORKSPACE"
out="$(run_review a)"
assert_contains "$out" "workspace record is invalid" "a queue whose workspace record doesn't hash back is refused"
assert_eq "$(target_num_commits)" "$fixture_num_commits" "  -> committing nothing, though the target it names is configured"
assert_present "$slot/adrift.patch" "  -> and leaving the patch queued"
assert_contains "$out" "1 failed" "  -> counted, so the run doesn't come out clean"


# ---------------------------------------------------------------------------
echo "a target configured relative to the workspace"
# ---------------------------------------------------------------------------
write_config "$TMPDIR/relative.sh" notes
reset_fixture
rel_target="$work/notes"
make_repo "$rel_target"
printf '# Guidelines\n\n## Comments\nBe brief.\n' > "$rel_target/Guidelines.md"
git -C "$rel_target" add -A
git -C "$rel_target" commit -qm "add guidelines"
queue="$(build_queue "$work" "$TMPDIR/relative.sh")"
rel_slot="$queue/$(path_id "$rel_target")"
queue_patch_into relative "$rel_slot" "A rule reached through a relative target." Guidelines.md "$rel_target"
out="$(review_with "$TMPDIR/relative.sh" a)"
assert_eq "$(git -C "$rel_target" log --format='%s' -1)" "relative" \
    "a workspace-relative target resolves against the queue's workspace"
assert_contains "$out" "patch for $rel_target" "  -> and is shown resolved, not as configured"

# A relative target resolves against the recorded workspace, so a record that doesn't hash back is
# never resolved against: the record is write-denied to the sandboxed command, and one that went
# bad regardless is no basis for aiming a patch.
reset_fixture
queue="$(build_queue "$work" "$TMPDIR/relative.sh")"
rel_slot="$queue/$(path_id "$rel_target")"
queue_patch_into askew "$rel_slot" "A rule aimed somewhere else." Guidelines.md "$rel_target"
mkdir -p "$TMPDIR/elsewhere/notes"
printf '%s\0' "$TMPDIR/elsewhere" > "$queue/WORKSPACE"
out="$(review_with "$TMPDIR/relative.sh" a)"
assert_contains "$out" "workspace record is invalid" \
    "a workspace record that doesn't hash back is not resolved against"
assert_present "$rel_slot/askew.patch" "  -> leaving the patch queued"
assert_absent "$TMPDIR/elsewhere/notes/Guidelines.md" "  -> and writing nothing where it pointed"


# ---------------------------------------------------------------------------
echo "a single-file target"
# ---------------------------------------------------------------------------
write_config "$TMPDIR/file.sh" CLAUDE.md
reset_fixture
printf '# Rules\n' > "$work/CLAUDE.md"
git -C "$work" add CLAUDE.md
git -C "$work" commit -qm "add CLAUDE.md"
file_target="$work/CLAUDE.md"
queue="$(build_queue "$work" "$TMPDIR/file.sh")"
file_slot="$queue/$(path_id "$file_target")"
queue_patch_into "one rule" "$file_slot" "Never force-push." CLAUDE.md "$work"
out="$(review_with "$TMPDIR/file.sh" a)"
assert_eq "$(git -C "$work" log --format='%s' -1)" "one rule" \
    "a file target is applied in its parent, one commit per patch"
assert_contains "$(cat "$file_target")" "Never force-push." "  -> changing the file"
assert_contains "$out" "patch for $file_target" "  -> and shown as the file, not its directory"

printf 'x\n' > "$work/other.md"
queue_patch_into sneaky "$file_slot" "A rule elsewhere." other.md "$work"
out="$(review_with "$TMPDIR/file.sh" a)"
assert_contains "$out" "refused"     "a patch writing any other path is refused"
assert_contains "$out" "other.md"    "  -> naming the path"
assert_contains "$out" "single file" "  -> and the reason"
assert_eq "$(git -C "$work" log --format='%s' -1)" "one rule" "  -> committing nothing"


# ---------------------------------------------------------------------------
echo "a target nested inside a repo"
# ---------------------------------------------------------------------------
write_config "$TMPDIR/nested.sh" docs
reset_fixture
nested="$work/docs"
mkdir -p "$nested"
printf '# Docs\n' > "$nested/Notes.md"
git -C "$work" add docs
git -C "$work" commit -qm "add docs"
queue="$(build_queue "$work" "$TMPDIR/nested.sh")"
nested_slot="$queue/$(path_id "$nested")"
queue_patch_into "a nested rule" "$nested_slot" "Write it down." Notes.md "$nested"
out="$(review_with "$TMPDIR/nested.sh" a)"
assert_eq "$(git -C "$work" log --format='%s' -1)" "a nested rule" \
    "a nested target's patch is committed by the repo holding it"
assert_contains "$(cat "$nested/Notes.md")" "Write it down." "  -> changing the file"
assert_eq "$(git -C "$work" status --porcelain -- docs)" "" "  -> leaving the target clean"
assert_absent "$nested/Notes.md.orig" "  -> and no .orig backup, which has no commit to revert from"
assert_contains "$out" "docs/Notes.md" "  -> shown at its path in the committing repo"


# ---------------------------------------------------------------------------
echo "a target that cannot be written"
# ---------------------------------------------------------------------------
reset_fixture
vanishing="$TMPDIR/vanishing"
mkdir -p "$vanishing"
write_config "$TMPDIR/vanishing.sh" "$vanishing"
queue="$(build_queue "$work" "$TMPDIR/vanishing.sh")"
vanishing_slot="$queue/$(path_id "$vanishing")"
printf 'x\n' > "$vanishing_slot/gone.patch"
printf 'x\n' > "$vanishing_slot/alongside.patch"
rmdir "$vanishing"
out="$(review_with "$TMPDIR/vanishing.sh" a)"
assert_contains "$out" "chopi-review: safe write target is not a directory" \
    "a target that isn't there is refused"
assert_eq "$(printf '%s\n' "$out" | grep -c 'is not a directory')" 1 \
    "  -> saying it once for the slot, not once per patch it holds"
assert_contains "$out" "2 failed" "  -> but counting every patch it turned away"
assert_present "$vanishing_slot/gone.patch" "  -> and leaving them queued"

reset_fixture
vanished="$TMPDIR/vanished"
mkdir -p "$vanished"
write_config "$TMPDIR/half-usable.sh" "$target" "$vanished"
queue="$(build_queue "$work" "$TMPDIR/half-usable.sh")"
slot="$queue/$(path_id "$target")"
queue_patch stopped "A rule for the target that is fine."
rmdir "$vanished"
out="$(review_with "$TMPDIR/half-usable.sh" a)"
assert_contains "$out" "is not a directory" "one entry that can't be honored refuses the whole queue"
assert_eq "$(target_num_commits)" "$fixture_num_commits" "  -> committing nothing for the target that is fine"
assert_present "$slot/stopped.patch"     "  -> whose patches wait for the config to be fixed"

# Every rule chopi refuses a target on is asked again here, off a config that may have been edited
# since. A git directory matters most: chopi would never have built this slot, but the queue is
# writable, so the command can leave one that looks just like it.
reset_fixture
hooks="$TMPDIR/other-repo/.git/hooks"
mkdir -p "$hooks"
hooks_slot="$queue/$(path_id "$hooks")"
mkdir -p "$hooks_slot"
printf '%s\0' "$hooks" > "$hooks_slot/TARGET"
printf 'x\n' > "$hooks_slot/planted.patch"
write_config "$TMPDIR/hooks.sh" "$hooks"
out="$(review_with "$TMPDIR/hooks.sh" a)"
assert_contains "$out" "has a .git component" "a git directory is refused at apply time too, not just at chopi's startup"
assert_present "$hooks_slot/planted.patch"    "  -> leaving the patch queued"


# ---------------------------------------------------------------------------
echo "a target that is not a git repo"
# ---------------------------------------------------------------------------
reset_fixture
queue_patch plain "A rule for a plain directory."
rm -rf "$target/.git"
out="$(run_review a)"
assert_contains "$out" "target not in git repo" "a plain directory is applied without pretending there is a commit"
assert_contains "$out" "Because the user said so twice." "  -> with the message shown"
assert_contains "$(cat "$target/Guidelines.md")" "A rule for a plain directory." "  -> the change lands"
assert_present "$target/Guidelines.md.orig" "  -> leaving a backup beside it"
# Rendered by git, off before and after copies, rather than read out as plain text.
assert_contains "$out" "${esc}[" "  -> and the diff is git's, colored as everywhere else"
assert_contains "$(uncolored "$out")" "Guidelines.md |" "  -> with a summary above it"

reset_fixture
rm -rf "$target/.git"
creating_diff Fresh.md "A rule on a path the target does not have yet." \
    | queue_raw_patch fresh "$slot" fresh
out="$(run_review a)"
assert_contains "$out" "${esc}[" "a patch creating a file in a plain directory renders the same way"
assert_contains "$(cat "$target/Fresh.md")" "A rule on a path the target does not have yet." "  -> and applies"
assert_absent "$target/Fresh.md.orig" "  -> with no .orig since there was nothing there to back up"

reset_fixture
rm -rf "$target/.git"
ln -s old/target "$target/Elsewhere.md"
{
    printf 'diff --git a/Elsewhere.md b/Elsewhere.md\n'
    printf 'index 1111111..2222222 120000\n'
    printf -- '--- a/Elsewhere.md\n'
    printf '+++ b/Elsewhere.md\n'
    printf '@@ -1 +1 @@\n'
    printf -- '-old/target\n'
    printf '\\ No newline at end of file\n'
    printf '+new/target\n'
    printf '\\ No newline at end of file\n'
} | queue_raw_patch retarget "$slot" retarget
out="$(run_review a)"
assert_contains "$out" "${esc}[" "a patch retargeting a dangling symlink is rendered by git too"
assert_contains "$(uncolored "$out")" "+new/target" "  -> showing where the link is being pointed"
assert_eq "$(readlink "$target/Elsewhere.md")" "new/target" "  -> and the retarget lands"
assert_eq "$(readlink "$target/Elsewhere.md.orig")" "old/target" \
    "  -> with the a backup of the link beside it"

# A change that arrived some other way, accounted for the way a git target accounts for it, with
# nothing written and so no backup left behind.
reset_fixture
queue_patch already "A rule that arrived first."
rm -rf "$target/.git"
printf 'A rule that arrived first.\n' >> "$target/Guidelines.md"
out="$(run_review a)"

assert_contains "$out" "noop, already there" "a plain target that already holds the diff is a no-op too"
assert_not_contains "$out" "[a]pply"  "  -> without asking either"
assert_contains "$(cat "$target/Guidelines.md")" "A rule that arrived first." \
    "  -> leaving the target as it was"
assert_absent "$target/Guidelines.md.orig" "  -> with no backup, since nothing was written"
assert_absent "$slot/already.patch"        "  -> and dropped from the queue"
assert_contains "$out" "1 applied, 0 rejected, 0 skipped, 0 failed" "  -> counted as applied"

# A path git has to quote is a path like any other, and the file that lands has to be the one the
# patch names rather than git's rendering of it.
reset_fixture
rm -rf "$target/.git"
awkward="two"$'\n'"lines.md"
printf 'a rule\n' > "$target/$awkward"
queue_patch_into awkward_plain "$slot" "A rule to add." "$awkward" "$target"
out="$(run_review a)"

assert_contains "$(cat "$target/$awkward")" "A rule to add." \
    "a patch for a path git reports quoted lands on that path"
assert_eq "$(find "$target" -maxdepth 1 -name '*\\*' | wc -l | tr -d ' ')" 0 \
    "  -> rather than under a name spelled the way git renders it"
# The backup is chopi's own doing, off the path it read out of the patch, so it is what says the
# path was read unquoted rather than left in git's spelling.
assert_present "$target/$awkward.orig" "  -> with the previous contents beside it under that path"


# ---------------------------------------------------------------------------
echo "an empty queue"
# ---------------------------------------------------------------------------
reset_fixture
out="$(under_pty "$repo/bin/chopi-review" --config "$config" < /dev/null)"
assert_contains     "$out" "nothing pending" "an empty queue says so"

write_config "$TMPDIR/no-targets.sh"
out="$(review_with "$TMPDIR/no-targets.sh")"
assert_contains "$out" "no safe write targets configured" "with the feature unconfigured it says so instead of nothing"


# ---------------------------------------------------------------------------
echo "the offer chopi makes when the command exits"
# ---------------------------------------------------------------------------
# Composed the way chopi.sh composes it -- the offer decides, the caller runs the review.
exit_offer="
    . '$repo/.internal/util.sh'
    . '$repo/.internal/write-targets.sh'
    offer_reviewing_queued_workspace_patches '$queue' && '$repo/bin/chopi-review' --config '$config' --queue '$queue'"

run_exit_offer() {
    answers "$@" | under_pty bash -c "$exit_offer"
}

reset_fixture
out="$(run_exit_offer)"
assert_not_contains "$out" "for review" "with nothing pending it makes no offer, so a clean session ends clean"

reset_fixture
queue_patch offered "A rule worth keeping."
out="$(run_exit_offer n)"
assert_contains "$out" "1 patch(es) for review" "with something pending it offers to review"
assert_contains "$out" "left for later"         "  -> and declining leaves it queued"
assert_contains "$out" "chopi-review"           "  -> naming the command that applies it"
assert_eq "$(target_num_commits)" "$fixture_num_commits" "  -> having committed nothing"

out="$(run_exit_offer "" a)"
assert_contains "$out" "patch for $target" "an empty answer accepts the offer and starts the review"
assert_eq "$(target_log)" "offered"        "  -> which applies the patch"

reset_fixture
queue_patch mine "A rule from this session."
other_work="$TMPDIR/other-work"
make_repo "$other_work"
other_queue="$(build_queue "$other_work" "$config")"
other_slot="$other_queue/$(path_id "$target")"
queue_patch_into theirs "$other_slot" "A rule from another session." Guidelines.md "$target"
out="$(run_exit_offer "" s)"
assert_contains "$out" "1 patch(es) for review" "the offer counts only the exiting session's workspace queue"
assert_contains "$out" "0 applied, 0 rejected, 1 skipped, 0 failed" \
    "  -> and the review it starts puts that same one to the reviewer"
assert_contains     "$out" "A rule from this session."    "  -> the patch being this session's"
assert_not_contains "$out" "A rule from another session." "  -> not one another workspace's session queued"
assert_present "$other_slot/theirs.patch" "  -> which stays queued for a review of its own"
out="$(run_review s)"
assert_contains "$out" "A rule from another session." "run by hand it reviews every workspace's queue"

reset_fixture
queue_patch skipped "A rule to skip."
out="$(answers a | with_test_env bash -c "$exit_offer" 2>&1)"
assert_eq "$out" "" "without a terminal the offer is skipped rather than stalling a scripted run"
assert_eq "$(target_num_commits)" "$fixture_num_commits" "  -> and nothing is applied unattended"

# ---------------------------------------------------------------------------
echo "Robust to a patch path that contains a newline"
# ---------------------------------------------------------------------------
reset_fixture
queue_patch awkward "A rule under an awkward name."
mv "$slot/awkward.patch" "$slot/two"$'\n'"lines.patch"
out="$(run_exit_offer "" a)"
assert_contains "$out" "1 patch(es) for review"        "a patch named with a newline is counted"
assert_contains "$out" "A rule under an awkward name." "  -> and put to review"
assert_eq "$(target_log)" "awkward"                    "  -> and applies like any other"
assert_absent "$slot/two"$'\n'"lines.patch"            "  -> leaving the queue"


# ---------------------------------------------------------------------------
summary

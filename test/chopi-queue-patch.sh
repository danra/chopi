#!/usr/bin/env bash
#
# test/chopi-queue-patch.sh -- unit tests for authoring and queueing patches in-session

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
. "$repo/.internal/util.sh"
. "$repo/test/lib.sh"

header "test/chopi-queue-patch.sh -- unit tests for authoring and queueing patches in-session"

TMPDIR="$(mktemp -d)"
# The script's realpath resolves through the /var symlink, so canonicalize before composing
# the paths the assertions expect.
TMPDIR="$(cd "$TMPDIR" && pwd -P)"; export TMPDIR
trap 'rm -rf "$TMPDIR"' EXIT

# Point HOME inside TMPDIR to avoid touching the real ~/.chopi.
HOME="$TMPDIR/home"; export HOME
mkdir -p "$HOME"
# Sourced only now so the repointed HOME applies
. "$repo/.internal/write-targets.sh"

# A fixture git author identity replaces the developer's real one; it's placed in the FROM:
# header when constructing a patch.
printf '[user]\n\tname = Test User\n\temail = test@example.com\n' > "$HOME/.gitconfig"
unset EMAIL GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

queue_patch="$repo/.internal/chopi-queue-patch.sh"

# Fixture: a workspace with a single-file target in it, a plain directory target, and a
# git-repo target.
work="$TMPDIR/work"
make_repo "$work"
printf 'workspace notes\n' > "$work/CLAUDE.md"
guidelines="$TMPDIR/guidelines"
mkdir -p "$guidelines/docs"
printf '# Guidelines\nBe kind.\n' > "$guidelines/Guidelines.md"
knowledge="$TMPDIR/knowledge"
make_repo "$knowledge"
printf '# Knowledge\n' > "$knowledge/README.md"
git -C "$knowledge" add README.md
git -C "$knowledge" commit -qm "add readme"

CHOPI_SAFE_WRITE_TARGETS=("$guidelines" "$knowledge" "$work/CLAUDE.md")
validate_write_targets "$work" chopi
CHOPI_PATCH_QUEUE="$(create_patch_queue "$work")"
export CHOPI_PATCH_QUEUE
guidelines_slot="$CHOPI_PATCH_QUEUE/$(path_id "$guidelines")"
knowledge_slot="$CHOPI_PATCH_QUEUE/$(path_id "$knowledge")"
claude_slot="$CHOPI_PATCH_QUEUE/$(path_id "$work/CLAUDE.md")"

# Queueing runs from a neutral directory, the way an agent would from anywhere
run() { (cd "$TMPDIR" && "$queue_patch" "$@") }

# Apply PATCH to a fresh copy of the guidelines target, the way chopi-review does, and
# assert -- as DESC -- that file REL of the copy comes out as DRAFT.
assert_patch_produces_draft() {
    arity 4
    local patch="$1" rel="$2" draft="$3" desc="$4"
    local applied="$TMPDIR/applied"
    rm -rf "$applied"; cp -R "$guidelines" "$applied"
    git -C "$applied" apply -p1 "$patch" 2>/dev/null; st=$?
    assert_zero "$st" "$desc"
    cmp -s "$applied/$rel" "$draft"; st=$?
    assert_zero "$st" "  -> leaving the file as drafted"
}

# Captured exit codes below rely on errexit being off.
set +e


# ---------------------------------------------------------------------------
echo "usage and preconditions"
# ---------------------------------------------------------------------------
out="$(run --help)"; st=$?
assert_zero "$st"                    "--help succeeds"
assert_contains "$out" "usage:"      "  -> printing the usage"
run -h >/dev/null; st=$?
assert_zero "$st"                    "  -> -h the same"

out="$(env -u CHOPI_PATCH_QUEUE "$queue_patch" -s 'x' "$guidelines/Guidelines.md" "$TMPDIR/whatever" 2>&1)"; st=$?
assert_eq "$st" 1                                      "without CHOPI_PATCH_QUEUE there is nothing to queue into"
assert_contains "$out" "CHOPI_PATCH_QUEUE is not set"  "  -> naming the missing variable"

out="$(run "$guidelines/Guidelines.md" "$TMPDIR/whatever" 2>&1)"; st=$?
assert_eq "$st" 1                              "a subject is required"
assert_contains "$out" "subject is required"   "  -> and asked for"

out="$(run -s 'x' "$guidelines/Guidelines.md" 2>&1)"; st=$?
assert_eq "$st" 1                            "FILE alone is not enough"
assert_contains "$out" "expected FILE and DRAFT" "  -> the usage error says what is missing"

run -s >/dev/null 2>&1; st=$?
assert_eq "$st" 1                       "-s with no value is refused"
out="$(run --frobnicate 2>&1)"; st=$?
assert_eq "$st" 1                       "an unknown option is refused"
assert_contains "$out" "unknown option" "  -> and named"


# ---------------------------------------------------------------------------
echo "queueing a change to a file under a directory target"
# ---------------------------------------------------------------------------
draft="$TMPDIR/draft"
cp "$guidelines/Guidelines.md" "$draft"
printf 'Greet warmly.\n' >> "$draft"
out="$(run -s 'Add a greeting rule' -m 'Warm greetings improve morale.' \
    "$guidelines/Guidelines.md" "$draft" 2>&1)"; st=$?
patch="$guidelines_slot/add-a-greeting-rule.patch"
assert_zero "$st"                  "a changed draft queues"
assert_present "$patch"            "  -> as a patch named after its subject, in the target's slot"
assert_contains "$out" "$patch"    "  -> named in the output, so it can be withdrawn"

content="$(cat "$patch")"
assert_prefix "$content" "From: Test User <test@example.com>" \
    "the change is authored as the user, so an approval makes it their own commit"
assert_contains "$content" "Subject: [PATCH] Add a greeting rule" "  -> under the given subject"
assert_contains "$content" 'Warm greetings improve morale.'       "  -> with the body after it"
assert_contains "$content" '+++ b/Guidelines.md'  "the diff paths strip to the target-relative file"
assert_contains "$content" '+Greet warmly.'       "  -> proposing the draft's addition"

assert_patch_produces_draft "$patch" Guidelines.md "$draft" "the patch applies the way chopi-review applies it"

printf 'And smile.\n' >> "$draft"
run -s 'Add a greeting rule' "$guidelines/Guidelines.md" "$draft" >/dev/null 2>&1; st=$?
assert_zero "$st" "a second patch under the same subject queues too"
assert_present "$guidelines_slot/add-a-greeting-rule-2.patch" \
    "  -> beside the first, not over it"

ln -s "$TMPDIR/link-target" "$guidelines_slot/take-the-name.patch"
run -s 'Take the name' "$guidelines/Guidelines.md" "$draft" >/dev/null 2>&1; st=$?
assert_zero "$st" "a broken symlink holding a patch name queues around it"
assert_present "$guidelines_slot/take-the-name-2.patch" "  -> under the next name"
assert_absent "$TMPDIR/link-target" "  -> never writing through the link"
assert_eq "$(readlink "$guidelines_slot/take-the-name.patch")" "$TMPDIR/link-target" \
    "  -> leaving the link alone"

run -s 'No body here' "$guidelines/Guidelines.md" "$TMPDIR/draft" >/dev/null 2>&1; st=$?
assert_zero "$st" "the body is optional"
assert_contains "$(cat "$guidelines_slot/no-body-here.patch")" $'Subject: [PATCH] No body here\n\n---\ndiff' \
    "  -> the diff separator directly follows the subject"

printf '#!/bin/sh\necho hi\n' > "$guidelines/tool.sh"
chmod 755 "$guidelines/tool.sh"
printf '#!/bin/sh\necho hello\n' > "$TMPDIR/draft-tool"
chmod 644 "$TMPDIR/draft-tool"
run -s 'Say hello' "$guidelines/tool.sh" "$TMPDIR/draft-tool" >/dev/null 2>&1; st=$?
assert_zero "$st" "a draft written fresh queues against an executable file"
assert_not_contains "$(cat "$guidelines_slot/say-hello.patch")" 'old mode' \
    "  -> keeping the file's own mode: the draft's bits propose nothing"

printf 'relatively\n' > "$TMPDIR/draft-rel"
(cd "$guidelines" && "$queue_patch" -s 'Relative paths work' Guidelines.md "$TMPDIR/draft-rel") \
    >/dev/null 2>&1; st=$?
assert_zero "$st" "a relative FILE resolves against the working directory"
assert_present "$guidelines_slot/relative-paths-work.patch" "  -> landing in the same slot"

printf 'PNG\x00\x01old' > "$guidelines/logo.bin"
printf 'PNG\x00\x01new' > "$TMPDIR/draft-bin"
run -s 'Refresh the logo' "$guidelines/logo.bin" "$TMPDIR/draft-bin" >/dev/null 2>&1; st=$?
assert_zero "$st" "a binary file queues"
assert_patch_produces_draft "$guidelines_slot/refresh-the-logo.patch" logo.bin "$TMPDIR/draft-bin" \
    "  -> as a binary patch that produces the draft"


# ---------------------------------------------------------------------------
echo "queueing a file that doesn't exist yet"
# ---------------------------------------------------------------------------
printf 'Fresh topic.\n' > "$TMPDIR/draft-new"
run -s 'Document the new topic' "$guidelines/docs/new/topic.md" "$TMPDIR/draft-new" >/dev/null 2>&1; st=$?
patch="$guidelines_slot/document-the-new-topic.patch"
assert_zero "$st"       "a FILE not there yet queues its creation"
assert_present "$patch" "  -> as a patch like any other"
content="$(cat "$patch")"
assert_contains "$content" '--- /dev/null'             "  -> a creation diff"
assert_contains "$content" '+++ b/docs/new/topic.md'   "  -> at the target-relative path, missing dirs included"

assert_patch_produces_draft "$patch" docs/new/topic.md "$TMPDIR/draft-new" "the creation patch produces the draft"


# ---------------------------------------------------------------------------
echo "a single-file target, and a symlink into a target"
# ---------------------------------------------------------------------------
cp "$work/CLAUDE.md" "$TMPDIR/draft-claude"
printf 'Remember the tests.\n' >> "$TMPDIR/draft-claude"
run -s 'Note the tests' "$work/CLAUDE.md" "$TMPDIR/draft-claude" >/dev/null 2>&1; st=$?
assert_zero "$st" "a change to a single-file target queues"
patch="$claude_slot/note-the-tests.patch"
assert_present "$patch" "  -> into that target's slot"
assert_contains "$(cat "$patch")" '+++ b/CLAUDE.md' "  -> patching the file by its basename"

out="$(run -s 'Sibling' "$work/other.md" "$TMPDIR/draft-claude" 2>&1)"; st=$?
assert_eq "$st" 1 "a sibling of a single-file target is not covered by it"
assert_contains "$out" "no safe write target covers" "  -> and is refused"

ln -s "$guidelines/Guidelines.md" "$work/linked.md"
printf 'via the link\n' > "$TMPDIR/draft-link"
run -s 'Via symlink' "$work/linked.md" "$TMPDIR/draft-link" >/dev/null 2>&1; st=$?
assert_zero "$st" "a symlink into a target queues for where it points"
assert_present "$guidelines_slot/via-symlink.patch" "  -> in the target's slot, not the link's"
assert_contains "$(cat "$guidelines_slot/via-symlink.patch")" '+++ b/Guidelines.md' \
    "  -> at the resolved path"


# ---------------------------------------------------------------------------
echo "refusals"
# ---------------------------------------------------------------------------
out="$(run -s 'x' "$guidelines" "$TMPDIR/draft" 2>&1)"; st=$?
assert_eq "$st" 1                        "a directory is not a file to change"
assert_contains "$out" "is a directory"  "  -> and is named as one"

out="$(run -s 'x' "$TMPDIR/elsewhere.md" "$TMPDIR/draft" 2>&1)"; st=$?
assert_eq "$st" 1                                    "a file no target covers is refused"
assert_contains "$out" "no safe write target covers" "  -> saying so"

cp "$guidelines/Guidelines.md" "$TMPDIR/draft-same"
out="$(run -s 'x' "$guidelines/Guidelines.md" "$TMPDIR/draft-same" 2>&1)"; st=$?
assert_eq "$st" 1                           "a draft identical to the file has nothing to propose"
assert_contains "$out" "nothing to queue"   "  -> and queues nothing"

out="$(run -s 'x' "$knowledge/.git/config" "$TMPDIR/draft" 2>&1)"; st=$?
assert_eq "$st" 1                         "git internals under a target are refused"
assert_contains "$out" "git internals"    "  -> with the reason"
assert_absent "$knowledge_slot/x.patch"   "  -> and no patch queued"

out="$(run -s 'x' "$guidelines/absent/../Guidelines.md" "$TMPDIR/draft" 2>&1)"; st=$?
assert_eq "$st" 1                       "a '..' component past where the path exists cannot resolve"
assert_contains "$out" "cannot resolve" "  -> and is refused"

printf 'outside\n' > "$TMPDIR/outside.md"
ln -s "$TMPDIR/outside.md" "$guidelines/outward.md"
out="$(run -s 'x' "$guidelines/outward.md" "$TMPDIR/draft" 2>&1)"; st=$?
assert_eq "$st" 1                                    "a symlink inside a target that points out of it is not covered"
assert_contains "$out" "no safe write target covers" "  -> and is refused"

# The same link dangling: it stats as missing, so resolving it would yield the link's own
# path, inside the target, rather than where it points, outside.
ln -s "$TMPDIR/gone.md" "$guidelines/dangling.md"
out="$(run -s 'x' "$guidelines/dangling.md" "$TMPDIR/draft" 2>&1)"; st=$?
assert_eq "$st" 1                          "a dangling symlink cannot resolve"
assert_contains "$out" "broken symlink"    "  -> and is refused"
assert_absent "$guidelines_slot/x.patch"   "  -> and no patch queued"

# The other way a link fails to stat: the walk gives up on the cycle with ELOOP, where the
# dangling one gets ENOENT.
ln -s loop-b.md "$guidelines/loop-a.md"
ln -s loop-a.md "$guidelines/loop-b.md"
out="$(run -s 'x' "$guidelines/loop-a.md" "$TMPDIR/draft" 2>&1)"; st=$?
assert_eq "$st" 1                          "a symlink loop cannot resolve"
assert_contains "$out" "broken symlink"    "  -> and is refused the same way"

out="$(run -s 'x' "$guidelines/Guidelines.md" "$TMPDIR/no-such-draft" 2>&1)"; st=$?
assert_eq "$st" 1                            "a missing draft is refused"
assert_contains "$out" "not a readable file" "  -> for what it is"


# ---------------------------------------------------------------------------
echo "the queued patch survives the review's git am"
# ---------------------------------------------------------------------------
cp "$knowledge/README.md" "$TMPDIR/draft-fact"
printf 'New fact.\n' >> "$TMPDIR/draft-fact"
run -s 'Record a new fact' -m 'It came up in testing.' "$knowledge/README.md" "$TMPDIR/draft-fact" \
    >/dev/null 2>&1; st=$?
assert_zero "$st" "a change to a repo-held target queues"
patch="$knowledge_slot/record-a-new-fact.patch"

git -C "$knowledge" am --3way "$patch" >/dev/null 2>&1; st=$?
assert_zero "$st" "git am takes the patch the way chopi-review commits it"
assert_eq "$(git -C "$knowledge" log -1 --format='%an <%ae>')" "Test User <test@example.com>" \
    "  -> authored as the user"
assert_eq "$(git -C "$knowledge" log -1 --format='%s')" "Record a new fact" \
    "  -> under the given subject"
assert_eq "$(git -C "$knowledge" log -1 --format='%b')" "It came up in testing." \
    "  -> with the body as the commit body"
cmp -s "$knowledge/README.md" "$TMPDIR/draft-fact"; st=$?
assert_zero "$st" "  -> and the file as drafted"


# ---------------------------------------------------------------------------
summary

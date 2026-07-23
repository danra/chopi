# shellcheck shell=bash
#
# test/lib.sh -- shared utilities for chopi's tests

pass=0
fail=0

# header -- announce a test suite. Printed once at the top of each suite so that
# when several run back-to-back (e.g. `make test`) they stay visually separable,
# clearly distinct from the plain-text section sub-headers inside a suite.
header() {
    arity 1
    local title="$1"
    printf '\n'
    printf '════════════════════════════════════════════════════════════════════════════\n'
    printf '  %s\n' "$title"
    printf '════════════════════════════════════════════════════════════════════════════\n'
}

ok()   { arity 1; pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad()  { arity 1; fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }

assert_eq() {
    arity 3
    local got="$1" want="$2" desc="$3"
    if [ "$got" = "$want" ]; then ok "$desc"; else
        bad "$desc"
        printf '         want: %q\n' "$want"
        printf '         got:  %q\n' "$got"
    fi
}

assert_contains() {
    arity 3
    local haystack="$1" needle="$2" desc="$3"
    case "$haystack" in
        *"$needle"*) ok "$desc" ;;
        *)           bad "$desc"; printf '         %q\n         does not contain %q\n' "$haystack" "$needle" ;;
    esac
}

assert_not_contains() {
    arity 3
    local haystack="$1" needle="$2" desc="$3"
    case "$haystack" in
        *"$needle"*) bad "$desc"; printf '         %q\n         unexpectedly contains %q\n' "$haystack" "$needle" ;;
        *)           ok "$desc" ;;
    esac
}

assert_prefix() {
    arity 3
    local string="$1" prefix="$2" desc="$3"
    case "$string" in
        "$prefix"*) ok "$desc" ;;
        *)          bad "$desc"; printf '         %q\n         does not start with %q\n' "$string" "$prefix" ;;
    esac
}

# assert_has_line HAYSTACK LINE DESC -- HAYSTACK has a line reading LINE, ignoring that line's
# surrounding whitespace.
assert_has_line() {
    arity 3
    local haystack="$1" want="$2" desc="$3" trimmed
    trimmed="$(printf '%s\n' "$haystack" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    if printf '%s\n' "$trimmed" | grep -qxF -- "$want"; then ok "$desc"; else
        bad "$desc"; printf '         %q\n         has no line reading %q\n' "$haystack" "$want"
    fi
}

# assert_zero ST DESC / assert_nonzero ST DESC -- assert on a captured exit status
assert_zero() {
    arity 2
    local st="$1" desc="$2"
    if [ "$st" -eq 0 ]; then ok "$desc"; else
        bad "$desc"
        printf '         exit status: %s (want 0)\n' "$st"
    fi
}

assert_nonzero() {
    arity 2
    local st="$1" desc="$2"
    if [ "$st" -ne 0 ]; then ok "$desc"; else
        bad "$desc"
        printf '         exit status: 0 (want non-zero)\n'
    fi
}

# assert_absent PATH DESC -- nothing exists at PATH (a denied write left no trace)
assert_absent() {
    arity 2
    local path="$1" desc="$2"
    if [ -e "$path" ]; then
        bad "$desc"
        printf '         unexpectedly exists: %q\n' "$path"
    else
        ok "$desc"
    fi
}

# rule_line FILE RULE -- 1-based line of RULE's first occurrence in FILE; empty when absent
rule_line() {
    arity 2
    local file="$1" pattern="$2"
    grep -nF "$pattern" "$file" | head -n 1 | cut -d: -f1
}

# assert_rule_order FILE EARLIER LATER DESC -- both rules present, with EARLIER's first
# occurrence before LATER's. Profiles are last-match-wins, so rule order carries semantics.
assert_rule_order() {
    arity 4
    local file="$1" earlier="$2" later="$3" desc="$4"
    local earlier_ln later_ln
    earlier_ln="$(rule_line "$file" "$earlier")"
    later_ln="$(rule_line "$file" "$later")"
    if [ -n "$earlier_ln" ] && [ -n "$later_ln" ] && [ "$earlier_ln" -lt "$later_ln" ]; then ok "$desc"; else
        bad "$desc"
        printf '         %s (line %s)\n         must precede %s (line %s)\n' \
            "$earlier" "${earlier_ln:-missing}" "$later" "${later_ln:-missing}"
    fi
}

# make_repo DIR [GIT-INIT-ARG...] -- a repo with an initial commit; extra args go to git init
make_repo() {
    local dir="$1"; shift
    git init -q "$@" "$dir"
    git -C "$dir" config user.email t@t.t
    git -C "$dir" config user.name  t
    git -C "$dir" commit -q --allow-empty -m init
}

# in_progress DIR -- print the exec-capable op git sees in worktree DIR ('rebase'|'sequencer'),
# else nothing. Kept independent of the production inflight_exec_sequencing it mirrors, so tests
# don't lean on the code they exercise.
in_progress() {
    arity 1
    ( cd "$1" || exit 0
      [ -d "$(git rev-parse --git-path rebase-merge)" ] && { printf 'rebase'; exit 0; }
      [ -d "$(git rev-parse --git-path sequencer)" ]    && { printf 'sequencer'; exit 0; }
      exit 0 )
}

# isolate_git_config -- ignore the developer's global/system git config so the real-git fixtures
# (stop_a_rebase_in and friends) build the same state everywhere: it pins the default rebase
# backend so a stopped rebase lands in rebase-merge (what the code under test detects), and keeps
# rerere / merge drivers from auto-resolving the conflict the fixture needs to pause on. Opt-in,
# not global: other suites keep the developer's config (e.g. init.defaultBranch) that they assume.
isolate_git_config() {
    arity 0
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0
}

# stop_a_rebase_in DIR -- leave worktree DIR paused mid-rebase on a conflict. Needs a repo with
# at least one commit; builds two branches whose same-region edits collide on rebase.
stop_a_rebase_in() {
    arity 1
    local dir="$1"
    git -C "$dir" checkout -q -b _sideA
    printf 'base\n' > "$dir/_c.txt"; git -C "$dir" add _c.txt; git -C "$dir" commit -qm _cbase
    printf 'A\n'    >> "$dir/_c.txt"; git -C "$dir" commit -qam _ca
    git -C "$dir" checkout -q -b _sideB HEAD~1
    printf 'B\n'    >> "$dir/_c.txt"; git -C "$dir" commit -qam _cb
    git -C "$dir" rebase _sideA >/dev/null 2>&1
}

# stop_a_cherry_pick_in DIR -- leave worktree DIR paused mid cherry-pick sequence on a conflict.
stop_a_cherry_pick_in() {
    arity 1
    local dir="$1"
    git -C "$dir" checkout -q -b _base
    printf 'base\n'   > "$dir/_q.txt"; git -C "$dir" add _q.txt; git -C "$dir" commit -qm _qbase
    git -C "$dir" checkout -q -b _topic
    printf 'topicA\n' >> "$dir/_q.txt"; git -C "$dir" commit -qam _tA
    printf 'z\n'       > "$dir/_z.txt"; git -C "$dir" add _z.txt; git -C "$dir" commit -qam _tB
    git -C "$dir" checkout -q _base
    printf 'baseX\n'  >> "$dir/_q.txt"; git -C "$dir" commit -qam _bx
    git -C "$dir" cherry-pick _topic~1 _topic >/dev/null 2>&1
}

# stop_a_revert_in DIR -- leave worktree DIR paused mid revert sequence on a conflict. Reverting
# the file's creation collides with its later edit, and two args make it a `sequencer` sequence.
stop_a_revert_in() {
    arity 1
    local dir="$1"
    git -C "$dir" checkout -q -b _revbranch
    printf 'A\n' > "$dir/_v.txt"; git -C "$dir" add _v.txt; git -C "$dir" commit -qm _rA
    printf 'B\n' > "$dir/_v.txt"; git -C "$dir" commit -qam _rB
    git -C "$dir" revert --no-edit HEAD~1 HEAD >/dev/null 2>&1
}

# Print the N'th (1-based) NUL-terminated record from stdin; prints nothing when there
# are fewer records. Reads stdin to the end and always exits zero.
nul_record() {
    arity 1
    local index="$1"
    local i=1 record wanted=""
    while IFS= read -r -d '' record || [ -n "$record" ]; do
        [ "$i" -eq "$index" ] && wanted="$record"
        i=$((i + 1))
    done
    printf '%s' "$wanted"
}

summary() {
    echo
    echo "$pass passed, $fail failed"
    [ "$fail" -eq 0 ]
}

# git >= 2.38 refuses file-protocol submodules by default; allow for test
export allow_git_file_protocol=(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always)

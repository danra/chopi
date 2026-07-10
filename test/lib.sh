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

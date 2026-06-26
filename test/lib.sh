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

summary() {
    echo
    echo "$pass passed, $fail failed"
    [ "$fail" -eq 0 ]
}

#!/usr/bin/env bash
#
# test/install.sh -- unit tests for install.sh's option parsing

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
. "$repo/.internal/util.sh"
. "$repo/test/lib.sh"

header "test/install.sh -- unit tests for install.sh's option parsing"

install_sh="$repo/install.sh"

TMPDIR="$(mktemp -d)"; export TMPDIR
trap 'rm -rf "$TMPDIR"' EXIT

fixture_home="$TMPDIR/home"; mkdir -p "$fixture_home"

run_install() {
    HOME="$fixture_home" "$install_sh" "$@" </dev/null 2>&1
}

# Captured exit codes below rely on errexit being off.
set +e


# ---------------------------------------------------------------------------
echo "the help flags print the usage"
# ---------------------------------------------------------------------------
out="$(run_install -h)"; st=$?
assert_zero "$st" "-h exits zero"
assert_contains "$out" "usage: ./install.sh" "  -> printing the usage"

out="$(run_install --help)"; st=$?
assert_zero "$st" "--help exits zero"
assert_contains "$out" "usage: ./install.sh" "  -> printing the usage"


# ---------------------------------------------------------------------------
echo "an unknown option is refused"
# ---------------------------------------------------------------------------
out="$(run_install --bogus)"; st=$?
assert_nonzero "$st" "an unknown option is refused"
assert_contains "$out" "unknown option: --bogus" "  -> naming it"

out="$(run_install -hh -h)"; st=$?
assert_nonzero "$st" "an unknown option ahead of -h is refused"
assert_contains "$out" "unknown option: -hh" "  -> naming it"

out="$(run_install -h -hh)"; st=$?
assert_nonzero "$st" "an unknown option behind -h is refused"
assert_contains "$out" "unknown option: -hh" "  -> naming it"


# ---------------------------------------------------------------------------
echo "at most one option is accepted"
# ---------------------------------------------------------------------------
out="$(run_install --uninstall --uninstall)"; st=$?
assert_nonzero "$st" "a repeated --uninstall is refused"
assert_contains "$out" "usage: ./install.sh" "  -> printing the usage"

out="$(run_install -h -h)"; st=$?
assert_nonzero "$st" "a repeated -h is refused"
assert_contains "$out" "usage: ./install.sh" "  -> printing the usage"

out="$(run_install --uninstall -h)"; st=$?
assert_nonzero "$st" "--uninstall together with -h is refused"
assert_contains "$out" "usage: ./install.sh" "  -> printing the usage"


# ---------------------------------------------------------------------------
summary

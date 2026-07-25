#!/usr/bin/env bash
#
# test/shell-rc.sh -- unit tests for the shell startup file helpers

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo/.internal/util.sh"
. "$repo/.internal/shell-rc.sh"
. "$repo/test/lib.sh"

header "test/shell-rc.sh -- unit tests for the shell startup file helpers"

TMPDIR="$(mktemp -d)"; export TMPDIR
trap 'rm -rf "$TMPDIR"' EXIT

# A fixture rc file holding CONTENT; prints its path.
rc_fixture() {
    arity 1
    local content="$1" file
    file="$(mktemp "$TMPDIR/rc.XXXXXX")"
    printf '%s' "$content" >"$file"
    printf '%s' "$file"
}


# ---------------------------------------------------------------------------
echo "CHOPI_PATH_LINE"
# ---------------------------------------------------------------------------
assert_eq "$CHOPI_PATH_LINE" "export PATH=\"$CHOPI_DIR/bin:\$PATH\"" "the PATH line prepends this clone's bin"


# ---------------------------------------------------------------------------
echo "shell_rc_file reports the expected .rc file"
# ---------------------------------------------------------------------------
assert_eq "$(HOME=/h SHELL=/bin/zsh shell_rc_file)"             /h/.zshrc  "zsh -> ~/.zshrc"
assert_eq "$(HOME=/h SHELL=/usr/local/bin/bash shell_rc_file)"  /h/.bashrc "bash -> ~/.bashrc"
assert_eq "$(HOME=/h SHELL=/usr/bin/fish shell_rc_file)"        ""         "an unknown shell has no rc file"
assert_eq "$(HOME=/h SHELL='' shell_rc_file)"                   ""         "an empty SHELL has no rc file"


# ---------------------------------------------------------------------------
echo "lookup of this chopi clone's PATH line in the rc file"
# ---------------------------------------------------------------------------
set +euo pipefail

file="$(rc_fixture "$CHOPI_PATH_LINE"$'\n')"
if file_has_line "$file" "$CHOPI_PATH_LINE"; then ok "finds the line"; else bad "finds the line"; fi

file="$(rc_fixture "    $CHOPI_PATH_LINE"$'\n')"
if file_has_line "$file" "$CHOPI_PATH_LINE"; then ok "finds an indented line"; else bad "finds an indented line"; fi

file="$(rc_fixture "# $CHOPI_PATH_LINE"$'\n')"
if file_has_line "$file" "$CHOPI_PATH_LINE"; then bad "a commented-out line is not a match"; else ok "a commented-out line is not a match"; fi

if file_has_line "$TMPDIR/absent" "$CHOPI_PATH_LINE"; then bad "a missing file is not a match"; else ok "a missing file is not a match"; fi


# ---------------------------------------------------------------------------
summary

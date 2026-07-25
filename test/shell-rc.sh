#!/usr/bin/env bash
#
# test/shell-rc.sh -- unit tests for the shell startup file helpers
#
# These edit the user's shell rc, so the properties that matter are that the removal is
# exact (it must not eat an unrelated PATH edit, or a line that merely contains ours),
# that an install/uninstall cycle round-trips the file byte for byte, and that the
# rewrite preserves the file's mode instead of leaving mktemp's 0600 behind.

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

# FILE's exact bytes, terminated by a marker so command substitution doesn't eat a
# trailing newline.
rc_bytes() {
    arity 1
    cat "$1"
    printf '|'
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
echo "rc_remove_line (round-trip)"
# ---------------------------------------------------------------------------
# The rc file install.sh leaves behind: its line after a blank separator.
original=$'# my rc\nexport EDITOR=vim\n'
file="$(rc_fixture "$original"$'\n'"$CHOPI_PATH_LINE"$'\n')"
rc_remove_line "$file" "$CHOPI_PATH_LINE"
assert_eq "$(rc_bytes "$file")" "$original|" "remove restores the file, separator and all"

# Two install/uninstall cycles must not accumulate blank lines.
printf '\n%s\n' "$CHOPI_PATH_LINE" >>"$file"; rc_remove_line "$file" "$CHOPI_PATH_LINE"
printf '\n%s\n' "$CHOPI_PATH_LINE" >>"$file"; rc_remove_line "$file" "$CHOPI_PATH_LINE"
assert_eq "$(rc_bytes "$file")" "$original|" "repeated cycles leave nothing behind"


# ---------------------------------------------------------------------------
echo "rc_remove_line (exactness)"
# ---------------------------------------------------------------------------
file="$(rc_fixture $'export PATH="/opt/bin:$PATH"\n')"
if rc_remove_line "$file" "$CHOPI_PATH_LINE"; then bad "reports failure when the line is absent"; else ok "reports failure when the line is absent"; fi
assert_eq "$(cat "$file")" "export PATH=\"/opt/bin:\$PATH\"" "an unrelated PATH edit is untouched"

# A line that contains ours is a different line.
file="$(rc_fixture "$CHOPI_PATH_LINE"' # chopi'$'\n')"
if rc_remove_line "$file" "$CHOPI_PATH_LINE"; then bad "a superstring line is not removed"; else ok "a superstring line is not removed"; fi

# Indentation is not part of the line, so whatever the lookup finds is what goes.
file="$(rc_fixture "    $CHOPI_PATH_LINE"$'\n')"
rc_remove_line "$file" "$CHOPI_PATH_LINE"
assert_eq "$(rc_bytes "$file")" "|" "an indented line is removed"

# Blank lines that are not our separator stay put.
file="$(rc_fixture $'a\n\n\nb\n\n'"$CHOPI_PATH_LINE"$'\n')"
rc_remove_line "$file" "$CHOPI_PATH_LINE"
assert_eq "$(rc_bytes "$file")" $'a\n\n\nb\n|' "unrelated blank lines survive"

# A hand-duplicated line takes one call per copy.
file="$(rc_fixture "$CHOPI_PATH_LINE"$'\nother\n'"$CHOPI_PATH_LINE"$'\n')"
rc_remove_line "$file" "$CHOPI_PATH_LINE"
assert_eq "$(rc_bytes "$file")" $'other\n'"$CHOPI_PATH_LINE"$'\n|' "removes the first copy"
rc_remove_line "$file" "$CHOPI_PATH_LINE"
assert_eq "$(rc_bytes "$file")" $'other\n|' "a second call removes the next"


# ---------------------------------------------------------------------------
echo "rc_remove_line (file properties)"
# ---------------------------------------------------------------------------
file="$(rc_fixture $'a\n'"$CHOPI_PATH_LINE"$'\n')"
chmod 644 "$file"
rc_remove_line "$file" "$CHOPI_PATH_LINE"
assert_eq "$(stat -f '%Lp' "$file")" 644 "the rewrite keeps the file's mode"
leftovers="$(find "$TMPDIR" -name 'rc.*.chopi.*' | wc -l | tr -d ' ')"
assert_eq "$leftovers" 0 "the rewrite leaves no temp file behind"

# A final line with no newline is still matched and removed.
file="$(rc_fixture $'a\n'"$CHOPI_PATH_LINE")"
rc_remove_line "$file" "$CHOPI_PATH_LINE"
assert_eq "$(cat "$file")" "a" "an unterminated final line is removed"


# ---------------------------------------------------------------------------
summary

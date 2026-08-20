#!/usr/bin/env bash
#
# test/claude-prompt.sh -- unit tests for chopi's addition to claude's prompt

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo/.internal/util.sh"
. "$repo/.internal/claude-prompt.sh"
. "$repo/test/lib.sh"

header "test/claude-prompt.sh -- unit tests for chopi's addition to claude's prompt"

TMPDIR="$(mktemp -d)"; export TMPDIR
trap 'rm -rf "$TMPDIR"' EXIT

chopi_claude_prompt="$(chopi_prompt_document "")"   # as a session with no safe write targets gets it

prompt_file() { arity 0; printf '%s' "${CLAUDE_ARGV_WITH_CHOPI_PROMPT[2]}"; }
prompt_text() { arity 0; cat "${CLAUDE_ARGV_WITH_CHOPI_PROMPT[2]}"; }


# ---------------------------------------------------------------------------
echo "the prompt contents"
# ---------------------------------------------------------------------------
assert_contains "$chopi_claude_prompt" "$PROXY_PORT"        "the document names the proxy port"
assert_contains "$chopi_claude_prompt" "$GITHUB_RELAY_PORT" "  -> and the GitHub relay port"
assert_contains "$chopi_claude_prompt" "CHOPI_DIR" "the document names the marker chopi sets in the environment"


# ---------------------------------------------------------------------------
echo "the safe write targets in the document"
# ---------------------------------------------------------------------------
document="$(cat "$CHOPI_CLAUDE_PROMPT_FILE")"
slot="$CHOPI_CLAUDE_PROMPT_TARGETS_SLOT"
assert_eq "$(grep -c -x -F "$slot" "$CHOPI_CLAUDE_PROMPT_FILE")" 1 "the document holds the slot once, on a line of its own"

assert_not_contains "$chopi_claude_prompt" "$slot" "rendering fills the slot"
assert_eq "$chopi_claude_prompt" "${document/"$slot"/No safe write targets are configured this session.}" \
    "  -> with a line saying the session has none, the rest of the document as written"

targets="/team/guidelines"$'\n'"/notes/a & b\\c"
listed="$(chopi_prompt_document "$targets")"
assert_contains "$listed" "Safe write targets this session" "targets passed in are announced"
assert_contains "$listed" $'\n- `/team/guidelines`\n- `/notes/a & b\\c`\n' \
    "  -> and listed in order, each verbatim, shell-special characters included"
assert_not_contains "$listed" "No safe write targets" "  -> in place of the none line"


# ---------------------------------------------------------------------------
echo "claude_argv_with_chopi_prompt"
# ---------------------------------------------------------------------------
set +euo pipefail

claude_argv_with_chopi_prompt /wd "" claude -p hi
assert_eq "${CLAUDE_ARGV_WITH_CHOPI_PROMPT[0]}" claude "keeps the command first"
assert_eq "${CLAUDE_ARGV_WITH_CHOPI_PROMPT[1]}" --append-system-prompt-file "inserts the flag before everything else"
assert_prefix "$(prompt_file)" "$TMPDIR/$CHOPI_CLAUDE_SYSTEM_PROMPT_PREFIX" "  -> pointing into the run's temp dir"
assert_eq "$(prompt_text)" "$chopi_claude_prompt" "  -> at a copy of the document"
assert_eq "${CLAUDE_ARGV_WITH_CHOPI_PROMPT[3]}" -p  "the user's args follow"
assert_eq "${CLAUDE_ARGV_WITH_CHOPI_PROMPT[4]}" hi  "  -> in order"
assert_eq "${#CLAUDE_ARGV_WITH_CHOPI_PROMPT[@]}" 5  "  -> and nothing else"

claude_argv_with_chopi_prompt /wd "$targets" claude -p hi
assert_eq "$(prompt_text)" "$listed" "the targets passed in render into the copy"

claude_argv_with_chopi_prompt /wd "" claude
assert_eq "${#CLAUDE_ARGV_WITH_CHOPI_PROMPT[@]}" 3 "a bare command gets just the flag"

# Inserting the flag first keeps subcommands working (tested on Claude 2.1.220)
claude_argv_with_chopi_prompt /wd "" claude mcp list
assert_eq "${CLAUDE_ARGV_WITH_CHOPI_PROMPT[3]}" mcp "a subcommand follows the inserted flag"

claude_argv_with_chopi_prompt /wd "" claude -- --append-system-prompt
assert_eq "${CLAUDE_ARGV_WITH_CHOPI_PROMPT[3]}" --                     "the user's -- follows the inserted flag"
assert_eq "${CLAUDE_ARGV_WITH_CHOPI_PROMPT[4]}" --append-system-prompt "  -> and what follows it is kept as text"
assert_eq "${#CLAUDE_ARGV_WITH_CHOPI_PROMPT[@]}" 5                     "  -> not treated as the user's own flag"


# ---------------------------------------------------------------------------
echo "claude_argv_with_chopi_prompt (a prompt the user passed)"
# ---------------------------------------------------------------------------
claude_argv_with_chopi_prompt /wd "" claude --append-system-prompt "mine" -p hi
assert_eq "${CLAUDE_ARGV_WITH_CHOPI_PROMPT[1]}" --append-system-prompt-file "the inline flag is replaced with the file-variant one"
assert_prefix "$(prompt_file)" "$TMPDIR/$CHOPI_CLAUDE_SYSTEM_PROMPT_PREFIX" "  -> pointing at chopi's"
assert_eq "$(prompt_text)" "mine"$'\n\n'"$chopi_claude_prompt" "the user's prompt is folded in ahead of the document"
assert_not_contains "${CLAUDE_ARGV_WITH_CHOPI_PROMPT[*]}" "mine" "  -> and is taken out of argv"
assert_eq "${CLAUDE_ARGV_WITH_CHOPI_PROMPT[*]:3}" "-p hi"  "their remaining args are kept"

claude_argv_with_chopi_prompt /wd "" claude --append-system-prompt=mine
assert_eq "$(prompt_text)" "mine"$'\n\n'"$chopi_claude_prompt" "the = spelling is folded in the same way"
assert_eq "${#CLAUDE_ARGV_WITH_CHOPI_PROMPT[@]}" 3 "  -> and dropped from the argv"

# claude keeps one value for a repeated flag, the last (tested on Claude 2.1.220);
# chopi needs to keep the same one in the merge
claude_argv_with_chopi_prompt /wd "" claude --append-system-prompt first --append-system-prompt last
assert_eq "$(prompt_text)" "last"$'\n\n'"$chopi_claude_prompt" "a repeated flag folds in the last value, as claude resolves it"
assert_eq "${#CLAUDE_ARGV_WITH_CHOPI_PROMPT[@]}" 3 "  -> and every occurrence is dropped, so neither collides with chopi's"

claude_argv_with_chopi_prompt /wd "" claude --append-system-prompt --append-system-prompt-file
assert_eq "$(prompt_text)" "--append-system-prompt-file"$'\n\n'"$chopi_claude_prompt" "a flag-shaped value is folded in as text"


# ---------------------------------------------------------------------------
echo "claude_argv_with_chopi_prompt (a prompt file the user passed)"
# ---------------------------------------------------------------------------
user_filename=mine.txt
user_file="$TMPDIR/$user_filename"
printf 'from a file\n' >"$user_file"

claude_argv_with_chopi_prompt /wd "" claude --append-system-prompt-file "$user_file"
assert_prefix "$(prompt_file)" "$TMPDIR/$CHOPI_CLAUDE_SYSTEM_PROMPT_PREFIX" "the flag is re-pointed at chopi's copy"
assert_eq "$(prompt_text)" "from a file"$'\n\n'"$chopi_claude_prompt" "  -> holding their file plus the document"
assert_eq "$(cat "$user_file")" "from a file" "the user's own file is untouched"

claude_argv_with_chopi_prompt /wd "" claude "--append-system-prompt-file=$user_file"
assert_eq "$(prompt_text)" "from a file"$'\n\n'"$chopi_claude_prompt" "the = spelling is merged the same way"

merged="$( cd / && claude_argv_with_chopi_prompt "$TMPDIR" "" claude --append-system-prompt-file "$user_filename" && prompt_file )"
assert_eq "$(cat "$merged")" "from a file"$'\n\n'"$chopi_claude_prompt" "a relative file path resolves against the run dir, not chopi's cwd"

out="$(claude_argv_with_chopi_prompt /wd "" claude --append-system-prompt-file "$TMPDIR/absent" 2>&1)"; st=$?
assert_eq "$st" 1 "an unreadable prompt file is an error, not a silently dropped flag"
assert_contains "$out" "cannot read" "  -> and says so"


# ---------------------------------------------------------------------------
echo "claude_argv_with_chopi_prompt (argv claude rejects on its own)"
# ---------------------------------------------------------------------------
claude_argv_with_chopi_prompt /wd "" claude --append-system-prompt a --append-system-prompt-file "$user_file"
assert_eq "${CLAUDE_ARGV_WITH_CHOPI_PROMPT[*]}" "claude --append-system-prompt a --append-system-prompt-file $user_file" \
    "both flags together are left exactly as written, for claude to reject"

claude_argv_with_chopi_prompt /wd "" claude --append-system-prompt
assert_eq "${CLAUDE_ARGV_WITH_CHOPI_PROMPT[*]}" "claude --append-system-prompt" "a flag with no value is left for claude to reject"

claude_argv_with_chopi_prompt /wd "" claude -p hi --append-system-prompt-file
assert_eq "${CLAUDE_ARGV_WITH_CHOPI_PROMPT[*]}" "claude -p hi --append-system-prompt-file" "so is a trailing file flag with no value"


# ---------------------------------------------------------------------------
summary

# shellcheck shell=bash
#
# sandbox-prompt.sh -- render chopi's sandbox context document for claude-prompt.sh
#
# Sourced (never run directly).

_sandbox_prompt_dir="$(dirname "${BASH_SOURCE[0]}")"
. "$_sandbox_prompt_dir/util.sh"
unset _sandbox_prompt_dir

CHOPI_SANDBOX_PROMPT_FILE="$CHOPI_DIR/.internal/sandbox-prompt.md"
CHOPI_SANDBOX_PROMPT_TARGETS_SLOT='@@SAFE_WRITE_TARGETS@@'

# Print the paragraph listing the safe write targets TARGETS names, one per line; an empty
# TARGETS says the session has none.
safe_write_targets_paragraph() {
    arity 1
    local targets="$1"
    local path
    if [ -z "$targets" ]; then
        echo "No safe write targets are configured this session."
        return 0
    fi
    echo 'Safe write targets this session (readable; changes land as queued patches, see "Queueing a'
    echo 'change to a safe write target" below):'
    echo
    while IFS= read -r path; do
        # shellcheck disable=SC2016 # the backticks are markdown, not a substitution
        printf -- '- `%s`\n' "$path"
    done <<<"$targets"
}

# Print chopi's context document, filling in the safe write targets slot
chopi_prompt_document() {
    arity 1
    local targets="$1"
    local document paragraph
    document="$(<"$CHOPI_SANDBOX_PROMPT_FILE")" || return 1
    paragraph="$(safe_write_targets_paragraph "$targets")"
    fill_slots "$document" "$CHOPI_SANDBOX_PROMPT_TARGETS_SLOT" "$paragraph"
}

# shellcheck shell=bash
# shellcheck disable=SC2034 # Defines variables that are used by the scripts that source this file
#
# claude-prompt.sh -- append context for chopi to claude's system prompt
#
# Sourced (never run directly).

_claude_prompt_dir="$(dirname "${BASH_SOURCE[0]}")"
. "$_claude_prompt_dir/util.sh"
unset _claude_prompt_dir

CHOPI_CLAUDE_PROMPT_FILE="$CHOPI_DIR/.internal/claude-sandbox-prompt.md"

# Amends the given claude command-line to append chopi's context to claude's system prompt and writes
# it to CLAUDE_ARGV_WITH_CHOPI_PROMPT. Sets --append-system-prompt-file to point to chopi's context
# merged with the contents of an existing --append-system-prompt{,-file} flag, if any.
CLAUDE_ARGV_WITH_CHOPI_PROMPT=()
claude_argv_with_chopi_prompt() {
    local run_dir="$1" cmd="$2"
    shift 2 # run_dir, cmd
    local args=("$@")

    local kept=() inline_at=-1 file_at=-1
    local i=0 n="${#args[@]}"
    while [ "$i" -lt "$n" ]; do
        case "${args[$i]}" in
            --)                            break ;;
            --append-system-prompt)        inline_at=$((i + 1)); i=$((i + 2)); continue ;;
            --append-system-prompt-file)   file_at=$((i + 1));   i=$((i + 2)); continue ;;
            --append-system-prompt=*)      inline_at=$i;         i=$((i + 1)); continue ;;
            --append-system-prompt-file=*) file_at=$i;           i=$((i + 1)); continue ;;
        esac
        kept+=("${args[$i]}")
        i=$((i + 1))
    done
    kept+=("${args[@]:i}")

    # An argv claude would reject anyway (both flags, or flag with no value) is left as-is.
    if { [ "$inline_at" -ge 0 ] && [ "$file_at" -ge 0 ]; } \
        || [ "$inline_at" -ge "$n" ] || [ "$file_at" -ge "$n" ]; then
        CLAUDE_ARGV_WITH_CHOPI_PROMPT=("$cmd" "$@")
        return 0
    fi

    local user_prompt=""
    if [ "$inline_at" -ge 0 ]; then
        user_prompt="${args[inline_at]#--append-system-prompt=}"
    elif [ "$file_at" -ge 0 ]; then
        local path="${args[file_at]#--append-system-prompt-file=}"
        case "$path" in
            /*) ;;
            *)  path="$run_dir/$path" ;;
        esac
        if [ ! -r "$path" ]; then
            echo "chopi: cannot read the --append-system-prompt-file path '$path'" >&2
            return 1
        fi
        user_prompt="$(cat "$path")" || return 1
    fi

    local merged
    merged="$(mktemp "$TMPDIR/${CHOPI_CLAUDE_SYSTEM_PROMPT_PREFIX}XXXXXX")" || return 1
    if [ -n "$user_prompt" ]; then
        printf '%s\n\n' "$user_prompt" >"$merged" || return 1
    fi
    cat "$CHOPI_CLAUDE_PROMPT_FILE" >>"$merged" || return 1

    CLAUDE_ARGV_WITH_CHOPI_PROMPT=("$cmd" --append-system-prompt-file "$merged" \
        "${kept[@]+"${kept[@]}"}")
}

# shellcheck shell=bash
# shellcheck disable=SC2034 # Defines variables that are used by the scripts that source this file
#
# codex-prompt.sh -- hand chopi's context to Codex as developer instructions
#
# Sourced (never run directly).

_codex_prompt_dir="$(dirname "${BASH_SOURCE[0]}")"
. "$_codex_prompt_dir/sandbox-prompt.sh"
unset _codex_prompt_dir

CHOPI_CODEX_PROMPT_PREFACE='Chopi enforces the outer filesystem and network sandbox. Codex reports danger-full-access because its own sandbox is disabled.'

is_codex_command() {
    arity 1
    [ "${1##*/}" = codex ]
}

# Print the developer instructions Codex gets in a session whose safe write targets are TARGETS
codex_developer_instructions() {
    arity 1
    local context
    context="$(chopi_prompt_document "$1")" || return 1
    printf '%s\n\n%s' "$CHOPI_CODEX_PROMPT_PREFACE" "$context"
}

# Amends the given codex command-line to run under chopi as its external sandbox, writing it to
# CODEX_ARGV_WITH_CHOPI_PROMPT. Asking Codex to install another macOS Seatbelt policy would make
# built-in tools such as apply_patch fail with EPERM, and its shared app-server daemon can't start
# sandboxed: recording the daemon's pid runs ps, which is denied. chopi's context goes in as
# developer instructions, overriding any set in Codex's configuration files.
CODEX_ARGV_WITH_CHOPI_PROMPT=()
codex_argv_with_chopi_prompt() {
    local safe_write_targets="$1" cmd="$2"
    shift 2 # safe_write_targets, cmd
    local instructions
    instructions="$(codex_developer_instructions "$safe_write_targets")" || return 1
    # jq's JSON string encoding also produces a TOML basic string.
    instructions="$(printf '%s' "$instructions" | jq -Rs .)" || return 1
    CODEX_ARGV_WITH_CHOPI_PROMPT=("$cmd" --sandbox danger-full-access --no-daemon
        -c "developer_instructions=$instructions" "$@")
}

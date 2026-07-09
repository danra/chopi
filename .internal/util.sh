# shellcheck shell=bash
# shellcheck disable=SC2034 # Defines variables that are used by the scripts that source this file
#
# util.sh -- shared helpers

# chopi's repo root (physical path). Every chopi script gets CHOPI_DIR by sourcing this
# file, which resolves it from its own location in .internal/.
_util_dir="$(dirname "${BASH_SOURCE[0]}")"
CHOPI_DIR="$(cd "$_util_dir/.." && pwd -P)"
unset _util_dir

# smokescreen isn't a Homebrew formula; `go install` drops it in GOBIN, which
# defaults to $HOME/go/bin. It isn't on PATH, so chopi always invokes it by this
# absolute path.
SMOKESCREEN_BIN="$HOME/go/bin/smokescreen"

PROXY_PORT=4760

# mktemp name prefixes of chopi's per-invocation temporaries (created under the private
# TMPDIR); shared so the tests assert on the same names chopi creates.
CHOPI_GITCONF_WRAPPER_PREFIX="chopi-gitconf-wrapper."
CHOPI_CMD_ALIAS_PREFIX="chopi-cmd-alias."

if command -v shopt >/dev/null 2>&1; then shopt -s expand_aliases; fi

# arity -- verify expected number of positional args.
_arity() {
    local got="$1" want="$2"   # got is the CALLER's $#, supplied by the alias
    [ "$got" -eq "$want" ] && return 0
    printf 'BUG: %s expects %d arg(s), got %d\n' "${FUNCNAME[1]:-${funcstack[2]:-?}}" "$want" "$got" >&2
    exit 2
}
alias arity='_arity "$#"'

# trace executed commands on/off
alias trace_on='set -x'
alias trace_off='{ set +x; } 2>/dev/null'

# Escape a filesystem path for embedding inside a Seatbelt string literal (the "..." of a
# subpath/literal/prefix matcher).
_sb_string_escape() {
    arity 1
    local s="$1"
    s="${s//\\/\\\\}"   # backslashes first...
    s="${s//\"/\\\"}"   # ...then double-quotes
    printf '%s' "$s"
}

# Emit one Seatbelt rule: (ACTION (MATCHER "PATH")), PATH escaped for the string literal.
# An empty PATH is a caller bug: the rule would silently misapply (e.g. an accidentally
# empty variable turning a targeted subpath rule into one matching somewhere else).
rule() {
    arity 3
    local action="$1" matcher="$2" path="$3"
    if [ -z "$path" ]; then
        printf 'BUG: rule called with an empty path\n' >&2
        exit 2
    fi
    printf '(%s (%s "%s"))\n' "$action" "$matcher" "$(_sb_string_escape "$path")"
}

# Is directory $1 the same as, or nested inside, directory $2? Both are absolute and
# normalized (no trailing slash except the root "/").
is_path_within() {
    arity 2
    local inner="$1" outer="$2"
    if [ -z "$inner" ] || [ -z "$outer" ]; then
        printf 'BUG: is_path_within called with an empty path\n' >&2
        exit 2
    fi
    [ "$inner" = "$outer" ] && return 0
    [ "$outer" = "/" ] && return 0   # every absolute path is inside the root
    case "$inner" in "$outer"/*) return 0 ;; esac
    return 1
}

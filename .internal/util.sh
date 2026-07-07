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

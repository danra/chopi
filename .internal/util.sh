# shellcheck shell=bash
# shellcheck disable=SC2034 # Defines variables that are used by the scripts that source this file
#
# util.sh -- shared helpers

# chopi's repo root (physical path). Every chopi script gets CHOPI_DIR by sourcing this
# file, which resolves it from its own location in .internal/.
_util_dir="$(dirname "${BASH_SOURCE[0]}")"
CHOPI_DIR="$(cd "$_util_dir/.." && pwd -P)"
unset _util_dir

SMOKESCREEN_BIN="$CHOPI_DIR/.internal/proxy/chopi-smokescreen"

PROXY_PORT=4760
# The GitHub relay's loopback listener. Keep this in sync with the hole hardcoded in
# .internal/network.sb (a Seatbelt profile can't read these shell vars).
GITHUB_RELAY_PORT=4761       # git-smart-HTTP -> github.com

# mktemp name prefixes of chopi's per-invocation temporaries (created under the private
# TMPDIR); shared so the tests assert on the same names chopi creates.
CHOPI_CLAUDE_CONTEXT_READS_PREFIX="chopi-claude-context-reads."
CHOPI_IN_SANDBOX_WRAPPER_PREFIX="chopi-in-sandbox-wrapper."
CHOPI_CMD_ALIAS_PREFIX="chopi-cmd-alias."

# The libs (basenames under .internal/) that the in-sandbox wrapper and cleanup source
CHOPI_IN_SANDBOX_LIBS=(git-layout.sh util.sh claude-common.sh claude-context-check.sh)

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

trim() {
    arity 1
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"    # ltrim
    s="${s%"${s##*[![:space:]]}"}"    # rtrim
    printf '%s' "$s"
}

# Print a config-file line with any trailing '#'-comment dropped and surrounding whitespace trimmed
strip_comment_and_trim() {
    arity 1
    trim "${1%%#*}"
}

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

# Canonicalize path $1, keeping it as-is when realpath fails (a dangling path, or -- in the
# sandbox -- a component whose metadata the sandbox blinds).
realpath_or_self() {
    arity 1
    realpath "$1" 2>/dev/null || printf '%s\n' "$1"
}

# Resolve the GitHub token the relay authenticates with, following gh's own source precedence:
# GH_TOKEN, then GITHUB_TOKEN, then gh's stored login. A variable that is SET wins over the next
# source even when EMPTY -- an explicit GH_TOKEN='' (or GITHUB_TOKEN='' when GH_TOKEN is unset) means
# "no token, and do NOT fall back to gh auth" -- so this tests set-vs-unset (the "+x" form), not
# empty-vs-non-empty. A token pasted with a trailing newline or stray surrounding whitespace would
# corrupt the Basic credential, so trim it. Read HERE on the host by both
# chopi-proxy.sh and test/github-relay-test.sh, so the smoke test resolves the token the proxy would; it
# never enters the sandbox.
resolve_gh_token() {
    arity 0
    local token
    if [ -n "${GH_TOKEN+x}" ]; then
        token="$GH_TOKEN"
    elif [ -n "${GITHUB_TOKEN+x}" ]; then
        token="$GITHUB_TOKEN"
    elif command -v gh >/dev/null 2>&1; then
        token="$(gh auth token 2>/dev/null || true)"
    else
        token=""
    fi
    trim "$token"
}

# Build the "Basic ..." Authorization header the GitHub relay injects: the git-smart-HTTP
# Basic-auth of "x-access-token:<token>". Shared by chopi-proxy.sh (which ships it) and
# test/github-relay-test.sh, so the smoke test exercises the exact bytes the relay sends. The tr drops the
# line wrap GNU coreutils' base64 adds at 76 cols (macOS base64 doesn't wrap, but PATH may have GNU).
gh_basic_auth_header() {
    arity 1
    local token="$1" encoded
    encoded="$(printf 'x-access-token:%s' "$token" | base64 | tr -d '\n')"
    printf 'Basic %s' "$encoded"
}

# Print the github domains in a rules file's allowed_domains sections that make exfiltration
# trivial: supports migration from when they were allowed in the template
exfiltration_prone_github_allowed_domains() {
    arity 1
    local rules_file="$1"

    # The allowed_domains sections' lines
    local section
    section="$(awk '
        /^[[:space:]]*allowed_domains:/ { in_section = 1; next }
        !in_section                     { next }
        /^[[:space:]]*(-|#|$)/          { print; next }
                                        { in_section = 0 }
    ' "$rules_file")"

    local line item
    while IFS= read -r line; do
        item="$(strip_comment_and_trim "$line")"
        [ -z "$item" ] && continue
        item="$(trim "${item#-}")" # "- domain" -> "domain"
        case "$item" in
            \"*\" | \'*\') item="${item#?}"; item="${item%?}" ;; # drop surrounding quotes
        esac
        case "$item" in
            github.com | api.github.com) printf '%s\n' "$item" ;;
        esac
    done <<< "$section"
}

github_relay_git_config() {
    arity 0
    local relay="http://127.0.0.1:$GITHUB_RELAY_PORT"
    printf '%s\n' \
        "url.$relay/.insteadOf=https://github.com/" \
        "url.$relay/.insteadOf=git@github.com:" \
        "url.$relay/.insteadOf=ssh://git@github.com/"

    # git-lfs verbosely warns on not having a config for whether locks verification
    # is enabled or not, EXCEPT for github.com which is baked in the git-lfs binary
    # as a special case (lfs.https://github.com/.locksverify=true). Since we rewrite
    # github.com to the relay loopback, this warning started popping up; silence it
    # by setting the config value (to true, after confirming the feature does indeed
    # work through the relay)
    printf '%s\n' "lfs.$relay/.locksverify=true"
}

# Do github remote URLs resolve to the relay under the ambient git config (all scopes, read from
# the current directory)? The in-sandbox wrapper runs this after exporting chopi's
# rewrites into the command scope, so it checks exactly the config the sandboxed command will see:
# a competing insteadOf in an earlier-read scope wins the longest-prefix tie and would divert
# github git off the relay onto a transport the sandbox blocks.
is_github_relay_reroute_effective() {
    arity 0
    local relay="http://127.0.0.1:$GITHUB_RELAY_PORT"
    local src resolved
    for src in "https://github.com/o/r" "git@github.com:o/r" "ssh://git@github.com/o/r"; do
        resolved="$(git ls-remote --get-url "$src" 2>/dev/null)"
        [ "$resolved" = "$relay/o/r" ] || return 1
    done
    return 0
}

port_has_listener() {
    arity 1
    nc -z 127.0.0.1 "$1" 2>/dev/null
}

# Print the first of the given 127.0.0.1 ports that already has a listener and return 0; print
# nothing and return 1 when all are free. Callers decide what a busy port means (error vs. skip).
first_listening_port() {
    local port
    for port in "$@"; do
        if port_has_listener "$port"; then
            printf '%s' "$port"
            return 0
        fi
    done
    return 1
}

# Poll for a listener on 127.0.0.1:PORT (~5s, 50 x 0.1s), bailing early if process PID exits first
# (e.g. a server that dies on a bad config). Returns 0 once the port accepts a connection, 1 on
# timeout or if the process is already gone.
wait_for_listener() {
    arity 2
    local port="$1" pid="$2" _
    for _ in {1..50}; do
        port_has_listener "$port" && return 0
        kill -0 "$pid" 2>/dev/null || return 1
        sleep 0.1
    done
    return 1
}

start_github_relay() {
    arity 2
    local caddyfile_text="$1" log="$2"
    # Feed the config to Caddy over a pipe (--config -): printf is a builtin, so the baked GitHub
    # token doesn't appear in any process's argv.
    printf '%s' "$caddyfile_text" | caddy run --adapter caddyfile --config - > "$log" 2>&1 &
    CADDY_PID=$!
    wait_for_listener "$GITHUB_RELAY_PORT" "$CADDY_PID"
}

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

# mktemp name prefixes of chopi's per-invocation temporaries (created under the private
# TMPDIR); shared so the tests assert on the same names chopi creates.
CHOPI_CLAUDE_CONTEXT_READS_PREFIX="chopi-claude-context-reads."
CHOPI_CLAUDE_SYSTEM_PROMPT_PREFIX="chopi-claude-system-prompt."
CHOPI_IN_SANDBOX_WRAPPER_PREFIX="chopi-in-sandbox-wrapper."
CHOPI_CMD_ALIAS_PREFIX="chopi-cmd-alias."

# The libs (basenames under .internal/) that the in-sandbox wrapper and cleanup source
CHOPI_IN_SANDBOX_LIBS=(git-layout.sh util.sh claude-common.sh claude-context-check.sh)

if command -v shopt >/dev/null 2>&1; then shopt -s expand_aliases; fi

# Keep ${var//pattern/replacement} replacements literal, as in macOS's bash 3.2: bash 5.2 expands
# an unquoted & in the replacement to the matched text, so a value holding one (a path, a token)
# would come out mangled. Older bashes lack the option.
shopt -u patsub_replacement 2>/dev/null || true

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

# readarray -t NAME -- the bash-4 builtin, polyfilled: split stdin into array NAME, one element
# per line. macOS's bash 3.2 lacks it; defined unconditionally so newer bashes run the same code.
# Only the -t form is supported, and NAME must be a plain identifier (it is eval'd).
readarray() {
    local _ra_name="${2-}" _ra_line _ra_lines=()
    if [ "$#" -ne 2 ] || [ "$1" != -t ] || [[ ! "$_ra_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        printf 'BUG: this readarray polyfill supports exactly: readarray -t NAME\n' >&2
        exit 2
    fi
    while IFS= read -r _ra_line; do _ra_lines+=("$_ra_line"); done
    eval "$_ra_name=(\${_ra_lines[@]+\"\${_ra_lines[@]}\"})"
}

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

# Print TEXT with every occurrence of each SLOT replaced by the VALUE following it. Callers
# assemble a text from a varying set of fragments, so a SLOT it doesn't hold is no error.
#
# usage: fill_slots TEXT [SLOT VALUE...]
fill_slots() {
    local text="$1"; shift
    if [ $(($# % 2)) -ne 0 ]; then
        printf 'BUG: fill_slots called with a slot missing its value\n' >&2
        exit 2
    fi
    local slot value
    while [ "$#" -gt 0 ]; do
        slot="$1" value="$2"; shift 2
        # Both taken literally: the quoted slot can't match as a glob pattern, and with
        # patsub_replacement off (see above), an & in the value stays an &. Quoting the value
        # instead isn't portable: bash 3.2 keeps the quotes in the result.
        text="${text//"$slot"/$value}"
    done
    printf '%s\n' "$text"
}

# Get the next keystroke for a prompt, as soon as it is pressed rather than waiting for a return
prompt_read_key() {
    arity 0
    local key
    IFS= read -r -n 1 key || return 1
    printf '\n' >&2
    printf '%s' "$key"
}

# Print the 1-based number of FILE's first line that matches LINE, modulo trimming whitespace
# around it. Prints nothing and fails when FILE has no such line (or can't be read).
file_line_number() {
    arity 2
    local file="$1" line="$2" current n=0
    [ -r "$file" ] || return 1
    while IFS= read -r current || [ -n "$current" ]; do
        n=$((n + 1))
        if [ "$(trim "$current")" = "$line" ]; then
            printf '%s' "$n"
            return 0
        fi
    done <"$file"
    return 1
}

# Does FILE have the exact LINE, modulo trimming whitespace around it
file_has_line() {
    arity 2
    file_line_number "$1" "$2" >/dev/null
}

# Is ITEM ($1) exactly one of the arguments after it?
# The list is passed as separate arguments, so items may contain any byte, newlines included.
is_item_in_list() {
    local item="$1"; shift
    local candidate
    for candidate in "$@"; do
        [ "$candidate" = "$item" ] && return 0
    done
    return 1
}

# Escape a filesystem path for embedding inside a Seatbelt string literal (the "..." of a
# subpath/literal/prefix matcher). Newline deliberately passes through raw: only an unescaped
# quote can end the literal, so the profile reader either takes the rule intact or rejects the
# whole profile and the sandbox never starts (fail-closed). Escaping it as \n instead would be
# fail-open for a deny if the reader lacked that escape: the rule would match a different path
# than the sibling it denies.
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

# Emit a write-deny literal for each directory node from every START (inclusive) up to
# STOP (exclusive; the walk also stops at the filesystem root). Plugs the Seatbelt hole of
# being able to write into a denied literal path by first moving a parent dir elsewhere,
# writing, and moving the parent dir back.
#
# usage: pin_ancestries STOP [START...]
pin_ancestries() {
    local stop="$1"; shift
    local pinned=() start node
    for start in "$@"; do
        node="$start"
        while [ "$node" != "$stop" ] && [ "$node" != / ]; do
            if ! is_item_in_list "$node" "${pinned[@]+"${pinned[@]}"}"; then
                pinned+=("$node")
                rule 'deny file-write*' literal "$node"
            fi
            node="$(dirname "$node")"
        done
    done
}

# Print dir $1's path relative to dir $2 -- nothing when they are the same directory -- failing
# when $1 is not within $2. Both are absolute and normalized (no trailing slash except the
# root "/").
relative_path_within() {
    arity 2
    local inner="$1" outer="$2"
    if [ -z "$inner" ] || [ -z "$outer" ]; then
        printf 'BUG: relative_path_within called with an empty path\n' >&2
        exit 2
    fi
    [ "$inner" = "$outer" ] && return 0
    [ "$outer" = "/" ] && { printf '%s' "${inner#/}"; return 0; }   # every absolute path is inside the root
    case "$inner" in
        "$outer"/*) printf '%s' "${inner#"$outer"/}" ;;
        *)          return 1 ;;
    esac
}

# Is directory $1 the same as, or nested inside, directory $2? Both are absolute and
# normalized (no trailing slash except the root "/").
is_path_within() {
    arity 2
    relative_path_within "$1" "$2" >/dev/null
}

overlapping_dirs() {
    arity 2
    is_path_within "$1" "$2" || is_path_within "$2" "$1"
}

# Canonicalize path $1, keeping it as-is when realpath fails (a dangling path, or -- in the
# sandbox -- a component whose metadata the sandbox blinds).
realpath_or_self() {
    arity 1
    realpath "$1" 2>/dev/null || printf '%s\n' "$1"
}

# Does path $1 reach chopi's own directory, in either direction? Its own function so the invariant
# has a name: a command must not reach the policy confining it, whether by a path inside chopi's
# directory or one that holds it.
overlaps_chopi_dir() {
    arity 1
    local real
    real="$(realpath_or_self "$1")"
    overlapping_dirs "$real" "$CHOPI_DIR"
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

# The "Bearer ..." Authorization header the relay's API routes inject. Shared for the same
# reason as gh_basic_auth_header above.
gh_bearer_auth_header() {
    arity 1
    local token="$1"
    printf 'Bearer %s' "$token"
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

# The git config pairs (key=value lines) routing github git to the git relay on PORT.
github_relay_git_config() {
    arity 1
    local relay="http://127.0.0.1:$1"
    printf '%s\n' \
        "url.$relay/.insteadOf=https://github.com/" \
        "url.$relay/.insteadOf=git@github.com:" \
        "url.$relay/.insteadOf=ssh://git@github.com/"

    # gh commands that shell out to git build remote URLs from GH_HOST=github.localhost --
    # as plaintext http, a gh special case for that hostname -- so reroute the alias like
    # github.com itself, mirroring the API relay answering for both api hostnames. gh never
    # emits the https form; it's for completeness, in case an agent seeing GH_HOST in its
    # environment constructs such a URL itself.
    printf '%s\n' \
        "url.$relay/.insteadOf=http://github.localhost/" \
        "url.$relay/.insteadOf=https://github.localhost/"

    # git-lfs verbosely warns on not having a config for whether locks verification
    # is enabled or not, EXCEPT for github.com which is baked in the git-lfs binary
    # as a special case (lfs.https://github.com/.locksverify=true). Since we rewrite
    # github.com to the relay loopback, this warning started popping up; silence it
    # by setting the config value (to true, after confirming the feature does indeed
    # work through the relay)
    printf '%s\n' "lfs.$relay/.locksverify=true"
}

# The env wiring (VAR=val lines) pointing gh at the API relay on unix socket SOCK, writing
# CONFIG_DIR's config file on the way. gh reaches the API relay over a unix socket rather than a TCP
# port: GH_HOST=github.localhost makes gh address the API as plaintext
# http://api.github.localhost/... (no CA), and http_unix_socket makes it dial the relay socket
# instead of resolving that name -- it has no environment variable, so it goes in the config file.
# The relay therefore sees the cleartext API request and scopes it to the same allowlist as git.
# The GH_TOKEN placeholder only has to make gh consider itself logged in; the relay wipes it and
# injects the real token host-side.
github_relay_gh_env() {
    arity 2
    local config_dir="$1" sock="$2"
    printf 'http_unix_socket: %s\n' "$sock" > "$config_dir/config.yml" || return 1
    printf '%s\n' \
        "GH_HOST=github.localhost" \
        "GH_CONFIG_DIR=$config_dir" \
        "GH_TOKEN=x-chopi-relay"
}

# Refuse, for REASON and the DETAIL of why it matters, with HINT on what to do about it -- or, with
# CHOPI_ALLOW_SELF set, only warn.
#
# usage: refuse_or_warn REASON DETAIL HINT
refuse_or_warn() {
    arity 3
    local reason="$1" detail="$2" hint="$3"
    if [ -n "${CHOPI_ALLOW_SELF:-}" ]; then
        echo "warning: $reason;" >&2
        echo "         $detail." >&2
        echo "         continuing anyway (CHOPI_ALLOW_SELF is set)." >&2
        echo >&2
    else
        echo "error: $reason;" >&2
        echo "       $detail." >&2
        echo "$hint" >&2
        return 1
    fi
}

# Run COMMAND in the background and exit with its status once it ends -- however it ends, a
# SIGKILL or a crash included -- signalling the rest of our process group to stop first. For a
# group's leader, whose group must not outlive COMMAND, its main process: a helper of COMMAND's,
# with nothing of its own to stop it, then still goes with it, and whoever stops the group by its
# id, our pid, reaches it all for as long as any of it is left.
#
# usage: lead_group COMMAND [ARGS...]
lead_group() {
    local pid status=0
    # Given our stdin explicitly: bash otherwise gives a background command /dev/null for it.
    "$@" <&0 &
    pid=$!
    wait "$pid" || status=$?
    trap '' TERM
    kill -TERM 0
    exit "$status"
}

# Do github remote URLs resolve to the git relay on PORT under the ambient git config (all
# scopes, read from the current directory)? The in-sandbox wrapper runs this after exporting
# chopi's rewrites into the command scope, so it checks exactly the config the sandboxed command
# will see: a competing insteadOf in an earlier-read scope wins the longest-prefix tie and would
# divert github git off the relay onto a transport the sandbox blocks.
#
# Returns 1 when a github URL resolves elsewhere, and 2 when git itself fails (e.g. the
# /usr/bin/git stub finding no developer tools it can read), with git's output on stderr.
is_github_relay_reroute_effective() {
    arity 1
    local relay="http://127.0.0.1:$1"
    local src resolved
    for src in "https://github.com/o/r" "git@github.com:o/r" "ssh://git@github.com/o/r"; do
        resolved="$(git ls-remote --get-url "$src")" || return 2
        [ "$resolved" = "$relay/o/r" ] || return 1
    done
    return 0
}

# Open FILE for the user from a process with no terminal, like the proxy's notifications: in
# their editor, VISUAL or else EDITOR, when it's one known to open a window of its own, and in the
# default text editor macOS has for it otherwise -- a terminal editor would have nowhere to show.
open_in_gui_editor() {
    arity 1
    local file="$1" editor
    read -r -a editor <<< "${VISUAL:-${EDITOR:-}}"
    case "$(basename -- "${editor[0]:-}")" in
        code|code-insiders|codium|cursor|windsurf|zed|subl|mate|bbedit)
            "${editor[@]}" "$file" ;;
        *)  open -t "$file" ;;
    esac
}

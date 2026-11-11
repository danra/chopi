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

# The outgoing proxy's and the GitHub relay's loopback ports: the kernel picks them as chopi-proxy
# first starts, and a restart takes them again where free (recorded in PROXY_PORTS_FILE.last), and
# read_proxy_ports reads them from PROXY_PORTS_FILE.
PROXY_PORT=""
GITHUB_RELAY_PORT=""         # git-smart-HTTP -> github.com

# The Caddy GitHub-API relay's endpoint. Unlike the git relay (a TCP port), gh reaches this over a
# unix socket: chopi sets GH_HOST=github.localhost so gh addresses the API as plaintext
# http://api.github.localhost/... (no CA needed), and gh's http_unix_socket config dials this path
# instead of resolving that name. The relay therefore sees the cleartext API request and scopes it
# to the same allowlist as git. chopi.sh opens a Seatbelt hole to this exact path.
#
# It and the ports file live in PROXY_RUN_DIR, which chopi-proxy.sh and chopi.sh share: run/ under
# ~/.chopi, which the sandbox can neither read nor write. Not under TMPDIR, which it can write: the
# ports decide which holes chopi opens, so a sandboxed command that rewrote them would aim the next
# run's holes, and HTTP_PROXY, at a local service of its choosing. Setting CHOPI_RUN_DIR gives a
# chopi-proxy, and the chopi runs started under it, a proxy of their own, as the tests do: its run/,
# which chopi-proxy makes private (make_private_dir), leaving the dir CHOPI_RUN_DIR names as it is.
# A relative one is taken from where it is given: chopi-proxy moves into chopi's directory and chopi
# into a worktree, so left relative it would name a different dir for each.
CHOPI_RUN_DIR="${CHOPI_RUN_DIR:-$HOME/.chopi}"
case "$CHOPI_RUN_DIR" in
    /*) ;;
    *) CHOPI_RUN_DIR="$PWD/$CHOPI_RUN_DIR" ;;
esac
PROXY_RUN_DIR="${CHOPI_RUN_DIR%/}/run"
GH_RELAY_SOCK="$PROXY_RUN_DIR/chopi-gh-relay.sock"
# Where chopi-proxy reports its ports once it serves, and removes them as it stops.
PROXY_PORTS_FILE="$PROXY_RUN_DIR/chopi-proxy.ports"

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

# Set variable NAME to STRING with surrounding whitespace trimmed: trim without a subshell, for
# loops over a file's lines.
#
# usage: trim_into NAME STRING
trim_into() {
    arity 2
    local _ti_s="$2"
    _ti_s="${_ti_s#"${_ti_s%%[![:space:]]*}"}"    # ltrim
    _ti_s="${_ti_s%"${_ti_s##*[![:space:]]}"}"    # rtrim
    printf -v "$1" '%s' "$_ti_s"
}

# Set variable NAME to a config-file LINE with any trailing '#'-comment dropped and surrounding
# whitespace trimmed
#
# usage: strip_comment_and_trim_into NAME LINE
strip_comment_and_trim_into() {
    arity 2
    trim_into "$1" "${2%%#*}"
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
        trim_into current "$current"
        if [ "$current" = "$line" ]; then
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
            node="${node%/*}"
            node="${node:-/}"
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

# Does path $1 reach chopi-proxy's run dir, in either direction? Its ports file aims each run's
# network holes and HTTP_PROXY, so nothing a session can write may reach it.
overlaps_proxy_run_dir() {
    arity 1
    overlapping_dirs "$(realpath_or_self "$1")" "$(realpath_or_self "$PROXY_RUN_DIR")"
}

# Resolve the GitHub token the relay authenticates with, following gh's own source precedence:
# GH_TOKEN, then GITHUB_TOKEN, then gh's stored login. A SET variable wins even when empty -- an
# explicit GH_TOKEN='' means "no token, don't fall back to gh auth" -- hence the "+x" tests. Trimmed,
# as stray whitespace from a paste would corrupt the Basic credential. Runs on the host only; the
# token never enters the sandbox. Shared with the relay smoke test, so it resolves the same token.
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
    trim_into token "$token"
    printf '%s' "$token"
}

# Build the "Basic ..." Authorization header the GitHub relay injects: the git-smart-HTTP
# Basic-auth of "x-access-token:<token>". Shared with the tests, so they check the exact bytes the
# relay sends. The tr drops the line wrap GNU base64 adds at 76 cols (PATH may have it on macOS).
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
        strip_comment_and_trim_into item "$line"
        trim_into item "${item#-}" # "- domain" -> "domain"
        [ -z "$item" ] && continue
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

# The env wiring (VAR=val lines) pointing gh at the API relay, writing CONFIG_DIR's config file on
# the way: GH_HOST=github.localhost makes gh address the API as plaintext
# http://api.github.localhost/... (no CA), and http_unix_socket makes it dial the relay socket
# instead of resolving that name -- it has no environment variable, so it goes in the config file.
# The GH_TOKEN placeholder only has to make gh consider itself logged in; the relay wipes it and
# injects the real token host-side.
github_relay_gh_env() {
    arity 1
    local config_dir="$1"
    printf 'http_unix_socket: %s\n' "$GH_RELAY_SOCK" > "$config_dir/config.yml" || return 1
    printf '%s\n' \
        "GH_HOST=github.localhost" \
        "GH_CONFIG_DIR=$config_dir" \
        "GH_TOKEN=x-chopi-relay"
}

# Write the Seatbelt profile denying the sandboxed command any access to chopi-proxy's run dir
# RUN_DIR to FILE. Its ports file aims each run's network holes and HTTP_PROXY, so a command that
# rewrote it would aim the next session's at a local port of its choosing. Preflight keeps the
# workspace off it, but other grants can cover it too: an --add-dirs path, a safe write target
# (readable), or a CHOPI_RUN_DIR under a dir safehouse grants, like TMPDIR. Appended after every
# file grant, so that among matching filtered rules this deny comes last and wins. Its ancestors
# are pinned so the dir can't be renamed away and replaced. Connecting to the API relay's socket
# in it is a network operation, which the proxy's network profile allows on its own.
#
# usage: write_proxy_run_dir_profile FILE RUN_DIR
write_proxy_run_dir_profile() {
    arity 2
    local file="$1" run_dir
    run_dir="$(realpath "$2")" \
        || { echo "chopi: cannot resolve chopi-proxy's run directory '$2'" >&2; return 1; }
    {
        echo ";; chopi: chopi-proxy's run dir, whose ports aim the network holes, stays out of reach."
        rule 'deny file-read* file-write*' subpath "$run_dir"
        pin_ancestries / "$(dirname "$run_dir")"
    } >"$file"
}

# Write the Seatbelt profile re-opening the proxy's endpoints to FILE: network.sb denies every
# outgoing connection, so these are the only ones the sandboxed command can make -- the smokescreen
# forward proxy on PORT, the git relay on RELAY_PORT, and the API relay's socket SOCK.
#
# usage: write_proxy_network_profile FILE PORT RELAY_PORT SOCK
write_proxy_network_profile() {
    arity 4
    local file="$1" port="$2" relay_port="$3" sock
    sock="$(realpath "$4")" \
        || { echo "chopi: cannot resolve the GitHub API relay socket path '$4'" >&2; return 1; }
    {
        echo ";; chopi: re-open the proxy's endpoints (network.sb denies the rest)."
        rule 'allow network-outbound' 'remote ip' "localhost:$port"
        rule 'allow network-outbound' 'remote ip' "localhost:$relay_port"
        rule 'allow network-outbound' literal "$sock"
    } >"$file"
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

port_has_listener() {
    arity 1
    nc -z 127.0.0.1 "$1" 2>/dev/null
}

# True when something accepts connections on unix socket PATH. curl does the dialing because
# macOS nc cannot -z-scan a unix socket; any HTTP outcome after a successful connect counts.
sock_has_listener() {
    arity 1
    curl -s -o /dev/null --max-time 2 --unix-socket "$1" http://sock/ 2>/dev/null
}

# Set PROXY_PORT and GITHUB_RELAY_PORT from PROXY_PORTS_FILE, one "NAME PORT" line each, as
# chopi-proxy reports them once it serves. Fails, setting neither, when the file is missing or
# malformed.
read_proxy_ports() {
    arity 0
    local name port proxy="" relay=""
    [ -f "$PROXY_PORTS_FILE" ] || return 1
    while read -r name port; do
        case "$name" in
            proxy) proxy="$port" ;;
            relay) relay="$port" ;;
        esac
    done <"$PROXY_PORTS_FILE"
    [[ "$proxy" =~ ^[0-9]+$ && "$relay" =~ ^[0-9]+$ ]] || return 1
    PROXY_PORT="$proxy"
    GITHUB_RELAY_PORT="$relay"
}

# run_chopi_smokescreen RULES ALLOWLIST RENDER RELAY_LOG -- run chopi's proxy and the GitHub relays,
# on the rules file RULES, with Caddy's config the output of RENDER run on ALLOWLIST, again on each
# edit to it, and Caddy's output in RELAY_LOG; the API relay on GH_RELAY_SOCK, and the ports
# reported in PROXY_PORTS_FILE. It execs, for its PID to be the proxy's: run it in the background.
run_chopi_smokescreen() {
    arity 4
    exec "$SMOKESCREEN_BIN" --relay-log "$4" --gh-sock "$GH_RELAY_SOCK" --ports-file "$PROXY_PORTS_FILE" \
        --github-allowlist "$2" --relay-config "$3" -- \
        --config-file "$CHOPI_DIR/.internal/smokescreen-config.yaml" \
        --egress-acl-file "$1"
}

# Make dir $1, in an existing parent, a directory only we can reach: created so if missing, else
# made so, once it is sure to be our own directory, not a link or another user's, as one planted in
# a shared parent such as /tmp could be.
make_private_dir() {
    arity 1
    local dir="$1"
    mkdir -m 700 "$dir" 2>/dev/null || true
    if [ -L "$dir" ] || [ ! -d "$dir" ]; then
        echo "error: $dir is not a directory" >&2
        return 1
    fi
    if [ "$(stat -f %u "$dir")" != "$EUID" ]; then
        echo "error: $dir belongs to another user" >&2
        return 1
    fi
    chmod 700 "$dir"
}

# Run COMMAND in the background, in a process group of its own, and once it exits -- however it
# exits, a SIGKILL or a crash included -- TERM the rest of that group and exit with its status.
# This keeps COMMAND's helpers (Caddy) from outliving it, while leaving our caller's group alone.
# A stop signal sent to us is passed on to COMMAND as a TERM, so it stops as it would have stopped
# itself; out of the terminal's foreground group, COMMAND gets no Ctrl-C of its own beside that.
# chopi-proxy calls it under `set -e`, so a command here that may fail harmlessly (a kill finding
# nothing left to stop) must be guarded: unguarded, it would end lead_group short of its cleanup.
#
# COMMAND should be a shell function, which may exec a program, as chopi-proxy's does. Under
# macOS's bash 3.2, a program run as COMMAND itself can drop a stop signal passed on to it just as
# it starts, and run on.
#
# usage: lead_group COMMAND [ARGS...]
lead_group() {
    local pid="" signaled="" early="" status
    # Trapped before COMMAND starts, lest a signal in between kill us and orphan it: one that comes
    # as it starts, too early for the trap to pass on, is passed on once its pid is known.
    trap 'signaled=1; if [ -n "$pid" ]; then kill -TERM "$pid" 2>/dev/null || :; else early=1; fi' \
        TERM HUP INT
    # Job control also keeps our stdin as COMMAND's: without it, a background job gets /dev/null.
    set -m
    "$@" &
    pid=$!
    set +m
    [ -z "$early" ] || kill -TERM "$pid" 2>/dev/null || :
    # A trapped signal cuts the wait short, with the signal's status rather than COMMAND's, so wait
    # again until a wait the trap left alone: its status is COMMAND's, even if an earlier wait
    # already took it and the trap came just after.
    while :; do
        signaled=""
        status=0
        wait "$pid" || status=$?
        [ -n "$signaled" ] || break
    done
    trap '' TERM HUP INT
    # The group outlives COMMAND, its ID with it, for as long as a helper of COMMAND's is in it.
    kill -TERM -- "-$pid" 2>/dev/null || :
    exit "$status"
}

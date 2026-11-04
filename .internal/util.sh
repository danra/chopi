# shellcheck shell=bash
# shellcheck disable=SC2034 # Defines variables that are used by the scripts that source this file
#
# util.sh -- shared helpers

# The aliases come first: bash expands an alias only in code parsed after its definition, so a
# function above them would keep a bare `arity` command, failing only when called.
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

# chopi's repo root (physical path). Every chopi script gets CHOPI_DIR by sourcing this
# file, which resolves it from its own location in .internal/.
_util_dir="$(dirname "${BASH_SOURCE[0]}")"
CHOPI_DIR="$(cd "$_util_dir/.." && pwd -P)"
unset _util_dir

SMOKESCREEN_BIN="$CHOPI_DIR/.internal/proxy/chopi-smokescreen"

# PROXY_RUN_DIR holds each session's proxy dir (see session-proxy.sh), where its proxy reports its
# ports and serves the GitHub API relay's socket: run/ under ~/.chopi, which the sandbox can neither
# read nor write. Not under TMPDIR, which it can write: the ports decide which holes chopi opens, so
# a sandboxed command -- another session's, say -- that rewrote them would aim the session's holes,
# and HTTP_PROXY, at a local service of its choosing. Setting CHOPI_RUN_DIR moves it, as the tests
# do: to its run/, which chopi makes private (make_private_dir), leaving the dir CHOPI_RUN_DIR names
# as it is. A relative one is taken from where it is given: chopi moves into a worktree, so left
# relative it would name a different dir there.
CHOPI_RUN_DIR="${CHOPI_RUN_DIR:-$HOME/.chopi}"
case "$CHOPI_RUN_DIR" in
    /*) ;;
    *) CHOPI_RUN_DIR="$PWD/$CHOPI_RUN_DIR" ;;
esac
PROXY_RUN_DIR="${CHOPI_RUN_DIR%/}/run"
# Where a custom proxy config -- the sandbox config's CHOPI_PROXY_RULES, CHOPI_GITHUB_ALLOWLIST --
# must be (see proxy_config_paths).
PROXY_CONFIG_DIR="${CHOPI_RUN_DIR%/}/config"
# The default proxy config files' names, under $CHOPI_DIR/config (see proxy_config_paths).
DEFAULT_PROXY_RULES="proxy-rules.yaml"
DEFAULT_GITHUB_ALLOWLIST="github-allowlist"
# The file in each session's proxy dir listing the config files its proxy reads, for as long as it
# runs (see proxy_config_paths).
PROXY_CONFIGS_FILE_NAME="configs"
# The name each session's proxy dir in PROXY_RUN_DIR starts with, before a "." and a random suffix.
PROXY_SESSION_DIR_PREFIX="chopi-proxy"

# Names of chopi's per-invocation temporaries (created under the private TMPDIR); shared so the
# tests assert on the same names chopi creates. The *_PROFILE ones are new_profile NAMEs, which it
# creates under profile_prefix; the *_PREFIX ones are mktemp prefixes.
CHOPI_CLAUDE_CONTEXT_READS_PROFILE=claude-context-reads
CHOPI_IN_SANDBOX_WRAPPER_PROFILE=in-sandbox-wrapper
CHOPI_CLAUDE_SYSTEM_PROMPT_PREFIX="chopi-claude-system-prompt."
CHOPI_CMD_ALIAS_PREFIX="chopi-cmd-alias."

# The libs (basenames under .internal/) that the in-sandbox wrapper and cleanup source
CHOPI_IN_SANDBOX_LIBS=(git-layout.sh util.sh claude-common.sh claude-context-check.sh)

# Print the mktemp prefix of the temp file new_profile makes for the Seatbelt profile NAME.
#
# usage: profile_prefix NAME
profile_prefix() {
    arity 1
    printf 'chopi-%s.' "$1"
}

# Print a new temp file, named by profile_prefix NAME and resolved by realpath (a writer may name
# the file in its own profile), holding the Seatbelt profile WRITER writes to it, called as
# WRITER FILE ARGS...
#
# usage: new_profile NAME WRITER [ARGS...]
new_profile() {
    local name="$1" writer="$2" file
    shift 2
    file="$(mktemp "$TMPDIR/$(profile_prefix "$name")XXXXXX")" \
        || { echo "chopi: could not create a temp file for the $name profile" >&2; return 1; }
    file="$(realpath "$file")" || return 1
    "$writer" "$file" "$@" \
        || { echo "chopi: could not write the $name profile" >&2; return 1; }
    printf '%s' "$file"
}

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

# Emit the Seatbelt rule ACTION as a literal on each directory node from every START (inclusive)
# up to STOP (exclusive), each node once. The walk also stops at the filesystem root, excluded.
# An empty START spells the root, as "${path%/*}" does for a path directly under it. A relative
# START is a caller bug: its walk would never reach the root.
#
# usage: ancestry_rules ACTION STOP [START...]
ancestry_rules() {
    local action="$1" stop="$2"; shift 2
    local seen=() start node
    for start in "$@"; do
        node="${start:-/}"
        if [ "${node#/}" = "$node" ]; then
            printf 'BUG: ancestry_rules called with a relative START: %s\n' "$start" >&2
            exit 2
        fi
        while [ "$node" != "$stop" ] && [ "$node" != / ]; do
            if ! is_item_in_list "$node" "${seen[@]+"${seen[@]}"}"; then
                seen+=("$node")
                rule "$action" literal "$node"
            fi
            node="${node%/*}"
            node="${node:-/}"
        done
    done
}

# ancestry_rules with a write-deny. Plugs the Seatbelt hole of being able to write into a denied
# literal path by first moving a parent dir elsewhere, writing, and moving the parent dir back.
#
# usage: pin_ancestries STOP [START...]
pin_ancestries() {
    ancestry_rules 'deny file-write*' "$@"
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

# Does path $1 reach the proxy's run dir, in either direction? The ports in it aim each session's
# network holes and HTTP_PROXY, so nothing a session can write may reach it.
overlaps_proxy_run_dir() {
    arity 1
    overlapping_dirs "$(realpath_or_self "$1")" "$(realpath_or_self "$PROXY_RUN_DIR")"
}

# Does path $1 reach any proxy config (proxy_config_paths), in either direction? Printing the
# config it reaches. The proxy hot-reloads it, so nothing that changes it unreviewed may reach it.
overlaps_proxy_config() {
    arity 1
    local real config
    real="$(realpath_or_self "$1")"
    while IFS= read -r config; do
        if overlapping_dirs "$real" "$config"; then
            printf '%s' "$config"
            return 0
        fi
    done < <(proxy_config_paths)
    return 1
}

# Print the GitHub token the environment sets, as it is: GH_TOKEN, then GITHUB_TOKEN. A SET variable
# wins even when empty -- an explicit GH_TOKEN='' means "no token, don't fall back to gh auth" --
# hence the "+x" tests. Fails when neither is set, leaving the token to gh's stored login.
env_gh_token() {
    arity 0
    if [ -n "${GH_TOKEN+x}" ]; then
        printf '%s' "$GH_TOKEN"
    elif [ -n "${GITHUB_TOKEN+x}" ]; then
        printf '%s' "$GITHUB_TOKEN"
    else
        return 1
    fi
}

# Resolve the GitHub token the relay authenticates with, following gh's own source precedence: the
# environment's (env_gh_token), else gh's stored login. Trimmed, as stray whitespace from a paste
# would corrupt the Basic credential. Runs on the host only; the token never enters the sandbox.
# Shared with the relay smoke test, so it resolves the same token.
resolve_gh_token() {
    arity 0
    local token
    if ! token="$(env_gh_token)"; then
        if command -v gh >/dev/null 2>&1; then
            token="$(gh auth token 2>/dev/null || true)"
        else
            token=""
        fi
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

# Write the Seatbelt profile letting the sandboxed side run chopi's in-sandbox WRAPPER and teardown
# CLEANUP to FILE: reading and running them, reading the libs they source, and stat on chopi's dir
# chain, for the in-sandbox CHOPI_DIR resolution.
#
# usage: write_in_sandbox_wrapper_profile FILE WRAPPER CLEANUP
write_in_sandbox_wrapper_profile() {
    arity 3
    local file="$1" wrapper="$2" cleanup="$3" lib
    {
        echo ";; chopi: the in-sandbox wrapper itself."
        rule 'allow file-read* process-exec' literal "$wrapper"
        echo ";; chopi: the in-sandbox teardown cleanup and the libs it and the wrapper source."
        rule 'allow file-read* process-exec' literal "$cleanup"
        for lib in "${CHOPI_IN_SANDBOX_LIBS[@]}"; do
            rule 'allow file-read*' literal "$CHOPI_DIR/.internal/$lib"
        done
        echo ";; chopi: stat-only on chopi's dir chain for in-sandbox CHOPI_DIR resolution."
        ancestry_rules 'allow file-read-metadata' / "$CHOPI_DIR/.internal"
        # The walk excludes the root, which the resolution stats too.
        rule 'allow file-read-metadata' literal /
    } >"$file"
}

# Write the Seatbelt profile denying the sandboxed command any access to the proxy's run dir
# RUN_DIR to FILE. The ports in it aim each session's network holes and HTTP_PROXY, so a command
# that rewrote another session's would aim them at a local port of its choosing. Preflight keeps the
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
        || { echo "chopi: cannot resolve the proxy's run directory '$2'" >&2; return 1; }
    {
        echo ";; chopi: the proxy's run dir, whose ports aim the network holes, stays out of reach."
        rule 'deny file-read* file-write*' subpath "$run_dir"
        pin_ancestries / "$(dirname "$run_dir")"
    } >"$file"
}

# Print what decides which file path $1 names, one per line: every symlink met resolving it, each
# where it really is -- in a dir with no symlink on its way -- then the real path it resolves to.
# Repointing any of those links would have $1 name another file. Past a missing node, the rest is
# appended unresolved. A symlink loop ends the walk, its links printed: $1 names no file then.
resolution_paths() {
    arity 1
    local todo="$1" cur="" node target hops=0
    case "$todo" in
        /*) ;;
        *)  todo="$PWD/$todo" ;;
    esac
    while [ -n "$todo" ]; do
        todo="${todo#/}"
        node="${todo%%/*}"
        case "$todo" in
            */*) todo="${todo#*/}" ;;
            *)   todo="" ;;
        esac
        case "$node" in
            "" | .) continue ;;
            ..)     cur="${cur%/*}"; continue ;;
        esac
        if [ -L "$cur/$node" ] && target="$(readlink "$cur/$node")"; then
            printf '%s\n' "$cur/$node"
            hops=$((hops + 1))
            [ "$hops" -le 40 ] || return 0
            case "$target" in
                /*) cur="" ;;
            esac
            todo="$target${todo:+/$todo}"
        else
            cur="$cur/$node"
        fi
    done
    printf '%s\n' "${cur:-/}"
}

# Print every path deciding which proxy config a session's proxy reads, now or as a later session
# starts, one per line (resolution_paths): PROXY_CONFIG_DIR's, where a custom one must be; the
# default files', which may link elsewhere, through any number of links; and those of the files each
# running session's proxy reads, as listed in its dir (launch_session_proxy), should a link have been
# repointed since it started. Every session keeps its command from changing them all, as a safe
# write target must not overlap them.
proxy_config_paths() {
    arity 0
    local path configs
    # Sessions mostly list the same files, so each is resolved once.
    {
        printf '%s\n' "$PROXY_CONFIG_DIR" "$CHOPI_DIR/config/$DEFAULT_PROXY_RULES" \
            "$CHOPI_DIR/config/$DEFAULT_GITHUB_ALLOWLIST"
        for configs in "$PROXY_RUN_DIR/$PROXY_SESSION_DIR_PREFIX".*/"$PROXY_CONFIGS_FILE_NAME"; do
            [ -f "$configs" ] && cat "$configs"
        done
    } | awk 'length && !seen[$0]++' | while IFS= read -r path; do
        resolution_paths "$path"
    done | awk '!seen[$0]++'
}

# Write the Seatbelt profile denying the sandboxed command any change to the proxy's config to FILE
# (proxy_config_paths): a command that could rewrite its rules or GitHub allowlist could lift the
# outgoing limits of every session, mid-session even, as the proxy hot-reloads them. Whatever grant
# covers one -- the workspace, the sandbox config's, safehouse's own, a trusted .safehouse's -- this
# deny, appended after every file grant, comes last among the matching rules and wins: nothing in
# them can be written, removed, or have another put in its place. Their ancestors are pinned, so
# none can be renamed away and replaced, nor made where missing. Reading is left as granted. Another
# name for a config file, a hard link, which these rules can't see, chopi refuses before launch (see
# preflight_proxy_config_links), and the proxy refuses a change to a file with one.
#
# usage: write_proxy_config_profile FILE
write_proxy_config_profile() {
    arity 1
    local file="$1" paths path
    readarray -t paths < <(proxy_config_paths)
    {
        echo ";; chopi: the proxy's config, which sets the sessions' outgoing limits, stays unchangeable."
        for path in "${paths[@]}"; do
            rule 'deny file-write*' subpath "$path"
        done
        pin_ancestries / "${paths[@]}"
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

# The macOS banner group of the proxy's reload failures for config file FILE, the rules or the
# GitHub allowlist: one per file, shared by the proxy of every session reading it. They all reload
# the same edit, so a broken one shows a single banner, rather than one per session, and the next
# good one withdraws it, whichever session's proxy reloads it first. That holds only among sessions
# whose reloads of FILE can't differ: a non-empty KEY sets apart those that can -- the allowlist's
# render depends on where the session takes its GitHub token from (gh_token_source).
#
# usage: reload_banner_group FILE KEY
reload_banner_group() {
    arity 2
    local hash
    hash="$(md5 -q -s "$1${2:+
$2}")"
    printf 'chopi-proxy-reload-%s' "${hash:0:12}"
}

# Where resolve_gh_token takes the GitHub token from, which decides whether the relays' config
# renders for a non-empty allowlist: "env" for a non-empty one in the environment (env_gh_token),
# "none" for an empty one, which resolve_gh_token takes as it is, and "gh" for gh's own, the same
# for every session. Its value alone matters to nothing a reload checks, so it is no part of this.
gh_token_source() {
    arity 0
    local token
    token="$(env_gh_token)" || { echo gh; return; }
    trim_into token "$token"
    if [ -n "$token" ]; then echo env; else echo none; fi
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

# run_chopi_smokescreen DIR PARENT RULES ALLOWLIST RENDER RELAY_LOG -- run a session's proxy and its
# GitHub relays, on the rules file RULES, with Caddy's config the output of RENDER run on ALLOWLIST,
# again on each edit to it, and Caddy's output in RELAY_LOG; the API relay on DIR/gh.sock, and the
# ports reported in DIR/ports; stopping once process PARENT exits. It execs, for its PID to be the
# proxy's: run it in the background.
run_chopi_smokescreen() {
    arity 6
    exec "$SMOKESCREEN_BIN" --dir "$1" --parent "$2" --relay-log "$6" \
        --github-allowlist "$4" --relay-config "$5" -- \
        --config-file "$CHOPI_DIR/.internal/smokescreen-config.yaml" \
        --egress-acl-file "$3"
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
# itself.
# chopi-proxy.sh calls it under `set -e`, so a command here that may fail harmlessly (a kill finding
# nothing left to stop) must be guarded: unguarded, it would end lead_group short of its cleanup.
#
# COMMAND should be a shell function, which may exec a program, as chopi-proxy.sh's does. Under
# macOS's bash 3.2, a program run as COMMAND itself can drop a stop signal passed on to it just as
# it starts, and run on.
#
# usage: lead_group COMMAND [ARGS...]
lead_group() {
    local pid="" signaled="" early="" status
    # Trapped before COMMAND starts, lest a signal in between kill us and orphan it: one that comes
    # as it starts, too early for the trap to pass on, is passed on once its pid is known.
    trap 'signaled=1; if [ -n "$pid" ]; then kill -TERM "$pid" 2>/dev/null || :; else early=1; fi' \
        TERM HUP
    # Job control gives COMMAND a process group of its own, for its helpers to be stopped with it.
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
    trap '' TERM HUP
    # The group outlives COMMAND, its ID with it, for as long as a helper of COMMAND's is in it.
    kill -TERM -- "-$pid" 2>/dev/null || :
    exit "$status"
}

# Pop a macOS banner with SUBTITLE and MESSAGE, in the background, replacing the last one in
# GROUP. A click on it opens FILE.
#
# usage: notify GROUP FILE SUBTITLE MESSAGE
notify() {
    arity 4
    local group="$1" file="$2" subtitle="$3" message="$4"
    {
        result=$(alerter --title 'Chopi' \
                         --subtitle "$subtitle" \
                         --message "$message" \
                         --group "$group" \
                         --timeout 10 2>/dev/null || true)
        case "$result" in
            @TIMEOUT | @CLOSED | '') ;;
            *) open "$file" >/dev/null 2>&1 || true ;;
        esac
    } &
}

#!/usr/bin/env bash
#
# github-relays-caddyfile.sh -- emit the Caddy config for chopi's GitHub relays.
#
#   github-relays-caddyfile.sh <allowlist-file>   # prints a Caddyfile to stdout
#
# Compiles the GitHub repo allowlist into a path regex and assembles the Caddyfile from the
# github-relay-*.caddy (git) and github-api-relay-*.caddy (API) fragments next to this script:
# two loopback reverse-proxy listeners,
#
#   :GITHUB_RELAY_PORT (TCP)      git-smart-HTTP -> github.com
#   GH_RELAY_SOCK (unix socket)   gh REST API    -> api.github.com / uploads.github.com
#
# with the credentialed routes included only when the allowlist has entries, and a catch-all
# tail on the API relay: an anonymous passthrough for GitHub's signed-storage download hosts
# (gh follows those redirects over the socket) and a loud refusal for any other Host.
#
# chopi-proxy.sh renders this, fills the @@CHOPI_AUTH@@ / @@CHOPI_API_AUTH@@ credential slots and
# the @@CHOPI_GH_SOCK@@ socket-path slot in memory, and pipes the result to Caddy over stdin -- so
# they never touch disk.
#
# These are reverse proxies, not MITMs: the sandbox reaches them over plaintext loopback HTTP (gh
# speaks plaintext because chopi sets GH_HOST=github.localhost, dialing the socket via
# http_unix_socket), and Caddy originates its own TLS to GitHub with real certs, so no CA is
# involved.
#
# Every route drops all inbound request headers and re-adds only a fixed necessary set. The
# injected credentials are re-added ONLY on the allowlisted @allowed / @api_allowed routes.

set -euo pipefail

_render_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$_render_dir/util.sh"
unset _render_dir

main() {
    if [ "$#" -ne 1 ]; then
        echo "github-relays-caddyfile.sh: usage: github-relays-caddyfile.sh <allowlist-file>" >&2
        exit 2
    fi
    local allowlist="$1"
    if [ ! -f "$allowlist" ]; then
        echo "github-relays-caddyfile.sh: allowlist file not found: $allowlist" >&2
        exit 2
    fi

    local allowlist_regex
    allowlist_regex="$(build_allowlist_regex "$allowlist")"
    emit_caddyfile "$allowlist_regex"
}

# build_allowlist_regex -- read the allowlist file and print an regex alternation of its entries,
# e.g. "soundradix/[^/]+|acme/tool(\.git)?". Empty output means an empty allowlist.
build_allowlist_regex() {
    arity 1
    local allowlist="$1"

    local entries_regexes=()
    local line entry owner repo esc_owner esc_repo entry_regex
    while IFS= read -r line || [ -n "$line" ]; do
        entry="$(strip_comment_and_trim "$line")"
        [ -z "$entry" ] && continue
        case "$entry" in
            */*) ;;
            *) echo "github-relays-caddyfile.sh: allowlist entry needs owner/repo or owner/*: '$entry'" >&2; exit 2 ;;
        esac
        owner="${entry%%/*}"
        repo="${entry#*/}"
        validate_repo_slug "$owner" owner "$entry"
        esc_owner="${owner//./\\.}"
        if [ "$repo" = "*" ]; then
            entry_regex="$esc_owner/[^/]+"
        else
            validate_repo_slug "$repo" repo "$entry"
            esc_repo="${repo//./\\.}"
            entry_regex="$esc_owner/$esc_repo(\\.git)?"
        fi
        entries_regexes+=("$entry_regex")
    done < "$allowlist"

    if [ "${#entries_regexes[@]}" -eq 0 ]; then
        return 0
    fi
    local IFS='|'
    printf '%s' "${entries_regexes[*]}"
}

# deny_pkt -- print a git smart-HTTP body that makes git fail with "remote error: <message>":
# the service advertisement preamble, a flush pkt, then an ERR pkt-line. $1 is the git service
# name, $2 the message (ASCII only: the pkt-line length prefixes are byte counts).
deny_pkt() {
    arity 2
    local service="$1" message="$2"
    local svc_line="# service=$service"$'\n'
    local err_line="ERR $message"
    printf '%04x%s0000%04x%s' "$((4 + ${#svc_line}))" "$svc_line" "$((4 + ${#err_line}))" "$err_line"
}

# validate_repo_slug -- verify VALUE is a "normal" non-empty string. A generic
# sanity check that keeps a config value safe -- NOT an attempt to match GitHub's
# actual owner/repo rules.
validate_repo_slug() {
    arity 3
    local value="$1" kind="$2" entry="$3"
    case "$value" in
        ''|*[!A-Za-z0-9._-]*) echo "github-relays-caddyfile.sh: bad $kind in '$entry'" >&2; exit 2 ;;
    esac
}

# emit_caddyfile -- assemble the Caddyfile from the fragments and fill every slot except the
# caller-filled ones: @@CHOPI_AUTH@@ / @@CHOPI_API_AUTH@@ (in-memory credential fills, so this
# generator never handles the token itself) and @@CHOPI_GH_SOCK@@ (the API-relay socket path: the caller
# knows it; this generator may run under an already-repointed TMPDIR, where re-deriving it gives a
# different path). $1 is the allowlist regex alternation; when it is empty the credentialed
# fragments are dropped entirely, so no push route and no authed API route exist at all.
emit_caddyfile() {
    arity 1
    local allowlist_regex="$1"

    local fragments=(github-relay-head)
    [ -n "$allowlist_regex" ] && fragments+=(github-relay-allowed)
    fragments+=(github-relay-pub github-api-relay-head)
    [ -n "$allowlist_regex" ] && fragments+=(github-api-relay-allowed)
    fragments+=(github-api-relay-pub)
    [ -n "$allowlist_regex" ] && fragments+=(github-api-relay-uploads)
    fragments+=(github-api-relay-tail)

    local name paths=()
    for name in "${fragments[@]}"; do
        paths+=("$CHOPI_DIR/.internal/$name.caddy")
    done
    local text
    text="$(cat "${paths[@]}")"

    local deny_fetch deny_push auth_msg deny_auth_fetch deny_auth_push
    deny_fetch="$(deny_pkt git-upload-pack \
        "chopi: repo not found, or private and missing from chopi's config/github-allowlist")"
    deny_push="$(deny_pkt git-receive-pack \
        "chopi: push denied, repo is not in chopi's config/github-allowlist")"
    auth_msg="chopi: GitHub rejected the relay credential; refresh the host's GitHub token outside the sandbox (gh auth login / GH_TOKEN)"
    deny_auth_fetch="$(deny_pkt git-upload-pack "$auth_msg")"
    deny_auth_push="$(deny_pkt git-receive-pack "$auth_msg")"

    fill_slots "$text" \
        @@GITPORT@@ "$GITHUB_RELAY_PORT" \
        @@ALLOWLIST_REGEX@@ "$allowlist_regex" \
        @@DENY_PKT_FETCH@@ "$deny_fetch" \
        @@DENY_PKT_PUSH@@ "$deny_push" \
        @@DENY_PKT_AUTH_FETCH@@ "$deny_auth_fetch" \
        @@DENY_PKT_AUTH_PUSH@@ "$deny_auth_push"
}

main "$@"

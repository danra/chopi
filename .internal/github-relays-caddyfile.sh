#!/usr/bin/env bash
#
# github-relays-caddyfile.sh -- emit the Caddy config for chopi's GitHub relays.
#
#   github-relays-caddyfile.sh [ENTRY...]   # prints a Caddyfile to stdout
#
# Compiles the GitHub repo allowlist, one entry per argument, into a path regex and assembles the
# Caddyfile from the github-relay-*.caddy (git) and github-api-relay-*.caddy (API) fragments next to
# this script: two loopback reverse-proxy listeners,
#
#   fd/{$CHOPI_GIT_FD} (TCP)        git-smart-HTTP -> github.com
#   fd/{$CHOPI_GH_FD} (unix socket) gh REST API    -> api.github.com / uploads.github.com
#
# with the credentialed routes included only when the allowlist has entries (code search and
# org-wide reads only when it has owner/* entries), and a catch-all tail on the API relay: an
# anonymous passthrough for GitHub's signed-storage download hosts (gh follows those redirects over
# the socket) and a loud refusal for any other Host.
#
# github-relays-config.sh renders this, fills the @@CHOPI_AUTH@@ / @@CHOPI_API_AUTH@@ credential
# slots in memory, and chopi-smokescreen pipes the result to Caddy over stdin -- so the credentials
# never touch disk. The
# listeners are chopi-smokescreen's, opened before Caddy starts and handed to it open: Caddy reads
# their descriptors from its environment, and the git relay's kernel-picked port, for the redirects
# it rewrites, too ({$CHOPI_GIT_PORT}).
#
# These are reverse proxies, not MITMs: the sandbox reaches them over plaintext loopback HTTP (gh
# speaks plaintext because chopi sets GH_HOST=github.localhost, dialing the socket via
# http_unix_socket), and Caddy originates its own TLS to GitHub with real certs, so no CA is
# involved.
#
# Every route drops all inbound request headers and re-adds only a fixed necessary set. The
# injected credentials are re-added ONLY on the routes scoped to the allowlist.

set -euo pipefail

_render_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$_render_dir/util.sh"
unset _render_dir

main() {
    # The entries' regex alternation, and the owner/* entries' owners: the owners whose every repo
    # is allowlisted, so a code search or org-wide read scoped to one reaches only allowlisted repos.
    local allowlist_regex="" owners_regex="" entry esc re
    for entry in "$@"; do
        # The proxy already checks every entry as it reads the network config, and names the file
        # in its error. This check stays because the regex built below is safe only for entries
        # that pass it.
        if ! is_allowlist_entry "$entry"; then
            echo "github-relays-caddyfile.sh: allowlist entry needs owner/repo or owner/*, using only A-Za-z0-9._-: '$entry'" >&2
            exit 2
        fi
        # is_allowlist_entry admits no regex metacharacter but the dot (and owner/*'s star)
        esc="${entry//./\\.}"
        if [[ $esc == */\* ]]; then
            owners_regex+="${owners_regex:+|}${esc%/*}"
            re="${esc%/*}/[^/]+"
        else
            re="$esc(\\.git)?"
        fi
        allowlist_regex+="${allowlist_regex:+|}$re"
    done
    emit_caddyfile "$allowlist_regex" "$owners_regex"
}

# Is ENTRY a GitHub allowlist entry: owner/repo, or owner/* for the owner's every repo? A generic
# sanity check that keeps a config value safe -- NOT an attempt to match GitHub's actual rules.
#
# usage: is_allowlist_entry ENTRY
is_allowlist_entry() {
    arity 1
    [[ "$1" =~ ^[A-Za-z0-9._-]+/([A-Za-z0-9._-]+|\*)$ ]]
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

# emit_caddyfile -- assemble the Caddyfile from the fragments and fill every slot except the
# caller-filled ones: @@CHOPI_AUTH@@ / @@CHOPI_API_AUTH@@ (in-memory credential fills, so this
# generator never handles the token itself). $1 is the allowlist regex alternation; when it is
# empty the credentialed fragments are dropped entirely, so no push route and no authed API route
# exist at all. $2 is the owner/* owners' alternation; when it is empty the code search and org
# routes are dropped likewise.
emit_caddyfile() {
    arity 2
    local allowlist_regex="$1" owners_regex="$2"

    local fragments=(github-relay-head)
    [ -n "$allowlist_regex" ] && fragments+=(github-relay-allowed)
    fragments+=(github-relay-pub github-api-relay-head)
    [ -n "$allowlist_regex" ] && fragments+=(github-api-relay-allowed)
    [ -n "$owners_regex" ] && fragments+=(github-api-relay-search github-api-relay-orgs)
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
        "chopi: repo not found, or private and missing from the github_allowlist of chopi's network config")"
    deny_push="$(deny_pkt git-receive-pack \
        "chopi: push denied, repo is not on the github_allowlist of chopi's network config")"
    auth_msg="chopi: GitHub rejected the relay credential; refresh the host's GitHub token outside the sandbox (gh auth login / GH_TOKEN)"
    deny_auth_fetch="$(deny_pkt git-upload-pack "$auth_msg")"
    deny_auth_push="$(deny_pkt git-receive-pack "$auth_msg")"

    fill_slots "$text" \
        @@ALLOWLIST_REGEX@@ "$allowlist_regex" \
        @@OWNERS_REGEX@@ "$owners_regex" \
        @@DENY_PKT_FETCH@@ "$deny_fetch" \
        @@DENY_PKT_PUSH@@ "$deny_push" \
        @@DENY_PKT_AUTH_FETCH@@ "$deny_auth_fetch" \
        @@DENY_PKT_AUTH_PUSH@@ "$deny_auth_push"
}

main "$@"

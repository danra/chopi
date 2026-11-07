#!/usr/bin/env bash
#
# github-relays-config.sh -- print the Caddy config of chopi's GitHub relays, credentials included.
#
#   github-relays-config.sh <allowlist-file>
#
# Renders the config for the allowlist (github-relays-caddyfile.sh) and fills its credential slots
# with the GitHub token: the GH_TOKEN or GITHUB_TOKEN set, else gh's. chopi-proxy.sh runs this as
# the proxy starts, piping the output to Caddy over stdin: the token never touches disk or any argv.
#
# Notes for the user, and why it fails, go to stderr.

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCRIPT_DIR/util.sh"

main() {
    if [ "$#" -ne 1 ]; then
        echo "$SCRIPT_NAME: usage: $SCRIPT_NAME <allowlist-file>" >&2
        exit 2
    fi
    local allowlist="$1" config token auth api_auth
    config="$("$SCRIPT_DIR/github-relays-caddyfile.sh" "$allowlist")" \
        || { echo "[$SCRIPT_NAME] error: could not render the GitHub relay config from $allowlist" >&2; exit 1; }
    if [[ "$config" == *@@CHOPI_AUTH@@* ]]; then
        token="$(resolve_gh_token)"
        if [ -z "$token" ]; then
            echo "[$SCRIPT_NAME] error: the GitHub allowlist has entries but no GitHub token is set." >&2
            echo "              Push and private-repo access to allowlisted repos need one; set GH_TOKEN" >&2
            echo "              or run 'gh auth login' -- or empty the allowlist for anonymous public fetch only." >&2
            exit 1
        fi
        auth="$(gh_basic_auth_header "$token")"
        api_auth="$(gh_bearer_auth_header "$token")"
        config="$(fill_slots "$config" @@CHOPI_AUTH@@ "$auth" @@CHOPI_API_AUTH@@ "$api_auth")"
    else
        # No credential slot: the GitHub allowlist is empty, so the relay proxies anonymous public
        # fetch only.
        echo "[$SCRIPT_NAME] NOTE: the GitHub allowlist is empty; only public fetch and anonymous public API reads are enabled until you add allowed repos." >&2
    fi
    printf '%s\n' "$config"
}

main "$@"

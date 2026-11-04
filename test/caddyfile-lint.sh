#!/usr/bin/env bash
#
# test/caddyfile-lint.sh -- lint the relay Caddy configs (run by `make lint`).
#
#   caddyfile-lint.sh   # no arguments; exit 0 = clean (or caddy not installed), nonzero = findings
#
# The .caddy fragments are not complete Caddyfiles on their own, so render each relay config shape
# chopi-proxy uses and have caddy check the result with `caddy validate` and `caddy fmt --diff`.

set -euo pipefail

_lint_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$_lint_dir/../.internal/util.sh"
unset _lint_dir

if ! command -v caddy >/dev/null 2>&1; then
    echo "caddy not installed -- skipping the relay config lint (brew install caddy)"
    exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/chopi-caddy-lint.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# The GitHub relay has two shapes: a populated allowlist (credentialed routes present) and an
# empty one (anonymous routes only).
printf 'owner/repo\n' > "$WORK/allow-populated"
: > "$WORK/allow-empty"
"$CHOPI_DIR/.internal/github-relays-caddyfile.sh" "$WORK/allow-populated" > "$WORK/github-populated"
"$CHOPI_DIR/.internal/github-relays-caddyfile.sh" "$WORK/allow-empty" > "$WORK/github-empty"

# Fill the socket-path slot the way chopi-proxy does before piping to caddy, so the config checked
# here is the one caddy is handed in production. The path is TMPDIR-derived, so fill with one
# holding whitespace, which a TMPDIR may legally hold.
sock="$WORK/tmp dir/chopi-gh-relay.sock"
# The git relay's port comes from Caddy's environment, as start_github_relay sets it. Not the
# default port, so the checks below tell the environment's from one baked in.
export CHOPI_GIT_PORT=24761

for cf in github-populated github-empty; do
    text="$(cat "$WORK/$cf")"
    printf '%s\n' "${text//@@CHOPI_GH_SOCK@@/$sock}" > "$WORK/$cf"

    if ! caddy validate --adapter caddyfile --config "$WORK/$cf" > "$WORK/log" 2>&1; then
        echo "caddy validate failed on the $cf render:" >&2
        cat "$WORK/log" >&2
        exit 1
    fi
    if ! caddy fmt --diff "$WORK/$cf" > "$WORK/log" 2>&1; then
        echo "caddy fmt wants changes on the $cf render -- fix the .caddy fragments:" >&2
        grep '^[+-]' "$WORK/log" >&2 || cat "$WORK/log" >&2
        exit 1
    fi
    # The relay must listen on the loopback port and the filled socket path, and nowhere else:
    # a site-address host only MATCHES requests, it never binds (a site without an explicit bind
    # gets Caddy's default wildcard listener), and whitespace in an unquoted bind token splits it
    # into bogus listeners that caddy accepts at validate time and fails to bind at run time.
    caddy adapt --adapter caddyfile --config "$WORK/$cf" > "$WORK/json" 2>/dev/null
    if ! grep -qF "\"unix/$sock\"" "$WORK/json"; then
        echo "the $cf render does not listen on the filled API socket path:" >&2
        grep -oE '"listen":\[[^]]*\]' "$WORK/json" >&2
        exit 1
    fi
    listeners="$(grep -oE '"listen":\[[^]]*\]' "$WORK/json" | grep -oE '"[^"]*"' | grep -v '^"listen"$' | tr -d '"')"
    while IFS= read -r addr; do
        case "$addr" in
            "127.0.0.1:$CHOPI_GIT_PORT" | "unix/$sock") ;;
            *)
                echo "the $cf render binds an unexpected listener '$addr':" >&2
                grep -oE '"listen":\[[^]]*\]' "$WORK/json" >&2
                exit 1 ;;
        esac
    done <<< "$listeners"
    # A GitHub redirect (a renamed repo) is rewritten back through the relay, on the same port.
    # shellcheck disable=SC2016  # a Caddy regex replacement, not this shell's expansion
    if ! grep -qF '"http://127.0.0.1:'"$CHOPI_GIT_PORT"'/$1"' "$WORK/json"; then
        echo "the $cf render does not rewrite GitHub redirects to the relay's port:" >&2
        grep -oE '"Location":[^]]*\]' "$WORK/json" >&2
        exit 1
    fi
done

echo "caddy relay configs: valid"

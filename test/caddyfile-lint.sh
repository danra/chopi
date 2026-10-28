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

# The listeners' descriptors, and the git listener's port, come from Caddy's environment, as
# chopi-smokescreen sets them.
export CHOPI_GIT_PORT=24761 CHOPI_GIT_FD=3 CHOPI_GH_FD=4

for cf in github-populated github-empty; do
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
    # The relays must listen on the inherited listeners (fd/N), and nowhere else: a site-address
    # host only MATCHES requests, it never binds (a site without an explicit bind gets Caddy's
    # default wildcard listener).
    caddy adapt --adapter caddyfile --config "$WORK/$cf" > "$WORK/json" 2>/dev/null
    if ! grep -qF "\"fd/$CHOPI_GH_FD\"" "$WORK/json"; then
        echo "the $cf render does not listen on the inherited API socket:" >&2
        grep -oE '"listen":\[[^]]*\]' "$WORK/json" >&2
        exit 1
    fi
    listeners="$(grep -oE '"listen":\[[^]]*\]' "$WORK/json" | grep -oE '"[^"]*"' | grep -v '^"listen"$' | tr -d '"')"
    while IFS= read -r addr; do
        case "$addr" in
            "fd/$CHOPI_GIT_FD" | "fd/$CHOPI_GH_FD") ;;
            *)
                echo "the $cf render binds an unexpected listener '$addr':" >&2
                grep -oE '"listen":\[[^]]*\]' "$WORK/json" >&2
                exit 1 ;;
        esac
    done <<< "$listeners"
done

echo "caddy relay configs: valid"

#!/usr/bin/env bash
#
# test/integration.sh -- chopi's end-to-end integration tests
#
# starts the real outgoing proxy (bin/chopi-proxy.sh) and runs real sandbox-protected
# commands through the `chopi` command (bin/chopi -> chopi.sh), then asserts that filesystem
# and network access are exactly what the policy allows -- no more, no less:
#
#   * filesystem: read/write inside the workspace works; reads/writes OUTSIDE it (incl.
#     chopi's own dir) are denied.
#   * network: an allowlisted host is reachable THROUGH the proxy; a non-allowlisted host
#     is refused by the proxy (and the denial is logged + notified); any direct outgoing connection
#     that bypasses the proxy, or aims at a non-4760 port, is blocked by Seatbelt.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
. "$repo/.internal/util.sh"
. "$repo/test/lib.sh"

header "test/integration.sh -- chopi's end-to-end integration tests"

ALLOWED_HOST="www.google.com"      # in the test allowlist  -> reachable through the proxy
DENIED_HOST="www.microsoft.com"    # NOT in the allowlist   -> refused by the proxy


# ---------------------------------------------------------------------------
# Skip guard -- print why and exit 0 (never fail) when prerequisites are absent.
# ---------------------------------------------------------------------------
skip() { arity 1; echo "SKIP: $1"; exit 0; }

[ "$(uname -s)" = "Darwin" ] || skip "not macOS (the sandbox needs Seatbelt/safehouse)"
for t in safehouse jq alerter nc; do
    command -v "$t" >/dev/null 2>&1 || skip "missing required tool on PATH: $t"
done
# smokescreen is invoked by absolute path (it isn't on PATH); mirror chopi-proxy.sh's check.
[ -x "$SMOKESCREEN_BIN" ] || skip "missing smokescreen at $SMOKESCREEN_BIN"
if nc -z 127.0.0.1 "$PROXY_PORT" 2>/dev/null; then
    skip "port $PROXY_PORT is already in use -- stop your running chopi-proxy first"
fi


# ---------------------------------------------------------------------------
# Fixtures -- everything under one base dir UNDER \$HOME (not /tmp or /var/folders, which
# safehouse grants read+write by default.
# ---------------------------------------------------------------------------
base="$(mktemp -d "$HOME/.chopi-itest.XXXXXX")" || { echo "error: mktemp failed" >&2; exit 1; }
trap 'if [ -n "${proxy_pid:-}" ]; then kill "$proxy_pid" 2>/dev/null || true; wait "$proxy_pid" 2>/dev/null || true; fi; rm -rf "$base"' EXIT

ws="$base/workspace"            # the sandbox workspace (read/write granted, as the workdir)
outside="$base/outside"         # sibling under $HOME -> reliably denied
alerter_stub="$base/bin"        # a recording `alerter` shim on the proxy's PATH
cfg="$base/config/sandbox.sh"   # minimal sandbox config, OUTSIDE the workspace
allowlist="$base/config/itest-allowlist.yaml"
proxy_log="$base/proxy.log"
alerter_log="$base/alerter-calls.log"
mkdir -p "$ws" "$outside" "$alerter_stub" "$base/config"

# A workspace file to read back, and an out-of-bounds secret that must stay unreadable.
secret="CHOPI_SECRET_$$"
printf 'INSIDE_MARKER\n' > "$ws/readable.txt"
printf '%s\n' "$secret"  > "$outside/secret.txt"

# Minimal config: no extra dir grants (so denials are clean), PATH of system binaries only
cat > "$cfg" <<'EOF'
CHOPI_SAFEHOUSE_FLAGS=()
CHOPI_EXTRA_ENV=( PATH=/usr/bin:/bin:/usr/sbin:/sbin )
EOF

# Test allowlist: exactly one host allowed.
cat > "$allowlist" <<EOF
version: v1
services: []
default:
  name: default
  action: enforce
  allowed_domains:
    - $ALLOWED_HOST
EOF

# alerter shim: record each invocation (so we can prove the denial-notification path fired)
# instead of popping a real macOS banner per DENY.
: > "$alerter_log"
cat > "$alerter_stub/alerter" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$alerter_log"
exit 0
EOF
chmod +x "$alerter_stub/alerter"

# Poll FILE for PATTERN (literal) -- the proxy writes its log and fires the alerter
# asynchronously, so log assertions must wait rather than read once.
wait_for() {
    arity 2
    local f="$1" pat="$2" _
    for _ in {1..50}; do
        grep -Fq "$pat" "$f" 2>/dev/null && return 0
        sleep 0.1
    done
    return 1
}


# ---------------------------------------------------------------------------
# Start the real proxy.
# ---------------------------------------------------------------------------
echo "proxy + sandbox setup"

# The stub alerter goes first on the proxy's PATH; jq/nc/etc. stay reachable via the rest.
PATH="$alerter_stub:$PATH" "$repo/bin/chopi-proxy.sh" --allowlist "$allowlist" > "$proxy_log" 2>&1 &
proxy_pid=$!

ready=""
for _ in {1..50}; do
    nc -z 127.0.0.1 "$PROXY_PORT" 2>/dev/null && { ready=1; break; }
    kill -0 "$proxy_pid" 2>/dev/null || break   # proxy died -- stop waiting
    sleep 0.1
done
if [ -z "$ready" ]; then
    echo "error: the test proxy did not come up on 127.0.0.1:$PROXY_PORT" >&2
    echo "--- proxy.log ---" >&2; cat "$proxy_log" >&2
    exit 1
fi
ok "test proxy is listening on 127.0.0.1:$PROXY_PORT"

# Every sandboxed call: run from the workspace with the minimal config.
chopi_t() { ( cd "$ws" && "$repo/bin/chopi" --config "$cfg" -- "$@" ); }

# Run curl INSIDE the sandbox and echo its HTTP status code ("000" when the connection is
# blocked/refused before any response).
sandbox_curl() { chopi_t /usr/bin/curl -sS -o /dev/null -w '%{http_code}' "$@" 2>/dev/null || true; }


# ---------------------------------------------------------------------------
echo "positive control + exit-code propagation"
# ---------------------------------------------------------------------------
out="$(chopi_t /bin/sh -c 'echo OK' 2>/dev/null)"
assert_eq "$out" "OK" "a command actually runs under the minimal sandbox config"

rc=0; chopi_t /bin/sh -c 'exit 7' >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "7" "chopi propagates the sandboxed command's exit code"


# ---------------------------------------------------------------------------
echo "filesystem confinement"
# ---------------------------------------------------------------------------
out="$(chopi_t /bin/sh -c 'echo M > ./in.txt && echo OK || echo FAIL' 2>/dev/null)"
assert_eq "$out" "OK"                              "write INSIDE the workspace succeeds"
assert_eq "$(cat "$ws/in.txt" 2>/dev/null)" "M"    "  -> the file is really written in the workspace"

out="$(chopi_t /bin/cat ./readable.txt 2>/dev/null)"
assert_eq "$out" "INSIDE_MARKER"                   "read INSIDE the workspace returns the content"

out="$(chopi_t /bin/sh -c "cat '$outside/secret.txt' && echo READ_OK || echo READ_FAIL" 2>/dev/null)"
assert_not_contains "$out" "$secret"               "read OUTSIDE the workspace is denied (no secret leaks)"
assert_contains     "$out" "READ_FAIL"             "  -> and the read itself fails"

chopi_t /bin/sh -c "echo x > '$outside/evil.txt'" >/dev/null 2>&1 || true
if [ -e "$outside/evil.txt" ]; then
    bad "write OUTSIDE the workspace is denied (file must not exist)"
else
    ok  "write OUTSIDE the workspace is denied (no file created)"
fi

out="$(chopi_t /bin/sh -c "cat '$repo/.internal/chopi-preflight.sh' && echo READ_OK || echo READ_FAIL" 2>/dev/null)"
assert_not_contains "$out" "preflight"             "read of chopi's OWN dir is denied (config stays out of reach)"
assert_contains     "$out" "READ_FAIL"             "  -> and that read fails"


# ---------------------------------------------------------------------------
echo "network confinement"
# ---------------------------------------------------------------------------
# (1) Allowed host THROUGH the proxy -> 200. Needs real connectivity, so gate it on a
# host-side precheck and SKIP (not fail) when offline.
if curl -sS -o /dev/null --max-time 10 "https://$ALLOWED_HOST" 2>/dev/null; then
    code="$(sandbox_curl --max-time 20 "https://$ALLOWED_HOST")"
    assert_eq "$code" "200"                        "allowlisted host is reachable THROUGH the proxy"
else
    echo "  SKIP allowlisted-host reachability (no connectivity to $ALLOWED_HOST)"
fi

# (2) Denied host THROUGH the proxy -> refused (smokescreen denies on the ACL before
# dialing, so this works offline). Refused == not 200, plus a logged DENY, plus the
# notification path firing (the recording alerter stub).
code="$(sandbox_curl --max-time 20 "https://$DENIED_HOST")"
assert_not_contains "$code" "200"                  "non-allowlisted host is refused by the proxy"
if wait_for "$proxy_log" "$DENIED_HOST"; then
    ok  "  -> the proxy logged a DENY for $DENIED_HOST"
else
    bad "  -> the proxy did NOT log a DENY for $DENIED_HOST"
fi
if wait_for "$alerter_log" "DENY $DENIED_HOST"; then
    ok  "  -> the denial fired the alerter notification"
else
    bad "  -> the denial did NOT fire the alerter notification"
fi

# (3) A direct outgoing connection that bypasses the proxy is blocked by Seatbelt (offline-safe -- the
# socket never connects). --noproxy '*' overrides the *_PROXY env chopi injects.
code="$(sandbox_curl --max-time 15 --noproxy '*' "https://$ALLOWED_HOST")"
assert_not_contains "$code" "200"                  "a direct outgoing connection bypassing the proxy is blocked by the sandbox"

# (4) Outgoing connections are pinned to 4760 SPECIFICALLY: a different loopback proxy port is blocked
# (network.sb only allows localhost:4760). Offline-safe.
code="$(sandbox_curl --max-time 15 --proxy "http://127.0.0.1:4761" "https://$ALLOWED_HOST")"
assert_not_contains "$code" "200"                  "an outgoing connection to a non-4760 loopback port is blocked by the sandbox"

# ---------------------------------------------------------------------------
summary

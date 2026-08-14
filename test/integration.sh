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
#   * network: an allowed host is reachable THROUGH the proxy; a host that's not allowed
#     is refused by the proxy (and the denial is logged + notified); any direct outgoing connection
#     that bypasses the proxy, or aims at a non-allowlisted loopback port, is blocked by Seatbelt.
#   * rules hot reload: an edit to the rules file takes effect while the proxy runs; a
#     broken edit is refused loudly and the previous rules stay in effect.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

# A private TMPDIR, exported so the scripts under test leave their temporaries here too. Created
# before sourcing util.sh, which derives GH_RELAY_SOCK from it; trap it now so an early skip still
# cleans up (the rest of the fixtures, and the fuller trap, come after the skip guards below).
TMPDIR="$(mktemp -d)"; export TMPDIR
trap 'rm -rf "$TMPDIR"' EXIT

. "$repo/.internal/util.sh"
. "$repo/.internal/claude-prompt.sh"
. "$repo/test/lib.sh"

header "test/integration.sh -- chopi's end-to-end integration tests"

ALLOWED_HOST="www.google.com"      # allowed in the test rules       -> reachable through the proxy
DENIED_HOST="www.microsoft.com"    # NOT allowed in the test rules   -> refused by the proxy
OTHER_DENIED_HOST="www.wikipedia.org"  # never allowed -> stays refused across the hot-reload tests


# ---------------------------------------------------------------------------
# Skip guard -- print why and exit 0 (never fail) when prerequisites are absent.
# ---------------------------------------------------------------------------
skip() { arity 1; echo "SKIP: $1"; exit 0; }

[ "$(uname -s)" = "Darwin" ] || skip "not macOS (the sandbox needs Seatbelt/safehouse)"
for t in safehouse jq alerter nc caddy git gh; do
    command -v "$t" >/dev/null 2>&1 || skip "missing required tool on PATH: $t"
done
# The proxy binary is invoked by absolute path (it isn't on PATH); mirror chopi-proxy.sh's check.
[ -x "$SMOKESCREEN_BIN" ] || skip "proxy binary not built at $SMOKESCREEN_BIN (run: make build)"
if busy_port="$(first_listening_port "$PROXY_PORT" "$GITHUB_RELAY_PORT")"; then
    skip "port $busy_port is already in use -- stop your running chopi-proxy first"
fi


# ---------------------------------------------------------------------------
# Fixtures -- everything under one CANONICAL base dir in /var/tmp
# (Seatbelt filters, and so the assertions below, see /private/var/tmp, not the /var symlink).
# Why /var/tmp: safehouse grants nothing there, unlike /tmp and /var/folders; and unlike
# $HOME, its ancestors hold no Claude context files of the developer's, whose symlink
# targets and @-imports the minimal configs here do not grant, so every claude run below
# would be refused.
# ---------------------------------------------------------------------------
vartmp="$(cd /var/tmp && pwd -P)" || { echo "error: cannot resolve /var/tmp" >&2; exit 1; }
base="$(mktemp -d "$vartmp/chopi-itest.XXXXXX")" || { echo "error: mktemp failed" >&2; exit 1; }
trap 'if [ -n "${proxy_pid:-}" ]; then kill "$proxy_pid" 2>/dev/null || true; wait "$proxy_pid" 2>/dev/null || true; fi; rm -rf "$base" "$TMPDIR"' EXIT

ws="$base/workspace"            # the sandbox workspace (read/write granted, as the workdir)
outside="$base/outside"         # sibling of the workspace -> reliably denied
alerter_stub="$base/bin"        # a recording `alerter` shim on the proxy's PATH
claudebin="$base/claudebin"     # a stand-in `claude` for the Claude-context cases
codexbin="$base/codexbin"       # a stand-in `codex` for checking Chopi's argv
cfg="$base/config/sandbox.sh"   # minimal sandbox config, OUTSIDE the workspace
rules="$base/config/itest-rules.yaml"
proxy_log="$base/proxy.log"
alerter_log="$base/alerter-calls.log"
mkdir -p "$ws" "$outside" "$alerter_stub" "$claudebin" "$codexbin" "$base/config" "$base/home"

# Fixture HOME under $base, automatically cleaned-up and avoids dirtying actual ~
# Belongs in /var/tmp for the same reason $base does; under $TMPDIR, safehouse's blanket
# /var/folders grant would make that file readable to any command, agent profile or not.
HOME="$base/home"; export HOME
# A commit identity, the one thing the fixture takes away from the developer's global git config
printf '[user]\n\tname = t\n\temail = t@t.t\n' > "$HOME/.gitconfig"

make_repo "$ws"     # chopi only runs at a git worktree root

# A workspace file to read back, and an out-of-bounds secret that must stay unreadable.
secret="CHOPI_SECRET_$$"
printf 'INSIDE_MARKER\n' > "$ws/readable.txt"
printf '%s\n' "$secret"  > "$outside/secret.txt"

claude_shim="$claudebin/claude"
cat > "$claude_shim" <<'EOF'
#!/bin/sh
if [ "$1" = --append-system-prompt-file ]; then
    CHOPI_ITEST_PROMPT="$(cat "$2")"; export CHOPI_ITEST_PROMPT
    shift 2
fi
exec /bin/sh "$@"
EOF
chmod +x "$claude_shim"

codex_shim="$codexbin/codex"
cat > "$codex_shim" <<'EOF'
#!/bin/sh
printf '%s\n' "$@"
EOF
chmod +x "$codex_shim"

# Minimal config: no dir grants beyond the stub agent's (so denials are clean), PATH of
# system binaries only
cat > "$cfg" <<EOF
CHOPI_SAFEHOUSE_FLAGS=( --add-dirs-ro "$claudebin:$codexbin" )
CHOPI_EXTRA_ENV=( PATH=/usr/bin:/bin:/usr/sbin:/sbin )
EOF

# Test rules: exactly one host allowed.
# A function because the hot-reload tests below restore this same baseline mid-run.
write_test_rules() {
    arity 0
    cat > "$rules" <<EOF
version: v1
services: []
default:
  name: default
  action: enforce
  allowed_domains:
    - $ALLOWED_HOST
EOF
}
write_test_rules

# alerter shim: record each invocation (so we can prove the denial-notification path fired)
# instead of popping a real macOS banner per DENY.
: > "$alerter_log"
cat > "$alerter_stub/alerter" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$alerter_log"
exit 0
EOF
chmod +x "$alerter_stub/alerter"

# Poll FILE until PATTERN (literal) appears on at least COUNT lines -- for asserting a
# repeat of an already-seen log line (e.g. a second rules reload).
wait_for_count() {
    arity 3
    local f="$1" pat="$2" count="$3" _
    for _ in {1..50}; do
        [ "$(grep -Fc "$pat" "$f" 2>/dev/null)" -ge "$count" ] && return 0
        sleep 0.1
    done
    return 1
}

# Poll FILE for PATTERN (literal) -- the proxy writes its log and fires the alerter
# asynchronously, so log assertions must wait rather than read once.
wait_for() {
    arity 2
    local f="$1" pat="$2"
    wait_for_count "$f" "$pat" 1
}

# Poll ~5s for child PID to exit and reap it: returns 0 with its exit status in
# WAIT_FOR_EXIT_RC. On timeout kills PID, reaps it, and returns 1.
wait_for_exit() {
    arity 1
    local pid="$1" _
    for _ in {1..50}; do
        if ! kill -0 "$pid" 2>/dev/null; then
            WAIT_FOR_EXIT_RC=0
            wait "$pid" || WAIT_FOR_EXIT_RC=$?
            return 0
        fi
        sleep 0.1
    done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 1
}

# assert_no_listeners STAGE -- a refused chopi-proxy start must exit before binding anything:
# assert both proxy ports are free ("refused before STAGE").
assert_no_listeners() {
    arity 1
    local stage="$1"
    if first_listening_port "$PROXY_PORT" "$GITHUB_RELAY_PORT" >/dev/null; then
        bad "  -> but a port stayed bound (it must refuse before $stage)"
    else
        ok  "  -> and neither port was bound (refused before $stage)"
    fi
}


# ---------------------------------------------------------------------------
echo "the proxy refuses a populated allowlist with no GitHub token"
# ---------------------------------------------------------------------------
nonempty_github_allow="$base/config/itest-github-allowlist-nonempty"
printf 'soundradix/*\n' > "$nonempty_github_allow"
refuse_log="$base/refuse.log"

GH_TOKEN='' "$repo/bin/chopi-proxy.sh" --rules "$rules" --github-allowlist "$nonempty_github_allow" > "$refuse_log" 2>&1 &
refuse_pid=$!

if ! wait_for_exit "$refuse_pid"; then
    bad "chopi-proxy kept running for a populated allowlist with no token (it must refuse)"
else
    assert_nonzero  "$WAIT_FOR_EXIT_RC" "chopi-proxy refuses a populated allowlist with no token"
    assert_contains "$(cat "$refuse_log")" "no GitHub token is set" "  -> and logs the reason"
    assert_no_listeners "starting Caddy"
fi


# ---------------------------------------------------------------------------
echo "the proxy refuses rules that allow github.com/api.github.com (pre-relay leftovers)"
# ---------------------------------------------------------------------------
exfil_rules="$base/config/itest-rules-exfil.yaml"
cat > "$exfil_rules" <<EOF
version: v1
services: []
default:
  name: default
  action: enforce
  allowed_domains:
    - $ALLOWED_HOST
    - github.com
    - api.github.com
EOF
exfil_github_allow="$base/config/itest-github-allowlist-exfil"
: > "$exfil_github_allow"
exfil_log="$base/exfil-refuse.log"

"$repo/bin/chopi-proxy.sh" --rules "$exfil_rules" --github-allowlist "$exfil_github_allow" > "$exfil_log" 2>&1 &
exfil_pid=$!

if ! wait_for_exit "$exfil_pid"; then
    bad "chopi-proxy kept running with github.com allowed in the rules (it must refuse)"
else
    assert_nonzero  "$WAIT_FOR_EXIT_RC" "chopi-proxy refuses rules that allow github.com and api.github.com"
    assert_contains "$(cat "$exfil_log")" "github.com, api.github.com"  "  -> the refusal names the domains"
    assert_contains "$(cat "$exfil_log")" "dedicated relays"            "  -> and says both git and the API are relayed"
    assert_contains "$(cat "$exfil_log")" "proxy-rules.template.yaml"   "  -> and directs to the current template"
    assert_contains "$(cat "$exfil_log")" "global_deny_list"            "  -> or to moving the domains to the denylist"
    assert_contains "$(cat "$exfil_log")" "CHOPI_ALLOW_EXFILTRATION_PRONE_GITHUB_DOMAINS_DESPITE_API_RELAY" "  -> and names the override"
    assert_no_listeners "starting anything"
fi

# The override: the same rules only warn with CHOPI_ALLOW_EXFILTRATION_PRONE_GITHUB_DOMAINS_DESPITE_API_RELAY=1,
# and the proxy comes up.
override_log="$base/exfil-override.log"
CHOPI_ALLOW_EXFILTRATION_PRONE_GITHUB_DOMAINS_DESPITE_API_RELAY=1 "$repo/bin/chopi-proxy.sh" --rules "$exfil_rules" --github-allowlist "$exfil_github_allow" > "$override_log" 2>&1 &
override_pid=$!
if wait_for_listener "$PROXY_PORT" "$override_pid"; then
    ok "CHOPI_ALLOW_EXFILTRATION_PRONE_GITHUB_DOMAINS_DESPITE_API_RELAY=1 lets the proxy start"
    assert_contains "$(cat "$override_log")" "CHOPI_ALLOW_EXFILTRATION_PRONE_GITHUB_DOMAINS_DESPITE_API_RELAY is set" \
        "  -> with the refusal downgraded to a warning"
else
    bad "the proxy did not come up with CHOPI_ALLOW_EXFILTRATION_PRONE_GITHUB_DOMAINS_DESPITE_API_RELAY=1"
    sed 's/^/  /' "$override_log" >&2 || true
fi
kill "$override_pid" 2>/dev/null || true
wait "$override_pid" 2>/dev/null || true
# Free the ports for the real proxy below (Caddy exits ~0.2s after smokescreen).
for _ in {1..50}; do
    first_listening_port "$PROXY_PORT" "$GITHUB_RELAY_PORT" >/dev/null || break
    sleep 0.1
done


# ---------------------------------------------------------------------------
# Start the real proxy.
# ---------------------------------------------------------------------------
echo "proxy + sandbox setup"

empty_github_allow="$base/config/itest-github-allowlist-empty"
: > "$empty_github_allow"

# The stub alerter goes first on the proxy's PATH; jq/nc/etc. stay reachable via the rest.
PATH="$alerter_stub:$PATH" "$repo/bin/chopi-proxy.sh" --rules "$rules" --github-allowlist "$empty_github_allow" > "$proxy_log" 2>&1 &
proxy_pid=$!

if ! wait_for_listener "$PROXY_PORT" "$proxy_pid"; then
    echo "error: the test proxy did not come up on 127.0.0.1:$PROXY_PORT" >&2
    echo "--- proxy.log ---" >&2; cat "$proxy_log" >&2
    exit 1
fi
ok "test proxy is listening on 127.0.0.1:$PROXY_PORT"

# Every sandboxed call: run from the workspace with the minimal config. The Claude-context
# cases go through the stand-in agent, in another workspace or under another config when the
# case calls for it.
chopi_t() { ( cd "$ws" && "$repo/bin/chopi" --config "$cfg" -- "$@" ); }
chopi_claude_in() {
    local dir="$1" conf="$2"; shift 2
    ( cd "$dir" && "$repo/bin/chopi" --config "$conf" -- "$claude_shim" "$@" )
}
chopi_claude() { chopi_claude_in "$ws" "$cfg" "$@"; }
chopi_codex() { chopi_t "$codex_shim" "$@"; }

# Run curl INSIDE the sandbox and echo its HTTP status code ("000" when the connection is
# blocked/refused before any response).
sandbox_curl() { chopi_t /usr/bin/curl -sS -o /dev/null -w '%{http_code}' "$@" 2>/dev/null; }

# The CONNECT response code is the proxy's own verdict on a tunneled host: 200 = allowed (and
# the upstream TCP dial succeeded), 407 = denied by the rules. Unlike %{http_code} it does not
# depend on the full TLS+HTTP exchange with the remote host, which can stall mid-connection on
# a flaky network path (curl then reports 000, indistinguishable from a deny).
sandbox_curl_connect() { chopi_t /usr/bin/curl -sS -o /dev/null -w '%{http_connect}' "$@" 2>/dev/null; }

# Denied operations and captured exit codes below rely on errexit being off.
set +e


# ---------------------------------------------------------------------------
echo "positive control + exit-code propagation"
# ---------------------------------------------------------------------------
out="$(chopi_t /bin/sh -c 'echo OK' 2>/dev/null)"
assert_eq "$out" "OK" "a command actually runs under the minimal sandbox config"

chopi_t /bin/sh -c 'exit 7' >/dev/null 2>&1; rc=$?
assert_eq "$rc" "7" "chopi propagates the sandboxed command's exit code"

# shellcheck disable=SC2016 # the variable expands in the sandboxed shell, not here
out="$(chopi_t /bin/sh -c 'printf %s "${CHOPI_DIR:-unset}"' 2>/dev/null)"
assert_eq "$out" "$CHOPI_DIR" "the sandboxed command can tell it is confined, and where chopi is (CHOPI_DIR)"


# ---------------------------------------------------------------------------
echo "--verbose gates the safehouse command echo"
# ---------------------------------------------------------------------------
# The safehouse command line is echoed (to stderr, via xtrace) only with --verbose, so a
# quiet run stays quiet while an inspectable one shows exactly how safehouse was invoked.
# --append-profile is a distinctive token of chopi's constructed command that appears in the
# trace but never in safehouse's own output, so it cleanly tells the two runs apart.
chopi_run() { ( cd "$ws" && "$repo/bin/chopi" "$@" --config "$cfg" -- /bin/sh -c 'echo OK' ); }

err="$(chopi_run 2>&1 >/dev/null)"
assert_not_contains "$err" "--append-profile"      "without --verbose, the safehouse command line is not echoed"

err="$(chopi_run --verbose 2>&1 >/dev/null)"
assert_contains     "$err" "safehouse"             "with --verbose, the safehouse command line is echoed to stderr"
assert_contains     "$err" "--append-profile"      "  -> and the trace shows the full invocation (append-profile flags)"


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

chopi_t /bin/sh -c "echo x > '$outside/evil.txt'" >/dev/null 2>&1
assert_absent "$outside/evil.txt" "write OUTSIDE the workspace is denied (no file created)"

out="$(chopi_t /bin/sh -c "cat '$repo/.internal/preflight.sh' && echo READ_OK || echo READ_FAIL" 2>/dev/null)"
assert_not_contains "$out" "preflight"             "read of chopi's OWN dir is denied (config stays out of reach)"
assert_contains     "$out" "READ_FAIL"             "  -> and that read fails"


# ---------------------------------------------------------------------------
echo "Codex uses Chopi as its external sandbox"
# ---------------------------------------------------------------------------
out="$(chopi_codex exec --json 2>/dev/null)"
assert_eq "$out" $'--sandbox\ndanger-full-access\nexec\n--json' \
    "Codex disables its nested sandbox before its subcommand"


# ---------------------------------------------------------------------------
echo "chopi's addition to claude's system prompt"
# ---------------------------------------------------------------------------
# The claude shim reads --append-system-prompt-file into CHOPI_ITEST_PROMPT.
# shellcheck disable=SC2016 # the variable expands in the sandboxed shell, not here
probe_prompt='printf %s "${CHOPI_ITEST_PROMPT:-NO_PROMPT}"'
out="$(chopi_claude -c "$probe_prompt" 2>/dev/null)"
assert_eq "$out" "$(cat "$CHOPI_CLAUDE_PROMPT_FILE")" "claude's system prompt carries chopi's sandbox document"

out="$(chopi_t /bin/sh -c "$probe_prompt" 2>/dev/null)"
assert_eq "$out" "NO_PROMPT"                       "  -> and only for claude: no other command gets it"

out="$(chopi_claude -c "cat '$CHOPI_CLAUDE_PROMPT_FILE' && echo READ_OK || echo READ_FAIL" 2>/dev/null)"
assert_not_contains "$out" "Denials are configuration" "the document's own path stays unreadable in-sandbox"
assert_contains     "$out" "READ_FAIL"             "  -> and that read fails"


# ---------------------------------------------------------------------------
echo "Claude context files in parent dirs of the workspace"
# ---------------------------------------------------------------------------
printf 'PARENT_CLAUDE_MARKER\n' > "$base/CLAUDE.md"
printf 'PARENT_NOTES_MARKER\n'  > "$base/NOTES.md"

out="$(chopi_claude -c "cat '$base/CLAUDE.md' && echo READ_OK || echo READ_FAIL" 2>/dev/null)"
assert_contains "$out" "PARENT_CLAUDE_MARKER"      "a CLAUDE.md in a parent dir of the workspace is readable"
assert_contains "$out" "READ_OK"                   "  -> and the read succeeds"

out="$(chopi_claude -c "cat '$base/NOTES.md' && echo READ_OK || echo READ_FAIL" 2>/dev/null)"
assert_not_contains "$out" "PARENT_NOTES_MARKER"   "a non-CLAUDE.md file in the same parent dir stays denied (the hole is narrow)"
assert_contains     "$out" "READ_FAIL"             "  -> and that read fails"

mkdir -p "$base/.claude"
printf 'PARENT_DOTCLAUDE_MARKER\n' > "$base/.claude/CLAUDE.md"
out="$(chopi_claude -c "cat '$base/.claude/CLAUDE.md' && echo READ_OK || echo READ_FAIL" 2>/dev/null)"
assert_contains "$out" "PARENT_DOTCLAUDE_MARKER"   "a .claude/CLAUDE.md in a parent dir of the workspace is readable"
assert_contains "$out" "READ_OK"                   "  -> and the read succeeds"

# A second workspace whose ancestor's .claude is a symlink to a shared dir: the target is
# NOT auto-granted, so the run refuses until the user grants it -- then reads work through
# the link.
mkdir -p "$base/shared-claude" "$base/dev/ws2"
make_repo "$base/dev/ws2"
printf 'SHARED_DOTCLAUDE_MARKER\n' > "$base/shared-claude/CLAUDE.md"
ln -s "$base/shared-claude" "$base/dev/.claude"
both="$(chopi_claude_in "$base/dev/ws2" "$cfg" -c 'echo RAN' 2>&1)"; rc=$?
assert_nonzero      "$rc"                                    "chopi refuses while a symlinked ancestor .claude target is unreadable"
assert_contains     "$both" "$base/shared-claude/CLAUDE.md  (via the symlink at $base/dev/.claude)" "  -> naming the resolved target and the link it came from"
assert_not_contains "$both" "RAN"                            "  -> and does not run the command"

cfg_shared="$base/config/sandbox-shared-claude.sh"
cat > "$cfg_shared" <<EOF
CHOPI_SAFEHOUSE_FLAGS=( --add-dirs-ro "$base/shared-claude:$claudebin" )
CHOPI_EXTRA_ENV=( PATH=/usr/bin:/bin:/usr/sbin:/sbin )
EOF
out="$(chopi_claude_in "$base/dev/ws2" "$cfg_shared" -c "cat '$base/dev/.claude/CLAUDE.md' && echo READ_OK || echo READ_FAIL" 2>/dev/null)"
assert_contains "$out" "SHARED_DOTCLAUDE_MARKER"   "with the target granted, the CLAUDE.md behind the link is readable"
assert_contains "$out" "READ_OK"                   "  -> and the read succeeds"


# ---------------------------------------------------------------------------
echo "an unreadable CLAUDE.md @-import refuses the run until the user grants the read"
# ---------------------------------------------------------------------------
# The chain here is nested -- CLAUDE.md imports a symlinked file whose target imports
# another -- and an unreadable file cannot be followed, so the denials surface one grant
# at a time.
mkdir -p "$base/imports" "$base/import-target" "$base/import-nested"
printf 'NESTED_IMPORT_MARKER\n' > "$base/import-nested/deep.md"
printf 'LINKED_IMPORT_MARKER\n@%s/import-nested/deep.md\n' "$base" > "$base/import-target/actual.md"
ln -s "$base/import-target/actual.md" "$base/imports/linked-import.md"
printf 'PARENT_CLAUDE_MARKER\n@imports/linked-import.md\n' > "$base/CLAUDE.md"

both="$(chopi_claude -c 'echo RAN' 2>&1)"; rc=$?
assert_nonzero      "$rc"                                    "chopi refuses to run while an ancestor CLAUDE.md @-import is unreadable"
assert_contains     "$both" "$base/imports/linked-import.md" "  -> listing the unreadable import"
assert_contains     "$both" "(imported by $base/CLAUDE.md)"  "  -> and its importer"
assert_contains     "$both" "CHOPI_SAFEHOUSE_FLAGS"          "  -> directing to CHOPI_SAFEHOUSE_FLAGS"
assert_contains     "$both" "--add-dirs-ro"                  "  -> with an example --add-dirs-ro grant"
assert_not_contains "$both" "deep.md"                        "  -> the nested import is NOT listed (unreachable until the outer grant)"
assert_not_contains "$both" "RAN"                            "  -> and does not run the command"

# Granting the outer import -- the link's dir AND the target's, since Seatbelt checks both
# the traversed link node and the kernel-resolved file -- lets the check follow it, which
# surfaces its own nested import.
cfg_imports="$base/config/sandbox-imports.sh"
cat > "$cfg_imports" <<EOF
CHOPI_SAFEHOUSE_FLAGS=( --add-dirs-ro "$base/imports:$base/import-target:$claudebin" )
CHOPI_EXTRA_ENV=( PATH=/usr/bin:/bin:/usr/sbin:/sbin )
EOF
both="$(chopi_claude_in "$ws" "$cfg_imports" -c 'echo RAN' 2>&1)"; rc=$?
assert_nonzero      "$rc"                                     "chopi still refuses: the now-followable import reveals its nested import"
assert_contains     "$both" "$base/import-nested/deep.md"     "  -> listing the nested import"
assert_not_contains "$both" "(imported by $base/CLAUDE.md)"   "  -> the outer, now-readable import is no longer listed"
assert_not_contains "$both" "RAN"                             "  -> and does not run the command"

# With the whole chain granted, the run proceeds.
cfg_imports_all="$base/config/sandbox-imports-all.sh"
cat > "$cfg_imports_all" <<EOF
CHOPI_SAFEHOUSE_FLAGS=( --add-dirs-ro "$base/imports:$base/import-target:$base/import-nested:$claudebin" )
CHOPI_EXTRA_ENV=( PATH=/usr/bin:/bin:/usr/sbin:/sbin )
EOF
out="$(chopi_claude_in "$ws" "$cfg_imports_all" -c "cat '$base/imports/linked-import.md' '$base/import-nested/deep.md' && echo READ_OK || echo READ_FAIL" 2>/dev/null)"
assert_contains "$out" "LINKED_IMPORT_MARKER"      "with the full chain granted the run proceeds"
assert_contains "$out" "NESTED_IMPORT_MARKER"      "  -> the nested import is readable too"
assert_contains "$out" "READ_OK"                   "  -> reads succeed at the as-written paths (how the agent opens them)"

# Undo changes to CLAUDE.md for the following tests
printf 'PARENT_CLAUDE_MARKER\n' > "$base/CLAUDE.md"


# ---------------------------------------------------------------------------
echo "Claude-context handling applies only to claude"
# ---------------------------------------------------------------------------
# The ancestor read grants and the in-sandbox refusal gate exist for Claude Code alone:
# no other command reads context files, so none gets the ancestor read hole opened for
# it, and none may be refused over context it will never load.
out="$(chopi_t /bin/sh -c "cat '$base/CLAUDE.md' && echo READ_OK || echo READ_FAIL" 2>/dev/null)"
assert_contains     "$out" "READ_FAIL"            "an ancestor CLAUDE.md is NOT readable by a non-claude command"
assert_not_contains "$out" "PARENT_CLAUDE_MARKER" "  -> and no content leaks"

# shellcheck disable=SC2016  # $TMPDIR expands in the sandboxed shell, not here
out="$(chopi_t /bin/sh -c 'ls "$TMPDIR"' 2>/dev/null)"
assert_not_contains "$out" "$CHOPI_CLAUDE_CONTEXT_READS_PREFIX" "no context-reads profile is even built for a non-claude run"
# shellcheck disable=SC2016  # $TMPDIR expands in the sandboxed shell, not here
out="$(chopi_claude -c 'ls "$TMPDIR"' 2>/dev/null)"
assert_contains     "$out" "$CHOPI_CLAUDE_CONTEXT_READS_PREFIX" "  -> while a claude run gets one"

printf 'PARENT_CLAUDE_MARKER\n@imports/linked-import.md\n' > "$base/CLAUDE.md"
out="$(chopi_t /bin/sh -c 'echo RAN' 2>/dev/null)"; rc=$?
assert_zero     "$rc"        "a non-claude command runs despite an unreadable ancestor @-import"
assert_contains "$out" "RAN" "  -> the command itself runs"
printf 'PARENT_CLAUDE_MARKER\n' > "$base/CLAUDE.md"


# ---------------------------------------------------------------------------
echo "private per-invocation temp dir"
# ---------------------------------------------------------------------------
# chopi exports a freshly-made TMPDIR for each run (safehouse forwards it into the
# sandbox). ALL of chopi's own temporaries (in-sandbox wrapper profiles, isolation and
# hardening profiles, the command's tempfiles) live inside it, so the dir being gone after
# the run IS the cleanup check for every one of them -- the later sections don't re-assert it.
# shellcheck disable=SC2016  # $TMPDIR expands in the sandboxed shell, not here
out="$(chopi_t /bin/sh -c 'echo "SBX_TMPDIR=$TMPDIR"; ls "$TMPDIR"; echo probe > "$TMPDIR/probe.txt" && echo WRITE_OK' 2>/dev/null)"
sbx_tmpdir="$(printf '%s\n' "$out" | sed -n 's/^SBX_TMPDIR=//p')"
case "$sbx_tmpdir" in
    "$TMPDIR"*chopi.*) ok "the sandboxed TMPDIR is a chopi-private dir under the invoking temp dir" ;;
    *) bad "the sandboxed TMPDIR should be a chopi-private dir under '$TMPDIR' (got '$sbx_tmpdir')" ;;
esac
assert_contains "$out" "WRITE_OK"                  "  -> and the sandboxed command can write in it"

# This run's artifacts show up in the in-sandbox listing of $TMPDIR -- the dir is fresh
# and private to the invocation, so their presence pins them as subpaths of it. Guards the
# containment assumption the one-shot cleanup below relies on.
assert_contains "$out" "$CHOPI_IN_SANDBOX_WRAPPER_PREFIX" "the in-sandbox wrapper profile lives inside the invocation temp dir"

if [ -n "$sbx_tmpdir" ] && [ ! -e "$sbx_tmpdir" ]; then
    ok  "chopi removes the entire invocation temp dir (all temporaries with it) after the run"
else
    bad "chopi should remove the invocation temp dir ('$sbx_tmpdir') after the run"
fi


# ---------------------------------------------------------------------------
echo "chopi refuses to run outside a git worktree root"
# ---------------------------------------------------------------------------
plain_dir="$base/plain"
mkdir -p "$plain_dir"
both="$( ( cd "$plain_dir" && "$repo/bin/chopi" --config "$cfg" -- /bin/sh -c 'echo RAN' ) 2>&1 )"; rc=$?
assert_nonzero      "$rc"                                      "chopi refuses to run in a non-git dir"
assert_contains     "$both" "not the root of a git worktree"   "  -> naming the cause"
assert_not_contains "$both" "RAN"                              "  -> and does not run the command"

ws_subdir="$ws/subdir"
mkdir -p "$ws_subdir"
both="$( ( cd "$ws_subdir" && "$repo/bin/chopi" --config "$cfg" -- /bin/sh -c 'echo RAN' ) 2>&1 )"; rc=$?
assert_nonzero      "$rc"                                      "chopi refuses to run in a subdir of a worktree"
assert_has_line     "$both" "$(realpath "$ws")"                "  -> pointing at the enclosing worktree root"
assert_not_contains "$both" "RAN"                              "  -> and does not run the command"


# ---------------------------------------------------------------------------
echo "in-sandbox wrapper at a git worktree root (injection + command-name detection)"
# ---------------------------------------------------------------------------
wrap_repo="$base/wrap_repo"
make_repo "$wrap_repo"

# "claude" below stands in for the real agent. Both the fake agent and the sh probe
# below run the same body: cat the file named by $1, reporting READ_OK/READ_FAIL.
# shellcheck disable=SC2016 # $1 expands in the sandboxed shell, not here
read_probe='cat "$1" 2>/dev/null && echo READ_OK || echo READ_FAIL'
agentbin="$wrap_repo/agentbin"
mkdir -p "$agentbin"
cat > "$agentbin/claude" <<EOF
#!/bin/sh
[ "\$1" = --append-system-prompt-file ] && shift 2   # chopi's own, ahead of the args below
$read_probe
EOF
chmod +x "$agentbin/claude"

cfg_agent="$base/config/sandbox-agent.sh"
cat > "$cfg_agent" <<EOF
CHOPI_SAFEHOUSE_FLAGS=()
CHOPI_EXTRA_ENV=( PATH=$agentbin:/usr/bin:/bin:/usr/sbin:/sbin )
CHOPI_GIT_CONFIG=( chopi.wrapped=wrappedmarker )
EOF
chopi_wrap() { ( cd "$wrap_repo" && "$repo/bin/chopi" --config "$cfg_agent" -- "$@" ); }

# shellcheck disable=SC2016
out="$(chopi_wrap /bin/sh -c 'echo "$GIT_CONFIG_KEY_0=$GIT_CONFIG_VALUE_0"; git ls-remote --get-url https://github.com/o/r; ls "$TMPDIR"' 2>/dev/null)"
assert_contains "$out" "chopi.wrapped=wrappedmarker"   "a CHOPI_GIT_CONFIG pair reaches the sandboxed command at a worktree root"
assert_contains "$out" "http://127.0.0.1:$GITHUB_RELAY_PORT/o/r"   "  -> and github.com git reroutes to the relay in the sandbox"
assert_contains "$out" "$CHOPI_IN_SANDBOX_WRAPPER_PREFIX"  "  -> the in-sandbox wrapper profile is created for the run"
assert_contains "$out" "$CHOPI_CMD_ALIAS_PREFIX"            "  -> as is the command-alias dir"

# The wrapper profile opens the wrapper, the cleanup script, and the libs they source
# (CHOPI_IN_SANDBOX_LIBS) for reading only, and nothing else in chopi's dir.
for f in in-sandbox-wrapper.sh git-protect-cleanup.sh "${CHOPI_IN_SANDBOX_LIBS[@]}"; do
    out="$(chopi_wrap /bin/sh -c "cat '$repo/.internal/$f' >/dev/null 2>&1 && echo READ_OK || echo READ_FAIL; echo x >> '$repo/.internal/$f' 2>/dev/null && echo WRITE_OK || echo WRITE_FAIL" 2>/dev/null)"
    assert_contains     "$out" "READ_OK"   "  -> the in-sandbox wrapper opens $f"
    assert_not_contains "$out" "WRITE_OK"  "  -> and only for reading: $f is not writable"
done
out="$(chopi_wrap /bin/sh -c "cat '$repo/.internal/preflight.sh' >/dev/null 2>&1 && echo READ_OK || echo READ_FAIL" 2>/dev/null)"
assert_eq "$out" "READ_FAIL"                            "  -> but not the rest of chopi's dir"

err="$(chopi_wrap /bin/sh -c 'true' 2>&1 >/dev/null)"
assert_eq "$err" ""                                     "a no-op run leaves stderr empty"

# safehouse appends profiles based on the invoked command's BASENAME. chopi runs the
# sandboxed command through the in-sandbox wrapper (which is argv[0]), so it must present the
# wrapper under the real command's basename to get the needed grants. Test via safehouse's
# `claude` profile, the only one which grants read on ~/.claude.json.*.
marker_file="$HOME/.claude.json.chopi-itest"
printf 'CLAUDE_PROFILE_MARKER\n' > "$marker_file"

out="$(chopi_wrap claude "$marker_file" 2>/dev/null)"
assert_contains "$out" "CLAUDE_PROFILE_MARKER"     "a command's agent profile is selected through the wrapper (real basename reaches safehouse)"
assert_contains "$out" "READ_OK"                   "  -> and the profile's ~/.claude.json.* read grant actually applies in the sandbox"

out="$(chopi_wrap /bin/sh -c "$read_probe" sh "$marker_file" 2>/dev/null)"
assert_not_contains "$out" "CLAUDE_PROFILE_MARKER" "a non-agent basename (sh) selects no profile, so the same file stays unreadable"
assert_contains     "$out" "READ_FAIL"             "  -> and that read is denied"


# ---------------------------------------------------------------------------
echo "chopi refuses when a competing insteadOf would override the GitHub relay routing"
# ---------------------------------------------------------------------------
conflict_repo="$base/conflict_repo"
make_repo "$conflict_repo"
# A local https->ssh rewrite of the same prefix wins the longest-prefix tie against chopi's
# command-scope rewrite, so github git would leave the relay -- the in-sandbox wrapper must
# refuse before running the command.
git -C "$conflict_repo" config url."git@github.com:".insteadOf https://github.com/
both="$( ( cd "$conflict_repo" && "$repo/bin/chopi" --config "$cfg" -- /bin/sh -c 'echo RAN' ) 2>&1 )"; rc=$?
assert_nonzero  "$rc"                                            "chopi refuses at a worktree root when a competing insteadOf overrides the relay routing"
assert_contains "$both" "overrides chopi's GitHub relay routing" "  -> with an informative error naming the cause"
assert_not_contains "$both" "RAN"                                "  -> and does not run the command"


# ---------------------------------------------------------------------------
echo "network confinement"
# ---------------------------------------------------------------------------
# (1) Allowed host THROUGH the proxy -> 200. Needs real connectivity, so gate it on a
# host-side precheck and SKIP (not fail) when offline.
if curl -sS -o /dev/null --max-time 10 "https://$ALLOWED_HOST" 2>/dev/null; then
    code="$(sandbox_curl --max-time 20 "https://$ALLOWED_HOST")"
    assert_eq "$code" "200"                        "allowed host is reachable THROUGH the proxy"
else
    echo "  SKIP allowed-host reachability (no connectivity to $ALLOWED_HOST)"
fi

# (2) Denied host THROUGH the proxy -> refused (smokescreen denies on the rules before
# dialing, so this works offline). Refused == not 200, plus a logged DENY, plus the
# notification path firing (the recording alerter stub).
code="$(sandbox_curl --max-time 20 "https://$DENIED_HOST")"
assert_not_contains "$code" "200"                  "a host not allowed in the rules is refused by the proxy"
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

# (4) Outgoing connections are pinned to the allowed proxy ports SPECIFICALLY: a loopback port
# that network.sb does not allow (it allows 4760-4761) is blocked by Seatbelt. Offline-safe.
code="$(sandbox_curl --max-time 15 --proxy "http://127.0.0.1:9999" "https://$ALLOWED_HOST")"
assert_not_contains "$code" "200"                  "an outgoing connection to a non-allowlisted loopback port is blocked by the sandbox"

# (5) gh's relay plumbing, end-to-end: chopi writes the http_unix_socket config, exports the gh
# env, and opens the socket's Seatbelt hole -- and the real gh consumes all of it from inside
# the sandbox. GraphQL is denied by the relay itself, so this stays offline-safe: Caddy answers
# the 403 locally, and gh displays the JSON deny message.
[ -S "$GH_RELAY_SOCK" ] || bad "the GitHub API relay socket file is missing on the host: $GH_RELAY_SOCK"
# The config's in-sandbox PATH is system-only, so gh (a homebrew tool) must be invoked by
# absolute path, like the other in-sandbox commands; the profile allows reading+exec under /opt.
gh_bin="$(command -v gh)"
api_deny="$(chopi_t "$gh_bin" api graphql -f query='{viewer{login}}' 2>&1)"; rc=$?
assert_nonzero  "$rc"       "in-sandbox gh api graphql is refused"
assert_contains "$api_deny" 'not an allowed API operation' "  -> gh reached the relay through its socket and displays the deny"
assert_contains "$api_deny" 'HTTP 403'                     "  -> as the relay's own 403"

# (6) Conversely, chopi refuses upfront when no relay socket is present at the path it derives from
# TMPDIR.
no_sock_tmp="$(mktemp -d "$base/chopi-no-sock.XXXXXX")"
refuse_out="$(TMPDIR="$no_sock_tmp" chopi_t /bin/sh -c 'echo RAN' 2>&1)"; rc=$?
assert_nonzero     "$rc"         "chopi refuses when the GitHub API relay socket is absent"
assert_contains    "$refuse_out" "no GitHub API relay listening at $no_sock_tmp/chopi-gh-relay.sock" \
    "  -> the refusal names the missing relay socket"
assert_not_contains "$refuse_out" "RAN"                "  -> the sandboxed command never runs"


# ---------------------------------------------------------------------------
echo "github git public fetch through the relay (end-to-end: sandbox -> :$GITHUB_RELAY_PORT -> Caddy -> github.com)"
# ---------------------------------------------------------------------------
if ! curl -sS -o /dev/null --max-time 15 "https://github.com" 2>/dev/null; then
    echo "  SKIP github-through-relay (no host connectivity to github.com)"
else

    relay_repo="$base/relay_repo"
    make_repo "$relay_repo"
    chopi_relay() { ( cd "$relay_repo" && "$repo/bin/chopi" --config "$cfg" -- "$@" ); }

    # A real ls-remote drives GET .../info/refs through the relay to github and streams the refs back.
    refs="$(chopi_relay git ls-remote https://github.com/octocat/Hello-World 2>/dev/null)"
    assert_contains "$refs" "refs/heads/master" "anonymous public fetch of a github repo works through the relay"

    code="$(chopi_relay /usr/bin/curl -sS -o /dev/null -w '%{http_code}' --max-time 15 --noproxy '*' "https://github.com" 2>/dev/null)"
    assert_not_contains "$code" "200"           "a direct (non-relay) connection to github is blocked by the sandbox"
fi


# ---------------------------------------------------------------------------
echo "rules hot reload (edits take effect without restarting the proxy)"
# ---------------------------------------------------------------------------
# The proxy polls the rules file and swaps freshly loaded rules.
# (1) Allowing the denied host must lift its denial with no proxy restart; the log
# confirms the reload happened.
printf '    - %s\n' "$DENIED_HOST" >> "$rules"
if wait_for "$proxy_log" "rules reloaded"; then
    ok "the proxy reloaded the rules after the file changed"
else
    bad "the proxy did NOT log a rules reload after the file changed"
fi
if curl -sS -o /dev/null --max-time 10 "https://$DENIED_HOST" 2>/dev/null; then
    code="$(sandbox_curl_connect --max-time 20 "https://$DENIED_HOST")"
    assert_eq "$code" "200"                        "the previously denied host is now allowed through the proxy"
else
    echo "  SKIP hot-reloaded host reachability (no connectivity to $DENIED_HOST)"
fi

# (2) A broken edit is refused loudly and the previous rules stay in effect: hosts not
# on the allowlist stay refused.
printf 'all rules have been broken\n' > "$rules"
if wait_for "$proxy_log" "RULES RELOAD FAILED"; then
    ok "a broken rules edit is logged loudly as a failed reload"
else
    bad "a broken rules edit did NOT log a failed reload"
fi
code="$(sandbox_curl --max-time 20 "https://$OTHER_DENIED_HOST")"
assert_not_contains "$code" "200"                  "after a failed reload the previous rules still refuse other hosts"
# ...and the host the last good edit ALLOWED stays allowed.
if curl -sS -o /dev/null --max-time 10 "https://$DENIED_HOST" 2>/dev/null; then
    code="$(sandbox_curl_connect --max-time 20 "https://$DENIED_HOST")"
    assert_eq "$code" "200"                        "after a failed reload the previously allowed host stays allowed"
else
    echo "  SKIP still-allowed host reachability (no connectivity to $DENIED_HOST)"
fi

# (3) Fixing the file reloads again.
write_test_rules
if wait_for_count "$proxy_log" "rules reloaded" 2; then
    ok "the proxy reloaded again once the rules were fixed"
else
    bad "the proxy did NOT reload after the rules were fixed"
fi
code="$(sandbox_curl --max-time 20 "https://$DENIED_HOST")"
assert_not_contains "$code" "200"                  "the restored rules refuse the host again"


# ---------------------------------------------------------------------------
echo "git worktree isolation"
# ---------------------------------------------------------------------------
gitrepo="$base/gitrepo"
cfg_git="$base/config/sandbox-git.sh"
make_repo "$gitrepo"
gitrepo_real="$(realpath "$gitrepo")"
shared_git="$gitrepo_real/.git"
submod="$gitrepo_real/submod"
submod_dotgit="$submod/.git"
root_only="$gitrepo_real/root-only.txt"

printf 'ROOT_ONLY_MARKER\n' > "$root_only"
git -C "$gitrepo" add root-only.txt
git -C "$gitrepo" commit -q -m root-marker

# Default sandbox config comes from sourcing the shipped template,
# so the suite tracks it; the grants and env are re-minimized like the main $cfg's.
cat > "$cfg_git" <<EOF
. '$repo/config/templates/sandbox.template.sh'
CHOPI_SAFEHOUSE_FLAGS=()
CHOPI_EXTRA_ENV=( PATH=/usr/bin:/bin:/usr/sbin:/sbin )
EOF

nested_wt="$gitrepo_real/.worktrees/nested_wt"
nested_wt_admin="$shared_git/worktrees/nested_wt"
external_wt="$base/external_wt"
git -C "$gitrepo" worktree add -q -b sib_wt "$nested_wt"
printf 'NESTED_ONLY_MARKER\n' > "$nested_wt/nested.txt"
git -C "$gitrepo" worktree add -q -b external_wt "$external_wt"
printf 'EXTERNAL_ONLY_MARKER\n' > "$external_wt/ext.txt"

chopi_main() { ( cd "$gitrepo" && "$repo/bin/chopi" --config "$cfg_git" -- "$@" ); }

workdir="$(chopi_main /bin/sh -c 'pwd' 2>/dev/null)"
assert_eq "$workdir" "$gitrepo_real"                    "the command runs with the repo root as its workdir"

# Verify isolation
out="$(chopi_main /bin/sh -c "cat '$nested_wt/nested.txt' && echo READ_OK || echo READ_FAIL" 2>/dev/null)"
assert_not_contains "$out" "NESTED_ONLY_MARKER"   "a nested sibling worktree's files are NOT readable"
assert_contains     "$out" "READ_FAIL"             "  -> and that read fails"
chopi_main /bin/sh -c "echo x > '$nested_wt/evil.txt'" >/dev/null 2>&1
assert_absent "$nested_wt/evil.txt" "a write into a nested sibling worktree is denied (no file created)"
out="$(chopi_main /bin/sh -c "cat '$external_wt/ext.txt' && echo READ_OK || echo READ_FAIL" 2>/dev/null)"
assert_not_contains "$out" "EXTERNAL_ONLY_MARKER"  "an external worktree's files are NOT readable (safehouse's read grant is undone)"
assert_contains     "$out" "READ_FAIL"             "  -> and that read fails"

# git keeps working in the isolated worktree
out="$(chopi_main /bin/sh -c 'echo CHG > ./main-commit.txt && git add main-commit.txt && git commit -q -m maincommit && echo COMMIT_OK' 2>/dev/null)"
assert_contains "$out" "COMMIT_OK"                 "a commit in the main worktree succeeds"
# A PARTIAL (pathspec-limited) commit builds its temp index at .git/next-index-<pid>,
# not index.lock -- a separate write hole that is easy to miss.
out="$(chopi_main /bin/sh -c 'echo one > ./partial.txt && git add partial.txt && git commit -q -m addpartial && echo two >> ./partial.txt && git commit -q -m partial -- partial.txt && echo PARTIAL_OK' 2>/dev/null)"
assert_contains "$out" "PARTIAL_OK"                "a pathspec-limited commit succeeds (the next-index temp-index hole)"
out="$(chopi_main /bin/sh -c 'git tag chopi-main-probe && echo TAG_OK' 2>/dev/null)"
assert_contains "$out" "TAG_OK"                    "a ref write succeeds"
out="$(chopi_main /bin/sh -c 'echo dirty >> ./main-commit.txt && git stash push -q -m t && git stash pop -q && echo STASH_OK' 2>/dev/null)"
assert_contains "$out" "STASH_OK"                  "git stash push/pop succeed"


# ---------------------------------------------------------------------------
echo "git internals hardening"
# ---------------------------------------------------------------------------
for var in "${allow_git_file_protocol[@]}"; do export "${var?}"; done

# A path submodule, to prove submodule work survives the .git write-allowlist (file-protocol
# allowed via the GIT_CONFIG_* env exported above). It carries its OWN submodule, so the
# repo gets a NESTED chain (gitrepo -> submod -> nested): the protections must lock down
# BOTH levels, and in-sandbox submodule work must still succeed at BOTH.
nested_src="$base/nested-src"
make_repo "$nested_src"
printf 'NESTED_MARKER\n' > "$nested_src/nested.txt"
git -C "$nested_src" add nested.txt
git -C "$nested_src" commit -q -m nested

submod_src="$base/submod-src"
make_repo "$submod_src"
printf 'SUBMODULE_MARKER\n' > "$submod_src/sub.txt"
git -C "$submod_src" add sub.txt
git -C "$submod_src" submodule add -q "$nested_src" nested
git -C "$submod_src" commit -q -m 'sub + nested submodule'
git -C "$gitrepo" submodule add -q "$submod_src" submod
git -C "$gitrepo" commit -q -m 'add submodule'

# Verify git is functional under hardening
git -C "$gitrepo" checkout -q -- .
mainbr="$(git -C "$gitrepo" symbolic-ref --short HEAD)"
git -C "$gitrepo" checkout -q -b mainpick
printf 'mp1\n' > "$gitrepo/mp1.txt"; git -C "$gitrepo" add mp1.txt; git -C "$gitrepo" commit -q -m mp1
printf 'mp2\n' > "$gitrepo/mp2.txt"; git -C "$gitrepo" add mp2.txt; git -C "$gitrepo" commit -q -m mp2
mpick1="$(git -C "$gitrepo" rev-parse HEAD~1)"
mpick2="$(git -C "$gitrepo" rev-parse HEAD)"
git -C "$gitrepo" checkout -q "$mainbr"
out="$(chopi_main /bin/sh -c "git cherry-pick $mpick1 $mpick2 && echo PICK_OK" 2>/dev/null)"
assert_contains "$out" "PICK_OK"                   "a multi-commit cherry-pick succeeds in the main worktree (sequencer + CHERRY_PICK_HEAD)"
out="$(chopi_main /bin/sh -c 'git rebase -f HEAD~2 && echo REBASE_OK' 2>/dev/null)"
assert_contains "$out" "REBASE_OK"                 "a rebase succeeds (merge backend: ORIG_HEAD/REBASE_HEAD + rebase-merge/)"
out="$(chopi_main /bin/sh -c 'git rebase --apply -f HEAD~2 && echo APPLY_OK' 2>/dev/null)"
assert_contains "$out" "APPLY_OK"                  "  -> and with --apply (rebase-apply/ + the rebased-patches spool)"

# Sparse-checkout works end to end, info/attributes and info/exclude beside it stay denied.
sparse_checkout="$shared_git/info/sparse-checkout"
git -C "$gitrepo" config core.sparseCheckout true
out="$(chopi_main /bin/sh -c "printf '/*\n!/mp1.txt\n' > '$sparse_checkout' && git sparse-checkout reapply && test ! -f mp1.txt && echo SPARSE_OK" 2>/dev/null)"
assert_contains "$out" "SPARSE_OK"                 "a sparse checkout works via the writable sparse-checkout file in the shared info/"
assert_absent "$gitrepo_real/mp1.txt" "  -> the excluded file is really pruned from the main worktree"
out="$(chopi_main /bin/sh -c "printf '/*\n' > '$sparse_checkout' && git sparse-checkout reapply && test -f mp1.txt && rm '$sparse_checkout' && echo RESTORE_OK" 2>/dev/null)"
assert_contains "$out" "RESTORE_OK"                "  -> widening the patterns restores it, and the file is removable"
git -C "$gitrepo" config --unset core.sparseCheckout
chopi_main /bin/sh -c "echo '* filter=evil' > '$shared_git/info/attributes'" >/dev/null 2>&1
assert_absent "$shared_git/info/attributes" "writing the shared .git/info/attributes is denied (no file created)"

# Verify exec surface is set to read-only
config_before="$(cat "$shared_git/config")"
chopi_main /bin/sh -c "echo pwn > '$shared_git/hooks/post-commit'" >/dev/null 2>&1
assert_absent "$shared_git/hooks/post-commit" "planting a hook in the shared .git/hooks is denied (no file created)"
chopi_main git config core.hooksPath /tmp/evil >/dev/null 2>&1
assert_eq "$(cat "$shared_git/config")" "$config_before" \
                                                   "the shared .git/config cannot be written from the sandbox"

# A submodule in the main tree: its gitdir (.git/modules/...) keeps its data holes, so
# in-sandbox submodule commits work, while its exec surface stays read-only.
out="$(chopi_main /bin/sh -c 'cd submod && echo more >> sub.txt && git add sub.txt && git commit -q -m mainsub && echo SUBCOMMIT_OK' 2>/dev/null)"
assert_contains "$out" "SUBCOMMIT_OK"              "a commit inside the main tree's submodule succeeds"
main_sub_gitdir="$(realpath "$(git -C "$submod" rev-parse --absolute-git-dir)")"
main_sub_dotgit_before="$(cat "$submod_dotgit")"
chopi_main /bin/sh -c "echo 'gitdir: /tmp/evil' > '$submod_dotgit'" >/dev/null 2>&1
chopi_main /bin/sh -c "echo pwn > '$main_sub_gitdir/hooks/post-checkout'"          >/dev/null 2>&1
assert_eq "$(cat "$submod_dotgit")" "$main_sub_dotgit_before" \
                                                   "the submodule's .git pointer file cannot be rewritten from the sandbox"
assert_absent "$main_sub_gitdir/hooks/post-checkout" "planting a hook in the submodule's gitdir is denied (no file created)"

# A sibling worktree's admin dir stays unwritable (only holes for the MAIN checkout
# state were poked).
chopi_main /bin/sh -c "echo x > '$nested_wt_admin/config.worktree'" >/dev/null 2>&1
if [ -s "$nested_wt_admin/config.worktree" ]; then
    bad "writing a sibling worktree's admin dir is denied (file must stay empty/absent)"
else
    ok  "writing a sibling worktree's admin dir is denied"
fi


# -----------------------------------------------------------------------
echo "git protections (submodule root)"
# -----------------------------------------------------------------------
# Run chopi from INSIDE the superproject's submodule: the submodule root is the main
# worktree of its own repo, whose shared git dir (.git/modules/submod) lives OUTSIDE
# the workspace -- chopi allows it, git must work against it, its exec surface stays
# read-only, and the superproject stays out of reach. The nested submodule is initialized
# first (unsandboxed) so the one-level-down checks below have a populated chain.
git -C "$submod" submodule update --init --recursive >/dev/null 2>&1
chopi_sub() { ( cd "$submod" && "$repo/bin/chopi" --config "$cfg_git" -- "$@" ); }
sub_main_gitdir="$(realpath "$(git -C "$submod" rev-parse --absolute-git-dir)")"

top="$(chopi_sub git rev-parse --show-toplevel 2>/dev/null)"
assert_eq "$top" "$submod"                         "git resolves the submodule root as its toplevel (module gitdir readable)"

out="$(chopi_sub /bin/sh -c 'echo CHG > ./subroot.txt && git add subroot.txt && git commit -q -m subroot && echo COMMIT_OK' 2>/dev/null)"
assert_contains "$out" "COMMIT_OK"                 "a commit at the submodule root succeeds (module gitdir data paths writable)"

# The superproject's working tree and its own .git internals are not granted; only
# the module gitdir subtree is.
out="$(chopi_sub /bin/sh -c "cat '$root_only' && echo READ_OK || echo READ_FAIL" 2>/dev/null)"
assert_not_contains "$out" "ROOT_ONLY_MARKER"      "the superproject's working files are NOT readable"
assert_contains     "$out" "READ_FAIL"             "  -> and that read fails"
out="$(chopi_sub /bin/sh -c "cat '$shared_git/config' >/dev/null 2>&1 && echo READ_OK || echo READ_FAIL" 2>/dev/null)"
assert_contains     "$out" "READ_FAIL"             "the superproject's .git/config is NOT readable"
chopi_sub /bin/sh -c "echo x > '$gitrepo_real/super-evil.txt'" >/dev/null 2>&1
assert_absent "$gitrepo_real/super-evil.txt" "a write into the superproject's tree is denied (no file created)"

# The submodule's own exec surface: its .git pointer file, the module config, the
# module hooks/ -- all repointable-into-unsandboxed-execution, all read-only.
sub_dotgit_before="$(cat "$submod_dotgit")"
sub_cfg_before="$(cat "$sub_main_gitdir/config")"
chopi_sub /bin/sh -c "echo 'gitdir: /tmp/evil' > '$submod_dotgit'" >/dev/null 2>&1
chopi_sub git config core.hooksPath /tmp/evil >/dev/null 2>&1
chopi_sub /bin/sh -c "echo pwn > '$sub_main_gitdir/hooks/post-commit'" >/dev/null 2>&1
assert_eq "$(cat "$submod_dotgit")" "$sub_dotgit_before" \
                                                   "the submodule's .git pointer file cannot be rewritten from the sandbox"
assert_eq "$(cat "$sub_main_gitdir/config")" "$sub_cfg_before" \
                                                   "the module config cannot be written (git config denied)"
assert_absent "$sub_main_gitdir/hooks/post-commit" "planting a hook in the module gitdir is denied (no file created)"

# One level down, the submodule's OWN submodule gets the usual treatment: data paths
# writable (a commit works), exec surface pinned.
out="$(chopi_sub /bin/sh -c 'cd nested && echo more >> nested.txt && git add nested.txt && git -c user.email=w@t.t -c user.name=w commit -q -m subnested && echo NESTEDCOMMIT_OK' 2>/dev/null)"
assert_contains "$out" "NESTEDCOMMIT_OK"           "a commit in the submodule's own nested submodule succeeds"
nested_gd="$(realpath "$(git -C "$submod/nested" rev-parse --absolute-git-dir)")"
chopi_sub /bin/sh -c "echo pwn > '$nested_gd/hooks/post-commit'" >/dev/null 2>&1
assert_absent "$nested_gd/hooks/post-commit" "planting a hook in the nested submodule's gitdir is denied (no file created)"


# -----------------------------------------------------------------------
echo "git protections (separate-git-dir root)"
# -----------------------------------------------------------------------
sgdrepo="$base/sgdrepo"; sgdgit="$base/sgdrepo-git"
make_repo "$sgdrepo" --separate-git-dir "$sgdgit"
sgdrepo_real="$(realpath "$sgdrepo")"
sgdgit_real="$(realpath "$sgdgit")"
sgd_dotgit="$sgdrepo_real/.git"
chopi_sgd() { ( cd "$sgdrepo" && "$repo/bin/chopi" --config "$cfg_git" -- "$@" ); }

out="$(chopi_sgd /bin/sh -c 'echo CHG > ./sgd.txt && git add sgd.txt && git commit -q -m sgd && echo COMMIT_OK' 2>/dev/null)"
assert_contains "$out" "COMMIT_OK"                 "a commit at a separate-git-dir root succeeds (detached gitdir writable on data paths)"

sgd_dotgit_before="$(cat "$sgd_dotgit")"
chopi_sgd /bin/sh -c "echo 'gitdir: /tmp/evil' > '$sgd_dotgit'" >/dev/null 2>&1
chopi_sgd /bin/sh -c "echo pwn > '$sgdgit_real/hooks/post-commit'" >/dev/null 2>&1
assert_eq "$(cat "$sgd_dotgit")" "$sgd_dotgit_before" \
                                                   "the root's .git pointer file cannot be rewritten from the sandbox"
assert_absent "$sgdgit_real/hooks/post-commit" "planting a hook in the detached gitdir is denied (no file created)"


# ---------------------------------------------------------------------------
echo "git protections (--worktree)"
# ---------------------------------------------------------------------------
nested_wt2="$gitrepo_real/.worktrees/nested_wt2"
nested_wt2_admin="$shared_git/worktrees/nested_wt2"
nested_wt2_sub="$nested_wt2/submod"
cfg_wt="$base/config/sandbox-wt.sh"

dummy_origin="$(mktemp -d "$TMPDIR/chopi-itest-origin.XXXXXX")"
git init -q --bare "$dummy_origin"
git -C "$gitrepo" remote add origin "$dummy_origin"

# Two commits on a side branch to cherry-pick later
mainbr="$(git -C "$gitrepo" symbolic-ref --short HEAD)"
git -C "$gitrepo" checkout -q -b pickable
printf 'p1\n' > "$gitrepo/p1.txt"; git -C "$gitrepo" add p1.txt; git -C "$gitrepo" commit -q -m p1
printf 'p2\n' > "$gitrepo/p2.txt"; git -C "$gitrepo" add p2.txt; git -C "$gitrepo" commit -q -m p2
pick1="$(git -C "$gitrepo" rev-parse HEAD~1)"
pick2="$(git -C "$gitrepo" rev-parse HEAD)"
git -C "$gitrepo" checkout -q "$mainbr"

cat > "$cfg_wt" <<EOF
. '$repo/config/templates/sandbox.template.sh'
CHOPI_SAFEHOUSE_FLAGS=( --add-dirs-ro "$claudebin" )
CHOPI_EXTRA_ENV=( PATH=/usr/bin:/bin:/usr/sbin:/sbin )
EOF

chopi_wt() { ( cd "$gitrepo" && "$repo/bin/chopi" --worktree nested_wt2 --config "$cfg_wt" -- "$@" ); }

# The worktree run as the stand-in agent, for the Claude-context cases (see chopi_claude).
chopi_wt_claude() { chopi_wt "$claude_shim" "$@"; }

workdir_wt="$(chopi_wt /bin/sh -c 'pwd' 2>/dev/null)"
assert_eq "$workdir_wt" "$nested_wt2"                             "the command runs with the worktree as its workdir"

chopi_wt /bin/sh -c 'echo HELLO > ./ws-file.txt' >/dev/null 2>&1
assert_eq "$(cat "$nested_wt2/ws-file.txt" 2>/dev/null)" "HELLO" \
                                                   "a write inside the worktree lands in the worktree"

# The root repo's working tree is unreadable from the worktree.
out="$(chopi_wt /bin/sh -c "cat '$root_only' && echo READ_OK || echo READ_FAIL" 2>/dev/null)"
assert_not_contains "$out" "ROOT_ONLY_MARKER"      "the root repo's working files are NOT readable from the worktree"
assert_contains     "$out" "READ_FAIL"             "  -> and that read fails"
out="$(chopi_wt /bin/sh -c "stat -f '%z' '$root_only' >/dev/null 2>&1 && echo STAT_OK || echo STAT_FAIL" 2>/dev/null)"
assert_contains     "$out" "STAT_FAIL"             "the root repo's file METADATA is not readable either"
# ...and unwritable.
chopi_wt /bin/sh -c "echo x > '$gitrepo_real/root-evil.txt'" >/dev/null 2>&1
assert_absent "$gitrepo_real/root-evil.txt" "a write into the root repo's working tree is denied"

# A sibling worktree nested under the repo root is unreadable.
out="$(chopi_wt /bin/sh -c "cat '$nested_wt/nested.txt' && echo READ_OK || echo READ_FAIL" 2>/dev/null)"
assert_not_contains "$out" "NESTED_ONLY_MARKER"   "a sibling worktree's working files are NOT readable"
assert_contains     "$out" "READ_FAIL"             "  -> and that read fails"
# ...and unwritable.
chopi_wt /bin/sh -c "echo x > '$nested_wt/nested-evil.txt'" >/dev/null 2>&1
assert_absent "$nested_wt/nested-evil.txt" "a write into a sibling worktree is denied"

# An external worktree is unreadable too.
out="$(chopi_wt /bin/sh -c "cat '$external_wt/ext.txt' && echo READ_OK || echo READ_FAIL" 2>/dev/null)"
assert_not_contains "$out" "EXTERNAL_ONLY_MARKER"  "an external (outside-the-repo) worktree's files are NOT readable"
assert_contains     "$out" "READ_FAIL"             "  -> and that read fails"
# ...and unwritable.
chopi_wt /bin/sh -c "echo x > '$external_wt/ext-evil.txt'" >/dev/null 2>&1
assert_absent "$external_wt/ext-evil.txt" "a write into an external worktree is denied"

# A Claude context file above the repo root stays readable from the worktree (e.g. a developer-dir
# CLAUDE.md meant for every repo beneath it), but the repo root's own copy are unreadable.
printf 'ABOVE_REPO_CLAUDE_MARKER\n' > "$base/CLAUDE.md"          # $base is the repo's parent dir
printf 'REPO_ROOT_CLAUDE_MARKER\n'  > "$gitrepo_real/CLAUDE.md"
out="$(chopi_wt_claude -c "cat '$base/CLAUDE.md' && echo READ_OK || echo READ_FAIL" 2>/dev/null)"
assert_contains "$out" "ABOVE_REPO_CLAUDE_MARKER"  "a CLAUDE.md ABOVE the repo root is readable from the worktree"
out="$(chopi_wt_claude -c "cat '$gitrepo_real/CLAUDE.md' && echo READ_OK || echo READ_FAIL" 2>/dev/null)"
assert_not_contains "$out" "REPO_ROOT_CLAUDE_MARKER" "the repo root's OWN CLAUDE.md is NOT readable from the worktree (isolation wins)"
assert_contains     "$out" "READ_FAIL"             "  -> and that read fails"

# Isolation covers the whole enclosing working tree, not just the root: an ancestor
# context file BETWEEN the repo root and the worktree is unreadable too.
printf 'MID_REPO_CLAUDE_MARKER\n' > "$gitrepo_real/.worktrees/CLAUDE.md"
out="$(chopi_wt_claude -c "cat '$gitrepo_real/.worktrees/CLAUDE.md' && echo READ_OK || echo READ_FAIL" 2>/dev/null)"
assert_not_contains "$out" "MID_REPO_CLAUDE_MARKER" "a CLAUDE.md in a repo subdir ABOVE the worktree is NOT readable from the worktree"
assert_contains     "$out" "READ_FAIL"              "  -> and that read fails"

# Every context filename gets the same treatment, so .claude/CLAUDE.md is covered too.
mkdir -p "$base/.claude" "$gitrepo_real/.claude"
printf 'ABOVE_REPO_DOTCLAUDE_MARKER\n' > "$base/.claude/CLAUDE.md"
printf 'REPO_ROOT_DOTCLAUDE_MARKER\n'  > "$gitrepo_real/.claude/CLAUDE.md"
out="$(chopi_wt_claude -c "cat '$base/.claude/CLAUDE.md' && echo READ_OK || echo READ_FAIL" 2>/dev/null)"
assert_contains "$out" "ABOVE_REPO_DOTCLAUDE_MARKER"  "a .claude/CLAUDE.md ABOVE the repo root is readable from the worktree"
out="$(chopi_wt_claude -c "cat '$gitrepo_real/.claude/CLAUDE.md' && echo READ_OK || echo READ_FAIL" 2>/dev/null)"
assert_not_contains "$out" "REPO_ROOT_DOTCLAUDE_MARKER" "the repo root's OWN .claude/CLAUDE.md is NOT readable from the worktree (isolation wins)"
assert_contains     "$out" "READ_FAIL"                "  -> and that read fails"

# All those denied in-repo context files (root and mid-repo) exist right now, yet none
# gate the run: a blind denial with no visible link is chopi's own isolation at work.
out="$(chopi_wt_claude -c 'echo RAN' 2>/dev/null)"; rc=$?
assert_zero     "$rc"        "denied in-repo ancestor context files do NOT refuse the worktree run"
assert_contains "$out" "RAN" "  -> the command runs"

# An unreadable symlinked context file ABOVE the repo root, by contrast, refuses the
# run: resolving the link and granting its target's read is the user's to do.
printf 'x\n' > "$base/wt-link-target.md"
rm "$base/CLAUDE.md"
ln -s "$base/wt-link-target.md" "$base/CLAUDE.md"
both="$(chopi_wt_claude -c 'echo RAN' 2>&1)"; rc=$?
assert_nonzero      "$rc"   "an unreadable symlinked CLAUDE.md above the repo root refuses the worktree run"
assert_contains     "$both" "$base/wt-link-target.md  (symlink target of $base/CLAUDE.md)" "  -> naming the resolved target and the link it came from"
assert_not_contains "$both" "RAN"                                          "  -> and does not run the command"
# Undo for the following tests.
rm "$base/CLAUDE.md"
printf 'ABOVE_REPO_CLAUDE_MARKER\n' > "$base/CLAUDE.md"

# An @-import pointing INSIDE the enclosing repo is denied by the worktree isolation,
# which no user grant can win. The run is unconditionally refused, because this case
# is unrealistic; but at least mention the possibility in the refusal message.
printf 'IN_REPO_IMPORT_MARKER\n' > "$gitrepo_real/team-conventions.md"
printf 'ABOVE_REPO_CLAUDE_MARKER\n@%s/team-conventions.md\n' "$gitrepo_real" > "$base/CLAUDE.md"
both="$(chopi_wt_claude -c 'echo RAN' 2>&1)"; rc=$?
assert_nonzero      "$rc"                                                                      "an isolation-denied in-repo @-import refuses the worktree run"
assert_contains     "$both" "$gitrepo_real/team-conventions.md  (imported by $base/CLAUDE.md)" "  -> listing it with its importer"
assert_contains     "$both" "a grant cannot cover an @-import"                                 "  -> and noting that a grant can't fix an isolation-zone import"
assert_not_contains "$both" "RAN"                                                              "  -> and does not run the command"

# An ungranted @-import OUTSIDE the repo also refuses the worktree run; there, the user
# can grant the missing dir.
mkdir -p "$base/wt-notes"
printf 'x\n' > "$base/wt-notes/style.md"
printf 'ABOVE_REPO_CLAUDE_MARKER\n@%s/wt-notes/style.md\n' "$base" > "$base/CLAUDE.md"
both="$(chopi_wt_claude -c 'echo RAN' 2>&1)"; rc=$?
assert_nonzero      "$rc"                                                            "an ungranted above-the-repo @-import still refuses the worktree run"
assert_contains     "$both" "$base/wt-notes/style.md  (imported by $base/CLAUDE.md)" "  -> listing it with its importer"
assert_not_contains "$both" "RAN"                                                    "  -> and does not run the command"

# Undo for the following tests.
rm "$gitrepo_real/team-conventions.md"
printf 'ABOVE_REPO_CLAUDE_MARKER\n' > "$base/CLAUDE.md"

# The two appended protection profiles (isolation + hardening) are unreadable.
# shellcheck disable=SC2016
probe='n=$(ls "$TMPDIR" 2>/dev/null | grep -cE "^chopi-git-(isolate|harden)\.")
echo "PROTECTION_COUNT=$n"
for f in $(ls "$TMPDIR" 2>/dev/null | grep -E "^chopi-git-(isolate|harden)\."); do
  cat "$TMPDIR/$f" 2>/dev/null && echo READ_OK || echo READ_FAIL
  echo x >> "$TMPDIR/$f" 2>/dev/null && echo WRITE_OK || echo WRITE_FAIL
done'
out="$(chopi_wt /bin/sh -c "$probe" 2>/dev/null)"
assert_contains     "$out" "PROTECTION_COUNT=2"    "both protection profiles (isolation + hardening) exist while the command runs"
assert_not_contains "$out" "READ_OK"               "the command cannot read the protection profiles that sandbox it"
assert_not_contains "$out" "isolate the command to the worktree" \
                                                   "  -> and none of the isolation profile's contents leak"
assert_not_contains "$out" "harden the git internals" \
                                                   "  -> nor the hardening profile's"
# ...and unwritable.
assert_not_contains "$out" "WRITE_OK"              "the command cannot write to the protection profiles either"

# git still works inside the isolated worktree
top="$(chopi_wt git rev-parse --show-toplevel 2>/dev/null)"
assert_eq "$top" "$nested_wt2"                     "git resolves the worktree as its toplevel"
out="$(chopi_wt /bin/sh -c 'git tag chopi-probe && echo TAG_OK' 2>/dev/null)"
assert_contains "$out" "TAG_OK"                    "git can write a ref into the shared .git from inside the sandbox"
assert_has_line "$(git -C "$gitrepo" tag)" chopi-probe "  -> and the tag really landed in the repo"

# Re-running the same NAME reuses the existing worktree rather than failing.
out="$(chopi_wt /bin/sh -c 'echo REUSED' 2>/dev/null)"
assert_eq "$out" "REUSED"                          "re-running --worktree reuses the existing worktree and runs there"

# -- The shared .git is READABLE but code-execution paths are NOT WRITABLE ---------------
config_before="$(cat "$shared_git/config")"

chopi_wt /bin/sh -c "echo pwn > '$shared_git/hooks/post-checkout'" >/dev/null 2>&1
assert_absent "$shared_git/hooks/post-checkout" "planting a hook in the shared .git/hooks is denied (no file created)"

# `git config` from the linked worktree targets the shared .git/config (no
# extensions.worktreeConfig here), so it is denied and the file stays byte-identical.
chopi_wt git config core.hooksPath /tmp/evil >/dev/null 2>&1

# An [include]/[includeIf] path= in a pre-existing config could point at any of these;
# leaving them writable would reopen the hole. All are under the default write-deny.
chopi_wt /bin/sh -c "echo x > '$shared_git/config.local'"    >/dev/null 2>&1
chopi_wt /bin/sh -c "echo '* filter=evil' > '$shared_git/info/attributes'" >/dev/null 2>&1
for f in config.local info/attributes; do
    assert_absent "$shared_git/$f" "writing shared .git/$f is denied (no file created)"
done

# A sibling worktree's admin dir is denied
chopi_wt /bin/sh -c "echo x > '$nested_wt_admin/config.worktree'" >/dev/null 2>&1
if [ -s "$nested_wt_admin/config.worktree" ]; then
    bad "writing a sibling worktree's admin dir is denied (file must stay empty/absent)"
else
    ok  "writing a sibling worktree's admin dir is denied"
fi

# The gitdir pointers that unsandboxed git follows are read-only
wt_dotgit="$nested_wt2/.git"
wt_commondir="$nested_wt2_admin/commondir"
dotgit_before="$(cat "$wt_dotgit")"
commondir_before="$(cat "$wt_commondir")"
chopi_wt /bin/sh -c "echo 'gitdir: /tmp/evil-admin' > '$wt_dotgit'"   >/dev/null 2>&1
chopi_wt /bin/sh -c "echo '/tmp/evil-common' > '$wt_commondir'"       >/dev/null 2>&1
assert_eq "$(cat "$wt_dotgit")" "$dotgit_before" \
                                                   "the worktree's own .git pointer file cannot be rewritten from the sandbox"
assert_eq "$(cat "$wt_commondir")" "$commondir_before" \
                                                   "the admin dir's commondir shared-dir pointer cannot be rewritten from the sandbox"

# Submodules in the worktree similarly have their code-execution surface write-denied
for sub_main_wt in "$nested_wt2_sub" "$nested_wt2_sub/nested"; do
    sub_rel="${sub_main_wt#"$nested_wt2/"}"
    sub_gitdir="$(realpath "$(git -C "$sub_main_wt" rev-parse --absolute-git-dir 2>/dev/null)" 2>/dev/null)"
    sub_dotgit_before="$(cat "$sub_main_wt/.git")"
    sub_config_before="$(cat "$sub_gitdir/config")"
    chopi_wt /bin/sh -c "echo 'gitdir: /tmp/evil' > '$sub_main_wt/.git'"    >/dev/null 2>&1
    chopi_wt /bin/sh -c "printf '[core]\n' > '$sub_gitdir/config'"              >/dev/null 2>&1
    chopi_wt /bin/sh -c "echo pwn > '$sub_gitdir/hooks/post-checkout'"          >/dev/null 2>&1
    assert_eq "$(cat "$sub_main_wt/.git")" "$sub_dotgit_before" \
                                                   "submodule '$sub_rel': its .git pointer file cannot be rewritten from the sandbox"
    assert_eq "$(cat "$sub_gitdir/config")" "$sub_config_before" \
                                                   "submodule '$sub_rel': its gitdir config cannot be written from the sandbox"
    assert_absent "$sub_gitdir/hooks/post-checkout" "submodule '$sub_rel': planting a hook in its gitdir is denied (no file created)"
done

# Legitimate git flows still work
out="$(chopi_wt /bin/sh -c 'echo CHG > ./commitme.txt && git add commitme.txt && git commit -q -m wtcommit && echo COMMIT_OK' 2>/dev/null)"
assert_contains "$out" "COMMIT_OK"                 "a commit inside the worktree succeeds"

out="$(chopi_wt /bin/sh -c 'git push 2>&1 && echo PUSH_OK' 2>/dev/null)"
assert_contains "$out" "PUSH_OK"                   "bare git push (pre-recorded upstream) succeeds from the sandbox"
git -C "$dummy_origin" rev-parse --verify --quiet refs/heads/nested_wt2 >/dev/null
assert_zero "$?" "  -> and the branch landed in the origin"

# branch create/delete writes refs with a packed backend.
out="$(chopi_wt /bin/sh -c 'git pack-refs --all && git branch tmpbr && git branch -d tmpbr && echo PACK_OK' 2>/dev/null)"
assert_contains "$out" "PACK_OK"                   "pack-refs + branch create/delete succeed"

out="$(chopi_wt /bin/sh -c "git cherry-pick $pick1 $pick2 && echo PICK_OK" 2>/dev/null)"
assert_contains "$out" "PICK_OK"                   "a multi-commit cherry-pick succeeds"

out="$(chopi_wt /bin/sh -c 'echo dirty >> ./commitme.txt && git stash push -q -m t && git stash pop -q && echo STASH_OK' 2>/dev/null)"
assert_contains "$out" "STASH_OK"                  "git stash push/pop succeed"

out="$(chopi_wt /bin/sh -c 'cd submod && echo more >> sub.txt && git add sub.txt && git -c user.email=w@t.t -c user.name=w commit -q -m subchg && echo SUBCOMMIT_OK' 2>/dev/null)"
assert_contains "$out" "SUBCOMMIT_OK"              "a commit inside an initialized submodule succeeds"

out="$(chopi_wt /bin/sh -c 'cd submod/nested && echo more >> nested.txt && git add nested.txt && git -c user.email=w@t.t -c user.name=w commit -q -m nestedchg && echo NESTEDCOMMIT_OK' 2>/dev/null)"
assert_contains "$out" "NESTEDCOMMIT_OK"           "a commit inside the NESTED submodule succeeds too"

# `git submodule update` is expected to fail loudly with the config untouched
sub_cfg="$(realpath "$(git -C "$nested_wt2_sub" rev-parse --absolute-git-dir)")/config"
sub_cfg_before="$(cat "$sub_cfg")"
out="$(chopi_wt git submodule update 2>&1 >/dev/null)"; rc=$?
assert_nonzero "$rc" "in-sandbox git submodule update fails"
assert_contains "$out" "core.worktree"             "  -> naming the denied core.worktree write"
assert_eq "$(cat "$sub_cfg")" "$sub_cfg_before"    "  -> and the submodule's config is untouched"

# Host-forwarded git config (safehouse --env-pass) survives, and overridable by CHOPI_GIT_CONFIG
cfg_envpass="$base/config/sandbox-envpass.sh"
cat > "$cfg_envpass" <<EOF
. '$repo/config/templates/sandbox.template.sh'
CHOPI_SAFEHOUSE_FLAGS=( --enable xcode
                    --env-pass GIT_CONFIG_COUNT,GIT_CONFIG_KEY_0,GIT_CONFIG_VALUE_0,GIT_CONFIG_KEY_1,GIT_CONFIG_VALUE_1,GIT_CONFIG_KEY_2,GIT_CONFIG_VALUE_2 )
CHOPI_EXTRA_ENV=( PATH=/usr/bin:/bin:/usr/sbin:/sbin )
CHOPI_GIT_CONFIG=( chopi.conflict=fromconfig )
EOF
chopi_ep() { ( cd "$gitrepo" && env \
    GIT_CONFIG_COUNT=3 \
    GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always \
    GIT_CONFIG_KEY_1=chopi.hostpassed GIT_CONFIG_VALUE_1=hostmarker \
    GIT_CONFIG_KEY_2=chopi.conflict GIT_CONFIG_VALUE_2=fromhost \
    "$repo/bin/chopi" --worktree nested_wt2 --config "$cfg_envpass" -- "$@" ); }
out="$(chopi_ep git config chopi.hostpassed 2>/dev/null)"
assert_eq "$out" "hostmarker"                      "a host GIT_CONFIG_* pair forwarded via safehouse --env-pass survives the append"
out="$(chopi_ep git config chopi.conflict 2>/dev/null)"
assert_eq "$out" "fromconfig"                      "  -> and on a conflicting key, the appended CHOPI_GIT_CONFIG pair wins"

# CHOPI_WORKTREE_SETUP: the config customizes the pre-sandbox setup, and
# CHOPI_WORKTREE_NAME expands to the worktree name at setup time.
wt_cfg="$base/config/sandbox-setup.sh"
setup_marker="$base/setup-marker.txt"
cat > "$wt_cfg" <<EOF
CHOPI_SAFEHOUSE_FLAGS=( --enable xcode )
CHOPI_EXTRA_ENV=( PATH=/usr/bin:/bin:/usr/sbin:/sbin )
CHOPI_WORKTREE_SETUP=( 'echo "\$CHOPI_WORKTREE_NAME" > "$setup_marker"' )
EOF
( cd "$gitrepo" && "$repo/bin/chopi" --worktree wtcfg --config "$wt_cfg" -- /bin/sh -c 'true' ) >/dev/null 2>&1
assert_eq "$(cat "$setup_marker" 2>/dev/null)" "wtcfg" \
    "a custom CHOPI_WORKTREE_SETUP command runs (unsandboxed) with CHOPI_WORKTREE_NAME set"

# --worktree mode refuses a config without CHOPI_WORKTREE_SETUP
out="$(cd "$gitrepo" && "$repo/bin/chopi" --worktree wtnone --config "$cfg" -- /bin/sh -c 'true' 2>&1)"; st=$?
assert_contains "$out" "CHOPI_WORKTREE_SETUP" "--worktree refuses a config without CHOPI_WORKTREE_SETUP"
assert_nonzero "$st" "  -> and exits non-zero"
assert_absent "$gitrepo/.worktrees/wtnone" "  -> and no worktree is created"

# --config placement is checked against the WORKTREE (the dir actually sandboxed), not
# the invocation dir.
#   (a) A config in the repo root but OUTSIDE the target worktree is allowed -- the
#       isolated worktree can't write it. (Checking the invocation dir would wrongly
#       refuse it.)
repo_cfg="$gitrepo_real/wt-repo-cfg.sh"          # in the repo, outside the worktree
cat > "$repo_cfg" <<EOF
. '$repo/config/templates/sandbox.template.sh'
CHOPI_SAFEHOUSE_FLAGS=()
CHOPI_EXTRA_ENV=( PATH=/usr/bin:/bin:/usr/sbin:/sbin )
EOF
out="$(cd "$gitrepo" && "$repo/bin/chopi" --worktree nested_wt2 --config "$repo_cfg" -- /bin/sh -c 'echo CFG_OK' 2>&1)"; st=$?
assert_contains "$out" "CFG_OK"                    "a --config in the repo but outside the target worktree is allowed"
assert_zero "$st" "  -> and the run succeeds"
#   (b) A config INSIDE the target worktree is refused -- the sandboxed command has
#       read/write there and could rewrite the policy that confines its next run.
#       (Checking the invocation dir would miss it entirely.)
inside_cfg="$nested_wt2/inside-cfg.sh"           # inside the worktree (writable by the command)
cat > "$inside_cfg" <<EOF
. '$repo/config/templates/sandbox.template.sh'
CHOPI_SAFEHOUSE_FLAGS=()
CHOPI_EXTRA_ENV=( PATH=/usr/bin:/bin:/usr/sbin:/sbin )
EOF
out="$(cd "$gitrepo" && "$repo/bin/chopi" --worktree nested_wt2 --config "$inside_cfg" -- /bin/sh -c 'echo NOPE' 2>&1)"; st=$?
assert_contains "$out" "is inside the workspace" "a --config inside the target worktree is refused"
assert_not_contains "$out" "NOPE"                  "  -> and the command never runs"
assert_nonzero "$st" "  -> and it exits non-zero"


# ---------------------------------------------------------------------------
summary

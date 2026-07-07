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
#     that bypasses the proxy, or aims at a non-4760 port, is blocked by Seatbelt.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
. "$repo/.internal/util.sh"
. "$repo/test/lib.sh"

header "test/integration.sh -- chopi's end-to-end integration tests"

ALLOWED_HOST="www.google.com"      # allowed in the test rules       -> reachable through the proxy
DENIED_HOST="www.microsoft.com"    # NOT allowed in the test rules   -> refused by the proxy


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
# Fixtures -- a private TMPDIR (exported so the scripts under test leave their
# temporaries here too), and everything else under one base dir UNDER \$HOME
# (not /tmp or /var/folders, which safehouse grants read+write by default).
# ---------------------------------------------------------------------------
TMPDIR="$(mktemp -d)"; export TMPDIR
base="$(mktemp -d "$HOME/.chopi-itest.XXXXXX")" || { echo "error: mktemp failed" >&2; exit 1; }
marker_file=""
trap 'if [ -n "${proxy_pid:-}" ]; then kill "$proxy_pid" 2>/dev/null || true; wait "$proxy_pid" 2>/dev/null || true; fi; rm -rf "$base" "$TMPDIR" ${marker_file:+"$marker_file"}' EXIT

ws="$base/workspace"            # the sandbox workspace (read/write granted, as the workdir)
outside="$base/outside"         # sibling under $HOME -> reliably denied
alerter_stub="$base/bin"        # a recording `alerter` shim on the proxy's PATH
cfg="$base/config/sandbox.sh"   # minimal sandbox config, OUTSIDE the workspace
rules="$base/config/itest-rules.yaml"
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

# Test rules: exactly one host allowed.
cat > "$rules" <<EOF
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
PATH="$alerter_stub:$PATH" "$repo/bin/chopi-proxy.sh" --rules "$rules" > "$proxy_log" 2>&1 &
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

chopi_t /bin/sh -c "echo x > '$outside/evil.txt'" >/dev/null 2>&1 || true
if [ -e "$outside/evil.txt" ]; then
    bad "write OUTSIDE the workspace is denied (file must not exist)"
else
    ok  "write OUTSIDE the workspace is denied (no file created)"
fi

out="$(chopi_t /bin/sh -c "cat '$repo/.internal/preflight.sh' && echo READ_OK || echo READ_FAIL" 2>/dev/null)"
assert_not_contains "$out" "preflight"             "read of chopi's OWN dir is denied (config stays out of reach)"
assert_contains     "$out" "READ_FAIL"             "  -> and that read fails"


# ---------------------------------------------------------------------------
echo "private per-invocation temp dir"
# ---------------------------------------------------------------------------
# chopi exports a freshly-made TMPDIR for each run (safehouse forwards it into the
# sandbox). ALL of chopi's own temporaries (gitconf wrapper profiles, isolation and
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
assert_contains "$out" "$CHOPI_GITCONF_WRAPPER_PREFIX" "the gitconf wrapper profile lives inside the invocation temp dir"
assert_contains "$out" "$CHOPI_CMD_ALIAS_PREFIX"       "the command-alias dir lives inside the invocation temp dir"

if [ -n "$sbx_tmpdir" ] && [ ! -e "$sbx_tmpdir" ]; then
    ok  "chopi removes the entire invocation temp dir (all temporaries with it) after the run"
else
    bad "chopi should remove the invocation temp dir ('$sbx_tmpdir') after the run"
fi


# ---------------------------------------------------------------------------
echo "git config injection (CHOPI_GIT_CONFIG)"
# ---------------------------------------------------------------------------
# CHOPI_GIT_CONFIG pairs reach a plain (non-worktree) sandboxed command through the append
# wrapper -- which the sandboxed process itself must read and exec. chopi's dir is otherwise
# unreadable (asserted above), so this exercises the gitconf-wrapper profile; and the grant
# must cover exactly the wrapper file, nothing else in chopi's dir.
cfg_gitcfg="$base/config/sandbox-gitcfg.sh"
cat > "$cfg_gitcfg" <<'EOF'
CHOPI_SAFEHOUSE_FLAGS=()
CHOPI_EXTRA_ENV=( PATH=/usr/bin:/bin:/usr/sbin:/sbin )
CHOPI_GIT_CONFIG=( chopi.plain=plainmarker )
EOF
chopi_gc() { ( cd "$ws" && "$repo/bin/chopi" --config "$cfg_gitcfg" -- "$@" ); }

# shellcheck disable=SC2016 # the $GIT_CONFIG_* probe expands in the sandboxed shell, not here
out="$(chopi_gc /bin/sh -c 'echo "$GIT_CONFIG_COUNT|$GIT_CONFIG_KEY_0=$GIT_CONFIG_VALUE_0"' 2>/dev/null)"
assert_eq "$out" "1|chopi.plain=plainmarker"       "a CHOPI_GIT_CONFIG pair reaches a plain (non-worktree) sandboxed command"

out="$(chopi_gc /bin/sh -c "cat '$repo/.internal/util.sh' >/dev/null 2>&1 && echo READ_OK || echo READ_FAIL" 2>/dev/null)"
assert_eq "$out" "READ_FAIL"                       "  -> the gitconf wrapper does not open the rest of chopi's dir"


# ---------------------------------------------------------------------------
echo "agent profile survives the git-config wrapper (command-name detection)"
# ---------------------------------------------------------------------------
# safehouse appends profiles based on the invoked command's BASENAME. chopi runs the
# sandboxed command through the git-config wrapper (which is argv[0]), so it must present the
# wrapper under the real command's basename to get the needed grants. Test via safehouse's
# `claude` profile, the only one which grants read on ~/.claude.json.*.
marker_file="$HOME/.claude.json.chopi-itest.$$"      # created here, removed by the EXIT trap
printf 'CLAUDE_PROFILE_MARKER\n' > "$marker_file"

# "claude" below stands in for the real agent. Both the fake agent and the sh probe
# below run the same body: cat the file named by $1, reporting READ_OK/READ_FAIL.
# shellcheck disable=SC2016 # $1 expands in the sandboxed shell, not here
read_probe='cat "$1" 2>/dev/null && echo READ_OK || echo READ_FAIL'
agentbin="$ws/agentbin"
mkdir -p "$agentbin"
cat > "$agentbin/claude" <<EOF
#!/bin/sh
$read_probe
EOF
chmod +x "$agentbin/claude"
cfg_agent="$base/config/sandbox-agent.sh"
cat > "$cfg_agent" <<EOF
CHOPI_SAFEHOUSE_FLAGS=()
CHOPI_EXTRA_ENV=( PATH=$agentbin:/usr/bin:/bin:/usr/sbin:/sbin )
EOF
chopi_agent() { ( cd "$ws" && "$repo/bin/chopi" --config "$cfg_agent" -- "$@" ); }

out="$(chopi_agent claude "$marker_file" 2>/dev/null)"
assert_contains "$out" "CLAUDE_PROFILE_MARKER"     "a command's agent profile is selected through the wrapper (real basename reaches safehouse)"
assert_contains "$out" "READ_OK"                   "  -> and the profile's ~/.claude.json.* read grant actually applies in the sandbox"

out="$(chopi_agent /bin/sh -c "$read_probe" sh "$marker_file" 2>/dev/null)"
assert_not_contains "$out" "CLAUDE_PROFILE_MARKER" "a non-agent basename (sh) selects no profile, so the same file stays unreadable"
assert_contains     "$out" "READ_FAIL"             "  -> and that read is denied"


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

# (4) Outgoing connections are pinned to 4760 SPECIFICALLY: a different loopback proxy port is blocked
# (network.sb only allows localhost:4760). Offline-safe.
code="$(sandbox_curl --max-time 15 --proxy "http://127.0.0.1:4761" "https://$ALLOWED_HOST")"
assert_not_contains "$code" "200"                  "an outgoing connection to a non-4760 loopback port is blocked by the sandbox"


# ---------------------------------------------------------------------------
echo "git worktree isolation"
# ---------------------------------------------------------------------------
if ! command -v git >/dev/null 2>&1; then
    echo "  SKIP git isolation tests (git not on PATH)"
else
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

    workdir="$(chopi_main /bin/sh -c 'pwd' 2>/dev/null || true)"
    assert_eq "$workdir" "$gitrepo_real"                    "the command runs with the repo root as its workdir"

    # Verify isolation
    out="$(chopi_main /bin/sh -c "cat '$nested_wt/nested.txt' && echo READ_OK || echo READ_FAIL" 2>/dev/null || true)"
    assert_not_contains "$out" "NESTED_ONLY_MARKER"   "a nested sibling worktree's files are NOT readable"
    assert_contains     "$out" "READ_FAIL"             "  -> and that read fails"
    chopi_main /bin/sh -c "echo x > '$nested_wt/evil.txt'" >/dev/null 2>&1 || true
    assert_absent "$nested_wt/evil.txt" "a write into a nested sibling worktree is denied (no file created)"
    out="$(chopi_main /bin/sh -c "cat '$external_wt/ext.txt' && echo READ_OK || echo READ_FAIL" 2>/dev/null || true)"
    assert_not_contains "$out" "EXTERNAL_ONLY_MARKER"  "an external worktree's files are NOT readable (safehouse's read grant is undone)"
    assert_contains     "$out" "READ_FAIL"             "  -> and that read fails"

    # git keeps working in the isolated worktree
    out="$(chopi_main /bin/sh -c 'echo CHG > ./main-commit.txt && git add main-commit.txt && git commit -q -m maincommit && echo COMMIT_OK' 2>/dev/null || true)"
    assert_contains "$out" "COMMIT_OK"                 "a commit in the main worktree succeeds"
    # A PARTIAL (pathspec-limited) commit builds its temp index at .git/next-index-<pid>,
    # not index.lock -- a separate write hole that is easy to miss.
    out="$(chopi_main /bin/sh -c 'echo one > ./partial.txt && git add partial.txt && git commit -q -m addpartial && echo two >> ./partial.txt && git commit -q -m partial -- partial.txt && echo PARTIAL_OK' 2>/dev/null)"
    assert_contains "$out" "PARTIAL_OK"                "a pathspec-limited commit succeeds (the next-index temp-index hole)"
    out="$(chopi_main /bin/sh -c 'git tag chopi-main-probe && echo TAG_OK' 2>/dev/null)"
    assert_contains "$out" "TAG_OK"                    "a ref write succeeds"
    out="$(chopi_main /bin/sh -c 'echo dirty >> ./main-commit.txt && git stash push -q -m t && git stash pop -q && echo STASH_OK' 2>/dev/null || true)"
    assert_contains "$out" "STASH_OK"                  "git stash push/pop succeed"
fi


# ---------------------------------------------------------------------------
echo "git internals hardening"
# ---------------------------------------------------------------------------
if command -v git >/dev/null 2>&1; then
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
    out="$(chopi_main /bin/sh -c "git cherry-pick $mpick1 $mpick2 && echo PICK_OK" 2>/dev/null || true)"
    assert_contains "$out" "PICK_OK"                   "a multi-commit cherry-pick succeeds in the main worktree (sequencer + CHERRY_PICK_HEAD)"
    out="$(chopi_main /bin/sh -c 'git rebase -f HEAD~2 && echo REBASE_OK' 2>/dev/null || true)"
    assert_contains "$out" "REBASE_OK"                 "a rebase succeeds (merge backend: ORIG_HEAD/REBASE_HEAD + rebase-merge/)"
    out="$(chopi_main /bin/sh -c 'git rebase --apply -f HEAD~2 && echo APPLY_OK' 2>/dev/null || true)"
    assert_contains "$out" "APPLY_OK"                  "  -> and with --apply (rebase-apply/ + the rebased-patches spool)"

    # Sparse-checkout works end to end, info/attributes and info/exclude beside it stay denied.
    sparse_checkout="$shared_git/info/sparse-checkout"
    git -C "$gitrepo" config core.sparseCheckout true
    out="$(chopi_main /bin/sh -c "printf '/*\n!/mp1.txt\n' > '$sparse_checkout' && git sparse-checkout reapply && test ! -f mp1.txt && echo SPARSE_OK" 2>/dev/null || true)"
    assert_contains "$out" "SPARSE_OK"                 "a sparse checkout works via the writable sparse-checkout file in the shared info/"
    assert_absent "$gitrepo_real/mp1.txt" "  -> the excluded file is really pruned from the main worktree"
    out="$(chopi_main /bin/sh -c "printf '/*\n' > '$sparse_checkout' && git sparse-checkout reapply && test -f mp1.txt && rm '$sparse_checkout' && echo RESTORE_OK" 2>/dev/null || true)"
    assert_contains "$out" "RESTORE_OK"                "  -> widening the patterns restores it, and the file is removable"
    git -C "$gitrepo" config --unset core.sparseCheckout
    chopi_main /bin/sh -c "echo '* filter=evil' > '$shared_git/info/attributes'" >/dev/null 2>&1 || true
    assert_absent "$shared_git/info/attributes" "writing the shared .git/info/attributes is denied (no file created)"

    # Verify exec surface is set to read-only
    config_before="$(cat "$shared_git/config")"
    chopi_main /bin/sh -c "echo pwn > '$shared_git/hooks/post-commit'" >/dev/null 2>&1 || true
    assert_absent "$shared_git/hooks/post-commit" "planting a hook in the shared .git/hooks is denied (no file created)"
    chopi_main /usr/bin/git config core.hooksPath /tmp/evil >/dev/null 2>&1 || true
    assert_eq "$(cat "$shared_git/config")" "$config_before" \
                                                       "the shared .git/config cannot be written from the sandbox"

    # A submodule in the main tree: its gitdir (.git/modules/...) keeps its data holes, so
    # in-sandbox submodule commits work, while its exec surface stays read-only.
    out="$(chopi_main /bin/sh -c 'cd submod && echo more >> sub.txt && git add sub.txt && git commit -q -m mainsub && echo SUBCOMMIT_OK' 2>/dev/null || true)"
    assert_contains "$out" "SUBCOMMIT_OK"              "a commit inside the main tree's submodule succeeds"
    main_sub_gitdir="$(realpath "$(git -C "$submod" rev-parse --absolute-git-dir)" || true)"
    main_sub_dotgit_before="$(cat "$submod_dotgit")"
    chopi_main /bin/sh -c "echo 'gitdir: /tmp/evil' > '$submod_dotgit'" >/dev/null 2>&1 || true
    chopi_main /bin/sh -c "echo pwn > '$main_sub_gitdir/hooks/post-checkout'"          >/dev/null 2>&1 || true
    assert_eq "$(cat "$submod_dotgit")" "$main_sub_dotgit_before" \
                                                       "the submodule's .git pointer file cannot be rewritten from the sandbox"
    assert_absent "$main_sub_gitdir/hooks/post-checkout" "planting a hook in the submodule's gitdir is denied (no file created)"

    # A sibling worktree's admin dir stays unwritable (only holes for the MAIN checkout
    # state were poked).
    chopi_main /bin/sh -c "echo x > '$nested_wt_admin/config.worktree'" >/dev/null 2>&1 || true
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
    sub_main_gitdir="$(realpath "$(git -C "$submod" rev-parse --absolute-git-dir)" || true)"

    top="$(chopi_sub /usr/bin/git rev-parse --show-toplevel 2>/dev/null || true)"
    assert_eq "$top" "$submod"                         "git resolves the submodule root as its toplevel (module gitdir readable)"

    out="$(chopi_sub /bin/sh -c 'echo CHG > ./subroot.txt && git add subroot.txt && git commit -q -m subroot && echo COMMIT_OK' 2>/dev/null || true)"
    assert_contains "$out" "COMMIT_OK"                 "a commit at the submodule root succeeds (module gitdir data paths writable)"

    # The superproject's working tree and its own .git internals are not granted; only
    # the module gitdir subtree is.
    out="$(chopi_sub /bin/sh -c "cat '$root_only' && echo READ_OK || echo READ_FAIL" 2>/dev/null || true)"
    assert_not_contains "$out" "ROOT_ONLY_MARKER"      "the superproject's working files are NOT readable"
    assert_contains     "$out" "READ_FAIL"             "  -> and that read fails"
    out="$(chopi_sub /bin/sh -c "cat '$shared_git/config' >/dev/null 2>&1 && echo READ_OK || echo READ_FAIL" 2>/dev/null || true)"
    assert_contains     "$out" "READ_FAIL"             "the superproject's .git/config is NOT readable"
    chopi_sub /bin/sh -c "echo x > '$gitrepo_real/super-evil.txt'" >/dev/null 2>&1 || true
    assert_absent "$gitrepo_real/super-evil.txt" "a write into the superproject's tree is denied (no file created)"

    # The submodule's own exec surface: its .git pointer file, the module config, the
    # module hooks/ -- all repointable-into-unsandboxed-execution, all read-only.
    sub_dotgit_before="$(cat "$submod_dotgit")"
    sub_cfg_before="$(cat "$sub_main_gitdir/config")"
    chopi_sub /bin/sh -c "echo 'gitdir: /tmp/evil' > '$submod_dotgit'" >/dev/null 2>&1 || true
    chopi_sub /usr/bin/git config core.hooksPath /tmp/evil >/dev/null 2>&1 || true
    chopi_sub /bin/sh -c "echo pwn > '$sub_main_gitdir/hooks/post-commit'" >/dev/null 2>&1 || true
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
    chopi_sub /bin/sh -c "echo pwn > '$nested_gd/hooks/post-commit'" >/dev/null 2>&1 || true
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

    out="$(chopi_sgd /bin/sh -c 'echo CHG > ./sgd.txt && git add sgd.txt && git commit -q -m sgd && echo COMMIT_OK' 2>/dev/null || true)"
    assert_contains "$out" "COMMIT_OK"                 "a commit at a separate-git-dir root succeeds (detached gitdir writable on data paths)"

    sgd_dotgit_before="$(cat "$sgd_dotgit")"
    chopi_sgd /bin/sh -c "echo 'gitdir: /tmp/evil' > '$sgd_dotgit'" >/dev/null 2>&1 || true
    chopi_sgd /bin/sh -c "echo pwn > '$sgdgit_real/hooks/post-commit'" >/dev/null 2>&1 || true
    assert_eq "$(cat "$sgd_dotgit")" "$sgd_dotgit_before" \
                                                       "the root's .git pointer file cannot be rewritten from the sandbox"
    assert_absent "$sgdgit_real/hooks/post-commit" "planting a hook in the detached gitdir is denied (no file created)"
fi


# ---------------------------------------------------------------------------
echo "git protections (--worktree)"
# ---------------------------------------------------------------------------
if ! command -v git >/dev/null 2>&1; then
    echo "  SKIP worktree tests (git not on PATH)"
else
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
CHOPI_SAFEHOUSE_FLAGS=()
CHOPI_EXTRA_ENV=( PATH=/usr/bin:/bin:/usr/sbin:/sbin )
EOF

    chopi_wt() { ( cd "$gitrepo" && "$repo/bin/chopi" --worktree nested_wt2 --config "$cfg_wt" -- "$@" ); }

    workdir_wt="$(chopi_wt /bin/sh -c 'pwd' 2>/dev/null)"
    assert_eq "$workdir_wt" "$nested_wt2"                             "the command runs with the worktree as its workdir"

    chopi_wt /bin/sh -c 'echo HELLO > ./ws-file.txt' >/dev/null 2>&1 || true
    assert_eq "$(cat "$nested_wt2/ws-file.txt" 2>/dev/null)" "HELLO" \
                                                       "a write inside the worktree lands in the worktree"

    # The root repo's working tree is unreadable from the worktree.
    out="$(chopi_wt /bin/sh -c "cat '$root_only' && echo READ_OK || echo READ_FAIL" 2>/dev/null)"
    assert_not_contains "$out" "ROOT_ONLY_MARKER"      "the root repo's working files are NOT readable from the worktree"
    assert_contains     "$out" "READ_FAIL"             "  -> and that read fails"
    out="$(chopi_wt /bin/sh -c "stat -f '%z' '$root_only' >/dev/null 2>&1 && echo STAT_OK || echo STAT_FAIL" 2>/dev/null)"
    assert_contains     "$out" "STAT_FAIL"             "the root repo's file METADATA is not readable either"
    # ...and unwritable.
    chopi_wt /bin/sh -c "echo x > '$gitrepo_real/root-evil.txt'" >/dev/null 2>&1 || true
    assert_absent "$gitrepo_real/root-evil.txt" "a write into the root repo's working tree is denied"

    # A sibling worktree nested under the repo root is unreadable.
    out="$(chopi_wt /bin/sh -c "cat '$nested_wt/nested.txt' && echo READ_OK || echo READ_FAIL" 2>/dev/null)"
    assert_not_contains "$out" "NESTED_ONLY_MARKER"   "a sibling worktree's working files are NOT readable"
    assert_contains     "$out" "READ_FAIL"             "  -> and that read fails"
    # ...and unwritable.
    chopi_wt /bin/sh -c "echo x > '$nested_wt/nested-evil.txt'" >/dev/null 2>&1 || true
    assert_absent "$nested_wt/nested-evil.txt" "a write into a sibling worktree is denied"

    # An external worktree is unreadable too.
    out="$(chopi_wt /bin/sh -c "cat '$external_wt/ext.txt' && echo READ_OK || echo READ_FAIL" 2>/dev/null)"
    assert_not_contains "$out" "EXTERNAL_ONLY_MARKER"  "an external (outside-the-repo) worktree's files are NOT readable"
    assert_contains     "$out" "READ_FAIL"             "  -> and that read fails"
    # ...and unwritable.
    chopi_wt /bin/sh -c "echo x > '$external_wt/ext-evil.txt'" >/dev/null 2>&1 || true
    assert_absent "$external_wt/ext-evil.txt" "a write into an external worktree is denied"

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
    top="$(chopi_wt /usr/bin/git rev-parse --show-toplevel 2>/dev/null)"
    assert_eq "$top" "$nested_wt2"                     "git resolves the worktree as its toplevel"
    out="$(chopi_wt /bin/sh -c 'git tag chopi-probe && echo TAG_OK' 2>/dev/null)"
    assert_contains "$out" "TAG_OK"                    "git can write a ref into the shared .git from inside the sandbox"
    if git -C "$gitrepo" tag | grep -qx chopi-probe; then
        ok  "  -> and the tag really landed in the repo"
    else
        bad "  -> but the tag did not land in the repo"
    fi

    # Re-running the same NAME reuses the existing worktree rather than failing.
    out="$(chopi_wt /bin/sh -c 'echo REUSED' 2>/dev/null)"
    assert_eq "$out" "REUSED"                          "re-running --worktree reuses the existing worktree and runs there"

    # -- The shared .git is READABLE but code-execution paths are NOT WRITABLE ---------------
    config_before="$(cat "$shared_git/config")"

    chopi_wt /bin/sh -c "echo pwn > '$shared_git/hooks/post-checkout'" >/dev/null 2>&1 || true
    assert_absent "$shared_git/hooks/post-checkout" "planting a hook in the shared .git/hooks is denied (no file created)"

    # `git config` from the linked worktree targets the shared .git/config (no
    # extensions.worktreeConfig here), so it is denied and the file stays byte-identical.
    chopi_wt /usr/bin/git config core.hooksPath /tmp/evil >/dev/null 2>&1 || true

    # An [include]/[includeIf] path= in a pre-existing config could point at any of these;
    # leaving them writable would reopen the hole. All are under the default write-deny.
    chopi_wt /bin/sh -c "echo x > '$shared_git/config.local'"    >/dev/null 2>&1 || true
    chopi_wt /bin/sh -c "echo '* filter=evil' > '$shared_git/info/attributes'" >/dev/null 2>&1 || true
    for f in config.local info/attributes; do
        assert_absent "$shared_git/$f" "writing shared .git/$f is denied (no file created)"
    done

    # A sibling worktree's admin dir is denied
    chopi_wt /bin/sh -c "echo x > '$nested_wt_admin/config.worktree'" >/dev/null 2>&1 || true
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
    chopi_wt /bin/sh -c "echo 'gitdir: /tmp/evil-admin' > '$wt_dotgit'"   >/dev/null 2>&1 || true
    chopi_wt /bin/sh -c "echo '/tmp/evil-common' > '$wt_commondir'"       >/dev/null 2>&1 || true
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
        chopi_wt /bin/sh -c "echo 'gitdir: /tmp/evil' > '$sub_main_wt/.git'"    >/dev/null 2>&1 || true
        chopi_wt /bin/sh -c "printf '[core]\n' > '$sub_gitdir/config'"              >/dev/null 2>&1 || true
        chopi_wt /bin/sh -c "echo pwn > '$sub_gitdir/hooks/post-checkout'"          >/dev/null 2>&1 || true
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
    if git -C "$dummy_origin" rev-parse --verify --quiet refs/heads/nested_wt2 >/dev/null; then
        ok  "  -> and the branch landed in the origin"
    else
        bad "  -> but the branch did not land in the origin"
    fi

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
    rc=0; out="$(chopi_wt /usr/bin/git submodule update 2>&1 >/dev/null)" || rc=$?
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
    out="$(chopi_ep /usr/bin/git config chopi.hostpassed 2>/dev/null)"
    assert_eq "$out" "hostmarker"                      "a host GIT_CONFIG_* pair forwarded via safehouse --env-pass survives the append"
    out="$(chopi_ep /usr/bin/git config chopi.conflict 2>/dev/null)"
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
    ( cd "$gitrepo" && "$repo/bin/chopi" --worktree wtcfg --config "$wt_cfg" -- /bin/sh -c 'true' ) >/dev/null 2>&1 || true
    assert_eq "$(cat "$setup_marker" 2>/dev/null)" "wtcfg" \
        "a custom CHOPI_WORKTREE_SETUP command runs (unsandboxed) with CHOPI_WORKTREE_NAME set"

    # --worktree mode refuses a config without CHOPI_WORKTREE_SETUP
    st=0
    out="$(cd "$gitrepo" && "$repo/bin/chopi" --worktree wtnone --config "$cfg" -- /bin/sh -c 'true' 2>&1)" || st=$?
    assert_contains "$out" "CHOPI_WORKTREE_SETUP" "--worktree refuses a config without CHOPI_WORKTREE_SETUP"
    assert_nonzero "$st" "  -> and exits non-zero"
    assert_absent "$gitrepo/.worktrees/wtnone" "  -> and no worktree is created"
fi


# ---------------------------------------------------------------------------
summary

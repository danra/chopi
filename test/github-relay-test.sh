#!/usr/bin/env bash
#
# test/github-relay-test.sh -- manual end-to-end smoke test for the GitHub relay.
#
# NOT run by `make test`; it needs a repo you can push to to run fully, set in env
# as ALLOW_REPO=<owner/repo>
#
# It renders the relay config for a throwaway allowlist, starts caddy, and checks that:
#   1. anonymous public fetch works through the relay
#   1b. a gzipped fetch is decoded by GitHub
#   1c. fetch of a private/nonexistent repo fails with an informative error message
#   2. push to a non-allowlisted repo fails with an informative error message
#   2b. non-git requests still fail closed (403)
#   3. (opt) push/fetch authorized for allowlisted repo
#   3b. (opt) git-lfs push/fetch round-trips through the relay (the real blob survives)
#   4. a credential GitHub rejects fails with an informative error message

set -uo pipefail

_test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$_test_dir/../.internal/util.sh"
. "$_test_dir/lib.sh"

header "End-to-end GitHub relay test"

if ! command -v caddy >/dev/null 2>&1; then
    echo "  SKIP: caddy not installed (brew install caddy)"
    exit 0
fi

# The test's caddy must own the relay port itself: wait_for_listener cannot tell a foreign
# listener (a running chopi-proxy) from ours, and the probes would quietly test that instead.
if busy_port="$(first_listening_port "$GITHUB_RELAY_PORT")"; then
    echo "  SKIP: port $busy_port is already in use -- stop your running chopi-proxy first"
    exit 0
fi

RENDER="$CHOPI_DIR/.internal/github-relay-caddyfile.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/chopi-github-relay-test.XXXXXX")"
CADDY_PID=""
cleanup() { [ -n "$CADDY_PID" ] && kill "$CADDY_PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

# A denied git operation must fail, not hang on a credential prompt.
export GIT_TERMINAL_PROMPT=0

TOKEN="$(resolve_gh_token)"

if [ -n "${ALLOW_REPO:-}" ]; then
    if [ -z "$TOKEN" ]; then
        echo "  SKIP: ALLOW_REPO is set but no GitHub token is available (set GH_TOKEN or run 'gh auth login')."
        echo "        chopi-proxy refuses a populated allowlist without a token, so there is no config to smoke-test."
        exit 0
    fi
    printf '%s/*\n' "${ALLOW_REPO%%/*}" > "$WORK/allow"
else
    : > "$WORK/allow"
fi

caddy_cfg="$("$RENDER" "$WORK/allow")" || { bad "github-relay-caddyfile.sh failed"; summary; exit 1; }
if [[ "$caddy_cfg" == *@@CHOPI_AUTH@@* ]]; then
    caddy_cfg="${caddy_cfg//@@CHOPI_AUTH@@/$(gh_basic_auth_header "$TOKEN")}"
fi

if ! start_github_relay "$caddy_cfg" "$WORK/caddy.log"; then
    bad "caddy failed to start"; sed 's/^/      /' "$WORK/caddy.log"; summary; exit 1
fi

git_url="http://127.0.0.1:$GITHUB_RELAY_PORT"

# 1. anonymous public fetch through the relay
if git clone -q "$git_url/octocat/Hello-World" "$WORK/hw" 2>"$WORK/e1"; then
    ok "anonymous public fetch via relay (octocat/Hello-World)"
else
    bad "anonymous public fetch failed"; sed 's/^/      /' "$WORK/e1"
fi

# 1b. a gzipped fetch (upload-pack) request is decoded by GitHub
# Forced artificially here, but git does gzip large-enough request bodies
printf '0014command=ls-refs\n0017object-format=sha1\n00010000' | gzip -c > "$WORK/upload-pack.gz"
code="$(curl -s -o /dev/null -w '%{http_code}' \
    -H 'Content-Type: application/x-git-upload-pack-request' -H 'Accept: application/x-git-upload-pack-result' \
    -H 'Git-Protocol: version=2' -H 'Content-Encoding: gzip' \
    --data-binary "@$WORK/upload-pack.gz" "$git_url/octocat/Hello-World/git-upload-pack")"
if [ "$code" = "200" ]; then ok "gzipped upload-pack decoded (relay forwards Content-Encoding: gzip)"
else bad "gzipped upload-pack -> $code (relay dropped Content-Encoding: gzip)"; fi

# 1c. denied fetch (GitHub 401s anonymous ref discovery of nonexistent repos like private ones)
if git clone -q "$git_url/chopi-e2e-test/no-such-repo" "$WORK/denied" 2>"$WORK/e1c"; then
    bad "nonexistent-repo clone unexpectedly succeeded"
elif grep -q 'remote error: chopi: repo not found' "$WORK/e1c"; then
    ok "denied fetch shows an informative error message"
else
    bad "denied fetch shows the wrong error:"; sed 's/^/      /' "$WORK/e1c"
fi

# 2. non-allowlisted push denied with an informative error message
make_repo "$WORK/pushsrc"
if git -C "$WORK/pushsrc" push -q "$git_url/torvalds/linux" HEAD:refs/heads/chopi-e2e 2>"$WORK/e2"; then
    bad "non-allowlisted push unexpectedly succeeded (torvalds/linux)"
elif grep -q 'remote error: chopi: push denied' "$WORK/e2"; then
    ok "non-allowlisted push denied with an informative error message"
else
    bad "non-allowlisted push shows the wrong error:"; sed 's/^/      /' "$WORK/e2"
fi

# 2b. non-git requests still fail closed
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$git_url/torvalds/linux/git-receive-pack")"
if [ "$code" = "403" ]; then ok "non-git operation refused (bare receive-pack POST -> 403)"
else bad "non-git operation probe expected 403, got $code"; fi

# 3. optional: push/fetch authorized for allowlisted repo
if [ -n "${ALLOW_REPO:-}" ] && [ -n "$TOKEN" ]; then
    code="$(curl -s -o /dev/null -w '%{http_code}' "$git_url/$ALLOW_REPO/info/refs?service=git-receive-pack")"
    if [ "$code" = "200" ]; then ok "allowlisted push authorized ($ALLOW_REPO receive-pack -> 200)"
    else bad "allowlisted push on $ALLOW_REPO -> $code"; fi

    if git clone -q --depth 1 "$git_url/$ALLOW_REPO" "$WORK/allowed" 2>"$WORK/e4"; then
        ok "allowlisted fetch succeeded ($ALLOW_REPO)"
    else
        bad "allowlisted fetch failed"; sed 's/^/      /' "$WORK/e4"
    fi
else
    echo "  note: set ALLOW_REPO=owner/repo (with gh logged in) to exercise the authenticated push path"
fi

# 3b. optional: git-lfs push/fetch round-trips through the relay. Pushes a throwaway branch with a
# new LFS object to ALLOW_REPO, fetches it back in a fresh clone, and checks the real blob (not the
# pointer) survives -- exercising the relay's LFS batch API, the object upload/download, and the
# batch response's verify action. Content is unique per run so the upload (and its verify) runs
# every time; only the branch is deleted afterward. GitHub has no way to delete an individual LFS
# object, so each run leaves a ~20-byte object in the repo's LFS storage (negligible, but permanent
# short of recreating the repo).
if [ -n "${ALLOW_REPO:-}" ] && [ -n "$TOKEN" ] && command -v git-lfs >/dev/null 2>&1; then
    lfs_branch="chopi-e2e-lfs-$$"
    lfs_src="$WORK/lfs-src"
    git init -q "$lfs_src"
    git -C "$lfs_src" config user.email chopi-e2e@example.invalid
    git -C "$lfs_src" config user.name  chopi-e2e
    git -C "$lfs_src" lfs install --local >/dev/null 2>&1
    git -C "$lfs_src" lfs track '*.bin'   >/dev/null 2>&1
    lfs_blob="chopi-lfs-e2e-$$"
    printf '%s\n' "$lfs_blob" > "$lfs_src/data.bin"
    git -C "$lfs_src" add .gitattributes data.bin
    git -C "$lfs_src" commit -q -m "lfs e2e"

    if git -C "$lfs_src" push -q "$git_url/$ALLOW_REPO" "HEAD:refs/heads/$lfs_branch" 2>"$WORK/e-lfs-push"; then
        ok "git-lfs push of a new object to $ALLOW_REPO succeeded through the relay"

        if git clone -q --branch "$lfs_branch" --single-branch "$git_url/$ALLOW_REPO" "$WORK/lfs-clone" 2>"$WORK/e-lfs-clone" \
           && git -C "$WORK/lfs-clone" lfs pull >/dev/null 2>&1; then
            fetched="$(cat "$WORK/lfs-clone/data.bin" 2>/dev/null)"
            if [ "$fetched" = "$lfs_blob" ]; then
                ok "git-lfs fetch returned the real blob, not the pointer (relay LFS round-trip works)"
            else
                bad "git-lfs fetch returned the wrong content (pointer left un-smudged?):"
                sed 's/^/      /' "$WORK/lfs-clone/data.bin" 2>/dev/null
            fi
        else
            bad "git-lfs clone/pull of the pushed branch failed"; sed 's/^/      /' "$WORK/e-lfs-clone"
        fi

        git -C "$lfs_src" push -q "$git_url/$ALLOW_REPO" ":refs/heads/$lfs_branch" 2>/dev/null \
            || echo "  note: could not delete throwaway branch $lfs_branch on $ALLOW_REPO -- remove it manually"
    else
        bad "git-lfs push failed"; sed 's/^/      /' "$WORK/e-lfs-push"
    fi
elif [ -n "${ALLOW_REPO:-}" ] && [ -n "$TOKEN" ]; then
    echo "  note: install git-lfs to exercise the LFS push/fetch round-trip"
fi

# 4. credential rejected by GitHub: relaunch with an allowlist entry and a bogus token. Probe
# with operations GitHub can never serve anonymously (a push; a fetch of a nonexistent repo),
# so it must 401 the bogus credential rather than fall back to anonymous access.
kill "$CADDY_PID" 2>/dev/null; wait "$CADDY_PID" 2>/dev/null
printf 'octocat/*\n' > "$WORK/allow-bogus"
bogus_cfg="$("$RENDER" "$WORK/allow-bogus")"
bogus_cfg="${bogus_cfg//@@CHOPI_AUTH@@/Basic Ym9ndXM6Ym9ndXM=}"
if ! start_github_relay "$bogus_cfg" "$WORK/caddy-bogus.log"; then
    bad "caddy failed to restart for the rejected-credential test"; sed 's/^/      /' "$WORK/caddy-bogus.log"
else
    if git -C "$WORK/pushsrc" push -q "$git_url/octocat/Hello-World" HEAD:refs/heads/chopi-e2e 2>"$WORK/e5"; then
        bad "push with a rejected credential unexpectedly succeeded"
    elif grep -q 'remote error: chopi: GitHub rejected the relay credential' "$WORK/e5"; then
        ok "rejected credential on push shows an informative error message"
    else
        bad "rejected credential on push shows the wrong error:"; sed 's/^/      /' "$WORK/e5"
    fi

    if git clone -q "$git_url/octocat/no-such-repo-chopi-e2e" "$WORK/bogus" 2>"$WORK/e5c"; then
        bad "fetch with a rejected credential unexpectedly succeeded"
    elif grep -q 'remote error: chopi: GitHub rejected the relay credential' "$WORK/e5c"; then
        ok "rejected credential on fetch shows an informative error message"
    else
        bad "rejected credential on fetch shows the wrong error:"; sed 's/^/      /' "$WORK/e5c"
    fi
fi

summary

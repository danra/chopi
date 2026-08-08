#!/usr/bin/env bash
#
# test/github-relay-test.sh -- manual end-to-end smoke test for the GitHub relay.
#
# NOT run by `make test`; it needs a repo you can push to to run fully, set in env
# as ALLOW_REPO=<owner/repo>
#
# It renders the relay config for a throwaway allowlist, starts caddy, and checks that:
#   0. the relay listens on loopback only                          (not on all interfaces)
#   1. anonymous public fetch works through the relay
#   1b. a gzipped fetch is decoded by GitHub
#   1c. fetch of a private/nonexistent repo fails with an informative error message
#   2. push to a non-allowlisted repo fails with an informative error message
#   2b. non-git requests still fail closed (403), with a deny message git displays
#   3. (opt) push/fetch authorized for allowlisted repo
#   3b. (opt) git-lfs push/fetch round-trips through the relay (the real blob survives)
#   4a. gh's anonymous API read works and leaks no token to a non-allowlisted repo
#   4b. GraphQL is refused, and gh displays the deny             (not path-scopable -> fail closed)
#   4c. account-level endpoints are refused                      (fail closed)
#   4d. (opt) an allowlisted repo's gh read is authenticated     (injected Bearer token)
#   4e. absolute api.github.com URLs route like api.github.localhost  (gh follows them on the socket)
#   4f. signed-storage GETs are proxied anonymously to GitHub's storage hosts
#   4g. an unmatched Host on the API socket fails loudly              (not Caddy's empty-200 default)
#   4h. an anonymous authed-only API operation is refused with a message naming the allowlist
#   4i. (opt) a real Actions job log: API -> redirect -> signed storage, all over the one socket
#   4j. id-form /repositories/{id} URLs are served anonymously  (pagination Links, renamed-repo redirects)
#   4k. (opt) an allowlisted repo's pagination Links keep naming the repo  (page 2 stays authenticated)
#   4l. a losing concurrent double-start leaves the winner's live socket untouched
#   4m. (opt) a release with an asset: gh POSTs the asset to uploads.github.com (the API's
#       upload_url host) over the same socket, and the relay serves it authed
#   5. a credential GitHub rejects fails with an informative error message (git, API, and
#      uploads), and a dot-segment traversal cannot carry the credential past the allowlist

set -uo pipefail

_test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# A private TMPDIR, exported so the processes under test leave their temporaries here too. Created
# before sourcing util.sh, which derives GH_RELAY_SOCK from it, so the socket this test creates and
# removes is its own. Trap it now so an early skip still cleans up (the fuller trap, which also kills
# caddy, comes after the skip guards).
TMPDIR="$(mktemp -d)"; export TMPDIR
trap 'rm -rf "$TMPDIR"' EXIT

. "$_test_dir/../.internal/util.sh"
. "$_test_dir/lib.sh"

header "End-to-end GitHub relay test"

if ! command -v caddy >/dev/null 2>&1; then
    echo "  SKIP: caddy not installed (brew install caddy)"
    exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
    echo "  SKIP: gh not installed (brew install gh) -- the API checks drive the real gh binary"
    exit 0
fi

# The test's caddy must own the relay port itself: wait_for_listener cannot tell a foreign
# listener (a running chopi-proxy) from ours, and the probes would quietly test that instead.
if busy_port="$(first_listening_port "$GITHUB_RELAY_PORT")"; then
    echo "  SKIP: port $busy_port is already in use -- stop your running chopi-proxy first"
    exit 0
fi

RENDER="$CHOPI_DIR/.internal/github-relays-caddyfile.sh"
WORK="$(mktemp -d "$TMPDIR/chopi-github-relay-test.XXXXXX")"
CADDY_PID=""
cleanup() { [ -n "$CADDY_PID" ] && kill "$CADDY_PID" 2>/dev/null; rm -rf "$TMPDIR"; }
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

caddy_cfg="$("$RENDER" "$WORK/allow")" || { bad "github-relays-caddyfile.sh failed"; summary; exit 1; }
if [[ "$caddy_cfg" == *@@CHOPI_AUTH@@* ]]; then
    caddy_cfg="${caddy_cfg//@@CHOPI_AUTH@@/$(gh_basic_auth_header "$TOKEN")}"
    caddy_cfg="${caddy_cfg//@@CHOPI_API_AUTH@@/$(gh_bearer_auth_header "$TOKEN")}"
fi

if ! start_github_relay "$caddy_cfg" "$WORK/caddy.log"; then
    bad "caddy failed to start"; sed 's/^/      /' "$WORK/caddy.log"; summary; exit 1
fi

git_url="http://127.0.0.1:$GITHUB_RELAY_PORT"

# 0. the relay must listen on loopback only: a caddy site-address host is a Host matcher,
#    not a bind, so without an explicit bind caddy listens on all interfaces -- where a LAN
#    client sending "Host: 127.0.0.1" reaches the credentialed routes.
listeners="$(lsof -a -p "$CADDY_PID" -iTCP -sTCP:LISTEN -P -n | awk 'NR>1 {print $9}')"
assert_contains     "$listeners" "127.0.0.1:$GITHUB_RELAY_PORT" "git relay listener is bound to loopback"
assert_not_contains "$listeners" '*:'                           "no relay listener on the wildcard interface"

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
assert_eq "$code" "200" "gzipped upload-pack decoded (relay forwards Content-Encoding: gzip)"

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

# 2b. non-git requests still fail closed -- and readably: git relays a text/plain error body
#     as a "remote:" line, so the deny's usefulness rides on its content type and body.
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$git_url/torvalds/linux/git-receive-pack")"
assert_eq "$code" "403" "non-git operation refused (bare receive-pack POST)"
curl -s -D "$WORK/deny-h" -o "$WORK/deny-b" -X POST "$git_url/torvalds/linux/git-receive-pack"
assert_contains "$(cat "$WORK/deny-h")" 'Content-Type: text/plain' "git deny rides the text/plain remote-message channel"
assert_contains "$(cat "$WORK/deny-b")" 'chopi GitHub relay: not an allowed git operation' "git deny body names the refusal"
if git ls-remote "$git_url/a/b/c" >/dev/null 2>"$WORK/e2b"; then
    bad "out-of-contract ls-remote unexpectedly succeeded"
elif grep -q 'remote: chopi GitHub relay: not an allowed git operation' "$WORK/e2b"; then
    ok "catch-all deny is displayed by git as a remote: line"
else
    bad "catch-all deny not surfaced by git:"; sed 's/^/      /' "$WORK/e2b"
fi

# 3. optional: push/fetch authorized for allowlisted repo
if [ -n "${ALLOW_REPO:-}" ] && [ -n "$TOKEN" ]; then
    code="$(curl -s -o /dev/null -w '%{http_code}' "$git_url/$ALLOW_REPO/info/refs?service=git-receive-pack")"
    assert_eq "$code" "200" "allowlisted push authorized ($ALLOW_REPO receive-pack)"

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

# ---- API relay (unix socket) ----
# The API checks drive the real gh binary through the exact wiring bin/chopi.sh hands the
# sandboxed command (github_relay_gh_env), so the config key, the socket dial, and the host
# derivation are all pinned by gh itself.
mkdir -p "$WORK/gh-config"
readarray -t gh_env < <(github_relay_gh_env "$WORK/gh-config")
gh_relay() { env "${gh_env[@]}" gh "$@"; }

# curl fills in for gh to test forged Hosts, unclean paths, bogus storage blobs etc.
api_url="http://api.github.localhost"
# api_code [curl-opts...] URL -- HTTP code of a request over the API-relay socket
api_code() { curl -s -o /dev/null -w '%{http_code}' --unix-socket "$GH_RELAY_SOCK" "$@"; }
# api_body HDRS BODY [curl-opts...] URL -- request over the socket, saving headers and body
api_body() { local hdrs="$1" body="$2"; shift 2; curl -s -D "$hdrs" -o "$body" --unix-socket "$GH_RELAY_SOCK" "$@"; }

# 4a. anonymous API read is driven by gh and no token leaks to a non-allowlisted repo.
#     torvalds/linux isn't allowlisted, so the relay must wipe gh's placeholder Authorization
#     and send the request anonymous: GitHub's 60/hr anonymous rate tier (vs 5000/hr
#     authenticated) makes the x-ratelimit-limit header a "was a token injected?" tell.
if gh_relay api -i repos/torvalds/linux > "$WORK/gh_pub" 2>"$WORK/gh_pub_err"; then
    limit="$(grep -i '^x-ratelimit-limit:' "$WORK/gh_pub" | tr -dc '0-9')"
    if [ -n "$limit" ] && [ "$limit" -le 100 ]; then
        ok "gh api read via relay, no token leaked (torvalds/linux, rate-limit $limit)"
    else
        bad "gh api read expected the anonymous rate limit, got limit=${limit:-none}"
    fi
else
    bad "gh api repos/torvalds/linux failed through the relay:"; sed 's/^/      /' "$WORK/gh_pub_err"
fi

# 4b. GraphQL is refused: its repo lives in the POST body, not the path, so it can't be scoped
#     here.
if gh_relay api graphql -f query='{viewer{login}}' >/dev/null 2>"$WORK/gh_gql_err"; then
    bad "gh api graphql unexpectedly succeeded"
else
    assert_contains "$(cat "$WORK/gh_gql_err")" 'chopi GitHub relay: not an allowed API operation' "GraphQL refused, and gh displays the relay's deny message"
    assert_contains "$(cat "$WORK/gh_gql_err")" 'HTTP 403' "  -> as the relay's own 403"
fi

# 4c. account-level endpoints are refused.
if gh_relay api user >/dev/null 2>"$WORK/gh_user_err"; then
    bad "gh api user unexpectedly succeeded"
else
    assert_contains "$(cat "$WORK/gh_user_err")" 'not an allowed API operation' "account endpoint refused (gh api user)"
fi

# 4d. optional: an allowlisted repo's gh read carries the injected token (authed rate tier proves it)
if [ -n "${ALLOW_REPO:-}" ] && [ -n "$TOKEN" ]; then
    if gh_relay api -i "repos/$ALLOW_REPO" > "$WORK/gh_auth" 2>"$WORK/gh_auth_err"; then
        limit="$(grep -i '^x-ratelimit-limit:' "$WORK/gh_auth" | tr -dc '0-9')"
        if [ -n "$limit" ] && [ "$limit" -gt 100 ]; then
            ok "allowlisted gh api read authenticated ($ALLOW_REPO, rate-limit $limit = token injected)"
        else
            bad "allowlisted gh api read on $ALLOW_REPO got limit=${limit:-none} (want the authenticated rate limit)"
        fi
    else
        bad "gh api repos/$ALLOW_REPO failed:"; sed 's/^/      /' "$WORK/gh_auth_err"
    fi
else
    echo "  note: set ALLOW_REPO=owner/repo (with gh logged in) to exercise the injected-token API path"
fi

# 4e. gh follows absolute api.github.com URLs it finds in response bodies (jobs_url,
#     pagination) over this same socket. That Host must route like api.github.localhost, not fall back
#     to Caddy's unmatched-host empty 200.
code="$(api_code "http://api.github.com/repos/torvalds/linux")"
assert_eq "$code" "200" "Host api.github.com routes like api.github.localhost (absolute-URL follows)"

# 4f. Actions logs/artifacts: the API answers 303 with a signed URL on GitHub's storage;
#     gh follows it over the socket too. A bogus path gets the storage host's own 4xx.
code="$(api_code "http://productionresultssa10.blob.core.windows.net/chopi-e2e-no-such-blob")"
if [ "$code" -ge 400 ] && [ "$code" -lt 500 ]; then
    ok "signed-storage GET is proxied to the real storage host (bogus blob -> $code)"
else
    bad "signed-storage GET expected the storage host's own 4xx, got '$code'"
fi

# 4g. any other Host on the socket dead-ends loudly.
api_body "$WORK/h_evil" "$WORK/b_evil" "http://evil.example.com/x"
assert_contains "$(head -1 "$WORK/h_evil")" ' 421 ' "unmatched Host on the API socket is refused loudly (421)"
assert_contains "$(cat "$WORK/b_evil")" '"message":"chopi GitHub relay: unsupported host evil.example.com"' "unmatched-host deny is a JSON message naming the host"

# 4h. an anonymous authed-only operation (a write, here) is 401ed by GitHub; the relay converts
#     the raw "Requires authentication" to a message naming the allowlist.
api_body "$WORK/h_anonw" "$WORK/b_anonw" -X POST "$api_url/repos/torvalds/linux/issues"
assert_contains "$(head -1 "$WORK/h_anonw")" ' 401 ' "anonymous write is refused (401)"
assert_contains "$(cat "$WORK/b_anonw")" 'relay authenticates only repos in' "anonymous-write deny names the allowlist"

# 4i. the chain behind `gh run view --log`, walked for real: a run's jobs_url is an absolute
#     api.github.com URL, the job-log endpoint answers a redirect, and the signed URL it points at
#     is fetched back over the same socket. Only a completed run: a queued/running one already
#     answers the redirect before the log blob exists on storage, and the follow 404s.
if [ -n "${ALLOW_REPO:-}" ] && [ -n "$TOKEN" ]; then
    api_body "$WORK/h_runs" "$WORK/b_runs" "$api_url/repos/$ALLOW_REPO/actions/runs?status=completed&per_page=1"
    jobs_url="$(jq -r '.workflow_runs[0].jobs_url // empty' "$WORK/b_runs" 2>/dev/null)"
    if [ -z "$jobs_url" ]; then
        echo "  note: $ALLOW_REPO has no completed Actions runs -- skipping the Actions log chain"
    else
        # curl cannot copy gh's trick of speaking https URLs in cleartext down the socket, so only
        # the scheme is rewritten; the Host the relay routes on stays api.github.com.
        api_body "$WORK/h_jobs" "$WORK/b_jobs" "http://${jobs_url#https://}"
        assert_contains "$(head -1 "$WORK/h_jobs")" ' 200 ' "actions: a run's absolute jobs_url is served over the socket"
        job_id="$(jq -r '.jobs[0].id // empty' "$WORK/b_jobs" 2>/dev/null)"
        api_body "$WORK/h_log" "$WORK/b_log" "$api_url/repos/$ALLOW_REPO/actions/jobs/$job_id/logs"
        log_loc="$(grep -i '^location:' "$WORK/h_log" | tr -d '\r' | sed -E 's/^[^:]+:[[:space:]]*//')"
        if [ -z "$log_loc" ]; then
            # logs age out well before the run record does, so an old run is a skip, not a failure
            echo "  note: job $job_id has no log redirect ($(head -1 "$WORK/h_log" | tr -d '\r')) -- skipping the storage follow"
        else
            log_path="${log_loc#https://}"; log_path="${log_path#http://}"
            log_host="${log_path%%/*}"
            storage_re="$(printf '%s\n' "$caddy_cfg" | grep -E 'header_regexp storagehost Host ' | sed -E 's/.*Host //')"
            if printf '%s\n' "$log_host" | grep -qE "$storage_re"; then
                ok "actions: job logs redirect to a host the storage lane serves ($log_host)"
            else
                bad "actions: GitHub redirects job logs to $log_host, which the storage lane does not list"
            fi
            api_body "$WORK/h_store" "$WORK/b_store" "http://$log_path"
            store_status="$(head -1 "$WORK/h_store" | tr -d '\r')"
            if [[ "$store_status" == *' 200 '* ]]; then
                ok "actions: the signed log URL fetches back through the storage lane"
            else
                # the storage host's error body names the cause (BlobNotFound vs. an auth 404)
                bad "actions: the signed log URL fetch came back '$store_status'; the storage host says:"
                sed 's/^/      /' "$WORK/b_store"
            fi
        fi
    fi
fi

# 4j. GitHub emits id-form /repositories/{id} URLs -- pagination Link headers and renamed-repo
#     redirects point there -- and gh follows them over the same socket. The numeric id cannot be
#     matched to the allowlist, so they must be served anonymously: 200 for public data, and
#     never the token.
api_body "$WORK/h_repo" "$WORK/b_repo" "$api_url/repos/octocat/Hello-World"
repo_id="$(grep -m1 '"id":' "$WORK/b_repo" | tr -dc '0-9')"
code="$(api_code -D "$WORK/h_id" "$api_url/repositories/$repo_id")"
limit="$(grep -i '^x-ratelimit-limit:' "$WORK/h_id" | tr -dc '0-9')"
if [ "$code" = "200" ] && [ -n "$limit" ] && [ "$limit" -le 100 ]; then
    ok "id-form URL served anonymously (/repositories/$repo_id -> 200, rate-limit $limit)"
else
    bad "id-form /repositories/$repo_id expected 200 + anon rate limit, got code=$code limit=${limit:-none}"
fi

# 4k. an allowlisted repo's pagination must stay authenticated: GitHub's Link headers point at
#     id-form URLs, which only the anonymous lane serves -- where a private repo 404s. gh follows
#     the Link verbatim, so the relay must hand it back in the /repos/{owner}/{repo} form.
if [ -n "${ALLOW_REPO:-}" ] && [ -n "$TOKEN" ]; then
    api_body "$WORK/h_page" "$WORK/b_page" "$api_url/repos/$ALLOW_REPO/commits?per_page=1"
    page_link="$(grep -i '^link:' "$WORK/h_page" | tr -d '\r')"
    if [ -z "$page_link" ]; then
        echo "  note: $ALLOW_REPO has a single commit -- no Link header to check the pagination rewrite on"
    else
        assert_contains     "$page_link" "/repos/$ALLOW_REPO/commits" "allowlisted pagination Link keeps naming the repo"
        assert_not_contains "$page_link" '/repositories/'             "  -> no id-form URL in the Link (it would paginate anonymously)"
    fi
fi

# 4l. concurrent double-start: two chopi-proxys can both pass the busy-port check before either
#     binds, so this is the losing proxy's exact code path. It must fail without touching the
#     winner's live API socket -- unlinking it leaves the surviving proxy holding the port while
#     gh can no longer reach the relay. This test only pins the behavior when a one of two racing
#     proxies successfully bound the port before the second one tries to do so: as long as
#     start_github_relay is not atomic (it currently isn't), there is still a very short window
#     where both proxies bind concurrently and the race can trigger.
if ( start_github_relay "$caddy_cfg" "$WORK/caddy-loser.log" ) 2>"$WORK/e4l"; then
    bad "double-start: the losing start_github_relay unexpectedly reported success"
else
    ok "double-start: the losing start_github_relay fails"
fi
if [ -S "$GH_RELAY_SOCK" ]; then
    ok "double-start: the winner's API socket file survives"
else
    bad "double-start: the winner's API socket file is gone"
fi
code="$(api_code "$api_url/repos/octocat/Hello-World")"
if [ "$code" != "000" ]; then
    ok "double-start: the winner still answers on its API socket (HTTP $code)"
else
    bad "double-start: the winner's API socket no longer answers"
fi

# 4m. optional: a release with an asset. gh creates the release via the REST route, then POSTs
#     the asset to uploads.github.com -- the upload_url host in the API's release response --
#     over the same socket, so the relay must serve that Host authed too. A draft release keeps
#     the repo clean (no tag is created); it is deleted afterward either way.
if [ -n "${ALLOW_REPO:-}" ] && [ -n "$TOKEN" ]; then
    rel_tag="chopi-e2e-rel-$$"
    printf 'chopi release-asset e2e %s\n' "$$" > "$WORK/asset.txt"
    create_ok=""
    if gh_relay release create "$rel_tag" --repo "$ALLOW_REPO" --draft --notes "chopi e2e" \
        "$WORK/asset.txt" >/dev/null 2>"$WORK/e4m"; then
        ok "release created with an asset through the relay ($ALLOW_REPO)"
        create_ok=1
    else
        bad "release create with an asset failed through the relay:"; sed 's/^/      /' "$WORK/e4m"
    fi
    # Verify and clean up via gh api by release id: a draft's pending tag is invisible to REST
    # (releases/tags/{tag} only finds published releases), so the porcelain release view/delete
    # commands fall back to a GraphQL lookup, which the relay denies. Look the id up even after
    # a failed create, which can leave a half-made release behind. The list can lag a
    # just-created draft by a few seconds, so retry briefly.
    rel_id=""
    for attempt in 1 2 3 4 5; do
        [ "$attempt" -gt 1 ] && sleep 3
        rel_id="$(gh_relay api "repos/$ALLOW_REPO/releases" -q ".[] | select(.tag_name == \"$rel_tag\") | .id" 2>"$WORK/e4m_list")"
        [ -n "$rel_id" ] && break
    done
    if [ -n "$create_ok" ]; then
        if [ -n "$rel_id" ]; then
            assets="$(gh_relay api "repos/$ALLOW_REPO/releases/$rel_id" -q '.assets[].name' 2>/dev/null)"
            assert_contains "$assets" "asset.txt" "  -> the uploaded asset is listed on the release"
        else
            bad "created draft release $rel_tag is missing from the releases list even after retries:"; sed 's/^/      /' "$WORK/e4m_list"
        fi
    fi
    if [ -n "$rel_id" ]; then
        gh_relay api -X DELETE "repos/$ALLOW_REPO/releases/$rel_id" >/dev/null 2>&1 \
            || echo "  note: could not delete draft release $rel_tag (id $rel_id) on $ALLOW_REPO -- remove it manually"
    fi
fi

# 5. credential rejected by GitHub: relaunch with an allowlist entry and a bogus token. Probe
# with operations GitHub can never serve anonymously (a push; a fetch of a nonexistent repo),
# so it must 401 the bogus credential rather than fall back to anonymous access.
kill "$CADDY_PID" 2>/dev/null; wait "$CADDY_PID" 2>/dev/null
printf 'octocat/*\n' > "$WORK/allow-bogus"
bogus_cfg="$("$RENDER" "$WORK/allow-bogus")"
bogus_cfg="${bogus_cfg//@@CHOPI_AUTH@@/Basic Ym9ndXM6Ym9ndXM=}"
bogus_cfg="${bogus_cfg//@@CHOPI_API_AUTH@@/Bearer bogus}"
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

    # GitHub's API validates a presented credential even on an anonymously-readable endpoint,
    # so a public repo read suffices here.
    api_body "$WORK/h_api5" "$WORK/b_api5" "$api_url/repos/octocat/Hello-World"
    assert_contains "$(head -1 "$WORK/h_api5")" ' 401 ' "rejected credential on the API stays a 401"
    assert_contains "$(cat "$WORK/b_api5")" 'GitHub rejected the relay credential' "rejected credential on the API shows an informative error message"

    # The @api_allowed matcher (^/repos/(allowlist)(/.*)?$) accepts arbitrary trailing segments,
    # so it scopes the injected credential to the allowlist ONLY as long as Caddy cleans dot
    # segments before matching. The bogus credential makes the leak visible without a real token:
    # cleaned, the traversal escapes the allowlist and gets the relay's own 403; uncleaned, it
    # would match the allowed route, carry the credential upstream, and come back as GitHub's 401.
    code="$(api_code --path-as-is "$api_url/repos/octocat/x/../../../user")"
    assert_eq "$code" "403" "dot-segment traversal is cleaned before credential scoping (no leak past the allowlist)"

    # The uploads.github.com site scopes the credential by the same path-allowlist. GitHub's
    # uploads host validates Content-Type before auth, so the probe sends a typed dummy body to
    # reach the auth check; its 401 must convert to the rejected-credential remedy. (This pins
    # the route and the conversion; that the credential really rides it is 4m's job, since an
    # upload only ever succeeds authed.) A non-allowlisted path and a traversal must be refused
    # by the relay itself.
    up_url="http://uploads.github.com"
    api_body "$WORK/h_up5" "$WORK/b_up5" -H 'Content-Type: application/octet-stream' \
        --data-binary 'x' "$up_url/repos/octocat/Hello-World/releases/1/assets?name=x"
    assert_contains "$(head -1 "$WORK/h_up5")" ' 401 ' "rejected credential on an allowlisted asset upload stays a 401"
    assert_contains "$(cat "$WORK/b_up5")" 'GitHub rejected the relay credential' "  -> and shows the informative message"

    api_body "$WORK/h_up5n" "$WORK/b_up5n" -X POST "$up_url/repos/torvalds/linux/releases/1/assets?name=x"
    assert_contains "$(cat "$WORK/b_up5n")" 'relay authenticates only repos in' "non-allowlisted asset upload is refused naming the allowlist"

    api_body "$WORK/h_up5t" "$WORK/b_up5t" --path-as-is -X POST "$up_url/repos/octocat/x/../../../user"
    assert_contains     "$(cat "$WORK/b_up5t")" 'relay authenticates only repos in' "uploads dot-segment traversal is cleaned before credential scoping"
    assert_not_contains "$(cat "$WORK/b_up5t")" 'rejected the relay credential'     "  -> no credential carried past the uploads allowlist"
fi

summary

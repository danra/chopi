#!/usr/bin/env bash
#
# test/github-relays-caddyfile.sh -- unit tests for the GitHub relays config generator.
#
# Assert the generated Caddyfile structure and that the path matchers accept/reject the right paths.

set -uo pipefail

_test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$_test_dir/../.internal/util.sh"
. "$_test_dir/lib.sh"

RENDER="$CHOPI_DIR/.internal/github-relays-caddyfile.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/chopi-github-relay.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

render() { printf '%s\n' "$@" > "$WORK/allow"; "$RENDER" "$WORK/allow"; }

# extract_re FILE MATCHER -- the regex from a "@MATCHER path_regexp <re>" line
extract_re() { arity 2; grep -E "@$2 path_regexp " "$1" | sed -E 's/.*path_regexp //'; }

# re_match RE PATH -- does PATH match RE? Models Caddy's Go regexps with grep -E; a leading
# (?i) -- Go's whole-pattern case-insensitivity -- maps to grep -i.
re_match() {
    arity 2
    local re="$1" path="$2"
    local grep_flags=-qE
    case "$re" in
        "(?i)"*) re="${re#"(?i)"}"; grep_flags=-qiE ;;
    esac
    printf '%s\n' "$path" | grep "$grep_flags" "$re"
}
assert_match()    { arity 3; if re_match "$1" "$2"; then ok "$3"; else bad "$3"; fi; }
assert_no_match() { arity 3; if re_match "$1" "$2"; then bad "$3"; else ok "$3"; fi; }

header "github-relays-caddyfile"

# ---- a populated allowlist: a wildcard owner, an exact repo, an exact repo with a dot ----
cf="$WORK/populated"
render 'soundradix/*' 'acme/tool' 'acme/tool.js' > "$cf"

echo "-- structure --"
assert_contains "$(cat "$cf")" "http://127.0.0.1:$GITHUB_RELAY_PORT"  "GitHub relay listens on GITHUB_RELAY_PORT"
assert_contains "$(cat "$cf")" 'bind 127.0.0.1'         "git listener binds loopback explicitly"
assert_contains "$(cat "$cf")" '@@CHOPI_AUTH@@'         "git route carries the credential slot (caller-filled)"
assert_contains "$(cat "$cf")" 'acme/tool\.js'          "dots in repo names are regex-escaped"

git_re="$(extract_re "$cf" allowed)"

echo "-- git @allowed matcher (match => proxied WITH the token; push only reaches here) --"
assert_match    "$git_re" '/soundradix/anything/git-receive-pack'       "wildcard: push allowed"
assert_match    "$git_re" '/soundradix/anything/git-upload-pack'        "wildcard: fetch allowed"
assert_match    "$git_re" '/soundradix/anything/info/refs'              "wildcard: ref discovery allowed"
assert_match    "$git_re" '/acme/tool/git-receive-pack'                 "exact: push allowed"
assert_match    "$git_re" '/acme/tool.git/git-receive-pack'             "exact: .git suffix allowed"
assert_match    "$git_re" '/Acme/Tool/git-receive-pack'                 "exact: case-mismatched slug allowed (GitHub slugs are case-insensitive)"
assert_match    "$git_re" '/SOUNDRADIX/anything/info/refs'              "wildcard: case-mismatched owner allowed"
assert_match    "$git_re" '/soundradix/anything/info/lfs/objects/batch' "wildcard: Git-LFS API allowed"
assert_match    "$git_re" '/acme/tool.git/info/lfs/locks'               "exact: Git-LFS locks API allowed"
assert_no_match "$git_re" '/evil/repo/git-receive-pack'                 "non-allowlisted push refused"
assert_no_match "$git_re" '/evil/repo/info/lfs/objects/batch'           "non-allowlisted LFS not on the credentialed route"
assert_no_match "$git_re" '/acme/tool2/git-receive-pack'                "similar name refused"
assert_no_match "$git_re" '/acme/toolXjs/git-receive-pack'              "escaped dot: X is not . (refused)"
assert_no_match "$git_re" '/soundradix/a/b/git-receive-pack'            "extra path segment refused"

echo "-- anonymous LFS download routing (public LFS batch reaches non-allowlisted repos) --"
pub_lfs_re="$(grep -E 'path_regexp .*info/lfs/objects/batch' "$cf" | sed -E 's/.*path_regexp //')"
assert_match    "$pub_lfs_re" '/evil/repo/info/lfs/objects/batch' "non-allowlisted LFS batch is anonymously routed"
assert_match    "$pub_lfs_re" '/o/r.git/info/lfs/objects/batch'   ".git suffix is anonymously routed"
assert_no_match "$pub_lfs_re" '/evil/repo/info/lfs/locks'         "non-batch LFS (locks) not anonymously routed"

echo "-- credential scoping: the token reaches ONLY the @allowed route (SECURITY INVARIANT) --"
allowed_block="$(awk '/@allowed path_regexp/{f=1} /@pub_refs/{f=0} f' "$cf")"
pub_block="$(awk '/@pub_refs/{f=1} /^# GitHub git site end/{f=0} f' "$cf")"

assert_contains     "$allowed_block" 'Authorization "@@CHOPI_AUTH@@"' "@allowed injects the credential"
assert_not_contains "$pub_block"     '@@CHOPI_AUTH@@'                 "no anonymous @pub route carries the credential slot"
assert_not_contains "$pub_block"     'header_up Authorization'        "  -> nor sets any credential-bearing Authorization header"
auth_count="$(grep -c 'header_up Authorization' "$cf")"
assert_eq "$auth_count" 3 "credential headers are injected in exactly three places (git @allowed, API @api_allowed, uploads @uploads_allowed)"
# The filled credential holds a space ("Basic ...", "Bearer ..."), and Caddy parses an unquoted
# spaced header_up value as its 3-arg find-replace form: the config validates and the relay starts
# cleanly, but the route sends no credential at all. Only this render-level check pins the quoting.
bare_auth="$(grep 'header_up Authorization' "$cf" | grep -vE '"@@CHOPI_(API_)?AUTH@@"$')"
assert_eq "$bare_auth" "" "every credential injection quotes its slot (unquoted would silently send no credential)"

ghproxy_block="$(awk '/^\(ghproxy\)/{f=1} f{print; if (/^}/) exit}' "$cf")"
assert_contains "$ghproxy_block" 'header_up -*'   "(ghproxy) wipes inbound headers (header_up -*)"
assert_contains "$ghproxy_block" 'import githdrs' "(ghproxy) re-adds the githdrs header set"
total_proxies="$(grep -c 'reverse_proxy https://github.com' "$cf")"
assert_eq "$total_proxies" 1 "(ghproxy) is the only reverse_proxy (no route proxies around the wipe)"

assert_contains     "$allowed_block" 'git-receive-pack' "push (git-receive-pack) is proxied on the @allowed route"
pub_imports="$(printf '%s\n' "$pub_block" | grep -cE 'import (redirecting_)?ghproxy')"
assert_eq "$pub_imports" 2 "anonymous routes proxy only fetch + LFS batch (push is never proxied)"

echo "-- API listener structure --"
assert_contains "$(cat "$cf")" 'bind "unix/@@CHOPI_GH_SOCK@@"'        "API relay binds the socket-path slot (caller-filled)"
api_site="$(grep -E '^http://api\.' "$cf")"
assert_contains "$api_site"    'http://api.github.localhost'          "API relay serves api.github.localhost"
assert_contains "$api_site"    'http://api.github.com'                "API relay serves Host api.github.com too (gh follows absolute response-body URLs over the socket)"
assert_contains "$(cat "$cf")" 'import apiproxy api.github.com'       "API routes proxy through (apiproxy) to api.github.com"
assert_contains "$(cat "$cf")" '@@CHOPI_API_AUTH@@'                   "API route carries the credential slot (caller-filled)"

api_re="$(extract_re "$cf" api_allowed)"

echo "-- API @api_allowed matcher (match => proxied WITH the token; authed API only reaches here) --"
assert_match    "$api_re" '/repos/soundradix/anything'        "wildcard: repo root allowed"
assert_match    "$api_re" '/repos/soundradix/anything/issues' "wildcard: subresource allowed"
assert_match    "$api_re" '/repos/acme/tool/pulls/1'          "exact: subresource allowed"
assert_match    "$api_re" '/repos/Acme/Tool/pulls/1'          "exact: case-mismatched slug allowed (GitHub slugs are case-insensitive)"
assert_match    "$api_re" '/repos/SOUNDRADIX/anything'        "wildcard: case-mismatched owner allowed"
assert_no_match "$api_re" '/repos/evil/repo/contents/x'       "non-allowlisted repo refused"
assert_no_match "$api_re" '/repos/acme/tool2/issues'          "similar name refused"
assert_no_match "$api_re" '/graphql'                          "graphql not on the authed route (denied)"
assert_no_match "$api_re" '/user'                             "account endpoint not on the authed route (denied)"
assert_no_match "$api_re" '/gists'                            "gists not on the authed route (denied)"

# Actions is repo-scoped throughout, so gh's run/workflow commands reach the credentialed route.
# Logs and artifacts answer with a redirect onward to signed storage, served by the lane below.
assert_match    "$api_re" '/repos/acme/tool/actions/runs'                        "actions: gh run list"
assert_match    "$api_re" '/repos/acme/tool/actions/runs/12345'                  "actions: gh run view"
assert_match    "$api_re" '/repos/acme/tool/actions/runs/12345/jobs'             "actions: a run's jobs"
assert_match    "$api_re" '/repos/acme/tool/actions/runs/12345/logs'             "actions: whole-run log archive"
assert_match    "$api_re" '/repos/acme/tool/actions/jobs/67890/logs'             "actions: gh run view --log (one job)"
assert_match    "$api_re" '/repos/acme/tool/actions/artifacts/42/zip'            "actions: gh run download"
assert_match    "$api_re" '/repos/acme/tool/actions/runs/12345/rerun'            "actions: gh run rerun"
assert_match    "$api_re" '/repos/acme/tool/actions/workflows/ci.yml/dispatches' "actions: gh workflow run (dotted workflow file)"
assert_match    "$api_re" '/repos/soundradix/anything/actions/runs'              "actions: reached through a wildcard owner too"

# the rest of the routine gh surface
assert_match    "$api_re" '/repos/acme/tool/commits/abc123/check-runs' "checks: gh pr checks"
assert_match    "$api_re" '/repos/acme/tool/commits/abc123/status'     "checks: combined commit status"
assert_match    "$api_re" '/repos/acme/tool/pulls/1/merge'             "pulls: gh pr merge"
assert_match    "$api_re" '/repos/acme/tool/issues/7/comments'         "issues: gh issue comment"
assert_match    "$api_re" '/repos/acme/tool/releases/latest'           "releases: gh release view"
assert_match    "$api_re" '/repos/acme/tool/contents/README.md'        "contents: file read"
assert_match    "$api_re" '/repos/acme/tool/git/refs/heads/main'       "git refs: deep paths allowed"
assert_match    "$api_re" '/repos/acme/tool/compare/main...feature'    "compare: dots in a ref range are not path segments"
assert_match    "$api_re" '/repos/acme/tool.js/actions/runs'           "dotted repo name reaches its own Actions API"
assert_no_match "$api_re" '/repos/acme/toolXjs/actions/runs'           "escaped dot: X is not . (refused)"

# repo-scoped is what the allowlist can express, so these fail closed rather than carry the token
assert_no_match "$api_re" '/orgs/acme/actions/runners' "actions: org-level runner admin refused"
assert_no_match "$api_re" '/search/issues'             "gh search is not repo-scoped (denied)"
assert_no_match "$api_re" '/repositories/1296269'      "id-form URLs never carry the token (anonymous by design)"

uploads_re="$(extract_re "$cf" uploads_allowed)"
assert_eq "$uploads_re" "$api_re" "the uploads matcher mirrors @api_allowed (same allowlist scoping)"

echo "-- API @api_pub matcher (anonymous lane) --"
api_pub_re="$(extract_re "$cf" api_pub)"
assert_match    "$api_pub_re" '/repos/evil/repo/issues'         "non-allowlisted repo anonymously routed"
assert_match    "$api_pub_re" '/repositories/1296269'           "id-form repo root anonymously routed"
assert_match    "$api_pub_re" '/repositories/1296269/issues'    "id-form subresource (pagination Link) anonymously routed"
assert_no_match "$api_pub_re" '/repositories/octocat'           "non-numeric id refused"

echo "-- API credential scoping: the token reaches ONLY the @api_allowed route (SECURITY INVARIANT) --"
api_allowed_block="$(awk '/@api_allowed path_regexp/{f=1} /@api_pub/{f=0} f' "$cf")"
api_pub_block="$(awk '/@api_pub/{f=1} /^# GitHub API site end/{f=0} f' "$cf")"
assert_contains     "$api_allowed_block" 'Authorization "@@CHOPI_API_AUTH@@"' "@api_allowed injects the credential"
assert_not_contains "$api_pub_block"     'Authorization'                      "the anonymous @api_pub tail carries no Authorization at all"
assert_contains     "$api_allowed_block" 'header_down Link'                   "@api_allowed rewrites pagination Links to the name form (id-form would paginate anonymously)"
assert_contains     "$api_allowed_block" '/repos/{re.1}'                      "  -> the rewrite reuses the matcher's own owner/repo capture"

apiproxy_block="$(awk '/^\(apiproxy\)/{f=1} f{print; if (/^}/) exit}' "$cf")"
assert_contains "$apiproxy_block" 'header_up -*'   "(apiproxy) wipes inbound headers (header_up -*)"
assert_contains "$apiproxy_block" 'import apihdrs' "(apiproxy) re-adds the apihdrs header set"
api_proxies="$(grep -cF 'reverse_proxy https://{args[0]}' "$cf")"
assert_eq "$api_proxies" 1 "(apiproxy) is the only API reverse_proxy (no route proxies around the wipe)"

echo "-- API deny messages: upstream 401s are converted to readable chopi errors --"
rejected_block="$(awk '/^\(rejected_credential\)/{f=1} f{print; if (/^}/) exit}' "$cf")"
assert_contains "$rejected_block"    'GitHub rejected the relay credential'                         "(rejected_credential) names the host-side remedy"
assert_contains "$api_allowed_block" 'import rejected_credential'                                   "@api_allowed converts credential-rejected 401s"
assert_contains "$api_pub_block"     'relay authenticates only repos'                               "@api_pub converts anonymous auth-required 401s"
assert_contains "$api_pub_block"     '"message":"chopi GitHub relay: not an allowed API operation"' "the API deny is a JSON message (gh displays only those)"

echo "-- tail catch-alls: anonymous signed-storage passthrough; unmatched hosts fail loudly --"
tail_block="$(awk '/^# GitHub API relay tail fragment/{f=1} f' "$cf")"
blob_re="$(printf '%s\n' "$tail_block" | grep -E 'header_regexp blobhost Host ' | sed -E 's/.*Host //')"
exact_hosts="$(printf '%s\n' "$tail_block" | sed -nE 's/^[[:space:]]*header Host ([^ ]+)$/\1/p')"

# storage_allowed HOST -- does a signed-storage lane pass HOST through (an exact
# `header Host` lane, or the Actions blob regexp)?
storage_allowed() {
    arity 1
    local host="$1"
    printf '%s\n' "$exact_hosts" | grep -qFx "$host" || re_match "$blob_re" "$host"
}
assert_storage()    { arity 2; if storage_allowed "$1"; then ok "$2"; else bad "$2"; fi; }
assert_no_storage() { arity 2; if storage_allowed "$1"; then bad "$2"; else ok "$2"; fi; }

assert_storage    'productionresultssa10.blob.core.windows.net'          "storage: Actions per-job logs/artifacts hosts allowed"
assert_storage    'results-receiver.actions.githubusercontent.com'       "storage: Actions whole-run log archive host allowed"
assert_storage    'release-assets.githubusercontent.com'                 "storage: release-assets host allowed"
assert_no_storage 'productionresultssa10.blob.core.windows.net.evil.com' "storage: suffixed lookalike refused"
assert_no_storage 'myaccount.blob.core.windows.net'                      "storage: arbitrary Azure account refused"
assert_no_storage 'api.github.com'                                       "storage: API host is not on the anonymous storage lane"

# as many method lines as @matchers and all exactly "method GET", so a widened
# "method GET POST" or a lane that forgot its method constraint fails
matcher_count="$(printf '%s\n' "$tail_block" | grep -cE '^[[:space:]]*@')"
method_lines="$(printf '%s\n' "$tail_block" | sed -nE 's/^[[:space:]]*(method .*)$/\1/p')"
method_count="$(printf '%s\n' "$method_lines" | grep -c .)"
uniq_methods="$(printf '%s\n' "$method_lines" | sort -u)"
assert_eq "$method_count" "$matcher_count" "every storage matcher constrains the method"
assert_eq "$uniq_methods" 'method GET'     "storage passthrough is GET-only"
storage_proxies="$(printf '%s\n' "$tail_block" | grep -c 'reverse_proxy')"
assert_eq "$storage_proxies" 1 "(storageproxy) is the tail's only reverse_proxy (every lane goes through the header wipe)"
assert_not_contains "$tail_block" 'Authorization'                                   "storage passthrough carries no credential"
assert_contains     "$tail_block" '"message":"chopi GitHub relay: unsupported host' "unmatched Host is refused loudly, with a JSON message (not Caddy's implicit empty 200)"

echo "-- empty allowlist is fail-closed (no push route) --"
empty="$(render)"
assert_not_contains "$empty" '@allowed'                     "empty: no allowlisted git route"
empty_imports="$(printf '%s\n' "$empty" | awk '/@pub_refs/{f=1} f' | grep -cE 'import (redirecting_)?ghproxy')"
assert_eq "$empty_imports" 2                                "empty: push cannot be proxied (denied in-relay)"
assert_contains     "$empty" 'ERR chopi: push denied'       "empty: push deny still explains itself"
assert_not_contains "$empty" 'ERR chopi: GitHub rejected'   "empty: no credential, so no git credential-rejected deny"
assert_not_contains "$empty" 'import rejected_credential'   "empty: no API route imports the credential-rejected deny"
assert_not_contains "$empty" '@@CHOPI_AUTH@@'               "empty: no credential slot"
assert_not_contains "$empty" 'header_up Authorization'      "empty: no credential header"
assert_contains     "$empty" 'not an allowed git operation' "empty: still emits the deny handler"

echo "-- empty allowlist is fail-closed for the API too (no authed route) --"
assert_not_contains "$empty" '@api_allowed'                   "empty: no allowlisted API route"
assert_not_contains "$empty" '@@CHOPI_API_AUTH@@'             "empty: no API credential slot"
assert_contains     "$empty" 'relay authenticates only repos' "empty: anonymous auth-required deny still explains itself"
assert_contains     "$empty" 'not an allowed API operation'   "empty: still emits the API deny handler"
assert_contains     "$empty" 'unsupported host'               "empty: catch-all sites still emitted"

echo "-- invalid entries are rejected (fail closed, non-zero exit) --"
render 'no-slash-here' >/dev/null 2>&1; assert_nonzero "$?" "entry without owner/repo rejected"
render 'own er/repo'   >/dev/null 2>&1; assert_nonzero "$?" "entry with illegal char rejected"

summary

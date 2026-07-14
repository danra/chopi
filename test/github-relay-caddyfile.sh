#!/usr/bin/env bash
#
# test/github-relay-caddyfile.sh -- unit tests for the GitHub relay config generator.
#
# Assert the generated Caddyfile structure and that the path matchers accept/reject the right paths.

set -uo pipefail

_test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$_test_dir/../.internal/util.sh"
. "$_test_dir/lib.sh"

RENDER="$CHOPI_DIR/.internal/github-relay-caddyfile.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/chopi-github-relay.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

render() { printf '%s\n' "$@" > "$WORK/allow"; "$RENDER" "$WORK/allow"; }

# extract_re FILE MATCHER -- the regex from a "@MATCHER path_regexp <re>" line
extract_re() { arity 2; grep -E "@$2 path_regexp " "$1" | sed -E 's/.*path_regexp //'; }

# assert_match RE PATH DESC / assert_no_match -- does PATH match RE (as grep -E would)?
assert_match()    { arity 3; if printf '%s\n' "$2" | grep -qE "$1"; then ok "$3"; else bad "$3"; fi; }
assert_no_match() { arity 3; if printf '%s\n' "$2" | grep -qE "$1"; then bad "$3"; else ok "$3"; fi; }

header "github-relay-caddyfile"

# ---- a populated allowlist: a wildcard owner, an exact repo, an exact repo with a dot ----
cf="$WORK/populated"
render 'soundradix/*' 'acme/tool' 'acme/tool.js' > "$cf"

echo "-- structure --"
assert_contains "$(cat "$cf")" "http://127.0.0.1:$GITHUB_RELAY_PORT"  "GitHub relay listens on GITHUB_RELAY_PORT"
assert_contains "$(cat "$cf")" '@@CHOPI_AUTH@@'         "git route carries the credential slot (caller-filled)"
assert_contains "$(cat "$cf")" 'acme/tool\.js'          "dots in repo names are regex-escaped"

git_re="$(extract_re "$cf" allowed)"

echo "-- git @allowed matcher (match => proxied WITH the token; push only reaches here) --"
assert_match    "$git_re" '/soundradix/anything/git-receive-pack' "wildcard: push allowed"
assert_match    "$git_re" '/soundradix/anything/git-upload-pack'  "wildcard: fetch allowed"
assert_match    "$git_re" '/soundradix/anything/info/refs'        "wildcard: ref discovery allowed"
assert_match    "$git_re" '/acme/tool/git-receive-pack'           "exact: push allowed"
assert_match    "$git_re" '/acme/tool.git/git-receive-pack'       "exact: .git suffix allowed"
assert_match    "$git_re" '/soundradix/anything/info/lfs/objects/batch' "wildcard: Git-LFS API allowed"
assert_match    "$git_re" '/acme/tool.git/info/lfs/locks'               "exact: Git-LFS locks API allowed"
assert_no_match "$git_re" '/evil/repo/git-receive-pack'           "non-allowlisted push refused"
assert_no_match "$git_re" '/evil/repo/info/lfs/objects/batch'     "non-allowlisted LFS not on the credentialed route"
assert_no_match "$git_re" '/acme/tool2/git-receive-pack'          "similar name refused"
assert_no_match "$git_re" '/acme/toolXjs/git-receive-pack'        "escaped dot: X is not . (refused)"
assert_no_match "$git_re" '/soundradix/a/b/git-receive-pack'      "extra path segment refused"

echo "-- anonymous LFS download routing (public LFS batch reaches non-allowlisted repos) --"
pub_lfs_re="$(grep -E 'path_regexp .*info/lfs/objects/batch' "$cf" | sed -E 's/.*path_regexp //')"
assert_match    "$pub_lfs_re" '/evil/repo/info/lfs/objects/batch' "non-allowlisted LFS batch is anonymously routed"
assert_match    "$pub_lfs_re" '/o/r.git/info/lfs/objects/batch'   ".git suffix is anonymously routed"
assert_no_match "$pub_lfs_re" '/evil/repo/info/lfs/locks'         "non-batch LFS (locks) not anonymously routed"

echo "-- credential scoping: the token reaches ONLY the @allowed route (SECURITY INVARIANT) --"
allowed_block="$(awk '/@allowed path_regexp/{f=1} /@pub_refs/{f=0} f' "$cf")"
pub_block="$(awk '/@pub_refs/{f=1} f' "$cf")"

assert_contains     "$allowed_block" 'Authorization "@@CHOPI_AUTH@@"' "@allowed injects the credential"
assert_not_contains "$pub_block"     '@@CHOPI_AUTH@@'                 "no anonymous @pub route carries the credential slot"
assert_not_contains "$pub_block"     'header_up Authorization'       "  -> nor sets any credential-bearing Authorization header"
auth_count="$(grep -c 'header_up Authorization' "$cf")"
assert_eq "$auth_count" 1 "the credential header is injected in exactly one place (@allowed)"

ghproxy_block="$(awk '/^\(ghproxy\)/{f=1} f{print; if (/^}/) exit}' "$cf")"
assert_contains "$ghproxy_block" 'header_up -*'   "(ghproxy) wipes inbound headers (header_up -*)"
assert_contains "$ghproxy_block" 'import githdrs' "(ghproxy) re-adds the githdrs header set"
total_proxies="$(grep -c 'reverse_proxy https://github.com' "$cf")"
assert_eq "$total_proxies" 1 "(ghproxy) is the only reverse_proxy (no route proxies around the wipe)"

assert_contains     "$allowed_block" 'git-receive-pack' "push (git-receive-pack) is proxied on the @allowed route"
pub_imports="$(printf '%s\n' "$pub_block" | grep -cE 'import (redirecting_)?ghproxy')"
assert_eq "$pub_imports" 2 "anonymous routes proxy only fetch + LFS batch (push is never proxied)"

echo "-- empty allowlist is fail-closed (no push route) --"
empty="$(render)"
assert_not_contains "$empty" '@allowed'                     "empty: no allowlisted git route"
empty_imports="$(printf '%s\n' "$empty" | awk '/@pub_refs/{f=1} f' | grep -cE 'import (redirecting_)?ghproxy')"
assert_eq "$empty_imports" 2                                "empty: push cannot be proxied (denied in-relay)"
assert_contains     "$empty" 'ERR chopi: push denied'       "empty: push deny still explains itself"
assert_not_contains "$empty" 'GitHub rejected'              "empty: no credential, so no credential-rejected deny"
assert_not_contains "$empty" '@@CHOPI_AUTH@@'               "empty: no credential slot"
assert_not_contains "$empty" 'header_up Authorization'      "empty: no credential header"
assert_contains     "$empty" 'not an allowed git operation' "empty: still emits the deny handler"

echo "-- invalid entries are rejected (fail closed, non-zero exit) --"
render 'no-slash-here' >/dev/null 2>&1; assert_nonzero "$?" "entry without owner/repo rejected"
render 'own er/repo'   >/dev/null 2>&1; assert_nonzero "$?" "entry with illegal char rejected"

summary

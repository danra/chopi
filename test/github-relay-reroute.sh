#!/usr/bin/env bash
#
# test/github-relay-reroute.sh -- unit tests for chopi's GitHub->relay git-routing helpers

set -uo pipefail

_test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$_test_dir/../.internal/util.sh"
. "$_test_dir/lib.sh"

header "github-relay-reroute"

if ! command -v git >/dev/null 2>&1; then
    bad "github-relay-reroute tests need git on PATH"
    summary
    exit
fi

relay="http://127.0.0.1:$GITHUB_RELAY_PORT"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/chopi-github-relay-reroute.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

echo "-- github_relay_git_config --"
cfg="$(github_relay_git_config)"
assert_contains "$cfg" "url.$relay/.insteadOf=https://github.com/"   "rewrites the https github prefix to the relay"
assert_contains "$cfg" "url.$relay/.insteadOf=git@github.com:"       "rewrites the scp-style ssh github prefix"
assert_contains "$cfg" "url.$relay/.insteadOf=ssh://git@github.com/" "rewrites the ssh:// github prefix"
assert_contains "$cfg" "lfs.$relay/.locksverify=true"                "silences git-lfs locksverify for the relay url"

# Resolve against a controlled git config: neutralize system scope; GIT_CONFIG_GLOBAL is (re)set
# per case below. chopi's rewrites enter through the command-scope environment, exported exactly
# as the git-protect wrapper does in-sandbox -- the check reads only this ambient config.
export GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0
i=0
while IFS= read -r pair; do
    export "GIT_CONFIG_KEY_$i=${pair%%=*}" "GIT_CONFIG_VALUE_$i=${pair#*=}"
    i=$((i + 1))
done < <(github_relay_git_config)
export GIT_CONFIG_COUNT="$i"

# reroute_in DIR -- run the check from DIR, as the wrapper runs it from the run dir.
reroute_in() {
    arity 1
    ( cd "$1" && is_github_relay_reroute_effective )
}

empty="$WORK/empty"; : > "$empty"
repo="$WORK/repo"; make_repo "$repo" >/dev/null 2>&1

echo "-- effective with no competing config --"
export GIT_CONFIG_GLOBAL="$empty"
reroute_in "$repo"; rc=$?
assert_zero "$rc" "all github remote forms route to the relay"

echo "-- ineffective against a competing global https->ssh rewrite --"
ssh_global="$WORK/ssh-global"
printf '[url "git@github.com:"]\n\tinsteadOf = https://github.com/\n' > "$ssh_global"
export GIT_CONFIG_GLOBAL="$ssh_global"
reroute_in "$repo"; rc=$?
assert_nonzero "$rc" "a global rewrite that wins the tie is detected (the wrapper would refuse)"

echo "-- a competing rewrite in the run dir's LOCAL config is detected too --"
local_repo="$WORK/local-repo"; make_repo "$local_repo" >/dev/null 2>&1
git -C "$local_repo" config url."git@github.com:".insteadOf https://github.com/
export GIT_CONFIG_GLOBAL="$empty"
reroute_in "$local_repo"; rc=$?
assert_nonzero "$rc" "a local insteadOf that wins the tie is detected"

echo "-- an unrelated (non-github) rewrite does not trip the check --"
gl_global="$WORK/gl-global"
printf '[url "git@gitlab.com:"]\n\tinsteadOf = https://gitlab.com/\n' > "$gl_global"
export GIT_CONFIG_GLOBAL="$gl_global"
reroute_in "$repo"; rc=$?
assert_zero "$rc" "a gitlab insteadOf leaves github routing intact"

summary

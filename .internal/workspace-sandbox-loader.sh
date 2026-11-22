#!/usr/bin/env bash
#
# workspace-sandbox-loader.sh -- run by load_workspace_sandbox_config (preflight.sh) in a bash of
# its own: source a repo's own sandbox config FILE with the ARRAYs it may add to empty, then write
# each of their items to stdout as its array's name and the item, each NUL-terminated. The file's
# own output goes to stderr. Fails on a file that fails, that leaves one of the arrays not an array,
# or that changes any other CHOPI_ variable, which only the base config may set.
#
# usage: workspace-sandbox-loader.sh FILE ARRAY...

set -euo pipefail

_file="$1"; shift
_arrays=("$@")
_what="this repo's own sandbox config '$_file'"

# Declare every CHOPI_ variable but the arrays.
_chopi_others() {
    local _v
    for _v in $(compgen -v CHOPI_); do
        case " ${_arrays[*]} " in *" $_v "*) ;; *) declare -p "$_v" ;; esac
    done
}

for _name in "${_arrays[@]}"; do eval "$_name=()"; done
_before="$(_chopi_others)"
# shellcheck disable=SC1090  # the repo's own config
. "$_file" >&2
_after="$(_chopi_others)"
if [ "$_before" != "$_after" ]; then
    echo "error: $_what may only add to ${_arrays[*]}," >&2
    echo "but it sets other variables, which only the base sandbox config may:" >&2
    diff <(printf '%s\n' "$_before") <(printf '%s\n' "$_after") | sed -n 's/^> /  /p' >&2
    exit 1
fi
for _name in "${_arrays[@]}"; do
    if [[ "$(declare -p "$_name" 2>/dev/null)" != "declare -a"* ]]; then
        echo "error: $_what leaves $_name not an array" >&2
        exit 1
    fi
    _ref="${_name}[@]"
    for _item in ${!_ref+"${!_ref}"}; do printf '%s\0' "$_name" "$_item"; done
done

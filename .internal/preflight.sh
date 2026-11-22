# shellcheck shell=bash
#
# preflight.sh -- pre-run checks for chopi, as functions chopi calls at two points.
#
# Sourced (never run directly). The checks are split by WHEN they can run, because chopi
# only learns the dir the command will actually run in partway through setup:
#   * preflight_initial          -- runnable up front: the workspace doesn't overlap chopi's
#                                   own dir (a confined command must not reach the policy
#                                   that confines it), the proxy's run dir (whose ports aim
#                                   the holes), or the proxy's config (which sets the outgoing
#                                   limits), and the safehouse CLI is on PATH.
#   * preflight_config_placement -- deferred until chopi has resolved the workspace (the
#                                   --worktree target), since that is the dir a custom
#                                   --config must stay outside of.
#
# resolve_proxy_config, run up front, resolves the proxy's config, which it reads all session long.

_preflight_dir="$(dirname "${BASH_SOURCE[0]}")"
. "$_preflight_dir/util.sh"
unset _preflight_dir

refuse_or_warn() {
    arity 3
    local reason="$1" detail="$2" hint="$3"
    if [ -n "${CHOPI_ALLOW_SELF:-}" ]; then
        echo "warning: $reason;" >&2
        echo "         $detail." >&2
        echo "         continuing anyway (CHOPI_ALLOW_SELF is set)." >&2
        echo >&2
    else
        echo "error: $reason;" >&2
        echo "       $detail." >&2
        echo "$hint" >&2
        return 1
    fi
}

preflight_initial() {
    arity 0

    local workspace_dir
    workspace_dir="$(pwd -P)" || { echo "error: cannot resolve current directory" >&2; return 1; }

    if overlaps_chopi_dir "$workspace_dir"; then
        refuse_or_warn \
            "workspace '$workspace_dir' overlaps chopi's own directory ('$CHOPI_DIR')" \
            "the sandboxed command would get read/write access to its own config" \
            "Run chopi from inside the repo you're working on, not from chopi's own dir, a parent of it, or a subdir of it." \
            || return 1
    fi

    # The session's proxy reports its ports in the run dir, and they aim this run's holes and
    # HTTP_PROXY, so the sandboxed command must not reach it. Not a CHOPI_ALLOW_SELF matter: working
    # on chopi needs no access to it.
    if overlaps_proxy_run_dir "$workspace_dir"; then
        echo "error: workspace '$workspace_dir' overlaps the proxy's run directory ('$PROXY_RUN_DIR');" >&2
        echo "       the sandboxed command could rewrite the ports that aim its own network holes." >&2
        echo "Run chopi from a workspace that neither holds nor sits inside $PROXY_RUN_DIR." >&2
        return 1
    fi

    # The proxy's config sets every session's outgoing limits, which their proxies hot-reload. The
    # profile denies the command any change to it whatever the workspace (write_proxy_config_profile),
    # so CHOPI_ALLOW_SELF may downgrade this, for working on chopi, whose dir holds the default ones.
    local config
    overlaps_proxy_config config "$workspace_dir" || return 1
    if [ -n "$config" ]; then
        refuse_or_warn \
            "workspace '$workspace_dir' overlaps the proxy's config ('$config')" \
            "the sandboxed command would be granted its outgoing limits, and every other session's, to rewrite" \
            "Run chopi from a workspace that neither holds nor sits inside the proxy's config." \
            || return 1
    fi

    # Agent Safehouse builds the sandbox policy and execs the command inside it, so
    # it's a per-run dependency. Fail fast with a pointer rather than a bare
    # "command not found" when chopi calls it.
    if ! command -v safehouse >/dev/null 2>&1; then
        echo "error: safehouse CLI not found on PATH" >&2
        echo "Install it (see README, Prerequisites): https://github.com/eugene1g/agent-safehouse" >&2
        return 1
    fi
}

# preflight_config_placement <config_file> <run_dir>
#
# Refuse a custom --config file inside the workspace run_dir; with CHOPI_ALLOW_SELF non-empty, only
# warn. Also fails when either path can't be resolved, e.g. a missing --config file.
preflight_config_placement() {
    arity 2
    local config_file="$1" run_dir="$2"

    local real_run_dir
    real_run_dir="$(realpath "$run_dir" 2>/dev/null)" \
        || { echo "error: preflight: cannot resolve run dir '$run_dir'" >&2; return 1; }

    local config_abs
    if ! config_abs="$(realpath "$config_file" 2>/dev/null)"; then
        echo "error: cannot resolve --config path '$config_file' (does it exist?)" >&2
        return 1
    fi
    if is_path_within "$config_abs" "$real_run_dir"; then
        refuse_or_warn \
            "--config file '$config_abs' is inside the workspace ('$real_run_dir')" \
            "the sandboxed command would get read/write access to the config that defines its own sandbox" \
            "Keep the sandbox config outside the workspace you're sandboxing." \
            || return 1
    fi
}

# Check every file in PROXY_CONFIG_DIR, used or not, and the files in use by this session, the
# defaults, and running sessions for extra hard links, which write_proxy_config_profile's deny by
# path can't see. A session can't make a link, so one it writes through predates it, and its own
# check refuses. The proxy also checks the file it opens at startup and on reload. A repo's own
# sandbox config there is checked too: written through a link, it could widen that repo's next
# sessions.
#
# usage: preflight_proxy_config_links FILE...
preflight_proxy_config_links() {
    local file files linked=()
    # -H: PROXY_CONFIG_DIR may be a symlink. find can't descend into a dir it can't read. One it
    # can't search either is passed over, as no session can open a config in it. One it can search
    # but not list is refused: a session can still open a config in it by name, but its files can't
    # be checked.
    while IFS= read -r -d '' file; do
        if [ ! -d "$file" ]; then
            linked+=("$file")
        elif [ -x "$file" ] && [ ! -r "$file" ]; then
            refuse_or_warn \
                "the proxy config directory '$file' can be searched but not listed, so its files can't be checked for other hard links" \
                "the sandboxed command may have written a config in it through one" \
                "Make it readable, e.g.: chmod u+r '$file', or unsearchable if no config in it is used." \
                || return 1
        fi
    done < <(find -H "$PROXY_CONFIG_DIR" \( -type d -o -type f -links +1 \) -print0 2>/dev/null)
    proxy_config_files files "$@" "${linked[@]+"${linked[@]}"}" || return 1
    for file in "${files[@]}"; do
        if [[ "$file" == "$PROXY_CONFIG_DIR"/workspaces/*/"$WORKSPACE_SANDBOX_CONFIG" ]]; then
            check_config_file_links "$file" "a repo's own sandbox config" \
                "the sandboxed command could widen the sandbox of that repo's next sessions" \
                || return 1
        else
            check_config_file_links "$file" "the proxy's config file" \
                "the sandboxed command could lift its own outgoing limits, and every other session's" \
                || return 1
        fi
    done
}

# Refuse (or under CHOPI_ALLOW_SELF, warn of) the config FILE, named as WHAT, being a regular file,
# following a symlink, with other hard links, which the sandboxed command may write through, to do
# CONSEQUENCE. A missing FILE passes; one stat can't inspect fails. Pins the locale to recognize
# the error for a file that is missing.
#
# usage: check_config_file_links FILE WHAT CONSEQUENCE
check_config_file_links() {
    arity 3
    local info
    if ! info="$(LC_ALL=C /usr/bin/stat -L -f '%HT:%l' "$1" 2>&1)"; then
        [[ "$info" == *': No such file or directory' ]] && return 0
        echo "error: could not check $2 '$1' for other hard links" >&2
        echo "$info" >&2
        return 1
    fi
    if [[ "$info" == 'Regular File:'* && "${info#*:}" -gt 1 ]]; then
        refuse_or_warn \
            "$2 '$1' has other hard links, which the sandboxed command may write through" \
            "$3" \
            "Review what is in it, as it may have been written through another hard link, then
replace it with a fresh copy, e.g.: cp '$1' '$1.tmp' && mv '$1.tmp' '$1'" || return 1
    fi
}

# Succeed if the real path RESOLVED is in PROXY_CONFIG_DIR, where every session keeps its command
# from changing it; else explain, with PROBLEM and FIX, and fail.
#
# usage: require_in_proxy_config_dir RESOLVED PROBLEM FIX
require_in_proxy_config_dir() {
    arity 3
    local config_dir
    resolved_path config_dir "$PROXY_CONFIG_DIR" || return 1
    is_path_within "$1" "$config_dir" && return 0
    echo "$2" >&2
    echo "Every session keeps its command from changing what is in $PROXY_CONFIG_DIR; elsewhere," >&2
    echo "another session's could rewrite it, lifting this session's limits. $3" >&2
    return 1
}

# Resolve the proxy config file the sandbox config's variable VAR names -- or, when it names none,
# the default config/DEFAULT the installer creates from config/templates/TEMPLATE -- setting VAR to
# its real path. chopi hands the proxy that path, which it reads for the whole session, hot-reloading
# the rules: resolved once, as Seatbelt matches the real path, no symlink on the way can be
# repointed past the profile denying changes to it. A configured one must be in PROXY_CONFIG_DIR,
# where every session's command is kept from changing it, not just this session's.
#
# usage: resolve_proxy_config VAR DEFAULT TEMPLATE
resolve_proxy_config() {
    arity 3
    local var="$1" default="$CHOPI_DIR/config/$2" template="$CHOPI_DIR/config/templates/$3"
    local path resolved
    path="${!var}"
    case "$path" in
        '') if [ ! -e "$default" ]; then
                echo "chopi: no $2 at $default" >&2
                echo "Run the installer to create it from the template:  $CHOPI_DIR/install.sh" >&2
                echo "or copy it manually:  cp \"$template\" \"$default\"" >&2
                return 1
            fi
            path="$default" ;;
        /*) ;;
        *)  echo "chopi: $var must be an absolute path, got '$path'" >&2
            return 1 ;;
    esac
    # Checked first: resolved_path appends what follows a missing node unresolved.
    [ -f "$path" ] || { echo "chopi: no $var file at '$path'" >&2; return 1; }
    resolved_path resolved "$path" || return 1
    if [ "$path" != "$default" ]; then
        require_in_proxy_config_dir "$resolved" \
            "chopi: $var must be in $PROXY_CONFIG_DIR, got '$path'" \
            "Move it there, and point $var at it." || return 1
    fi
    printf -v "$var" '%s' "$resolved"
}

# Print the real path of the own config dir of the workspace at RUN_DIR (workspace_config_dir),
# whether or not it exists: chopi hands the proxy the proxy config files in it, and the proxy reads
# them all session, as they appear. Resolved through any symlinks on the way, it must still be in
# PROXY_CONFIG_DIR, where every session keeps its command from changing it.
#
# usage: resolve_workspace_config_dir RUN_DIR
resolve_workspace_config_dir() {
    arity 1
    local dir resolved
    dir="$(workspace_config_dir "$1")" || return 1
    resolved_path resolved "$dir" || return 1
    require_in_proxy_config_dir "$resolved" \
        "chopi: the repo's own config dir '$dir' leads out of $PROXY_CONFIG_DIR, to '$resolved'." \
        "Replace the link on the way with a dir." || return 1
    printf '%s' "$resolved"
}

# The sandbox config arrays a workspace's own sandbox config may add to.
WORKSPACE_SANDBOX_ARRAYS=(CHOPI_SAFEHOUSE_FLAGS CHOPI_EXTRA_ENV CHOPI_GIT_CONFIG)

# Add what the workspace's own sandbox config FILE adds to the sandbox config arrays
# (WORKSPACE_SANDBOX_ARRAYS), for its sessions alone, as workspace-sandbox-loader.sh reports it. A
# missing FILE adds nothing. Like the repo's own proxy config files beside it, it is in
# PROXY_CONFIG_DIR, where every session keeps its command from changing it; so a symlink, which may
# lead to where a command can, is refused, as is a file with other hard links, which a command may have written through
# (CHOPI_ALLOW_SELF downgrading that to a warning, as for the proxy config).
#
# usage: load_workspace_sandbox_config FILE
load_workspace_sandbox_config() {
    arity 1
    local file="$1" what="this repo's own sandbox config" out name item
    local loader="$CHOPI_DIR/.internal/workspace-sandbox-loader.sh"
    if [ -L "$file" ]; then
        echo "error: $what '$file' is a symlink, which may lead to where a sandboxed command" >&2
        echo "can change it. Replace it with the file it leads to." >&2
        return 1
    fi
    [ -e "$file" ] || return 0
    if [ ! -f "$file" ]; then
        echo "error: $what '$file' is not a regular file" >&2
        return 1
    fi
    check_config_file_links "$file" "$what" \
        "the sandboxed command could widen its own sandbox, for the repo's next sessions" \
        || return 1
    # A file, not a pipe, so the loader is known to have succeeded before any item is added.
    out="$(mktemp "$TMPDIR/chopi-ws-sandbox.XXXXXX")" \
        || { echo "error: could not create a temp file for loading $what" >&2; return 1; }
    if ! "$BASH" "$loader" "$file" "${WORKSPACE_SANDBOX_ARRAYS[@]}" >"$out"; then
        echo "error: could not load $what '$file'" >&2
        return 1
    fi
    # shellcheck disable=SC2034  # item is added by eval
    while IFS= read -r -d '' name && IFS= read -r -d '' item; do
        if ! is_item_in_list "$name" "${WORKSPACE_SANDBOX_ARRAYS[@]}"; then
            echo "error: garbled output loading '$file'" >&2; return 1
        fi
        eval "$name+=(\"\$item\")"
    done <"$out"
}

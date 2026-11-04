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
        echo "Run chopi from a workspace that neither holds nor sits inside $PROXY_RUN_DIR, or point" >&2
        echo "CHOPI_RUN_DIR elsewhere." >&2
        return 1
    fi

    # The proxy's config sets every session's outgoing limits, which their proxies hot-reload. The
    # profile denies the command any change to it whatever the workspace (write_proxy_config_profile),
    # so CHOPI_ALLOW_SELF may downgrade this, for working on chopi, whose dir holds the default ones.
    local config
    if config="$(overlaps_proxy_config "$workspace_dir")"; then
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

# Refuse a proxy config file (proxy_config_paths) with extra hard links: write_proxy_config_profile
# denies changes by path, so the sandboxed command could write the live rules through another link.
# The sandbox keeps the command from making one, but not one made outside it. One made once the
# session is up is caught by the proxy, which moves the file aside as *.refused-* (see its putBack);
# the proxy never reads those, so they're skipped here.
#
# usage: preflight_proxy_config_links
preflight_proxy_config_links() {
    arity 0
    local path file existing=()
    while IFS= read -r path; do
        [ -e "$path" ] && existing+=("$path")
    done < <(proxy_config_paths)
    [ "${#existing[@]}" -gt 0 ] || return 0
    # Run to the end before any refusal, for find's status: a file it couldn't check (an unreadable
    # dir) may be one with other hard links.
    local linked
    if ! linked="$(find "${existing[@]}" -type f -links +1 ! -name '*.refused-*')"; then
        echo "error: could not check every proxy config file for other hard links, which the sandboxed" >&2
        echo "       command may write through (see find's error above)." >&2
        echo "Make everything under ${existing[*]} readable to you." >&2
        return 1
    fi
    [ -n "$linked" ] || return 0
    while IFS= read -r file; do
        refuse_or_warn \
            "the proxy's config file '$file' has other hard links, which the sandboxed command may write through" \
            "the sandboxed command could lift its own outgoing limits, and every other session's" \
            "Review what is in it, as it may have been written through another hard link, then
replace it with a fresh copy, e.g.: cp '$file' '$file.tmp' && mv '$file.tmp' '$file'" \
            || return 1
    done <<<"$linked"
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
    local path resolved config_dir
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
    # Checked apart from realpath: GNU's, often first on PATH, resolves a path that doesn't exist.
    [ -f "$path" ] || { echo "chopi: no $var file at '$path'" >&2; return 1; }
    resolved="$(realpath "$path" 2>/dev/null)" \
        || { echo "chopi: cannot resolve $var path '$path'" >&2; return 1; }
    config_dir="$(realpath_or_self "$PROXY_CONFIG_DIR")"
    if [ "$path" != "$default" ] && ! is_path_within "$resolved" "$config_dir"; then
        echo "chopi: $var must be in $PROXY_CONFIG_DIR, got '$path'" >&2
        echo "Every session keeps its command from changing what is there; elsewhere, another session's" >&2
        echo "could rewrite it, lifting this session's limits. Move it there, and point $var at it." >&2
        return 1
    fi
    printf -v "$var" '%s' "$resolved"
}

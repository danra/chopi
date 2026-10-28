# shellcheck shell=bash
#
# preflight.sh -- pre-run checks for chopi, as functions chopi calls at two points.
#
# Sourced (never run directly). The checks are split by WHEN they can run, because chopi
# only learns the dir the command will actually run in partway through setup:
#   * preflight_initial          -- runnable up front: the workspace doesn't overlap chopi's
#                                   own dir (a confined command must not reach the policy
#                                   that confines it), and the safehouse CLI is on PATH.
#   * preflight_config_placement -- deferred until chopi has resolved the workspace (the
#                                   --worktree target), since that is the dir a custom
#                                   --config must stay outside of.
#
# resolve_proxy_config, run up front, resolves the proxy's config, which it reads all session long:
# the in-sandbox wrapper refuses to run the command where it can write it, as only the sandbox
# itself knows every path it lets the command write.

_preflight_dir="$(dirname "${BASH_SOURCE[0]}")"
. "$_preflight_dir/util.sh"
unset _preflight_dir

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

    # Agent Safehouse builds the sandbox policy and execs the command inside it, so
    # it's a per-run dependency. Fail fast with a pointer rather than a bare
    # "command not found" when chopi calls it.
    if ! command -v safehouse >/dev/null 2>&1; then
        echo "error: safehouse CLI not found on PATH" >&2
        echo "Install it (see README, Prerequisites): https://github.com/eugene1g/agent-safehouse" >&2
        return 1
    fi
}

# Refuse a custom --config CONFIG that lies inside the workspace RUN_DIR.
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

# Resolve the proxy config file the sandbox config's variable VAR names -- or, when it names none,
# the default config/DEFAULT the installer creates from config/templates/TEMPLATE -- setting VAR to
# its real path. chopi hands the proxy that path, which it reads for the whole session, hot-reloading
# the rules: resolved once, no symlink on the way can be repointed after the in-sandbox wrapper
# checks it.
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
    # Checked apart from realpath: GNU's, often first on PATH, resolves a path that doesn't exist.
    [ -f "$path" ] || { echo "chopi: no $var file at '$path'" >&2; return 1; }
    resolved="$(realpath "$path" 2>/dev/null)" \
        || { echo "chopi: cannot resolve $var path '$path'" >&2; return 1; }
    printf -v "$var" '%s' "$resolved"
}

# shellcheck shell=bash
#
# session-proxy.sh -- start and stop a chopi session's own outgoing proxy.
#
# Sourced (never run directly). Each session runs its own chopi-proxy.sh, on loopback ports the
# kernel picks, for the sandbox to reach through the holes write_proxy_network_profile
# opens, and stops it when the session ends. The proxy logs to a file of its own under
# CHOPI_PROXY_LOG_DIR, kept after the session for a while for inspection.

. "${BASH_SOURCE[0]%/*}/util.sh"

CHOPI_PROXY_SCRIPT="$CHOPI_DIR/.internal/chopi-proxy.sh"
CHOPI_PROXY_LOG_DIR="$HOME/Library/Logs/chopi"
# Days a log is kept past its last change, once its session is over.
CHOPI_PROXY_LOG_KEEP_DAYS=14
# Seconds a proxy may take to start before chopi says what it waits on.
CHOPI_PROXY_START_NOTICE_SECS=5

# Set by launch_session_proxy and await_session_proxy: the session's proxy, its log, temp dir and
# the stderr of its start, and its endpoints -- the smokescreen forward proxy's port (HTTP_PROXY), the git relay's port, and
# the API relay's unix socket (see github_relay_gh_env).
SESSION_PROXY_PID=""
SESSION_PROXY_LOG=""
SESSION_PROXY_DIR=""
SESSION_PROXY_ERR=""
SESSION_PROXY_PORT=""
SESSION_RELAY_PORT=""
SESSION_GH_SOCK=""

# Start the session's proxy, with RULES and ALLOWLIST as its configuration, and its log verbose when
# VERBOSE is non-empty. Returns as soon as it is launched, for chopi to go on with its own setup as
# the proxy starts; await_session_proxy waits for it.
#
# USER_TMPDIR is the TMPDIR chopi was started with, before it took a temp dir of its own; empty for
# none. The proxy runs with it, not with chopi's, which goes with the session: an editor its banner
# opens can outlive the session, and so must the TMPDIR it's given.
#
# usage: launch_session_proxy RULES ALLOWLIST VERBOSE USER_TMPDIR
launch_session_proxy() {
    arity 4
    local rules="$1" allowlist="$2" verbose="$3" user_tmpdir="$4"

    if ! mkdir -p "$CHOPI_PROXY_LOG_DIR" 2>/dev/null; then
        echo "chopi: cannot create the proxy log dir $CHOPI_PROXY_LOG_DIR" >&2
        return 1
    fi
    # Delete logs past their retention, in the background so the session's startup doesn't wait.
    # The subshell detaches it from chopi's jobs, so nothing waits for it later either, and its
    # output goes nowhere, so neither does a caller capturing chopi's, reading until it ends. A log
    # whose session still runs -- the chopi whose pid its name ends with -- is kept, however quiet.
    ( find "$CHOPI_PROXY_LOG_DIR" -name 'proxy-*.log' -mtime "+$CHOPI_PROXY_LOG_KEEP_DAYS" 2>/dev/null \
        | while IFS= read -r log; do
            pid="${log##*-}"
            kill -0 "${pid%%.*}" 2>/dev/null || rm -f "$log"
        done & ) </dev/null >/dev/null 2>&1
    local now
    now="$(date +%Y%m%d-%H%M%S)"
    SESSION_PROXY_LOG="$CHOPI_PROXY_LOG_DIR/proxy-$now-$$.log"

    # The proxy puts the relays' log beside its own, as a .caddy.log, which the sweep above covers
    # too.
    local flags=(--log "$SESSION_PROXY_LOG" --parent "$$" --rules "$rules"
                 --github-allowlist "$allowlist")
    [ -n "$verbose" ] && flags+=(--verbose)

    prepare_session_proxy_dir "$rules" "$allowlist" || return 1

    # Job control puts the proxy in a process group of its own, out of reach of the terminal's
    # signals: a Ctrl-C meant for the sandboxed command must not stop the proxy under it. chopi
    # stops it itself, and --parent covers chopi dying without the chance to.
    local tmpdir_env=(env -u TMPDIR)
    [ -n "$user_tmpdir" ] && tmpdir_env=(env TMPDIR="$user_tmpdir")
    set -m
    "${tmpdir_env[@]}" "$CHOPI_PROXY_SCRIPT" --dir "$SESSION_PROXY_DIR" "${flags[@]}" </dev/null 2>"$SESSION_PROXY_ERR" &
    SESSION_PROXY_PID=$!
    set +m
}

# Make the proxy's dir of its own, for its temporaries, the API relay's socket, and the ports the
# proxy reports: in the run dir, out of the sandbox's reach (see PROXY_RUN_DIR), which is ours
# alone, as the socket serves GitHub with the user's credential. The proxy removes it as it exits,
# so what it says as it starts goes in chopi's own temp dir, to read once it is gone. Lists RULES
# and ALLOWLIST in it as the config files the proxy reads. Sets SESSION_PROXY_DIR and
# SESSION_PROXY_ERR, for the proxy to be started with.
#
# usage: prepare_session_proxy_dir RULES ALLOWLIST
prepare_session_proxy_dir() {
    arity 2
    if ! { mkdir -p "$CHOPI_RUN_DIR" && make_private_dir "$PROXY_RUN_DIR"; }; then
        echo "chopi: cannot set up the proxy's run dir $PROXY_RUN_DIR" >&2
        return 1
    fi
    SESSION_PROXY_DIR="$(mktemp -d "$PROXY_RUN_DIR/$PROXY_SESSION_DIR_PREFIX.XXXXXX")" \
        || { echo "chopi: could not create a temp dir for the proxy" >&2; return 1; }
    # For every later session to keep its command from changing the files this proxy reads, whatever
    # their links point at by the time it starts (see proxy_config_paths).
    printf '%s\n' "$1" "$2" >"$SESSION_PROXY_DIR/$PROXY_CONFIGS_FILE_NAME" \
        || { echo "chopi: could not list the proxy's config files in $SESSION_PROXY_DIR" >&2; return 1; }
    SESSION_PROXY_ERR="$TMPDIR/proxy-startup.err"
}

# Wait for the proxy launch_session_proxy started to be up and serving, setting its endpoints, or
# fail with the reason on stderr.
#
# usage: await_session_proxy
await_session_proxy() {
    arity 0
    # Wait for the proxy to be up -- its ports reported, once it and the relays serve -- or to
    # die. A proxy that fails says so by exiting, and Caddy's start has a deadline of its own, so
    # chopi sets none: what else the start may wait on can take the user, like a keychain prompt
    # for the GitHub token the relays' config needs. A start that takes long says what it waits
    # on, for the user to answer the prompt, or give up with a Ctrl-C.
    # Polled briskly for the usual quick start, then, once it waits on the user, less often.
    local ports="$SESSION_PROXY_DIR/ports" notice=$((SECONDS + CHOPI_PROXY_START_NOTICE_SECS))
    local interval=0.02
    while [ ! -f "$ports" ] && session_proxy_alive; do
        if ((notice && SECONDS >= notice)); then
            notice=0 interval=0.2
            echo "chopi: waiting for the proxy to start -- for a keychain prompt to be answered," \
                 "if one is up; its log: $SESSION_PROXY_LOG" >&2
        fi
        sleep "$interval"
    done

    if ! session_proxy_alive; then
        wait "$SESSION_PROXY_PID" || true
        # The proxy says why it stopped on stderr; its log may tell more, smokescreen's own say
        # among it.
        if [ -s "$SESSION_PROXY_LOG" ]; then
            abandon_session_proxy "chopi: the proxy failed to start; its log: $SESSION_PROXY_LOG
$(tail -n 5 "$SESSION_PROXY_LOG" | sed 's/^/  /')"
        else
            abandon_session_proxy
        fi
        return 1
    fi

    # The ports are the ones the proxy bound as the kernel picked them, so no other process can
    # hold them.
    local name port
    while read -r name port; do
        case "$name" in
            proxy) SESSION_PROXY_PORT="$port" ;;
            relay) SESSION_RELAY_PORT="$port" ;;
        esac
    done <"$ports"
    # shellcheck disable=SC2034 # consumed by chopi.sh
    SESSION_GH_SOCK="$SESSION_PROXY_DIR/gh.sock"
    if ! [[ "$SESSION_PROXY_PORT" =~ ^[0-9]+$ && "$SESSION_RELAY_PORT" =~ ^[0-9]+$ ]]; then
        abandon_session_proxy "chopi: the proxy reported malformed ports in $ports"
        return 1
    fi

    # What chopi-proxy.sh said before it was up: notes and warnings, like a refusal the user
    # overrode, which are for the user to see all the same.
    cat "$SESSION_PROXY_ERR" >&2
}

# Is the session's proxy still running? Asked of bash's job table, not of the pid: once the proxy
# exits and bash reaps it, its pid -- and so its process group's id -- is free for the system to
# reuse, and signalling it then could reach an unrelated process.
session_proxy_alive() {
    arity 0
    # shellcheck disable=SC2046 # split into one pid per argument
    [ -n "$SESSION_PROXY_PID" ] && is_item_in_list "$SESSION_PROXY_PID" $(jobs -rp)
}

# Show what the proxy said as it failed to start, then chopi's own REASON if given, and stop what
# is left of it.
#
# usage: abandon_session_proxy [REASON]
abandon_session_proxy() {
    cat "$SESSION_PROXY_ERR" >&2
    [ $# -eq 0 ] || echo "$1" >&2
    stop_session_proxy
}

# Stop the session's proxy, if running: chopi-proxy.sh passes the TERM on to chopi-smokescreen,
# and stops Caddy with it (see lead_group), then removes its dir. The log formatter, left
# unsignalled, finishes once their output ends, so a last denial still reaches the log.
stop_session_proxy() {
    arity 0
    if session_proxy_alive; then
        kill -TERM "$SESSION_PROXY_PID" 2>/dev/null || true
    fi
    SESSION_PROXY_PID=""
}

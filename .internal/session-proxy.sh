# shellcheck shell=bash
#
# session-proxy.sh -- start and stop a chopi session's own outgoing proxy.
#
# Sourced (never run directly). Each session runs its own chopi-proxy.sh, on loopback ports the
# kernel picks, for the sandbox to reach through the holes write_session_proxy_network_profile
# opens, and stops it when the session ends. The proxy logs to a file of its own under
# CHOPI_PROXY_LOG_DIR, kept after the session for a while for inspection.

_session_proxy_dir="$(dirname "${BASH_SOURCE[0]}")"
. "$_session_proxy_dir/util.sh"
unset _session_proxy_dir

CHOPI_PROXY_SCRIPT="$CHOPI_DIR/.internal/chopi-proxy.sh"
CHOPI_PROXY_LOG_DIR="$HOME/Library/Logs/chopi"
# Days a log is kept past its last change. The proxy touches its logs daily while it runs, so a
# running session's log is never one of them.
CHOPI_PROXY_LOG_KEEP_DAYS=14

# Set by launch_session_proxy and await_session_proxy: the session's proxy, its log and temp dir,
# and its endpoints -- the smokescreen forward proxy's port (HTTP_PROXY), the git relay's port, and
# the API relay's unix socket (see github_relay_gh_env).
SESSION_PROXY_PID=""
SESSION_PROXY_LOG=""
SESSION_PROXY_DIR=""
SESSION_PROXY_PORT=""
SESSION_RELAY_PORT=""
SESSION_GH_SOCK=""

# Start the session's proxy, with temporaries under HOST_TMP (it must stay outside the sandbox's
# own private TMPDIR, which the sandboxed command can write), RULES and ALLOWLIST as its
# configuration, and its log verbose when VERBOSE is non-empty. Returns as soon as it is launched,
# for chopi to go on with its own setup as the proxy starts; await_session_proxy waits for it.
#
# usage: launch_session_proxy HOST_TMP RULES ALLOWLIST VERBOSE
launch_session_proxy() {
    arity 4
    local host_tmp="$1" rules="$2" allowlist="$3" verbose="$4"

    if ! mkdir -p "$CHOPI_PROXY_LOG_DIR" 2>/dev/null; then
        echo "chopi: cannot create the proxy log dir $CHOPI_PROXY_LOG_DIR" >&2
        return 1
    fi
    # Delete logs past their retention, in the background so the session's startup doesn't wait.
    # The subshell detaches it from chopi's jobs, so nothing waits for it later either.
    ( find "$CHOPI_PROXY_LOG_DIR" -name 'proxy-*.log' -mtime "+$CHOPI_PROXY_LOG_KEEP_DAYS" \
        -delete >/dev/null 2>&1 & )
    local now
    printf -v now '%(%Y%m%d-%H%M%S)T' -1
    SESSION_PROXY_LOG="$CHOPI_PROXY_LOG_DIR/proxy-$now-$$.log"

    local flags=(--log "$SESSION_PROXY_LOG" --parent "$$" --rules "$rules"
                 --github-allowlist "$allowlist")
    [ -n "$verbose" ] && flags+=(--verbose)

    # The proxy's dir of its own, for its temporaries, the API relay's socket, and the ports the
    # proxy reports.
    SESSION_PROXY_DIR="$(mktemp -d "${host_tmp%/}/chopi-proxy.XXXXXX")" \
        || { echo "chopi: could not create a temp dir for the proxy" >&2; return 1; }

    # Job control puts the proxy in a process group of its own, out of reach of the terminal's
    # signals: a Ctrl-C meant for the sandboxed command must not stop the proxy under it. chopi
    # stops it itself, and --parent covers chopi dying without the chance to.
    set -m
    "$CHOPI_PROXY_SCRIPT" --dir "$SESSION_PROXY_DIR" "${flags[@]}" </dev/null 2>"$SESSION_PROXY_DIR/startup.err" &
    SESSION_PROXY_PID=$!
    set +m
}

# Wait for the proxy launch_session_proxy started to be up and serving, setting its endpoints, or
# fail with the reason on stderr.
#
# usage: await_session_proxy
await_session_proxy() {
    arity 0
    # Wait for the proxy to be up -- its ports reported, once it and the relays serve -- or to
    # die. A proxy that fails says so by exiting, so the deadline only catches one that hangs: up
    # to 30s, well past a slow first start, when macOS scans each freshly built binary on its
    # first run.
    local ports="$SESSION_PROXY_DIR/ports" deadline=$((SECONDS + 30))
    while ((SECONDS < deadline)); do
        [ -f "$ports" ] && break
        session_proxy_alive || break
        sleep 0.1
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
    if [ ! -f "$ports" ]; then
        abandon_session_proxy "chopi: the proxy did not come up in time; its log: $SESSION_PROXY_LOG"
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

    show_session_proxy_startup_err
}

# Show what chopi-proxy.sh said before it was up: on success, notes and warnings, like a refusal
# the user overrode, which are for the user to see all the same; on failure, its reason.
show_session_proxy_startup_err() {
    arity 0
    cat "$SESSION_PROXY_DIR/startup.err" >&2
}

# Is the session's proxy still running? Asked of bash's job table, not of the pid: once the proxy
# exits and bash reaps it, its pid -- and so its process group's id -- is free for the system to
# reuse, and signalling it then could reach an unrelated process.
session_proxy_alive() {
    arity 0
    [ -n "$SESSION_PROXY_PID" ] && [[ " $(jobs -rp) " == *" $SESSION_PROXY_PID "* ]]
}

# Show what the proxy said as it failed to start, then chopi's own REASON if given, and stop what
# is left of it.
#
# usage: abandon_session_proxy [REASON]
abandon_session_proxy() {
    show_session_proxy_startup_err
    [ $# -eq 0 ] || echo "$1" >&2
    stop_session_proxy
}

# Stop the session's proxy, if running. Its process group goes with it -- Caddy included, even
# before chopi-smokescreen started it. Once the proxy is gone, so is the rest of its group, which it
# stops as it goes (see lead_group). Its dir goes too, which the proxy removes itself only once
# chopi is gone.
stop_session_proxy() {
    arity 0
    if session_proxy_alive; then
        kill -- "-$SESSION_PROXY_PID" 2>/dev/null || true
    fi
    SESSION_PROXY_PID=""
    if [ -n "$SESSION_PROXY_DIR" ]; then
        rm -rf "$SESSION_PROXY_DIR"
        SESSION_PROXY_DIR=""
    fi
}

# Write the Seatbelt profile re-opening the session's proxy endpoints to FILE: network.sb denies
# every outgoing connection, so these are the only ones the sandboxed command can make -- the
# smokescreen forward proxy on PORT, the git relay on RELAY_PORT, and the API relay's socket SOCK.
#
# usage: write_session_proxy_network_profile FILE PORT RELAY_PORT SOCK
write_session_proxy_network_profile() {
    arity 4
    local file="$1" port="$2" relay_port="$3" sock
    sock="$(realpath "$4")" \
        || { echo "chopi: cannot resolve the GitHub API relay socket path '$4'" >&2; return 1; }
    {
        echo ";; chopi: re-open the session's proxy endpoints (network.sb denies the rest):"
        echo ";; the smokescreen forward proxy, the git relay, and the API relay's socket."
        rule 'allow network-outbound' 'remote ip' "localhost:$port"
        rule 'allow network-outbound' 'remote ip' "localhost:$relay_port"
        rule 'allow network-outbound' literal "$sock"
    } >"$file"
}

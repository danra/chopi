package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"syscall"
	"time"
)

// The descriptors Caddy inherits its listeners on: ExtraFiles start at 3.
const (
	gitRelayFD = 3
	apiRelayFD = 4
)

// relayStartTimeout bounds Caddy's start, from launch to serving: time enough for macOS to scan
// a freshly installed Caddy on its first run.
const relayStartTimeout = 25 * time.Second

// options are chopi's own flags, given before "--" and smokescreen's flags.
type options struct {
	relayLog  string // Caddy's output
	gitPort   int    // the git relay's loopback port, or 0 for one the kernel picks
	ghSock    string // the API relay's unix socket
	smokeArgs []string
}

// parseOptions parses args (without the program name): chopi's flags, then "--" and smokescreen's.
func parseOptions(args []string) (options, error) {
	var opts options
	fs := flag.NewFlagSet("chopi-smokescreen", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	fs.StringVar(&opts.relayLog, "relay-log", "", "")
	fs.IntVar(&opts.gitPort, "git-port", -1, "")
	fs.StringVar(&opts.ghSock, "gh-sock", "", "")
	if err := fs.Parse(args); err != nil {
		return opts, err
	}
	if opts.gitPort > 65535 {
		return opts, fmt.Errorf("--git-port: not a port: %d", opts.gitPort)
	}
	// Parsing stops at "--" or at the first non-flag; only the former starts smokescreen's.
	if rest := len(args) - fs.NArg(); rest > 0 && args[rest-1] == "--" {
		opts.smokeArgs = fs.Args()
	}
	if opts.relayLog == "" || opts.gitPort < 0 || opts.ghSock == "" || opts.smokeArgs == nil {
		return opts, errors.New("usage: chopi-smokescreen --relay-log FILE --git-port PORT --gh-sock PATH -- SMOKESCREEN_FLAGS...")
	}
	return opts, nil
}

// relays are the GitHub relays' listeners, opened before Caddy starts, so no other process can
// take them first, and so Caddy, unable to report a port it picked, need not pick one.
type relays struct {
	git *net.TCPListener  // git smart-HTTP, on a loopback port
	api *net.UnixListener // the gh REST API, on a unix socket
}

// portOf is the port l listens on.
func portOf(l *net.TCPListener) int { return l.Addr().(*net.TCPAddr).Port }

// maxSocketPath is the longest unix socket path macOS binds: sun_path's 104 bytes, NUL included.
const maxSocketPath = 103

// listenRelays opens the git relay's listener on 127.0.0.1:gitPort -- or, for 0, a port the kernel
// picks -- and the API relay's on the unix socket sock.
func listenRelays(gitPort int, sock string) (*relays, error) {
	if len(sock) > maxSocketPath {
		return nil, fmt.Errorf("API relay: the socket path %s is %d bytes, past the %d macOS allows: "+
			"a shorter TMPDIR makes it fit", sock, len(sock), maxSocketPath)
	}
	git, err := net.ListenTCP("tcp", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1), Port: gitPort})
	if err != nil {
		return nil, fmt.Errorf("git relay: %w", err)
	}
	api, err := net.ListenUnix("unix", &net.UnixAddr{Name: sock, Net: "unix"})
	if err != nil {
		git.Close()
		return nil, fmt.Errorf("API relay: %w", err)
	}
	// Caddy serves on the socket from here on; closing this copy must leave its path in place.
	api.SetUnlinkOnClose(false)
	return &relays{git: git, api: api}, nil
}

// startCaddy starts Caddy on the relays' listeners, with its config on stdin -- never in argv,
// as it holds the GitHub token -- and its output in logPath. Caddy reads where its listeners are
// from its environment: CHOPI_GIT_FD and CHOPI_GH_FD, and CHOPI_GIT_PORT for the redirects it
// rewrites. It returns once Caddy is started, with a channel that closes once Caddy exits, and a
// stop that TERMs Caddy and returns once it has exited, killing it if it is still up after
// caddyStopTimeout.
func startCaddy(r *relays, logPath string) (stop func(), exited <-chan struct{}, err error) {
	gitFile, err := r.git.File()
	if err != nil {
		return nil, nil, err
	}
	defer gitFile.Close()
	apiFile, err := r.api.File()
	if err != nil {
		return nil, nil, err
	}
	defer apiFile.Close()
	logFile, err := os.OpenFile(logPath, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o600)
	if err != nil {
		return nil, nil, err
	}
	defer logFile.Close()

	ctx, cancel := context.WithCancel(context.Background())
	caddy := exec.CommandContext(ctx, "caddy", "run", "--adapter", "caddyfile", "--config", "-")
	caddy.Cancel = func() error { return caddy.Process.Signal(syscall.SIGTERM) }
	caddy.WaitDelay = caddyStopTimeout
	caddy.Stdin = os.Stdin
	caddy.Stdout = logFile
	caddy.Stderr = logFile
	caddy.ExtraFiles = []*os.File{gitFile, apiFile}
	// exec drops all but the last entry for a name, so these override any inherited ones.
	caddy.Env = append(os.Environ(),
		"CHOPI_GIT_PORT="+strconv.Itoa(portOf(r.git)),
		"CHOPI_GIT_FD="+strconv.Itoa(gitRelayFD),
		"CHOPI_GH_FD="+strconv.Itoa(apiRelayFD))
	if err := caddy.Start(); err != nil {
		cancel()
		return nil, nil, err
	}
	// Caddy holds the listeners now. Dropping ours means a Caddy that dies refuses connections
	// instead of leaving them queued on a listener nothing serves.
	r.git.Close()
	r.api.Close()

	done := make(chan struct{})
	go func() {
		caddy.Wait()
		close(done)
	}()
	return func() { cancel(); <-done }, done, nil
}

// caddyStopTimeout bounds Caddy's stop, from TERM to exit, before it is killed: by default Caddy
// waits as long as it takes for its connections to close. A var, for tests to shorten.
var caddyStopTimeout = 5 * time.Second

// awaitCaddy waits for Caddy to serve the git relay: any HTTP response there. The listener
// predates Caddy, so the request waits in its backlog until Caddy takes it. The channel it
// returns gets nil once Caddy serves, or why it doesn't.
func awaitCaddy(port int) <-chan error {
	// The zero Proxy is none: straight to Caddy, whatever http_proxy the user's environment has.
	// One request is all this client makes: it keeps no connection to Caddy open.
	client := &http.Client{Transport: &http.Transport{DisableKeepAlives: true}, Timeout: relayStartTimeout}
	answered := make(chan error, 1)
	go func() {
		resp, err := client.Get("http://127.0.0.1:" + strconv.Itoa(port) + "/")
		if err == nil {
			resp.Body.Close()
		}
		answered <- err
	}()
	return answered
}

// stopSignals are the signals that stop the proxy: a Ctrl-C's INT, a TERM, and a closing
// terminal's HUP.
func stopSignals() <-chan os.Signal {
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGTERM, syscall.SIGHUP, syscall.SIGINT)
	return ch
}

package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
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
	ghSock    string // the API relay's unix socket
	portsFile string // where the ports are reported once the proxy is up
	smokeArgs []string
}

// parseOptions parses args (without the program name): chopi's flags, then "--" and smokescreen's.
func parseOptions(args []string) (options, error) {
	var opts options
	fs := flag.NewFlagSet("chopi-smokescreen", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	fs.StringVar(&opts.relayLog, "relay-log", "", "")
	fs.StringVar(&opts.ghSock, "gh-sock", "", "")
	fs.StringVar(&opts.portsFile, "ports-file", "", "")
	if err := fs.Parse(args); err != nil {
		return opts, err
	}
	// Parsing stops at "--" or at the first non-flag; only the former starts smokescreen's.
	if rest := len(args) - fs.NArg(); rest > 0 && args[rest-1] == "--" {
		opts.smokeArgs = fs.Args()
	}
	if opts.relayLog == "" || opts.ghSock == "" || opts.portsFile == "" || opts.smokeArgs == nil {
		return opts, errors.New("usage: chopi-smokescreen --relay-log FILE --gh-sock PATH " +
			"--ports-file FILE -- SMOKESCREEN_FLAGS...")
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

// listenAPIRelay opens the API relay's listener on the unix socket sock.
func listenAPIRelay(sock string) (*net.UnixListener, error) {
	if len(sock) > maxSocketPath {
		return nil, fmt.Errorf("API relay: the socket path %s is %d bytes, past the %d macOS allows: "+
			"a shorter CHOPI_RUN_DIR makes it fit", sock, len(sock), maxSocketPath)
	}
	api, err := net.ListenUnix("unix", &net.UnixAddr{Name: sock, Net: "unix"})
	if err != nil {
		return nil, fmt.Errorf("API relay: %w", err)
	}
	// Caddy serves on the socket from here on; closing this copy must leave its path in place.
	api.SetUnlinkOnClose(false)
	return api, nil
}

// startCaddy starts Caddy on the relays' listeners, with its config on stdin -- never in argv,
// as it holds the GitHub token -- and its output in logPath. Caddy reads where its listeners are
// from its environment: CHOPI_GIT_FD and CHOPI_GH_FD, and CHOPI_GIT_PORT for the redirects it
// rewrites. It returns once Caddy is started, with a channel that closes once Caddy exits, one that
// gets nil once Caddy serves, or why it doesn't, and a stop that TERMs Caddy and returns once it
// has exited, killing it if it is still up after caddyStopTimeout.
func startCaddy(r *relays, logPath string) (stop func(), exited <-chan struct{}, served <-chan error, err error) {
	gitFile, err := r.git.File()
	if err != nil {
		return nil, nil, nil, err
	}
	defer gitFile.Close()
	apiFile, err := r.api.File()
	if err != nil {
		return nil, nil, nil, err
	}
	defer apiFile.Close()
	logFile, err := os.OpenFile(logPath, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o600)
	if err != nil {
		return nil, nil, nil, err
	}
	defer logFile.Close()
	pingback, err := listenLoopback(0)
	if err != nil {
		return nil, nil, nil, err
	}

	ctx, cancel := context.WithCancel(context.Background())
	caddy := exec.CommandContext(ctx, "caddy", "run", "--adapter", "caddyfile", "--config", "-",
		"--pingback", pingback.Addr().String())
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
		pingback.Close()
		return nil, nil, nil, err
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
	return func() { cancel(); <-done }, done, awaitPingback(pingback), nil
}

// awaitPingback waits for Caddy to report it serves, as it does by connecting to its --pingback
// address, pingback, which it closes then: Caddy's own word that its config is in effect, where a
// request to the relays only says something answers them. The channel it returns gets nil once
// Caddy serves, or why it doesn't.
func awaitPingback(pingback *net.TCPListener) <-chan error {
	pinged := make(chan error, 1)
	go func() {
		defer pingback.Close()
		pingback.SetDeadline(time.Now().Add(relayStartTimeout))
		conn, err := pingback.Accept()
		if err == nil {
			conn.Close()
		}
		pinged <- err
	}()
	return pinged
}

// caddyStopTimeout bounds Caddy's stop, from TERM to exit, before it is killed: by default Caddy
// waits as long as it takes for its connections to close. A var, for tests to shorten.
var caddyStopTimeout = 5 * time.Second

// writeAtomically writes content to path, whole or not at all: it is written beside path and
// renamed over it, so a reader polling for path never sees it partly written.
func writeAtomically(path, content string) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), ".tmp-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.WriteString(content); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

// ports are the proxy's and the git relay's ports, as reported to chopi.
type ports struct {
	proxy, relay int
}

// reportPorts writes the ports to path, one "NAME PORT" line each, for chopi to learn them from,
// and to know the proxy is up.
func reportPorts(path string, p ports) error {
	return writeAtomically(path, fmt.Sprintf("proxy %d\nrelay %d\n", p.proxy, p.relay))
}

// lastPortsFile is where the ports reported in portsFile are recorded for the proxy's next run: kept
// beside it, but left as the proxy stops, unlike portsFile, which says the proxy is up.
func lastPortsFile(portsFile string) string {
	return portsFile + ".last"
}

// readPorts reads the ports reportPorts wrote to path: zero for a port missing, invalid, or in a
// file missing or unreadable.
func readPorts(path string) ports {
	var p ports
	data, err := os.ReadFile(path)
	if err != nil {
		return p
	}
	for _, line := range strings.Split(string(data), "\n") {
		var name string
		var port int
		if n, _ := fmt.Sscan(line, &name, &port); n != 2 || port <= 0 || port > 65535 {
			continue
		}
		switch name {
		case "proxy":
			p.proxy = port
		case "relay":
			p.relay = port
		}
	}
	return p
}

// stopSignals are the signals that stop the proxy: a Ctrl-C's INT, a TERM, and a closing
// terminal's HUP.
func stopSignals() <-chan os.Signal {
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGTERM, syscall.SIGHUP, syscall.SIGINT)
	return ch
}

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
	"path/filepath"
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
// a freshly installed Caddy on its first run, yet short of chopi's own 30s wait for the proxy, so
// a Caddy that never serves still fails with its own reason rather than chopi's bare timeout.
const relayStartTimeout = 25 * time.Second

// options are chopi's own flags, given before "--" and smokescreen's flags.
type options struct {
	dir       string   // where the ports are reported and the API relay's socket is; removed once parent exits
	parent    int      // the process whose exit stops the proxy: chopi
	relayLog  string   // Caddy's output
	keepFresh []string // files touched hourly while the proxy runs, the relay log among them
	smokeArgs []string
}

// parseOptions parses args (without the program name): chopi's flags, then "--" and smokescreen's.
func parseOptions(args []string) (options, error) {
	var opts options
	fs := flag.NewFlagSet("chopi-smokescreen", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	fs.StringVar(&opts.dir, "dir", "", "")
	fs.IntVar(&opts.parent, "parent", 0, "")
	fs.StringVar(&opts.relayLog, "relay-log", "", "")
	fs.Func("keep-fresh", "", func(path string) error {
		opts.keepFresh = append(opts.keepFresh, path)
		return nil
	})
	if err := fs.Parse(args); err != nil {
		return opts, err
	}
	// Parsing stops at "--" or at the first non-flag; only the former starts smokescreen's.
	if rest := len(args) - fs.NArg(); rest > 0 && args[rest-1] == "--" {
		opts.smokeArgs = fs.Args()
	}
	if opts.parent < 0 {
		return opts, fmt.Errorf("--parent: not a pid: %d", opts.parent)
	}
	if opts.dir == "" || opts.parent == 0 || opts.relayLog == "" || opts.smokeArgs == nil {
		return opts, errors.New("usage: chopi-smokescreen --dir DIR --parent PID --relay-log FILE " +
			"[--keep-fresh FILE]... -- SMOKESCREEN_FLAGS...")
	}
	opts.keepFresh = append(opts.keepFresh, opts.relayLog)
	return opts, nil
}

// keepFreshInterval is how often keepFresh touches the session's logs: well within the days chopi
// keeps a log past its last change, so it never deletes a running session's. It counts awake time
// only, as Go's timers on macOS stand still while the machine sleeps, so it's short: a session
// on a laptop that's mostly asleep still gets its logs touched within an hour of each wake.
const keepFreshInterval = time.Hour

// keepFresh touches each of paths every interval, for as long as the proxy runs.
func keepFresh(paths []string, interval time.Duration) {
	for range time.Tick(interval) {
		now := time.Now()
		for _, path := range paths {
			os.Chtimes(path, now, now)
		}
	}
}

// relays are the GitHub relays' listeners, opened before Caddy starts, so no other process can
// take them first, and so Caddy, unable to report a port it picked, need not pick one.
type relays struct {
	git *net.TCPListener  // git smart-HTTP, on a loopback port the kernel picks
	api *net.UnixListener // the gh REST API, on DIR/gh.sock
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

// watchExit returns a channel that closes once process pid exits: the kernel reports it, with
// kqueue, so nothing polls. It closes right away for a process already gone.
func watchExit(pid int) (<-chan struct{}, error) {
	kq, err := syscall.Kqueue()
	if err != nil {
		return nil, err
	}
	syscall.CloseOnExec(kq)
	exited := make(chan struct{})
	var ev syscall.Kevent_t
	syscall.SetKevent(&ev, pid, syscall.EVFILT_PROC, syscall.EV_ADD|syscall.EV_ONESHOT)
	ev.Fflags = syscall.NOTE_EXIT
	if _, err := syscall.Kevent(kq, []syscall.Kevent_t{ev}, nil, nil); err != nil {
		syscall.Close(kq)
		if errors.Is(err, syscall.ESRCH) {
			close(exited)
			return exited, nil
		}
		return nil, err
	}
	go func() {
		defer syscall.Close(kq)
		events := make([]syscall.Kevent_t, 1)
		for {
			if _, err := syscall.Kevent(kq, nil, events, nil); !errors.Is(err, syscall.EINTR) {
				break
			}
		}
		close(exited)
	}()
	return exited, nil
}

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

// stopSignals are the signals that stop the proxy: chopi's TERM as the session ends, and a
// closing terminal's HUP.
func stopSignals() <-chan os.Signal {
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGTERM, syscall.SIGHUP, syscall.SIGINT)
	return ch
}

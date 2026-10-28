package main

import (
	"errors"
	"fmt"
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
	keepFresh []string // files touched daily while the proxy runs, the relay log among them
	smokeArgs []string
}

// parseOptions parses args (without the program name): chopi's flags, then "--" and smokescreen's.
func parseOptions(args []string) (options, error) {
	var opts options
	for len(args) > 0 {
		flag := args[0]
		args = args[1:]
		if flag == "--" {
			opts.smokeArgs = args
			break
		}
		if len(args) == 0 {
			return opts, fmt.Errorf("%s requires a value", flag)
		}
		value := args[0]
		args = args[1:]
		switch flag {
		case "--dir":
			opts.dir = value
		case "--relay-log":
			opts.relayLog = value
		case "--keep-fresh":
			opts.keepFresh = append(opts.keepFresh, value)
		case "--parent":
			pid, err := strconv.Atoi(value)
			if err != nil || pid <= 0 {
				return opts, fmt.Errorf("--parent: not a pid: %q", value)
			}
			opts.parent = pid
		default:
			return opts, fmt.Errorf("unknown option %s", flag)
		}
	}
	if opts.dir == "" || opts.parent == 0 || opts.relayLog == "" || opts.smokeArgs == nil {
		return opts, errors.New("usage: chopi-smokescreen --dir DIR --parent PID --relay-log FILE [--keep-fresh FILE]... -- SMOKESCREEN_FLAGS...")
	}
	opts.keepFresh = append(opts.keepFresh, opts.relayLog)
	return opts, nil
}

// keepFreshInterval is how often keepFresh touches the session's logs: well within the days chopi
// keeps a log past its last change, so it never deletes a running session's.
const keepFreshInterval = 24 * time.Hour

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
	git     *net.TCPListener  // git smart-HTTP, on a loopback port the kernel picks
	api     *net.UnixListener // the gh REST API, on DIR/gh.sock
	gitPort int
}

// maxSocketPath is the longest unix socket path macOS binds: sun_path's 104 bytes, NUL included.
const maxSocketPath = 103

func listenRelays(dir string) (*relays, error) {
	sock := filepath.Join(dir, "gh.sock")
	if len(sock) > maxSocketPath {
		return nil, fmt.Errorf("API relay: the socket path %s is %d bytes, past the %d macOS allows: "+
			"a shorter TMPDIR makes it fit", sock, len(sock), maxSocketPath)
	}
	git, err := net.ListenTCP("tcp", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
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
	return &relays{git: git, api: api, gitPort: git.Addr().(*net.TCPAddr).Port}, nil
}

// startCaddy starts Caddy on the relays' listeners, with its config on stdin -- never in argv,
// as it holds the GitHub token -- and its output in logPath. Caddy reads where its listeners are
// from its environment: CHOPI_GIT_FD and CHOPI_GH_FD, and CHOPI_GIT_PORT for the redirects it
// rewrites. It returns once Caddy is started, with a channel that closes once Caddy exits.
func startCaddy(r *relays, logPath string) (*exec.Cmd, <-chan struct{}, error) {
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

	caddy := exec.Command("caddy", "run", "--adapter", "caddyfile", "--config", "-")
	caddy.Stdin = os.Stdin
	caddy.Stdout = logFile
	caddy.Stderr = logFile
	caddy.ExtraFiles = []*os.File{gitFile, apiFile}
	// exec drops all but the last entry for a name, so these override any inherited ones.
	caddy.Env = append(os.Environ(),
		"CHOPI_GIT_PORT="+strconv.Itoa(r.gitPort),
		"CHOPI_GIT_FD="+strconv.Itoa(gitRelayFD),
		"CHOPI_GH_FD="+strconv.Itoa(apiRelayFD))
	if err := caddy.Start(); err != nil {
		return nil, nil, err
	}
	// Caddy holds the listeners now. Dropping ours means a Caddy that dies refuses connections
	// instead of leaving them queued on a listener nothing serves.
	r.git.Close()
	r.api.Close()

	exited := make(chan struct{})
	go func() {
		caddy.Wait()
		close(exited)
	}()
	return caddy, exited, nil
}

// awaitCaddy waits for Caddy to serve the git relay: any HTTP response there. The listener
// predates Caddy, so the request waits in its backlog until Caddy takes it. The channel it
// returns gets nil once Caddy serves, or why it doesn't.
func awaitCaddy(port int) <-chan error {
	// No proxy: straight to Caddy, whatever http_proxy the user's environment has.
	client := &http.Client{Transport: &http.Transport{Proxy: nil}, Timeout: relayStartTimeout}
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

// reportPorts writes the ports to DIR/ports, one "NAME PORT" line each, for chopi to learn them
// from, and to know the proxy is up.
func reportPorts(dir string, proxyPort, relayPort int) error {
	return writeAtomically(filepath.Join(dir, "ports"),
		fmt.Sprintf("proxy %d\nrelay %d\n", proxyPort, relayPort))
}

// stopSignals are the signals that stop the proxy: chopi's TERM as the session ends, and a
// closing terminal's HUP.
func stopSignals() <-chan os.Signal {
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGTERM, syscall.SIGHUP, syscall.SIGINT)
	return ch
}

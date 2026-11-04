package main

import (
	"bytes"
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
	"sync"
	"syscall"
	"time"

	"github.com/sirupsen/logrus"
)

// The descriptors Caddy inherits its listeners on: ExtraFiles start at 3.
const (
	gitRelayFD = 3
	apiRelayFD = 4
)

// relayStartTimeout bounds Caddy's start, from launch to serving: time enough for macOS to scan
// a freshly installed Caddy on its first run. chopi sets no deadline of its own for the proxy's
// start, so a Caddy that never serves fails the session by this one, with its own reason.
const relayStartTimeout = 25 * time.Second

// relayDrainTimeout bounds the stop of a Caddy a reload replaced, from TERM to exit, before it is
// killed: it serves the requests it has to their end, a long push among them, but takes no more.
const relayDrainTimeout = 10 * time.Minute

// options are chopi's own flags, given before "--" and smokescreen's flags.
type options struct {
	dir         string // where the ports are reported and the API relay's socket is
	relayLog    string // Caddy's output
	allowlist   string // the GitHub allowlist, watched for changes
	relayConfig string // the command rendering the relays' Caddy config from the allowlist
	smokeArgs   []string
}

// parseOptions parses args (without the program name): chopi's flags, then "--" and smokescreen's.
func parseOptions(args []string) (options, error) {
	var opts options
	fs := flag.NewFlagSet("chopi-smokescreen", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	fs.StringVar(&opts.dir, "dir", "", "")
	fs.StringVar(&opts.relayLog, "relay-log", "", "")
	fs.StringVar(&opts.allowlist, "github-allowlist", "", "")
	fs.StringVar(&opts.relayConfig, "relay-config", "", "")
	if err := fs.Parse(args); err != nil {
		return opts, err
	}
	// Parsing stops at "--" or at the first non-flag; only the former starts smokescreen's.
	if rest := len(args) - fs.NArg(); rest > 0 && args[rest-1] == "--" {
		opts.smokeArgs = fs.Args()
	}
	if opts.dir == "" || opts.relayLog == "" || opts.allowlist == "" ||
		opts.relayConfig == "" || opts.smokeArgs == nil {
		return opts, errors.New("usage: chopi-smokescreen --dir DIR --relay-log FILE " +
			"--github-allowlist FILE --relay-config CMD -- SMOKESCREEN_FLAGS...")
	}
	return opts, nil
}

// relays are the GitHub relays' listeners, opened before Caddy starts, so no other process can
// take them first, and so Caddy, unable to report a port it picked, need not pick one. Kept open
// here, for each Caddy a reload starts to serve them in turn.
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

// takeEnv removes the environment variables names from ours, returning those set as NAME=VALUE.
func takeEnv(names ...string) []string {
	var taken []string
	for _, name := range names {
		if value, ok := os.LookupEnv(name); ok {
			taken = append(taken, name+"="+value)
			os.Unsetenv(name)
		}
	}
	return taken
}

// relayConfig renders the relays' Caddy config: the output of cmd run on the GitHub allowlist, with
// env added to our environment -- the GitHub token the user exported, if any, which only cmd gets.
type relayConfig struct {
	cmd, allowlist string
	env            []string
}

// render returns the relays' config, with any notes cmd had for the user on stderr -- or, failing,
// an error with what cmd said on stderr: why.
func (c relayConfig) render() (config []byte, notes string, err error) {
	cmd := exec.Command(c.cmd, c.allowlist)
	cmd.Env = append(os.Environ(), c.env...)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	config, err = cmd.Output()
	said := strings.TrimSpace(stderr.String())
	if err != nil {
		return nil, "", fmt.Errorf("rendering the GitHub relays' config from %s failed (%v): %s",
			c.allowlist, err, said)
	}
	return config, said, nil
}

// caddyProc is a Caddy serving the relays, or starting or stopping to.
type caddyProc struct {
	process *os.Process
	config  []byte        // what it serves
	exited  chan struct{} // closed once it has exited
}

// stop TERMs Caddy and returns once it has exited, killing it if it is still up after timeout: by
// default Caddy waits as long as it takes for its connections to close.
func (c *caddyProc) stop(timeout time.Duration) {
	c.process.Signal(syscall.SIGTERM)
	select {
	case <-c.exited:
		return
	case <-time.After(timeout):
	}
	c.process.Kill()
	<-c.exited
}

// caddyStopTimeout bounds Caddy's stop as the proxy stops, from TERM to exit, before it is killed.
// A var, for tests to shorten.
var caddyStopTimeout = 5 * time.Second

// relaySupervisor runs the Caddy serving the relays, and on a change to the GitHub allowlist,
// replaces it with one on the new config, on the same listeners, kept open here for the proxy's
// life: their ports and socket path are what running chopi sessions are confined to.
type relaySupervisor struct {
	relays  *relays
	logPath string // Caddy's output, every Caddy's in turn
	config  relayConfig
	log     *logrus.Entry // where reloads are logged

	mu      sync.Mutex
	live    map[*caddyProc]bool // every Caddy running: starting, serving, or finishing up once replaced
	serving *caddyProc
	stopped bool // by stopAll: no Caddy starts from then on

	failed     chan struct{} // closed once the serving Caddy exits unasked
	failedOnce sync.Once
}

func newRelaySupervisor(r *relays, logPath string, config relayConfig, log *logrus.Entry) *relaySupervisor {
	return &relaySupervisor{relays: r, logPath: logPath, config: config, log: log,
		live: map[*caddyProc]bool{}, failed: make(chan struct{})}
}

// start starts a Caddy on the relays' listeners, with config on stdin -- never in argv, as it
// holds the GitHub token -- and its output in the log. Caddy reads where its listeners are from its
// environment: CHOPI_GIT_FD and CHOPI_GH_FD, and CHOPI_GIT_PORT for the redirects it rewrites. It
// returns once Caddy serves, as Caddy reports by connecting to its --pingback address: not by
// asking the relays, which may still be answered by the Caddy it replaces. A Caddy that doesn't
// come up is stopped.
func (s *relaySupervisor) start(config []byte) (*caddyProc, error) {
	gitFile, err := s.relays.git.File()
	if err != nil {
		return nil, err
	}
	defer gitFile.Close()
	apiFile, err := s.relays.api.File()
	if err != nil {
		return nil, err
	}
	defer apiFile.Close()
	logFile, err := os.OpenFile(s.logPath, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o600)
	if err != nil {
		return nil, err
	}
	defer logFile.Close()
	pingback, err := listenLoopback()
	if err != nil {
		return nil, err
	}
	defer pingback.Close()

	caddy := exec.Command("caddy", "run", "--adapter", "caddyfile", "--config", "-",
		"--pingback", pingback.Addr().String())
	caddy.Stdin = bytes.NewReader(config)
	caddy.Stdout = logFile
	caddy.Stderr = logFile
	caddy.ExtraFiles = []*os.File{gitFile, apiFile}
	// exec drops all but the last entry for a name, so these override any inherited ones.
	caddy.Env = append(os.Environ(),
		"CHOPI_GIT_PORT="+strconv.Itoa(portOf(s.relays.git)),
		"CHOPI_GIT_FD="+strconv.Itoa(gitRelayFD),
		"CHOPI_GH_FD="+strconv.Itoa(apiRelayFD))
	s.mu.Lock()
	if s.stopped {
		s.mu.Unlock()
		return nil, errors.New("the proxy is stopping")
	}
	if err := caddy.Start(); err != nil {
		s.mu.Unlock()
		return nil, err
	}
	proc := &caddyProc{process: caddy.Process, config: config, exited: make(chan struct{})}
	s.live[proc] = true
	s.mu.Unlock()
	go func() {
		caddy.Wait()
		close(proc.exited)
		s.mu.Lock()
		delete(s.live, proc)
		unasked := s.serving == proc
		s.mu.Unlock()
		if unasked {
			s.fail()
		}
	}()

	pinged := make(chan error, 1)
	go func() {
		conn, err := pingback.Accept()
		if err == nil {
			conn.Close()
		}
		pinged <- err
	}()
	select {
	case err := <-pinged:
		if err != nil {
			proc.stop(caddyStopTimeout)
			return nil, err
		}
		return proc, nil
	case <-proc.exited:
		return nil, errors.New("caddy exited")
	case <-time.After(relayStartTimeout):
		proc.stop(caddyStopTimeout)
		return nil, fmt.Errorf("caddy did not serve within %v", relayStartTimeout)
	}
}

func (s *relaySupervisor) fail() {
	s.failedOnce.Do(func() { close(s.failed) })
}

// serve has proc serve the relays, returning the Caddy it replaces, if any. A proc already gone
// fails the relays, as its exit, seen before it served them, didn't.
func (s *relaySupervisor) serve(proc *caddyProc) (replaced *caddyProc) {
	s.mu.Lock()
	replaced, s.serving = s.serving, proc
	s.mu.Unlock()
	select {
	case <-proc.exited:
		s.fail()
	default:
	}
	return replaced
}

// reload replaces the serving Caddy with one on the config rendered from the allowlist as it now
// is, unless that is the config it already serves (a save with no edit). On failure, the serving
// Caddy stays.
func (s *relaySupervisor) reload() error {
	config, notes, err := s.config.render()
	if err != nil {
		return err
	}
	if notes != "" {
		fmt.Println(notes)
	}
	s.mu.Lock()
	unchanged := s.serving != nil && bytes.Equal(s.serving.config, config)
	s.mu.Unlock()
	if unchanged {
		return nil
	}
	var logged int64
	if st, err := os.Stat(s.logPath); err == nil {
		logged = st.Size()
	}
	proc, err := s.start(config)
	if err != nil {
		return fmt.Errorf("caddy did not come up (%v): %s", err, outputSince(s.logPath, logged))
	}
	if replaced := s.serve(proc); replaced != nil {
		go replaced.stop(relayDrainTimeout)
	}
	return nil
}

// outputSince is what was written to the file at path past offset, on one line.
func outputSince(path string, offset int64) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	out, _ := io.ReadAll(io.NewSectionReader(f, offset, 1<<16))
	return strings.Join(strings.Fields(string(out)), " ")
}

// reloadIfChanged reloads the relays if the allowlist changed since lastMod, as the rules are.
func (s *relaySupervisor) reloadIfChanged(lastMod time.Time, warned bool) (time.Time, bool) {
	return applyIfChanged(s.log, s.config.allowlist, allowlistReloaded, allowlistReloadFailed, lastMod, warned, s.reload)
}

// stopAll stops every Caddy running, at once, returning once they have all exited.
func (s *relaySupervisor) stopAll() {
	s.mu.Lock()
	s.serving = nil // stopping it now is asked
	s.stopped = true
	procs := make([]*caddyProc, 0, len(s.live))
	for proc := range s.live {
		procs = append(procs, proc)
	}
	s.mu.Unlock()
	var wg sync.WaitGroup
	for _, proc := range procs {
		wg.Add(1)
		go func(proc *caddyProc) {
			defer wg.Done()
			proc.stop(caddyStopTimeout)
		}(proc)
	}
	wg.Wait()
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
	signal.Notify(ch, syscall.SIGTERM, syscall.SIGHUP)
	return ch
}

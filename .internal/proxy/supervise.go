package main

import (
	"bytes"
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
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
	parent      int    // the process whose exit stops the proxy: chopi
	relayLog    string // Caddy's output
	allowlist   string // the GitHub allowlist, watched for changes
	relayConfig string // the command rendering the relays' Caddy config from the allowlist

	// Rules and a GitHub allowlist adding to the base ones (see added.go). They are watched for
	// changes the same way, and each may be missing.
	addRules, addAllowlist string

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
	fs.StringVar(&opts.allowlist, "github-allowlist", "", "")
	fs.StringVar(&opts.relayConfig, "relay-config", "", "")
	fs.StringVar(&opts.addRules, "add-rules", "", "")
	fs.StringVar(&opts.addAllowlist, "add-github-allowlist", "", "")
	if err := fs.Parse(args); err != nil {
		return opts, err
	}
	// Parsing stops at "--" or at the first non-flag; only the former starts smokescreen's.
	if rest := len(args) - fs.NArg(); rest > 0 && args[rest-1] == "--" {
		opts.smokeArgs = fs.Args()
	}
	if opts.dir == "" || opts.parent <= 0 || opts.relayLog == "" ||
		opts.allowlist == "" || opts.relayConfig == "" ||
		opts.addRules == "" || opts.addAllowlist == "" || opts.smokeArgs == nil {
		return opts, errors.New("usage: chopi-smokescreen --dir DIR --parent PID " +
			"--relay-log FILE --github-allowlist FILE " +
			"--add-rules FILE --add-github-allowlist FILE " +
			"--relay-config CMD -- SMOKESCREEN_FLAGS...")
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
			"a shorter CHOPI_RUN_DIR, the tests' run dir, makes it fit", sock, len(sock), maxSocketPath)
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

// relayConfig renders the relays' Caddy config: the output of cmd run on the GitHub allowlist.
// env holds the GitHub token the user exported, if any. Only cmd gets it, added to our
// environment.
type relayConfig struct {
	cmd string
	env []string
}

// allowlistEntry matches a GitHub allowlist entry: owner/repo, or owner/* for all the owner's
// repos. github-relays-caddyfile.sh's is_allowlist_entry, which renders the relays from the
// entries, checks the same. It is a sanity check that keeps a config value safe, and doesn't
// follow GitHub's actual naming rules.
var allowlistEntry = regexp.MustCompile(`^[A-Za-z0-9._-]+/([A-Za-z0-9._-]+|\*)$`)

// allowlistEntries returns the GitHub allowlist the relays are rendered from: the entries of the
// base allowlist, at basePath, then those of the one added to it, at addedPath. A nil added, for a
// missing added allowlist, adds nothing.
//
// Each line holds one entry, with any trailing '#'-comment dropped and surrounding whitespace
// trimmed. Blank lines hold none. allowlistEntries refuses a line that isn't an entry, naming its
// file.
func allowlistEntries(basePath, addedPath string, base, added []byte) ([]string, error) {
	var entries []string
	for _, file := range []struct {
		path    string
		content []byte
	}{{basePath, base}, {addedPath, added}} {
		for _, line := range strings.Split(string(file.content), "\n") {
			entry, _, _ := strings.Cut(line, "#")
			entry = strings.TrimSpace(entry)
			if entry == "" {
				continue
			}
			if !allowlistEntry.MatchString(entry) {
				return nil, fmt.Errorf("%s: allowlist entry needs owner/repo or owner/*, using only A-Za-z0-9._-: '%s'", file.path, entry)
			}
			entries = append(entries, entry)
		}
	}
	return entries, nil
}

// renderCancelGrace bounds how long a cancelled render's output pipes are waited on, once its
// process group is TERMed, before they are closed on whatever still holds them.
const renderCancelGrace = 2 * time.Second

// render returns the relays' config, rendered by cmd from the GitHub allowlist, one entry per
// argument. It also returns any notes cmd wrote on stderr for the user. If cmd fails, the error
// includes what cmd wrote on stderr, which says why.
//
// Cancelling ctx TERMs cmd's whole process group: what cmd waits on, like gh at a keychain prompt
// for the token, is a child process of cmd's.
func (c relayConfig) render(ctx context.Context, allowlist []string) (config []byte, notes string, err error) {
	cmd := exec.CommandContext(ctx, c.cmd, allowlist...)
	cmd.Env = append(os.Environ(), c.env...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM) }
	cmd.WaitDelay = renderCancelGrace
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	config, err = cmd.Output()
	said := strings.TrimSpace(stderr.String())
	if err != nil {
		return nil, "", fmt.Errorf("rendering the GitHub relays' config failed (%v): %s", err, said)
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

// relaySupervisor runs the Caddy serving the relays. On a change to a GitHub allowlist, the base
// one or one added to it, it replaces that Caddy with one on the new config, on the same listeners.
// It keeps the listeners open for the proxy's life, as running chopi sessions are confined to their
// ports and socket path.
type relaySupervisor struct {
	relays  *relays
	logPath string // Caddy's output, every Caddy's in turn
	config  relayConfig

	mu      sync.Mutex
	live    map[*caddyProc]bool // every Caddy running: starting, serving, or finishing up once replaced
	serving *caddyProc
	stopped bool // by stopAll: no Caddy starts from then on, nor a render

	// A reload's render, maybe at a keychain prompt, is stopped by stopAll, which cancels it and
	// waits for it: its process group is its own, out of reach of a stop of ours.
	stopRenders context.CancelFunc
	renderCtx   context.Context
	rendering   sync.WaitGroup

	failed     chan struct{} // closed once the serving Caddy exits unasked
	failedOnce sync.Once
}

func newRelaySupervisor(r *relays, logPath string, config relayConfig) *relaySupervisor {
	renderCtx, stopRenders := context.WithCancel(context.Background())
	return &relaySupervisor{relays: r, logPath: logPath, config: config,
		live: map[*caddyProc]bool{}, failed: make(chan struct{}),
		renderCtx: renderCtx, stopRenders: stopRenders}
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

// reload replaces the serving Caddy with one on the config rendered from the GitHub allowlist
// (relayConfig.render), unless the serving Caddy already serves that config (a save with no
// edit). On failure, the serving Caddy stays.
func (s *relaySupervisor) reload(allowlist []string) error {
	s.mu.Lock()
	if s.stopped {
		s.mu.Unlock()
		return errors.New("the proxy is stopping")
	}
	s.rendering.Add(1)
	s.mu.Unlock()
	config, notes, err := s.config.render(s.renderCtx, allowlist)
	s.rendering.Done()
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

// stopAll stops every Caddy running, and any reload's render, at once, returning once they have
// all exited.
func (s *relaySupervisor) stopAll() {
	s.mu.Lock()
	s.serving = nil // stopping it now is asked
	s.stopped = true
	procs := make([]*caddyProc, 0, len(s.live))
	for proc := range s.live {
		procs = append(procs, proc)
	}
	s.mu.Unlock()
	s.stopRenders()
	var wg sync.WaitGroup
	for _, proc := range procs {
		wg.Add(1)
		go func(proc *caddyProc) {
			defer wg.Done()
			proc.stop(caddyStopTimeout)
		}(proc)
	}
	wg.Wait()
	s.rendering.Wait()
}

// watchExit returns a context derived from parent, cancelled too once process pid exits: the
// kernel reports it, with kqueue, so nothing polls. It is cancelled right away for a process
// already gone.
func watchExit(parent context.Context, pid int) (context.Context, error) {
	kq, err := syscall.Kqueue()
	if err != nil {
		return nil, err
	}
	syscall.CloseOnExec(kq)
	ctx, exited := context.WithCancel(parent)
	var ev syscall.Kevent_t
	syscall.SetKevent(&ev, pid, syscall.EVFILT_PROC, syscall.EV_ADD|syscall.EV_ONESHOT)
	ev.Fflags = syscall.NOTE_EXIT
	if _, err := syscall.Kevent(kq, []syscall.Kevent_t{ev}, nil, nil); err != nil {
		syscall.Close(kq)
		exited()
		if errors.Is(err, syscall.ESRCH) {
			return ctx, nil
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
		exited()
	}()
	return ctx, nil
}

// writeAtomically writes content to path, whole or not at all: it is written beside path and
// renamed over it, so a reader polling for path never sees it partly written, and no other
// hard link reaches it.
func writeAtomically(path, content string, perm fs.FileMode) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), ".tmp-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	err = tmp.Chmod(perm)
	if err == nil {
		_, err = tmp.WriteString(content)
	}
	if closeErr := tmp.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
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
	return writeAtomically(path, fmt.Sprintf("proxy %d\nrelay %d\n", p.proxy, p.relay), 0o600)
}

// stopSignals returns a context done once the proxy is asked to stop: by chopi's TERM as the
// session ends, or a stray HUP.
func stopSignals() context.Context {
	ctx, _ := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGHUP)
	return ctx
}

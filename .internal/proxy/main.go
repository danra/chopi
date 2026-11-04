// chopi-smokescreen -- a chopi session's proxy: Stripe's smokescreen egress proxy, embedded as a
// library and extended to hot-reload the --egress-acl-file rules, and the supervisor of the
// session's GitHub relays, served by Caddy.
//
//	chopi-smokescreen --dir DIR --parent PID --relay-log FILE --github-allowlist FILE
//	                  --relay-config CMD -- SMOKESCREEN_FLAGS...
//
//   - Smokescreen's flags and log output are identical to the standalone smokescreen binary's,
//     but for where it listens: --listen-ip and --listen-port are ignored.
//   - The rules file is polled for changes, with a new valid rules set immediately
//     and atomically swapped in.
//   - Every listener is opened here, on a loopback port the kernel picks, or the unix socket
//     DIR/gh.sock, so no other process can take it first. Smokescreen serves its own; Caddy, started
//     with its config on stdin and its output in the --relay-log FILE, inherits the relays'.
//   - Caddy's config is CMD's output, run on the --github-allowlist FILE. GH_TOKEN and
//     GITHUB_TOKEN, where set, are CMD's alone: taken out of the environment everything else gets.
//   - The allowlist is polled for changes, as the rules are, and on one, a Caddy on the new config
//     replaces the one serving, on the same listeners: their ports and socket path don't change.
//     The one replaced finishes the requests it has. A config that fails to render, or a Caddy
//     that fails to start on it, keeps the one serving.
//   - Once smokescreen listens and Caddy serves, the ports are reported in DIR/ports, for chopi
//     to learn them from, and to know the proxy is up, and a line says where on stdout. Until then,
//     errors go to stderr, for chopi to show; from then on, everything goes to stdout, the log.
//   - The proxy stops once process PID (chopi) exits, or on TERM or HUP; if the Caddy serving
//     exits, it stops too, so nothing is left serving half the session. Caddy is stopped with it.

package main

import (
	"errors"
	"fmt"
	"io/fs"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/sirupsen/logrus"
	"github.com/stripe/smokescreen/cmd"
	"github.com/stripe/smokescreen/pkg/smokescreen"
	acl "github.com/stripe/smokescreen/pkg/smokescreen/acl/v1"
)

const reloadPollInterval = time.Second

type swappableACL struct {
	current atomic.Pointer[acl.ACL]
}

func (s *swappableACL) Decide(args acl.DecideArgs) (acl.Decision, error) {
	return s.current.Load().Decide(args)
}

func loadRules(conf *smokescreen.Config, path string) (*acl.ACL, error) {
	return acl.New(conf.Log, acl.NewYAMLLoader(path), conf.DisabledAclPolicyActions)
}

// The log messages of a config file's reload, its failure keeping the previous config. The
// formatter (.internal/format-reload.jq, .internal/classify-log.sh) matches them; keep them in sync.
const (
	rulesReloaded         = "egress ACL reloaded"
	rulesReloadFailed     = "egress ACL reload failed; keeping the previous rules"
	allowlistReloaded     = "GitHub allowlist reloaded"
	allowlistReloadFailed = "GitHub allowlist reload failed; keeping the previous relays"
)

func reloadIfChanged(conf *smokescreen.Config, holder *swappableACL, file *configFile, lastMod time.Time, warned bool) (newLastMod time.Time, newWarned bool) {
	rulesLogEntry := conf.Log.WithField("rules", file.path)
	return applyIfChanged(rulesLogEntry, file, rulesReloaded, rulesReloadFailed, lastMod, warned, func() error {
		rules, err := loadRules(conf, file.path)
		if err != nil {
			return err
		}
		holder.current.Store(rules)
		return nil
	})
}

// configFile is a config file the proxy reads, and what it last took up from it, to put back
// should a change to it be refused (putBack).
type configFile struct {
	path     string
	accepted []byte
}

// newConfigFile is the config file at path, as the proxy is about to take it up, refused if it has
// other hard links (singleLink): it takes it up as it is then, so one written through another link
// since chopi's preflight checked would be served. One that can't be read is left for its loading
// to report.
func newConfigFile(path string) (*configFile, error) {
	if st, err := os.Stat(path); err == nil {
		if err := singleLink(path, st); err != nil {
			return nil, err
		}
	}
	accepted, _ := os.ReadFile(path)
	return &configFile{path: path, accepted: accepted}, nil
}

// mustConfigFile is newConfigFile, exiting the proxy on a refusal.
func mustConfigFile(path string) *configFile {
	file, err := newConfigFile(path)
	if err != nil {
		fail("%v: review it, as it may have been written through another hard link, before replacing it with a fresh copy", err)
	}
	return file
}

// applyIfChanged runs apply, which takes up the config file, if it changed since lastMod. Its
// success is logged to entry with okMsg; its failure, a file with other hard links (singleLink),
// and a file that can't be read, with failedMsg: each keeps the previous config. A file with other
// links is moved aside, the config last taken up put back in its place (putBack). It returns the
// modification time taken up, and whether an unreadable file was already logged, for the next call.
func applyIfChanged(entry *logrus.Entry, file *configFile, okMsg, failedMsg string, lastMod time.Time, warned bool, apply func() error) (newLastMod time.Time, newWarned bool) {
	st, err := os.Stat(file.path)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			// Ignore a missing file: atomic-rename saves make it momentarily disappear, and the
			// edge-case of a genuinely deleted file once its config is already in effect is also
			// harmless.
			return lastMod, warned
		}
		// Warn on other errors (once, until the file can be read again)
		if !warned {
			entry.WithError(err).Error(failedMsg)
		}
		return lastMod, true
	}
	if st.ModTime().Equal(lastMod) {
		return lastMod, false
	}
	if err := singleLink(file.path, st); err != nil {
		mod, err := file.putBack(st, err)
		entry.WithError(err).Error(failedMsg)
		return mod, false
	}
	content, err := os.ReadFile(file.path)
	if err == nil {
		err = apply()
	}
	if err != nil {
		entry.WithError(err).Error(failedMsg)
	} else {
		file.accepted = content
		entry.Info(okMsg)
	}
	return st.ModTime(), false
}

// putBack moves the config file, refused for its other hard links (refusal), to
// path.refused-TIMESTAMP for review, and rewrites path, under a new inode, with the content last
// taken up: what was written through another link is then never served, now or as the proxy next
// starts. It returns refusal, saying what became of the file, and the modification time to record
// -- the rewritten file's, else the refused one's -- so it isn't retried until it changes.
func (f *configFile) putBack(st fs.FileInfo, refusal error) (time.Time, error) {
	if f.accepted == nil {
		return st.ModTime(), fmt.Errorf("%w; nothing was taken up from it to put back: review it", refusal)
	}
	aside := f.path + ".refused-" + time.Now().Format("20060102-150405")
	if err := os.Rename(f.path, aside); err != nil {
		return st.ModTime(), fmt.Errorf("%w; could not move it aside for review: %v", refusal, err)
	}
	if err := writeAtomically(f.path, string(f.accepted), st.Mode().Perm()); err != nil {
		return st.ModTime(), fmt.Errorf("%w; moved it to %s for review, but could not put back the config last taken up: %v", refusal, aside, err)
	}
	return modTime(f.path), fmt.Errorf("%w; moved it to %s for review, and put back the config last taken up", refusal, aside)
}

// singleLink refuses a config file with more than one hard link:
// the sandbox denies changes to it by path, so a sandboxed command may have written it through
// another link. chopi refuses one before launch (preflight_proxy_config_links), and the proxy as it
// starts (newConfigFile); this is for one made since.
func singleLink(path string, st fs.FileInfo) error {
	if sys := st.Sys().(*syscall.Stat_t); sys.Nlink > 1 {
		return fmt.Errorf("%s has %d hard links, which a sandboxed command may write through", path, sys.Nlink)
	}
	return nil
}

// watchFile polls for changes to a config file since lastMod, for poll -- reloadIfChanged, or
// applyIfChanged -- to take each up.
func watchFile(lastMod time.Time, poll func(lastMod time.Time, warned bool) (time.Time, bool)) {
	warned := false
	for range time.Tick(reloadPollInterval) {
		lastMod, warned = poll(lastMod, warned)
	}
}

// modTime is the file at path's modification time: zero for one missing or unreadable.
func modTime(path string) time.Time {
	st, err := os.Stat(path)
	if err != nil {
		return time.Time{}
	}
	return st.ModTime()
}

func egressACLPath(args []string) string {
	for i, arg := range args {
		if arg == "--egress-acl-file" && i+1 < len(args) {
			return args[i+1]
		}
		if v, ok := strings.CutPrefix(arg, "--egress-acl-file="); ok {
			return v
		}
	}
	return ""
}

// Same role resolution as standalone smokescreen (https://github.com/stripe/smokescreen/blob/a3294a6cc4e4/main.go#L16-L24)
func defaultRoleFromRequest(req *http.Request) (string, error) {
	if req.TLS == nil {
		return "", smokescreen.MissingRoleError("defaultRoleFromRequest requires TLS")
	}
	if len(req.TLS.PeerCertificates) == 0 {
		return "", smokescreen.MissingRoleError("client did not provide certificate")
	}
	return req.TLS.PeerCertificates[0].Subject.CommonName, nil
}

// useListener has smokescreen serve on listener, a loopback one, recorded in conf.Port: opened here
// rather than left to smokescreen, as smokescreen would listen on port 0 but leave conf.Port at 0,
// and its self-connection check compares connections against conf.Port.
func useListener(conf *smokescreen.Config, listener *net.TCPListener) {
	conf.Listener = listener
	conf.Ip = "127.0.0.1"
	conf.Port = uint16(portOf(listener))
}

// listenLoopback listens on a loopback port the kernel picks. Loopback only: both the proxy and the
// relays would be open to the LAN on a wildcard address.
func listenLoopback() (*net.TCPListener, error) {
	return net.ListenTCP("tcp", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
}

func main() {
	// Caught from the start, a stop asked as the proxy starts still ends it in order: the render
	// cancelled, Caddy stopped.
	stop := stopSignals()
	opts, err := parseOptions(os.Args[1:])
	if err != nil {
		fmt.Fprintln(os.Stderr, "chopi-smokescreen:", err)
		os.Exit(2)
	}
	// Done once the proxy is asked to stop, or chopi is gone: watched from the start too, as the
	// render below may wait on a keychain prompt, long after chopi is gone.
	stop, err = watchExit(stop, opts.parent)
	if err != nil {
		fail("can't watch process %d: %v", opts.parent, err)
	}
	// The token is for rendering the relays' config, not for smokescreen or Caddy.
	relayConf := relayConfig{cmd: opts.relayConfig, allowlist: opts.allowlist,
		env: takeEnv("GH_TOKEN", "GITHUB_TOKEN")}
	args := append([]string{os.Args[0]}, opts.smokeArgs...)
	path := egressACLPath(opts.smokeArgs)
	rulesFile := mustConfigFile(path)
	allowlistFile := mustConfigFile(opts.allowlist)
	lastMod := modTime(path)

	// Smokescreen logs to stdout, the log, from the start, its global logger included: stderr is
	// for why the proxy can't start.
	logrus.SetOutput(os.Stdout)
	conf, err := cmd.NewConfiguration(args, logrus.StandardLogger())
	if err != nil {
		fail("could not create the smokescreen configuration: %v", err)
	}
	if conf == nil {
		return // --help or --version, already handled by NewConfiguration
	}
	conf.RoleFromRequest = defaultRoleFromRequest

	// Same log wiring as standalone smokescreen (https://github.com/stripe/smokescreen/blob/a3294a6cc4e4/main.go#L33-L41)
	conf.Log.Formatter = &logrus.JSONFormatter{}
	log.SetOutput(&smokescreen.Log2LogrusWriter{Entry: conf.Log.WithField("stdlog", "1")})
	log.SetFlags(0)

	if path == "" {
		fail("--egress-acl-file not found on the command line; chopi requires a hot-reloadable egress ACL")
	}
	rules, ok := conf.EgressACL.(*acl.ACL)
	if !ok {
		fail("expected NewConfiguration to have loaded the egress ACL")
	}
	holder := &swappableACL{}
	holder.current.Store(rules)
	conf.EgressACL = holder

	proxyListener, err := listenLoopback()
	if err != nil {
		fail("can't listen: %v", err)
	}
	useListener(conf, proxyListener)
	// Checked here, as smokescreen would only as it starts: a config it refuses is a reason the
	// session can't start, for chopi to show.
	if err := conf.Validate(); err != nil {
		fail("invalid smokescreen config: %v", err)
	}
	// Its time first, for an edit made as it renders to be taken up once the relays serve.
	allowlistMod := modTime(opts.allowlist)
	initialConfig, notes, err := relayConf.render(stop)
	if err != nil {
		if stop.Err() != nil {
			// Stopped as it rendered, maybe at a keychain prompt: nothing else is up yet.
			os.Exit(0)
		}
		fail("%v", err)
	}
	if notes != "" {
		// In the log, for the user to find why authenticated GitHub access fails: an empty
		// allowlist can be deliberate, so it is no reason to speak up at every start.
		fmt.Println(notes)
	}
	gitListener, err := listenLoopback()
	if err != nil {
		fail("can't listen: git relay: %v", err)
	}
	ghSock := filepath.Join(opts.dir, "gh.sock")
	api, err := listenAPIRelay(ghSock)
	if err != nil {
		fail("can't listen: %v", err)
	}
	relaySup := newRelaySupervisor(&relays{git: gitListener, api: api}, opts.relayLog, relayConf,
		allowlistFile, conf.Log.WithField("allowlist", opts.allowlist))
	reported := ports{proxy: int(conf.Port), relay: portOf(gitListener)}

	// Stop the proxy with STATUS, Caddy with it. The dir is chopi-proxy.sh's to remove, once we
	// are gone.
	exit := func(status int) {
		relaySup.stopAll()
		os.Exit(status)
	}
	// Both servers start at once: smokescreen serves its listener right away, as Caddy starts.
	relaysUp := make(chan error, 1)
	go func() {
		proc, err := relaySup.start(initialConfig)
		if err == nil {
			relaySup.serve(proc)
		}
		relaysUp <- err
	}()
	go watchFile(lastMod, func(lastMod time.Time, warned bool) (time.Time, bool) {
		return reloadIfChanged(conf, holder, rulesFile, lastMod, warned)
	})
	smokescreenExited := make(chan struct{})
	go func() {
		smokescreen.StartWithConfig(conf, nil)
		close(smokescreenExited)
	}()

	relayFailed := func(err error) {
		relayLog, _ := os.ReadFile(opts.relayLog)
		complain("the GitHub relay did not come up (%v). Its log:\n%s", err,
			strings.TrimRight(string(relayLog), "\n"))
		exit(1)
	}

	// Wait for Caddy to serve...
	select {
	case err := <-relaysUp:
		if err != nil {
			relayFailed(err)
		}
	case <-smokescreenExited:
		complain("smokescreen stopped as it started; see the log")
		exit(1)
	case <-stop.Done():
		exit(0)
	}
	if err := reportPorts(filepath.Join(opts.dir, "ports"), reported); err != nil {
		complain("can't report the ports: %v", err)
		exit(1)
	}
	fmt.Printf("[chopi-smokescreen] outgoing proxy on 127.0.0.1:%d, GitHub relay on 127.0.0.1:%d, "+
		"GitHub API relay on %s\n", reported.proxy, reported.relay, ghSock)
	// Up from here on, so anything left to say belongs in the log.
	syscall.Dup2(1, 2)
	// Should the log's formatter die, the log is lost from here on, but not the session's
	// network: writing to it then fails instead of killing the proxy.
	signal.Ignore(syscall.SIGPIPE)
	go watchFile(allowlistMod, relaySup.reloadIfChanged)

	// ...then serve, until the session ends or a server exits.
	select {
	case <-relaySup.failed:
		fmt.Println("[chopi-smokescreen] the GitHub relay exited; stopping the proxy")
		exit(1)
	case <-smokescreenExited:
		exit(1)
	case <-stop.Done():
		exit(0)
	}
}

// fail reports a reason the proxy can't start, as complain does, and exits.
func fail(format string, args ...any) {
	complain(format, args...)
	os.Exit(1)
}

// complain reports a reason the proxy can't start on stderr, for chopi to show.
func complain(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "chopi-smokescreen: "+format+"\n", args...)
}

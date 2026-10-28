// chopi-smokescreen -- a chopi session's proxy: Stripe's smokescreen egress proxy, embedded as a
// library and extended to hot-reload the --egress-acl-file rules, and the supervisor of the
// session's GitHub relays, served by Caddy.
//
//	chopi-smokescreen --dir DIR --parent PID --relay-log FILE [--keep-fresh FILE]... -- SMOKESCREEN_FLAGS...
//
//   - Smokescreen's flags and log output are identical to the standalone smokescreen binary's.
//   - The rules file is polled for changes, with a new valid rules set immediately
//     and atomically swapped in.
//   - Every listener is opened here, on a loopback port the kernel picks, or the unix socket
//     DIR/gh.sock, so no other process can take it first. Smokescreen serves its own; Caddy, started
//     with its config on stdin and its output in the --relay-log FILE, inherits the relays'.
//   - Once smokescreen listens and Caddy serves, the ports are reported in DIR/ports, for chopi
//     to learn them from, and to know the proxy is up. Until then, errors go to stderr, for chopi
//     to show; from then on, everything goes to stdout, the log.
//   - The proxy stops once process PID (chopi) exits, removing DIR, or on TERM or HUP; if Caddy
//     exits, it stops too, so nothing is left serving half the session. Caddy is stopped with it.
//   - The relay log and each --keep-fresh FILE are touched daily while the proxy runs, for chopi's
//     log retention, which goes by their last change, to leave them be.

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

func logRulesError(rulesLogEntry *logrus.Entry, err error) {
	rulesLogEntry.WithError(err).Error("egress ACL reload failed; keeping the previous rules")
}

func reloadIfChanged(conf *smokescreen.Config, holder *swappableACL, path string, lastMod time.Time, warned bool) (newLastMod time.Time, newWarned bool) {
	st, err := os.Stat(path)
	rulesLogEntry := conf.Log.WithField("rules", path)
	if err != nil {
		// A load failure keeps the previous rules.
		if errors.Is(err, fs.ErrNotExist) {
			// Ignore missing rules file: atomic-rename saves make it momentarily disappear,
			// and the edge-case of a genuinely deleted file once rules are already loaded is
			// also harmless.
			return lastMod, warned
		}
		// Warn on other errors (once, until rules become valid again)
		if !warned {
			logRulesError(rulesLogEntry, err)
		}
		return lastMod, true
	}
	if st.ModTime().Equal(lastMod) {
		return lastMod, false
	}
	rules, err := loadRules(conf, path)
	if err != nil {
		logRulesError(rulesLogEntry, err)
		return st.ModTime(), false
	}
	holder.current.Store(rules)
	rulesLogEntry.Info("egress ACL reloaded")
	return st.ModTime(), false
}

func watchRules(conf *smokescreen.Config, holder *swappableACL, path string, lastMod time.Time) {
	warned := false
	for range time.Tick(reloadPollInterval) {
		lastMod, warned = reloadIfChanged(conf, holder, path, lastMod, warned)
	}
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

// listenOnPickedPort opens conf's listener on conf.Ip, at a port the kernel picks, and records the
// port in conf.Port. Opened here rather than left to smokescreen, which would listen on the same
// port 0 but leave conf.Port at 0: smokescreen's self-connection check compares connections
// against conf.Port.
func listenOnPickedPort(conf *smokescreen.Config) error {
	listener, err := net.Listen("tcp", net.JoinHostPort(conf.Ip, "0"))
	if err != nil {
		return err
	}
	conf.Listener = listener
	conf.Port = uint16(listener.Addr().(*net.TCPAddr).Port)
	return nil
}

func main() {
	opts, err := parseOptions(os.Args[1:])
	if err != nil {
		fmt.Fprintln(os.Stderr, "chopi-smokescreen:", err)
		os.Exit(2)
	}
	args := append([]string{os.Args[0]}, opts.smokeArgs...)
	path := egressACLPath(opts.smokeArgs)
	var lastMod time.Time
	if path != "" {
		if st, err := os.Stat(path); err == nil {
			lastMod = st.ModTime()
		}
	}

	// Smokescreen logs to stdout, the log, from the start, its global logger included: stderr is
	// for why the proxy can't start.
	logrus.SetOutput(os.Stdout)
	logger := logrus.New()
	logger.Out = os.Stdout
	conf, err := cmd.NewConfiguration(args, logger)
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

	if err := listenOnPickedPort(conf); err != nil {
		fail("can't listen: %v", err)
	}
	// Checked here, as smokescreen would only as it starts: a config it refuses is a reason the
	// session can't start, for chopi to show.
	if err := conf.Validate(); err != nil {
		fail("invalid smokescreen config: %v", err)
	}
	relays, err := listenRelays(opts.dir)
	if err != nil {
		fail("can't listen: %v", err)
	}
	parentExited, err := watchExit(opts.parent)
	if err != nil {
		fail("can't watch process %d: %v", opts.parent, err)
	}
	stop := stopSignals()

	// Both servers start at once: smokescreen serves its listener right away, as Caddy starts.
	caddy, caddyExited, err := startCaddy(relays, opts.relayLog)
	if err != nil {
		fail("can't start caddy for the GitHub relay: %v", err)
	}
	// Stop the proxy with STATUS, Caddy with it.
	exit := func(status int) {
		caddy.Process.Signal(syscall.SIGTERM)
		os.Exit(status)
	}
	go watchRules(conf, holder, path, lastMod)
	go keepFresh(opts.keepFresh, keepFreshInterval)
	smokescreenExited := make(chan struct{})
	go func() {
		smokescreen.StartWithConfig(conf, nil)
		close(smokescreenExited)
	}()

	// Wait for Caddy, then serve -- until the session ends or a server exits. Once chopi is gone,
	// nobody else removes the dir.
	ready := awaitCaddy(relays.gitPort)
	up := false
	relayFailed := func(err error) {
		relayLog, _ := os.ReadFile(opts.relayLog)
		complain("the GitHub relay did not come up (%v). Its log:\n%s", err,
			strings.TrimRight(string(relayLog), "\n"))
		exit(1)
	}
	for {
		select {
		case err := <-ready:
			ready = nil
			if err != nil {
				relayFailed(err)
			}
			if err := reportPorts(opts.dir, int(conf.Port), relays.gitPort); err != nil {
				complain("can't report the ports: %v", err)
				exit(1)
			}
			fmt.Printf("[chopi-smokescreen] outgoing proxy on 127.0.0.1:%d, GitHub relay on 127.0.0.1:%d, "+
				"GitHub API relay on %s\n", conf.Port, relays.gitPort, filepath.Join(opts.dir, "gh.sock"))
			// Up from here on, so anything left to say belongs in the log.
			syscall.Dup2(1, 2)
			// Should the log's formatter die, the log is lost from here on, but not the session's
			// network: writing to it then fails instead of killing the proxy.
			signal.Ignore(syscall.SIGPIPE)
			up = true
		case <-caddyExited:
			if !up {
				relayFailed(errors.New("caddy exited"))
			}
			fmt.Println("[chopi-smokescreen] the GitHub relay exited; stopping the proxy")
			exit(1)
		case <-smokescreenExited:
			if !up {
				complain("smokescreen stopped as it started; see the log")
			}
			exit(1)
		case <-stop:
			exit(0)
		case <-parentExited:
			os.RemoveAll(opts.dir)
			exit(0)
		}
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

// chopi-smokescreen -- chopi's proxy: Stripe's smokescreen egress proxy, embedded as a library and
// extended to hot-reload the --egress-acl-file rules, and the supervisor of the GitHub relays,
// served by Caddy.
//
//	chopi-smokescreen --relay-log FILE --git-port PORT --gh-sock PATH -- SMOKESCREEN_FLAGS...
//
//   - Smokescreen's flags and log output are identical to the standalone smokescreen binary's.
//   - The rules file is polled for changes, with a new valid rules set immediately
//     and atomically swapped in.
//   - Every listener is opened here -- smokescreen's own, and the git relay's on 127.0.0.1:PORT,
//     each on a port the kernel picks for 0, and the API relay's on the unix socket PATH -- so no
//     other process can take one first. Smokescreen serves its own; Caddy, started with its config
//     on stdin and its output in the --relay-log FILE, inherits the relays'.
//   - Once smokescreen listens and Caddy serves, a line says where, on stdout. Until then, errors
//     go to stderr; from then on, everything goes to stdout, the log.
//   - The proxy stops on INT, TERM or HUP, removing the socket; if Caddy exits, it stops too, so
//     nothing is left serving half of what it should. Caddy is stopped with it.

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

// listen opens conf's listener on conf.Ip at conf.Port -- or, for 0, a port the kernel picks,
// recorded in conf.Port. Opened here rather than left to smokescreen, so that a port another
// process holds stops the proxy before Caddy starts; and for port 0, as smokescreen would listen on
// the same port 0 but leave conf.Port at 0: smokescreen's self-connection check compares
// connections against conf.Port.
func listen(conf *smokescreen.Config) error {
	listener, err := net.Listen("tcp", net.JoinHostPort(conf.Ip, fmt.Sprint(conf.Port)))
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

	if err := listen(conf); err != nil {
		fail("can't listen: %v", err)
	}
	// Checked here, as smokescreen would only as it starts: a config it refuses is a reason the
	// proxy can't start, to say before starting Caddy.
	if err := conf.Validate(); err != nil {
		fail("invalid smokescreen config: %v", err)
	}
	relays, err := listenRelays(opts.gitPort, opts.ghSock)
	if err != nil {
		fail("can't listen: %v", err)
	}
	stop := stopSignals()

	// Both servers start at once: smokescreen serves its listener right away, as Caddy starts.
	stopCaddy, caddyExited, err := startCaddy(relays, opts.relayLog)
	if err != nil {
		os.Remove(opts.ghSock)
		fail("can't start caddy for the GitHub relay: %v", err)
	}
	// Stop the proxy with STATUS, Caddy with it, and leave no socket behind once nothing serves it:
	// it was ours.
	exit := func(status int) {
		stopCaddy()
		os.Remove(opts.ghSock)
		os.Exit(status)
	}
	go watchRules(conf, holder, path, lastMod)
	smokescreenExited := make(chan struct{})
	go func() {
		smokescreen.StartWithConfig(conf, nil)
		close(smokescreenExited)
	}()

	// Wait for Caddy, then serve -- until stopped or a server exits.
	// ready goes nil once Caddy serves: from then on, the proxy is up.
	ready := awaitCaddy(portOf(relays.git))
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
			fmt.Printf("[chopi-smokescreen] outgoing proxy on 127.0.0.1:%d, GitHub relay on 127.0.0.1:%d, "+
				"GitHub API relay on %s\n", conf.Port, portOf(relays.git), opts.ghSock)
			// Should the log's formatter die, the log is lost from here on, but not the network:
			// writing to it then fails instead of killing the proxy.
			signal.Ignore(syscall.SIGPIPE)
		case <-caddyExited:
			if ready != nil {
				relayFailed(errors.New("caddy exited"))
			}
			fmt.Println("[chopi-smokescreen] the GitHub relay exited; stopping the proxy")
			exit(1)
		case <-smokescreenExited:
			if ready != nil {
				complain("smokescreen stopped as it started; see the log")
			}
			exit(1)
		case <-stop:
			exit(0)
		}
	}
}

// fail reports a reason the proxy can't start, as complain does, and exits.
func fail(format string, args ...any) {
	complain(format, args...)
	os.Exit(1)
}

// complain reports a reason the proxy can't start on stderr.
func complain(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "chopi-smokescreen: "+format+"\n", args...)
}

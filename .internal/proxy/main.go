// chopi-smokescreen -- chopi's proxy: Stripe's smokescreen egress proxy, embedded as a library and
// extended to hot-reload the --egress-acl-file rules, and the supervisor of the GitHub relays,
// served by Caddy.
//
//	chopi-smokescreen --relay-log FILE --gh-sock PATH --ports-file FILE -- SMOKESCREEN_FLAGS...
//
//   - Smokescreen's flags and log output are identical to the standalone smokescreen binary's,
//     but for where it listens: --listen-ip and --listen-port are ignored.
//   - The rules file is polled for changes, with a new valid rules set immediately
//     and atomically swapped in.
//   - Every listener is opened here -- smokescreen's own and the git relay's, each on a loopback
//     port: the one it had in the last run where free, else one the kernel picks; and the API
//     relay's on the unix socket PATH -- so no other process can take one first. Smokescreen
//     serves its own; Caddy, started with its config on stdin and its output in the --relay-log
//     FILE, inherits the relays'.
//   - Once smokescreen listens and Caddy serves, the ports are reported in the --ports-file FILE,
//     for chopi to learn them from, and to know the proxy is up, and a line says where on stdout.
//     They are also recorded in FILE.last, which outlives the proxy, for its next run to reclaim.
//     Until then, errors go to stderr; from then on, everything goes to stdout, the log.
//   - The proxy stops on INT, TERM or HUP, removing the socket and the ports file; if Caddy exits,
//     it stops too, so nothing is left serving half of what it should. Caddy is stopped with it.

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

// The log messages of the rules' reload, its failure keeping the previous rules. The formatter
// (.internal/format-reload.jq, .internal/classify-log.sh) matches them; keep them in sync.
const (
	rulesReloaded     = "egress ACL reloaded"
	rulesReloadFailed = "egress ACL reload failed; keeping the previous rules"
)

func reloadIfChanged(conf *smokescreen.Config, holder *swappableACL, path string, lastMod time.Time, warned bool) (newLastMod time.Time, newWarned bool) {
	rulesLogEntry := conf.Log.WithField("rules", path)
	return applyIfChanged(rulesLogEntry, path, rulesReloaded, rulesReloadFailed, lastMod, warned, func() error {
		rules, err := loadRules(conf, path)
		if err != nil {
			return err
		}
		holder.current.Store(rules)
		return nil
	})
}

// applyIfChanged runs apply, which takes up the config file at path, if the file changed since
// lastMod. Its success is logged to entry with okMsg; its failure, and a file that can't be read,
// with failedMsg: either keeps the previous config. It returns the modification time taken up, and
// whether an unreadable file was already logged, for the next call.
func applyIfChanged(entry *logrus.Entry, path, okMsg, failedMsg string, lastMod time.Time, warned bool, apply func() error) (newLastMod time.Time, newWarned bool) {
	st, err := os.Stat(path)
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
	if err := apply(); err != nil {
		entry.WithError(err).Error(failedMsg)
	} else {
		entry.Info(okMsg)
	}
	return st.ModTime(), false
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

// listenLoopback listens on loopback port, or, for 0, on one the kernel picks. Loopback only: both
// the proxy and the relays would be open to the LAN on a wildcard address.
func listenLoopback(port int) (*net.TCPListener, error) {
	return net.ListenTCP("tcp", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1), Port: port})
}

// listenLoopbackPorts opens a loopback listener for each of preferred: on that port where it is
// free, else on one the kernel picks. Keeping its ports keeps a restarted proxy reachable from the
// chopi sessions already running: their sandbox's holes, and their HTTP_PROXY, name the ports they
// started with. All the preferred ports are taken before the kernel picks any, so it can't hand one
// of them to another listener of ours.
func listenLoopbackPorts(preferred []int) ([]*net.TCPListener, error) {
	listeners := make([]*net.TCPListener, len(preferred))
	for i, port := range preferred {
		if port != 0 {
			listeners[i], _ = listenLoopback(port)
		}
	}
	for i := range listeners {
		if listeners[i] != nil {
			continue
		}
		listener, err := listenLoopback(0)
		if err != nil {
			for _, l := range listeners {
				if l != nil {
					l.Close()
				}
			}
			return nil, err
		}
		listeners[i] = listener
	}
	return listeners, nil
}

func main() {
	opts, err := parseOptions(os.Args[1:])
	if err != nil {
		fmt.Fprintln(os.Stderr, "chopi-smokescreen:", err)
		os.Exit(2)
	}
	args := append([]string{os.Args[0]}, opts.smokeArgs...)
	path := egressACLPath(opts.smokeArgs)
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

	// On the ports of the last run, where they are free.
	last := readPorts(lastPortsFile(opts.portsFile))
	listeners, err := listenLoopbackPorts([]int{last.proxy, last.relay})
	if err != nil {
		fail("can't listen: %v", err)
	}
	useListener(conf, listeners[0])
	reported := ports{proxy: int(conf.Port), relay: portOf(listeners[1])}
	// Checked here, as smokescreen would only as it starts: a config it refuses is a reason the
	// proxy can't start, to say before starting Caddy.
	if err := conf.Validate(); err != nil {
		fail("invalid smokescreen config: %v", err)
	}
	api, err := listenAPIRelay(opts.ghSock)
	if err != nil {
		fail("can't listen: %v", err)
	}
	relays := &relays{git: listeners[1], api: api}
	stop := stopSignals()

	// Leave no socket or ports file behind: they were ours.
	cleanup := func() {
		os.Remove(opts.ghSock)
		os.Remove(opts.portsFile)
	}

	// Both servers start at once: smokescreen serves its listener right away, as Caddy starts.
	stopCaddy, caddyExited, err := startCaddy(relays, opts.relayLog)
	if err != nil {
		cleanup()
		fail("can't start caddy for the GitHub relay: %v", err)
	}
	// Stop the proxy with STATUS, Caddy with it: the socket and ports file go once nothing serves
	// them.
	exit := func(status int) {
		stopCaddy()
		cleanup()
		os.Exit(status)
	}
	go watchFile(lastMod, func(lastMod time.Time, warned bool) (time.Time, bool) {
		return reloadIfChanged(conf, holder, path, lastMod, warned)
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
	case err := <-awaitCaddy(reported.relay):
		if err != nil {
			relayFailed(err)
		}
	case <-caddyExited:
		relayFailed(errors.New("caddy exited"))
	case <-smokescreenExited:
		complain("smokescreen stopped as it started; see the log")
		exit(1)
	case <-stop:
		exit(0)
	}
	// The last ports first: remembered past the proxy's stop, for its next start to take again.
	for _, path := range []string{lastPortsFile(opts.portsFile), opts.portsFile} {
		if err := reportPorts(path, reported); err != nil {
			complain("can't write the ports to %s: %v", path, err)
			exit(1)
		}
	}
	fmt.Printf("[chopi-smokescreen] outgoing proxy on 127.0.0.1:%d, GitHub relay on 127.0.0.1:%d, "+
		"GitHub API relay on %s\n", reported.proxy, reported.relay, opts.ghSock)
	// Should the log's formatter die, the log is lost from here on, but not the network:
	// writing to it then fails instead of killing the proxy.
	signal.Ignore(syscall.SIGPIPE)

	// ...then serve, until stopped or a server exits.
	select {
	case <-caddyExited:
		fmt.Println("[chopi-smokescreen] the GitHub relay exited; stopping the proxy")
		exit(1)
	case <-smokescreenExited:
		exit(1)
	case <-stop:
		exit(0)
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

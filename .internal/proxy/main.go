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
//   - Rules allowing a GitHub host that takes writes (see gitHubExfiltration) are refused, as the
//     proxy starts and on a reload alike: they would let a sandboxed command around the GitHub relays.
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
	"maps"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"slices"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/sirupsen/logrus"
	"github.com/stripe/smokescreen/cmd"
	"github.com/stripe/smokescreen/pkg/smokescreen"
	acl "github.com/stripe/smokescreen/pkg/smokescreen/acl/v1"
	"gopkg.in/yaml.v2"
)

const reloadPollInterval = time.Second

// The files made in DIR: the ports reported once up, and the API relay's socket. chopi reads them
// by the names in .internal/util.sh (PROXY_PORTS_FILE_NAME, PROXY_GH_SOCK_FILE_NAME), which must match.
const (
	portsFileName  = "ports"
	ghSockFileName = "gh.sock"
)

type swappableACL struct {
	current     atomic.Pointer[acl.ACL]
	allowGitHub bool // gitHubExfiltrationOverride is set: rules allowing GitHub's domains only warn
}

func (s *swappableACL) Decide(args acl.DecideArgs) (acl.Decision, error) {
	return s.current.Load().Decide(args)
}

// take swaps in rules, the one way rules take effect, as the proxy starts and on a reload alike.
// It refuses rules gitHubExfiltration refuses, unless allowGitHub: then it takes them up and
// passes the refusal to warn instead.
func (s *swappableACL) take(rules *acl.ACL, warn func(error)) error {
	if err := gitHubExfiltration(rules); err != nil {
		if !s.allowGitHub {
			return err
		}
		warn(fmt.Errorf("%w; taking up the rules anyway, as %s is set", err, gitHubExfiltrationOverride))
	}
	s.current.Store(rules)
	return nil
}

// parseRules is the rules in content, parsed as smokescreen's own YAML loader (acl.YAMLLoader)
// parses a rules file.
func parseRules(conf *smokescreen.Config, content []byte) (*acl.ACL, error) {
	var config acl.YAMLConfig
	if err := yaml.Unmarshal(content, &config); err != nil {
		return nil, err
	}
	if config.Version != "v1" {
		return nil, fmt.Errorf("expected version \"v1\" got %#v", config.Version)
	}
	return acl.New(conf.Log, &config, conf.DisabledAclPolicyActions)
}

// The log messages of a config file's reload, its failure keeping the previous config. The
// formatter (.internal/format-reload.jq, .internal/classify-log.sh) matches them; keep them in sync.
const (
	rulesReloaded         = "egress ACL reloaded"
	rulesReloadFailed     = "egress ACL reload failed; keeping the previous rules"
	allowlistReloaded     = "GitHub allowlist reloaded"
	allowlistReloadFailed = "GitHub allowlist reload failed; keeping the previous relays"
)

// configKind is how a kind of config file's reloads are logged: the file's path under key, with
// okMsg on success, and failedMsg on failure.
type configKind struct {
	key, okMsg, failedMsg string
}

var (
	rulesKind     = configKind{"rules", rulesReloaded, rulesReloadFailed}
	allowlistKind = configKind{"allowlist", allowlistReloaded, allowlistReloadFailed}
)

// takeRules takes up an edit to the rules file, its content: parses it, and swaps it into holder,
// its warnings logged as its reloads are.
func takeRules(conf *smokescreen.Config, holder *swappableACL, file *configFile) func([]byte) error {
	return func(content []byte) error {
		rules, err := parseRules(conf, content)
		if err != nil {
			return err
		}
		entry := file.logEntry(conf.Log)
		return holder.take(rules, func(warning error) { entry.Warn(warning.Error()) })
	}
}

// gitHubExfiltrationOverride is the environment variable that lets the proxy take up rules
// allowing GitHub's own domains. Its name marks the relays' coverage; it rotates when coverage
// grows, so an override set for an already-closed gap doesn't silently carry over.
const gitHubExfiltrationOverride = "CHOPI_ALLOW_EXFILTRATION_PRONE_GITHUB_DOMAINS_DESPITE_API_RELAY"

// gitHubExfiltration refuses rules that allow, to any service, a GitHub host taking writes with
// the writer's own token: github.com and api.github.com, which the relays cover, uploads.github.com
// (release assets) and gist.github.com (gist pushes). They defeat the GitHub repos allowlist, as a
// sandboxed command could push data to ANY repo directly, skipping the relays. A *.github.com glob
// is refused too, as it would allow any such host GitHub adds; a read-only host named alone, like
// codeload.github.com, is not. The rules themselves decide, so whatever way they allow a host
// counts -- a glob, the global allow list, an open or report policy.
func gitHubExfiltration(rules *acl.ACL) error {
	services := append(slices.Collect(maps.Keys(rules.Rules)), "") // "": the default rule
	allows := func(host string) bool {
		return slices.ContainsFunc(services, func(service string) bool {
			d, _ := rules.Decide(acl.DecideArgs{Service: service, Host: host})
			return d.Result == acl.Allow || d.Result == acl.AllowAndReport
		})
	}
	var allowed []string
	if allows("github.com") {
		allowed = append(allowed, "github.com")
	}
	// A subdomain no one would name: allowed, it is by a glob covering every subdomain, the
	// write-taking ones included, so the glob is named instead of them.
	if allows("chopi-probe-for-a-glob.github.com") {
		allowed = append(allowed, "*.github.com")
	} else {
		for _, host := range []string{"api.github.com", "uploads.github.com", "gist.github.com"} {
			if allows(host) {
				allowed = append(allowed, host)
			}
		}
	}
	if len(allowed) == 0 {
		return nil
	}
	return fmt.Errorf("the rules allow %s: a sandboxed command could push data to any GitHub repo, around the relays",
		strings.Join(allowed, ", "))
}

// rulesTemplate is chopi's current proxy rules template, relative to chopi's directory.
const rulesTemplate = "config/templates/proxy-rules.template.yaml"

// gitHubExfiltrationAdvice is what to do about rules at path that gitHubExfiltration refuses as
// the proxy starts, the relays enforcing the GitHub allowlist at allowlist. The expected case is a
// rules file copied from a template predating the relays. The template is found relative to the
// working directory, chopi's own as chopi-proxy.sh runs the proxy, and given absolute, as the user
// reads the advice in chopi's terminal, wherever they started chopi.
func gitHubExfiltrationAdvice(path, allowlist string) string {
	template, err := filepath.Abs(rulesTemplate)
	if err != nil {
		template = rulesTemplate
	}
	return fmt.Sprintf(`github.com git and gh's api.github.com REST calls go through
dedicated relays which limit push and private-repo access to the
repos in %s.

To fix this, overwrite your proxy rules with chopi's current template:
    cp %q %q
or move the domains from allowed_domains to global_deny_list in %s.

To run anyway, set %s=1.`, allowlist, template, path, path, gitHubExfiltrationOverride)
}

// configFile is a config file the proxy watches, of kind, and what it last took up from it, to put
// back should a change to it be refused (putBack). lastMod is the modification time last taken up,
// for the next poll (take); warned, if the file's being unreadable was already logged, the
// modification time of the edit it couldn't read -- zero if it couldn't stat the file.
type configFile struct {
	path     string
	kind     configKind
	accepted []byte
	lastMod  time.Time
	warned   *time.Time
}

// newConfigFile is the config file at path, as the proxy takes it up as it starts (take): refused
// if it has other hard links, so one written through another link since chopi's preflight checked
// isn't served, or if it can't be read, missing or for its mode, as taking it up as empty would
// start the session on a config other than the user's.
func newConfigFile(path string, kind configKind) (*configFile, error) {
	f := &configFile{path: path, kind: kind}
	if _, err := f.take(func([]byte) error { return nil }); err != nil {
		return nil, fmt.Errorf("can't take up the %s config: %w", kind.key, err)
	}
	return f, nil
}

// mustConfigFile is newConfigFile, exiting the proxy on a refusal.
func mustConfigFile(path string, kind configKind) *configFile {
	file, err := newConfigFile(path, kind)
	if err != nil {
		fail("%v", err)
	}
	return file
}

// unreadable is take's error for a config file it can't stat, mod then zero, or can't read: mod
// is then the modification time of the edit it can't read.
type unreadable struct {
	mod time.Time
	err error
}

func (u *unreadable) Error() string { return u.err.Error() }
func (u *unreadable) Unwrap() error { return u.err }

// take takes up the config file if it changed since last taken up (lastMod), returning whether it
// took an edit up: has apply take up its content, recorded as taken up (accepted) unless apply refuses it --
// the content as read here, for what is taken up to be what a refusal puts back. It refuses a file
// with other hard links (singleLink), moved aside, the config last taken up put back in its place
// (putBack), and one it can't stat or read (*unreadable). One it can't read is tried again on
// every call, until it can be: a chmod making it readable changes no modification time. The
// modification time is taken before the file is read, for an edit made as it is read to be taken
// up again.
func (f *configFile) take(apply func([]byte) error) (taken bool, err error) {
	st, err := os.Stat(f.path)
	if err != nil {
		return false, &unreadable{err: err}
	}
	if st.ModTime().Equal(f.lastMod) {
		return false, nil
	}
	if err := singleLink(f.path, st); err != nil {
		f.lastMod = st.ModTime()
		return false, f.putBack(st, err)
	}
	content, err := os.ReadFile(f.path)
	if err != nil {
		return false, &unreadable{mod: st.ModTime(), err: err}
	}
	f.lastMod = st.ModTime()
	if err := apply(content); err != nil {
		return false, err
	}
	f.accepted = content
	return true, nil
}

// applyIfChanged takes up the config file, for apply to take up its content, if it changed since
// last taken up (take). Its success is logged, to log as the file's kind logs it; so is its
// refusal, keeping the previous config -- a file that can't be stat'ed or read once until it can
// be, once per edit for one that can't be read -- unless it is missing.
func (f *configFile) applyIfChanged(log *logrus.Logger, apply func([]byte) error) {
	taken, err := f.take(apply)
	var unread *unreadable
	if errors.As(err, &unread) {
		if errors.Is(err, fs.ErrNotExist) {
			// Ignore a missing file: atomic-rename saves make it momentarily disappear, and the
			// edge-case of a genuinely deleted file once its config is already in effect is also
			// harmless.
			return
		}
		// Warn once until the file can be read, or an edit to it is made that can't be either.
		if f.warned == nil || !unread.mod.Equal(*f.warned) {
			f.logEntry(log).WithError(err).Error(f.kind.failedMsg)
		}
		f.warned = &unread.mod
		return
	}
	f.warned = nil
	switch {
	case err != nil:
		f.logEntry(log).WithError(err).Error(f.kind.failedMsg)
	case taken:
		f.logEntry(log).Info(f.kind.okMsg)
	}
}

// logEntry is the log entry for the config file: its path under its kind's key.
func (f *configFile) logEntry(log *logrus.Logger) *logrus.Entry {
	return log.WithField(f.kind.key, f.path)
}

// putBack moves the config file, refused for its other hard links (refusal), to
// path.refused-TIMESTAMP for review, and rewrites path, under a new inode, with the content last
// taken up: what was written through another link is then never served, now or as the proxy next
// starts. Having rewritten it, it records the rewritten file's modification time, so it isn't taken
// up as a change. It returns refusal, saying what became of the file -- or, refused as the proxy
// starts, nothing taken up yet to put back, what to do about it.
func (f *configFile) putBack(st fs.FileInfo, refusal error) error {
	if f.accepted == nil {
		return fmt.Errorf("%w: review it, as it may have been written through another hard link, before replacing it with a fresh copy", refusal)
	}
	aside := f.path + ".refused-" + time.Now().Format("20060102-150405")
	if err := os.Rename(f.path, aside); err != nil {
		return fmt.Errorf("%w; could not move it aside for review: %v", refusal, err)
	}
	if err := writeAtomically(f.path, string(f.accepted), st.Mode().Perm()); err != nil {
		return fmt.Errorf("%w; moved it to %s for review, but could not put back the config last taken up: %v", refusal, aside, err)
	}
	f.lastMod = modTime(f.path)
	return fmt.Errorf("%w; moved it to %s for review, and put back the config last taken up", refusal, aside)
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

// watch polls the config file for changes, for apply to take each up (applyIfChanged), logged to
// log.
func (f *configFile) watch(log *logrus.Logger, apply func([]byte) error) {
	for range time.Tick(reloadPollInterval) {
		f.applyIfChanged(log, apply)
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

// takeEgressACLPath is the path smokescreen's args name as the egress ACL file, and the args without
// it: the proxy takes the file up itself (configFile), for smokescreen not to read it too.
func takeEgressACLPath(args []string) (path string, rest []string) {
	rest = make([]string, 0, len(args))
	for i := 0; i < len(args); i++ {
		if args[i] == "--egress-acl-file" && i+1 < len(args) {
			path = args[i+1]
			i++
		} else if v, ok := strings.CutPrefix(args[i], "--egress-acl-file="); ok {
			path = v
		} else {
			rest = append(rest, args[i])
		}
	}
	return path, rest
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
	relayConf := relayConfig{cmd: opts.relayConfig, allowlistPath: opts.allowlist,
		env: takeEnv("GH_TOKEN", "GITHUB_TOKEN")}
	path, smokeArgs := takeEgressACLPath(opts.smokeArgs)
	if path == "" {
		fail("--egress-acl-file not found on the command line; chopi requires a hot-reloadable egress ACL")
	}
	args := append([]string{os.Args[0]}, smokeArgs...)
	// The config files, as taken up now, for their watches to take up any edit made from here on.
	rulesFile := mustConfigFile(path, rulesKind)
	allowlistFile := mustConfigFile(opts.allowlist, allowlistKind)

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

	// The rules as rulesFile read them: what a refusal puts back (configFile.accepted) must be what
	// is in effect.
	rules, err := parseRules(conf, rulesFile.accepted)
	if err != nil {
		fail("could not load the egress ACL: %v", err)
	}
	holder := &swappableACL{allowGitHub: os.Getenv(gitHubExfiltrationOverride) != ""}
	if err := holder.take(rules, func(warning error) { complain("warning: %v", warning) }); err != nil {
		fail("refusing to run: %v\n\n%s", err, gitHubExfiltrationAdvice(path, opts.allowlist))
	}
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
	initialConfig, notes, err := relayConf.render(stop, allowlistFile.accepted)
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
	ghSock := filepath.Join(opts.dir, ghSockFileName)
	api, err := listenAPIRelay(ghSock)
	if err != nil {
		fail("can't listen: %v", err)
	}
	relaySup := newRelaySupervisor(&relays{git: gitListener, api: api}, opts.relayLog, relayConf)
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
	go rulesFile.watch(conf.Log, takeRules(conf, holder, rulesFile))
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
	if err := reportPorts(filepath.Join(opts.dir, portsFileName), reported); err != nil {
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
	go allowlistFile.watch(conf.Log, relaySup.reload)

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

// chopi-smokescreen -- a chopi session's proxy. It embeds Stripe's smokescreen egress proxy as a
// library, takes its rules from chopi's network config and hot-reloads them, and supervises the
// session's GitHub relays, which Caddy serves.
//
//	chopi-smokescreen --dir DIR --parent PID --relay-log FILE --network FILE --add-network FILE
//	                  --network-template FILE --relay-config CMD -- SMOKESCREEN_FLAGS...
//
//   - Smokescreen's flags and log output are identical to the standalone smokescreen binary's,
//     but for where it listens: --listen-ip and --listen-port are ignored. Smokescreen takes its
//     rules from the network config (see network_config.go) instead of an --egress-acl-file.
//   - The proxy polls the --network file for changes and takes up a new valid config right away.
//     It swaps the config's rules in at once, and reloads the relays on its GitHub allowlist. A
//     render waiting on a keychain prompt holds up neither the rules nor the polls.
//   - The --add-network file adds to the --network file's config (see network_config.go). The
//     proxy polls it for changes the same way, including for being made or deleted mid-session.
//   - A change to either file takes up the config with the other file as last taken up. If the
//     proxy refuses the added file as it starts, the proxy doesn't start, and its error names that
//     file.
//   - Rules allowing a GitHub host that takes writes (see gitHubExfiltration) are refused, as the
//     proxy starts and on a reload alike: they would let a sandboxed command around the GitHub relays.
//   - Every listener is opened here, on a loopback port the kernel picks, or the unix socket
//     DIR/gh.sock, so no other process can take it first. Smokescreen serves its own; Caddy, started
//     with its config on stdin and its output in the --relay-log FILE, inherits the relays'.
//   - Caddy's config is CMD's output. CMD gets the GitHub allowlist merged from both files, one
//     entry per argument. Only CMD gets GH_TOKEN and GITHUB_TOKEN, where set: the proxy takes them
//     out of the environment everything else gets.
//   - A change to the GitHub allowlist starts a Caddy on the new config, which replaces the one
//     serving, on the same listeners, so their ports and socket path don't change. A save with no
//     edit does too, to take up a GitHub token gh replaced. The replaced Caddy finishes the
//     requests it has.
//   - If the config fails to render, or Caddy fails to start on it, the serving Caddy stays until
//     the next edit or save tries again. The rules taken up with that config stay in effect.
//   - A newer edit cancels a render still running for an older one. If the newest edit's relays
//     come up, they are the ones left serving, whatever order the reloads finish in.
//   - Once smokescreen listens and Caddy serves, the ports are reported in DIR/ports, for chopi
//     to learn them from, and to know the proxy is up, and a line says where on stdout. Until then,
//     errors go to stderr, for chopi to show; from then on, everything goes to stdout, the log.
//   - The proxy stops once process PID (chopi) exits, or on TERM or HUP; if the Caddy serving
//     exits, it stops too, so nothing is left serving half the session. Caddy is stopped with it.

package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log"
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
)

const reloadPollInterval = time.Second

// The files made in DIR: the ports reported once up, and the API relay's socket. chopi reads them
// by the names in .internal/util.sh (PROXY_PORTS_FILE_NAME, PROXY_GH_SOCK_FILE_NAME), which must match.
const (
	portsFileName  = "ports"
	ghSockFileName = "gh.sock"
)

// networkTaker takes up the network config from the contents of its files, as the proxy starts and
// on a reload alike. This is the only way the config takes effect. It stores the rules in current
// at once. It reloads the relays on the GitHub allowlist, or, before they are up, keeps the
// allowlist for them to start on.
//
// networkTaker is the proxy's egress ACL: it decides by the rules last taken up.
//
// Except for current, only the watcher's goroutine uses a networkTaker: take and what settled
// carries run on it (configFiles.watch).
type networkTaker struct {
	conf    *smokescreen.Config
	current atomic.Pointer[acl.ACL]
	// relays has the relays serve the given GitHub allowlist, unless ctx is cancelled first. It is
	// nil until the relays are up, rendered from initial. It runs on a goroutine of its own, as it
	// may wait on a keychain prompt.
	relays func(ctx context.Context, allowlist []string) error
	// served returns the GitHub allowlist the relays serve, whichever reload brought them up on it,
	// cancelled or not. It is set together with relays.
	served func() []string
	// initial is the GitHub allowlist taken up before the relays are up, for them to start on.
	initial []string
	// reloading is the relays' reload under way, if any. It is the newest one: reloadRelays cancels
	// any older one.
	reloading *relayReload
	// settled carries what to do as a reload of the relays ends. The watcher runs it.
	settled chan func()
	// allowGitHub is whether gitHubExfiltrationOverride is set. If it is, take only warns about
	// rules allowing GitHub's domains.
	allowGitHub bool
}

// relayReload is a reload of the relays on allowlist, cancelled by cancel.
type relayReload struct {
	allowlist []string
	cancel    context.CancelFunc
}

// newNetworkTaker returns a networkTaker for conf, before the relays are up.
func newNetworkTaker(conf *smokescreen.Config, allowGitHub bool) *networkTaker {
	return &networkTaker{conf: conf, allowGitHub: allowGitHub, settled: make(chan func())}
}

// take takes up the network config from its files' contents (loadNetwork).
//
// It returns loadNetwork's refusal of the rules, or else every gitHubExfiltration refusal, joined,
// leaving the config as it was. With allowGitHub set, it passes each gitHubExfiltration refusal to
// warn instead.
//
// Otherwise it swaps the rules in at once, and calls done once the config has taken effect. That is
// right away, unless the relays are to come up on the config's GitHub allowlist (reloadRelays). Then
// it calls done as the reload ends, with the error if the relays didn't come up. It never calls done
// for a reload a newer config's reload cancels.
//
// The relays are rendered again only for an allowlist that differs from the one they serve, or
// will once the reload under way ends, or for a save with no edit (resave) while the allowlist has
// entries, which takes up a GitHub token gh replaced since: the rules alone never wait on, nor fail
// for, the token.
func (t *networkTaker) take(files []configContent, resave bool, warn func(error), done func(error)) error {
	n, err := loadNetwork(t.conf, files)
	if err != nil {
		return err
	}
	if len(n.exfiltration) > 0 && !t.allowGitHub {
		refusals := make([]error, len(n.exfiltration))
		for i, refusal := range n.exfiltration {
			refusals[i] = refusal
		}
		return errors.Join(refusals...)
	}
	for _, refusal := range n.exfiltration {
		warn(fmt.Errorf("%w; taking up the rules anyway, as %s is set", refusal, gitHubExfiltrationOverride))
	}
	t.current.Store(n.rules)
	if t.relays == nil {
		t.initial = n.allowlist
	} else if resave && len(n.allowlist) > 0 || !slices.Equal(n.allowlist, t.upcoming()) {
		t.reloadRelays(n.allowlist, done)
		return nil
	}
	done(nil)
	return nil
}

// upcoming is the GitHub allowlist the relays serve, or will once the reload under way ends.
func (t *networkTaker) upcoming() []string {
	if t.reloading != nil {
		return t.reloading.allowlist
	}
	return t.served()
}

// reloadRelays has the relays come up on allowlist, on a goroutine of its own. It cancels the
// reload under way, if any.
//
// As the reload ends, reloadRelays calls done on the watcher's goroutine (settled). A reload that a
// newer one cancelled doesn't call done: the newer reload's done reports for both. A failed reload
// leaves the relays serving what they did, and the next config taken up tries again.
func (t *networkTaker) reloadRelays(allowlist []string, done func(error)) {
	if t.reloading != nil {
		t.reloading.cancel()
	}
	ctx, cancel := context.WithCancel(context.Background())
	r := &relayReload{allowlist: allowlist, cancel: cancel}
	t.reloading = r
	relays, settled := t.relays, t.settled
	go func() {
		err := relays(ctx, allowlist)
		cancel()
		settled <- func() {
			if t.reloading != r {
				return
			}
			t.reloading = nil
			if err != nil {
				done(fmt.Errorf("the relays keep the previous GitHub allowlist, the rest of the config taking effect: %w", err))
				return
			}
			done(nil)
		}
	}()
}

func (t *networkTaker) Decide(args acl.DecideArgs) (acl.Decision, error) {
	return t.current.Load().Decide(args)
}

// The log messages for a config file's reload, and for a failed reload, which keeps the previous
// config. The formatter (.internal/format-reload.jq, .internal/classify-log.sh) matches them, so
// keep them in sync.
const (
	networkReloaded     = "network config reloaded"
	networkReloadFailed = "network config reload failed; keeping the previous config"
)

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
// counts, a glob included. path is the network config file the refusal names as allowing the
// hosts.
func gitHubExfiltration(rules *acl.ACL, path string) *exfiltrationError {
	allows := func(host string) bool {
		d, _ := rules.Decide(acl.DecideArgs{Host: host})
		return d.Result == acl.Allow
	}
	var allowed []string
	if allows("github.com") {
		allowed = append(allowed, "github.com")
	}
	if allows(gitHubProbeForAGlob) {
		// Name the glob instead of the hosts it covers.
		allowed = append(allowed, "*.github.com")
	} else {
		for _, host := range gitHubWriteSubdomains {
			if allows(host) {
				allowed = append(allowed, host)
			}
		}
	}
	if len(allowed) == 0 {
		return nil
	}
	return &exfiltrationError{path, allowed}
}

// gitHubProbeForAGlob is a subdomain of github.com no one would name. Rules that allow it do so by
// a glob, which covers every subdomain, including those that take writes.
const gitHubProbeForAGlob = "chopi-probe-for-a-glob.github.com"

// gitHubWriteSubdomains are the subdomains of github.com that take writes.
var gitHubWriteSubdomains = []string{"api.github.com", "uploads.github.com", "gist.github.com"}

// exfiltrationError is gitHubExfiltration's refusal: the GitHub hosts the rules in the file at path
// allow.
type exfiltrationError struct {
	path    string
	allowed []string
}

func (e *exfiltrationError) Error() string {
	return fmt.Sprintf("%s allows %s: a sandboxed command could push data to any GitHub repo, around the relays",
		e.path, strings.Join(e.allowed, ", "))
}

// gitHubExfiltrationAdvice tells the user what to do when gitHubExfiltration refuses the network
// config at path as the proxy starts. The expected case is a config copied from a template that
// predates the relays. template is chopi's current template.
func gitHubExfiltrationAdvice(path, template string) string {
	return fmt.Sprintf(`github.com git and gh's api.github.com REST calls go through
dedicated relays which limit push and private-repo access to the
repos on the network config's github_allowlist.

To fix this, move the domains from allowed_domains to global_deny_list in %s,
or start over from chopi's current template:
    cp %q %q

To run anyway, set %s=1.`, path, template, path, gitHubExfiltrationOverride)
}

// configFile is a network config file the proxy watches. added is whether it adds to the base
// config (network_config.go), which makes it the workspace's own.
//
// read is what the file's own reload last read from it, after checking the file (readChecked),
// whether or not the reload took it up. accepted is what was last taken up from it (zero if nothing was): a change to the
// other file takes up the config with it, and putBack puts it back. Each is parsed once, as it is
// read, rather than at every poll.
//
// lastMod is the modification time last read. It is zero for an added file that has been missing
// since the proxy started, or since it was last taken away.
//
// unreadable is set when the file's last read failed and the failure was logged. It holds the
// modification time of the edit the read failed on (zero if unknown). The cached lastMod then
// proves nothing, so the file is read again.
//
// goneFailed is whether taking away a missing added file failed, and the failure was logged
// (applyIfGone). missing is whether an added file was missing at the last poll (applyIfChanged).
type configFile struct {
	path           string
	added          bool
	read, accepted configContent // nil content for an added file with none
	lastMod        time.Time
	unreadable     *time.Time
	goneFailed     bool
	missing        bool
}

// newConfigFile is the config file at path, as the proxy is about to take it up, refused if it has
// other hard links (singleLink): it takes it up as it is then, so one written through another link
// since chopi's preflight checked would be served. An added one may be missing, but not have a
// symlink on its way (configFile.open). Its modification time is taken as it is opened, before it
// is read, for an edit made as it is read to be taken up again.
func newConfigFile(path string, added bool) (*configFile, error) {
	f := &configFile{path: path, added: added, read: newConfigContent(path, nil)}
	content, st, err := f.readChecked()
	if added && errors.Is(err, fs.ErrNotExist) {
		return f, nil
	}
	if err != nil {
		return nil, err
	}
	f.lastMod = st.ModTime()
	f.read = newConfigContent(f.path, content)
	return f, nil
}

// readChecked reads the config file (open), refused if it has other hard links (singleLink), with
// what to do about it, returning too its status as opened, before it was read.
func (f *configFile) readChecked() ([]byte, fs.FileInfo, error) {
	file, st, err := f.open()
	if err != nil {
		return nil, nil, err
	}
	defer file.Close()
	if err := singleLink(f.path, st); err != nil {
		return nil, nil, fmt.Errorf("%w: review it, as it may have been written through another hard link, before replacing it with a fresh copy", err)
	}
	content, err := io.ReadAll(file)
	return content, st, err
}

// oNoFollowAny is macOS's O_NOFOLLOW_ANY (macOS 11+), which syscall lacks: an open refusing a
// symlink anywhere on the path, ELOOP for one, even one leading nowhere.
const oNoFollowAny = 0x20000000

// open opens the config file, and stats what it opened, for its status and content to be the same
// file's. It opens nonblocking so a FIFO cannot stall the proxy.
//
// An added file is refused should it, or a dir on its way, be a symlink, even one leading nowhere:
// chopi denies the sandbox changes to the config dir the file is in, as it was when the session
// started, but not to wherever a link, made since, would lead. The path is given real, its links
// resolved, so any link on it was made since. A link leading nowhere is refused rather than taken
// for a missing file, which would take away what the file added. The one open both checks the path
// and reads the file, so a link swapped in after the check is not read.
func (f *configFile) open() (*os.File, fs.FileInfo, error) {
	flags := os.O_RDONLY | syscall.O_NONBLOCK
	if f.added {
		flags |= oNoFollowAny
	}
	file, err := os.OpenFile(f.path, flags, 0)
	if f.added && errors.Is(err, syscall.ELOOP) {
		return nil, nil, fmt.Errorf("%s, or a dir on its way, is a symlink, which could lead out of the dir chopi keeps sandboxed commands from changing: make it a regular file or dir", f.path)
	}
	if err != nil {
		return nil, nil, err
	}
	st, err := file.Stat()
	if err != nil {
		file.Close()
		return nil, nil, err
	}
	if !st.Mode().IsRegular() {
		file.Close()
		return nil, nil, fmt.Errorf("%s is not a regular file", f.path)
	}
	return file, st, nil
}

// taker takes up a config from the contents of its files: the base file, and the one added to it.
// resave is whether the contents are as last taken up, as when a file is saved with no edit. warn
// receives the warnings about a config it takes up. done is called once a config it took up has
// taken effect, or with the error if it didn't fully take effect (networkTaker.take).
type taker func(files []configContent, resave bool, warn func(error), done func(error)) error

// configFiles are the network config files, the base file and the one added to it, which the proxy
// takes up as one config. A change to either file takes up the config with the other file as last
// taken up (apply). take takes up their config.
type configFiles struct {
	base, added *configFile
	take        taker
}

// currentPending checks that a refused edit still matches the file before a partner reload
// retries it. The file's own poll handles any replacement, disappearance, or read failure.
func (f *configFile) currentPending() bool {
	if f.read.content == nil || f.accepted.content != nil && bytes.Equal(f.read.content, f.accepted.content) {
		return false
	}
	content, _, err := f.readChecked()
	return err == nil && bytes.Equal(content, f.read.content)
}

// watch polls the files for changes in turn, the base file and then the added one, and takes up
// the config on a change to either. Between polls, it runs what settled carries: what to do as a
// reload of the relays ends (networkTaker.reloadRelays). The reload itself never holds up a poll.
func (g *configFiles) watch(log *logrus.Logger, settled <-chan func()) {
	tick := time.Tick(reloadPollInterval)
	for {
		select {
		case <-tick:
			g.poll(log)
		case settle := <-settled:
			settle()
		}
	}
}

// poll polls each file for a change once, as watch does.
func (g *configFiles) poll(log *logrus.Logger) {
	for _, f := range g.files() {
		g.applyIfChanged(log, f)
	}
}

// files returns the watched files in the order they are polled and taken up: the base file, then
// the added one.
func (g *configFiles) files() []*configFile {
	return []*configFile{g.base, g.added}
}

// view is the content of f to take up on a change to changed. That is f's content as last read if
// f is the changed file, or if the proxy is starting (changed is nil). Otherwise, it is f's content
// as last taken up.
func (f *configFile) view(changed *configFile) configContent {
	if changed == nil || f == changed {
		return f.read
	}
	return f.accepted
}

// takeUp takes up the config on a change to changed (nil as the proxy starts), from the files'
// contents (configFile.view). On success, it records each file's content as taken up. On failure,
// it records nothing, and the previous config stays.
//
// warn receives take's warnings, and the refusal returned names the file to fix. done is called
// once the config has taken effect (taker).
//
// As the proxy starts, a mistake in the content of a workspace's own config keeps its sessions from
// starting, as a mistake in the base config does. A running session keeps what it last took up
// through an edit it refuses, and a new session starts only on what a running one would take up.
// So every session of the workspace runs on the same config, and one session's reload banners hold
// for them all.
func (g *configFiles) takeUp(changed *configFile, warn func(error), done func(error)) error {
	used := g.files()
	contents := make([]configContent, len(used))
	for i, f := range used {
		contents[i] = f.view(changed)
	}
	resave := changed != nil && bytes.Equal(changed.read.content, changed.accepted.content)
	if err := g.take(contents, resave, warn, done); err != nil {
		return err
	}
	for i, f := range used {
		f.accepted = contents[i]
	}
	return nil
}

// applyIfChanged takes up the config when f has changed, or when f recovers from a read failure.
// It reads f's content now, and takes the other file's as last taken up (apply), so a change to f
// reads no other file.
//
// It logs the reload's success, marked if f is added. It also logs each failure, which keeps the
// previous config: a refused config, a file with other hard links (singleLink), an added file with
// a symlink on its way (configFile.open), and a file that can't be read. It moves a file with other
// links aside and puts the config last taken up in its place (putBack). applyIfGone handles a
// missing file.
func (g *configFiles) applyIfChanged(log *logrus.Logger, f *configFile) {
	file, st, err := f.open()
	if errors.Is(err, fs.ErrNotExist) {
		g.applyIfGone(log, f)
		return
	}
	f.missing = false
	if err != nil {
		var changed time.Time
		if errors.Is(err, fs.ErrPermission) {
			changed = modTime(f.path)
		}
		f.warnUnreadable(log, changed, err)
		return
	}
	defer file.Close()
	changed := st.ModTime()
	if changed.Equal(f.lastMod) && f.unreadable == nil && !f.goneFailed {
		return
	}
	f.goneFailed = false
	if err := singleLink(f.path, st); err != nil {
		f.unreadable = nil
		f.lastMod = changed
		f.logEntry(log).WithError(f.putBack(st, err)).Error(networkReloadFailed)
		return
	}
	content, err := io.ReadAll(file)
	if err != nil {
		f.warnUnreadable(log, changed, err)
		return
	}
	f.unreadable = nil
	f.lastMod = changed
	f.read = newConfigContent(f.path, content)
	if err := g.apply(log, f); err != nil {
		f.logEntry(log).WithError(err).Error(networkReloadFailed)
	}
}

// warnUnreadable logs once per unreadable edit, or once until recovery if its modification time is
// unknown.
func (f *configFile) warnUnreadable(log *logrus.Logger, changed time.Time, err error) {
	if f.unreadable == nil || !f.unreadable.Equal(changed) {
		f.logEntry(log).WithError(err).Error(networkReloadFailed)
	}
	f.unreadable = &changed
}

// applyIfGone handles the config file, f, found missing. A base file's absence is ignored: atomic-
// rename saves make it momentarily disappear, and with a genuinely deleted one, the config in
// effect stays, as there is nothing else to go on. An added file missing adds nothing, so what it
// added is taken away -- once it is still missing at the next poll, past any atomic save. One
// missing all along is left be, but for a refusal of what was there instead, before anything was
// read from it (a symlink, a file it couldn't read), which no longer stands: it is confirmed gone
// at once, as nothing is taken away. If taking it away is refused, applyIfGone tries again at each
// poll, logging the failure once, so what the file added doesn't outlive it.
func (g *configFiles) applyIfGone(log *logrus.Logger, f *configFile) {
	if !f.added {
		return
	}
	if f.lastMod.IsZero() {
		if f.unreadable != nil {
			f.unreadable = nil
			f.logEntry(log).Info(networkReloaded)
		}
		return
	}
	if !f.missing {
		f.missing = true
		f.unreadable = nil
		return
	}
	f.read = newConfigContent(f.path, nil)
	if err := g.apply(log, f); err != nil {
		if !f.goneFailed {
			f.logEntry(log).WithError(err).Error(networkReloadFailed)
		}
		f.goneFailed = true
		return
	}
	f.goneFailed = false
	f.missing = false
	f.lastMod = time.Time{}
}

// apply takes up the config on a change to f, from f's content as last read and the other files'
// as last taken up (takeUp). It logs how the config took effect (configFile.settled).
//
// A refused edit to one file isn't taken up with an edit to another: the other edit is taken up or
// refused on its own merits. On failure, the previous config stays, and apply returns the refusal
// for the caller to log.
//
// On success, apply tries again a refused edit to another file, if that edit is still current, and
// logs the retry as it logs f's reload. That way, an edit refused for what f had is taken up now
// that f has changed. A failed retry leaves the original refusal in effect.
func (g *configFiles) apply(log *logrus.Logger, f *configFile) error {
	if err := g.takeUp(f, f.warn(log), f.settled(log)); err != nil {
		return err
	}
	for _, other := range g.files() {
		if other != f && other.currentPending() {
			g.takeUp(other, other.warn(log), other.settled(log))
		}
	}
	return nil
}

// settled logs how a config taken up on a change to the file took effect: its reload, or its
// failure if the relays didn't come up on it.
func (f *configFile) settled(log *logrus.Logger) func(error) {
	return func(err error) {
		if err != nil {
			f.logEntry(log).WithError(err).Error(networkReloadFailed)
			return
		}
		f.logEntry(log).Info(networkReloaded)
	}
}

// warn logs a warning on taking up the config file as its reloads are logged.
func (f *configFile) warn(log *logrus.Logger) func(error) {
	return func(warning error) { f.logEntry(log).Warn(warning.Error()) }
}

// logEntry is the log entry for the config file. Its fields are the file's path ("network"),
// whether it adds to the base config ("added"), what the user knows it as ("what"), and its name
// for a banner to show ("name"). The log's formatter and the banners show them as they are, and
// group banners by file (.internal/format-reload.jq, .internal/chopi-proxy.sh's notify_reload).
//
// A file added to the base config is the workspace's own, so its name includes its dir, which says
// whose it is.
func (f *configFile) logEntry(log *logrus.Logger) *logrus.Entry {
	what, name := "network config", filepath.Base(f.path)
	if f.added {
		what = "workspace " + what
		name = filepath.Join(filepath.Base(filepath.Dir(f.path)), name)
	}
	return log.WithFields(logrus.Fields{"network": f.path, "added": f.added, "what": what, "name": name})
}

// putBack moves the config file, refused for its other hard links (refusal), to
// path.refused-TIMESTAMP for review, and rewrites path, under a new inode, with the content last
// taken up: what was written through another link is then never served, now or as the proxy next
// starts. Having rewritten it, it records the rewritten file's modification time, so it isn't taken
// up as a change, and what it holds as its content last read. An added file with nothing taken up from it
// is moved aside alone, leaving none, as was taken up. It returns refusal, saying what became of
// the file.
func (f *configFile) putBack(st fs.FileInfo, refusal error) error {
	aside := f.path + ".refused-" + time.Now().Format("20060102-150405")
	if err := os.Rename(f.path, aside); err != nil {
		return fmt.Errorf("%w; could not move it aside for review: %v", refusal, err)
	}
	f.read = f.accepted
	if f.accepted.content == nil {
		f.lastMod = time.Time{}
		return fmt.Errorf("%w; moved it to %s for review, leaving none, as none was taken up", refusal, aside)
	}
	if err := writeAtomically(f.path, string(f.accepted.content), st.Mode().Perm()); err != nil {
		return fmt.Errorf("%w; moved it to %s for review, but could not put back the config last taken up: %v", refusal, aside, err)
	}
	f.lastMod = modTime(f.path)
	return fmt.Errorf("%w; moved it to %s for review, and put back the config last taken up", refusal, aside)
}

// singleLink refuses a config file with more than one hard link:
// the sandbox denies changes to it by path, so a sandboxed command may have written it through
// another link. chopi refuses one before launch (preflight_proxy_config_links), and the proxy as
// it starts (newConfigFile); this is for one made since.
func singleLink(path string, st fs.FileInfo) error {
	if sys := st.Sys().(*syscall.Stat_t); sys.Nlink > 1 {
		return fmt.Errorf("%s has %d hard links, which a sandboxed command may write through", path, sys.Nlink)
	}
	return nil
}

// newConfigFiles reads the network config files, the base file and the one added to it, as the
// proxy starts, with take to take up their config. It doesn't take up the config yet (takeUp).
func newConfigFiles(base, added string, take taker) (*configFiles, error) {
	baseFile, err := newConfigFile(base, false)
	if err != nil {
		return nil, err
	}
	addedFile, err := newConfigFile(added, true)
	if err != nil {
		return nil, err
	}
	return &configFiles{base: baseFile, added: addedFile, take: take}, nil
}

// modTime is the file at path's modification time: zero for one missing or unreadable.
func modTime(path string) time.Time {
	st, err := os.Stat(path)
	if err != nil {
		return time.Time{}
	}
	return st.ModTime()
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
	if len(os.Args) > 1 && os.Args[1] == migrateNetworkCommand {
		os.Exit(runMigrateNetwork(os.Args[2:], os.Stderr))
	}
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
	args := append([]string{os.Args[0]}, opts.smokeArgs...)
	// The token is for rendering the relays' config, not for smokescreen or Caddy.
	relayConf := relayConfig{cmd: opts.relayConfig, env: takeEnv("GH_TOKEN", "GITHUB_TOKEN")}

	// Smokescreen logs to stdout, the log, from the start, its global logger included: stderr is
	// for why the proxy can't start.
	logrus.SetOutput(os.Stdout)
	conf, err := cmd.NewConfiguration(args, logrus.StandardLogger())
	if err != nil {
		fail("could not create the smokescreen configuration: %v", err)
	}
	if conf == nil {
		// What NewConfiguration gives for --help or --version, having printed them: never passed by
		// chopi-proxy.sh, so nothing to run.
		fail("smokescreen gave no configuration (--help or --version on the command line?)")
	}
	conf.RoleFromRequest = defaultRoleFromRequest

	// Same log wiring as standalone smokescreen (https://github.com/stripe/smokescreen/blob/a3294a6cc4e4/main.go#L33-L41)
	conf.Log.Formatter = &logrus.JSONFormatter{}
	log.SetOutput(&smokescreen.Log2LogrusWriter{Entry: conf.Log.WithField("stdlog", "1")})
	log.SetFlags(0)

	taker := newNetworkTaker(conf, os.Getenv(gitHubExfiltrationOverride) != "")
	// Read the config files now, the base file and the one added to it, and take up the proxy's
	// config from them alone. Their watch takes up any edit made from here on, and takes up a
	// missing added file once it is made.
	networkFiles, err := newConfigFiles(opts.network, opts.addNetwork, taker.take)
	if err != nil {
		fail("%v", err)
	}
	if err := networkFiles.takeUp(nil, func(warning error) { complain("warning: %v", warning) }, func(error) {}); err != nil {
		// The advice is for a base file from a template predating the relays.
		if e := (*exfiltrationError)(nil); errors.As(err, &e) && e.path == opts.network {
			fail("refusing to run: %v\n\n%s", err, gitHubExfiltrationAdvice(opts.network, opts.networkTemplate))
		}
		fail("could not load the network config: %v", err)
	}
	conf.EgressACL = taker

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
	initialConfig, notes, err := relayConf.render(stop, taker.initial)
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
		proc, err := relaySup.start(initialConfig, taker.initial)
		if err == nil {
			relaySup.serve(proc)
		}
		relaysUp <- err
	}()
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
	// Start the watch once the relays are up, so an edit reloads them along with the rules. The
	// first poll sees an edit made as the proxy started, as that edit changed the file since it
	// was taken up.
	taker.relays, taker.served = relaySup.reload, relaySup.served
	go networkFiles.watch(conf.Log, taker.settled)

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

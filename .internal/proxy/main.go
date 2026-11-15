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
	"bytes"
	"errors"
	"fmt"
	"io"
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
// okMsg on success, and failedMsg on failure. name is what the user knows it as, as the log says.
type configKind struct {
	key, okMsg, failedMsg, name string
}

var (
	rulesKind     = configKind{"rules", rulesReloaded, rulesReloadFailed, "rules"}
	allowlistKind = configKind{"allowlist", allowlistReloaded, allowlistReloadFailed, "GitHub allowlist"}
)

// takeRules is the rules files' taker: it parses the base config and takes it up in holder.
func takeRules(conf *smokescreen.Config, holder *swappableACL) taker {
	return func(base, _ []byte, warn func(error)) error {
		rules, err := parseRules(conf, base)
		if err != nil {
			return err
		}
		return holder.take(rules, warn)
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

// configFile is a config file the proxy watches, of kind, and whether it is added to the base
// config (added.go). content is what was last read from it, by its own reload, which checks it
// first, whether or not that was refused. accepted is what was last taken up from it: what its pair
// is taken up with, and what putBack puts back. lastMod is the modification time last read: zero
// for an added file missing since the proxy started or since it was last taken away. unreadable is
// set when its last read failed, and was logged, to the modification time of the edit it failed on
// (zero if unknown): the cached lastMod then proves nothing, so it is read
// again. goneFailed is whether, added and missing, taking it away failed, and was logged
// (applyIfGone). missing is whether, added, it was missing at the last poll (applyIfChanged).
type configFile struct {
	path              string
	kind              configKind
	added             bool
	content, accepted []byte // nil for an added file with none
	lastMod           time.Time
	unreadable        *time.Time
	goneFailed        bool
	missing           bool
}

// newConfigFile is the config file at path, as the proxy is about to take it up, refused if it has
// other hard links (singleLink): it takes it up as it is then, so one written through another link
// since chopi's preflight checked would be served. An added one may be missing, but not have a
// symlink on its way (configFile.open). Its modification time is taken as it is opened, before it
// is read, for an edit made as it is read to be taken up again.
func newConfigFile(path string, kind configKind, added bool) (*configFile, error) {
	f := &configFile{path: path, kind: kind, added: added}
	content, st, err := f.readChecked()
	if added && errors.Is(err, fs.ErrNotExist) {
		return f, nil
	}
	if err != nil {
		return nil, err
	}
	f.lastMod = st.ModTime()
	f.content = content
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

// taker takes up a config from the contents of its files: added nil for an added file missing, or
// none. warn is for what it has to say of a config it takes up.
type taker func(base, added []byte, warn func(error)) error

// configFiles are the config files of one kind -- the base file, and the one added to it, if any
// (nil for none) -- taken up as one: a change to either takes it up with the other as last taken
// up (takeOnChange). take takes up their config, set before they are taken up or watched.
type configFiles struct {
	base, added *configFile
	take        taker
}

// contentOrNil is the config file's content as last read: nil for none, as for no file (nil f).
func (f *configFile) contentOrNil() []byte {
	if f == nil {
		return nil
	}
	return f.content
}

// acceptedOrNil is the config file's content last taken up: nil for none, as for no file (nil f).
func (f *configFile) acceptedOrNil() []byte {
	if f == nil {
		return nil
	}
	return f.accepted
}

// currentPending checks that a refused edit still matches the file before a partner reload
// retries it. The file's own poll handles any replacement, disappearance, or read failure.
func (f *configFile) currentPending() bool {
	if f == nil || f.content == nil || f.accepted != nil && bytes.Equal(f.content, f.accepted) {
		return false
	}
	content, _, err := f.readChecked()
	return err == nil && bytes.Equal(content, f.content)
}

// takeUpAtStart takes up the config from the files as the proxy started with them, warn
// being for what take has to say, and returns its refusal, which names the file to fix. A mistake
// in the content of a workspace's own config keeps its sessions from starting, as one in the base
// config does: a running session keeps what it last took up through an edit it refuses, and a new
// one starts only on what it would take up, so every session of the workspace runs on the same
// config, and their reloads' banners speak for them all.
func (g *configFiles) takeUpAtStart(warn func(error)) error {
	if err := g.take(g.base.content, g.added.contentOrNil(), warn); err != nil {
		return err
	}
	g.accept()
	return nil
}

// accept records the files' content as last read as the config taken up.
func (g *configFiles) accept() {
	g.base.accepted = g.base.content
	if g.added != nil {
		g.added.accepted = g.added.content
	}
}

// watch polls the files for changes, in turn, taking up the two on a change to either.
func (g *configFiles) watch(log *logrus.Logger) {
	for range time.Tick(reloadPollInterval) {
		g.applyIfChanged(log, g.base)
		if g.added != nil {
			g.applyIfChanged(log, g.added)
		}
	}
}

// applyIfChanged takes up the files when f has changed or recovers from a read failure: f's
// content, read now, with the other's as last read, so a change to f reads no other file. Its
// success is logged, as f's kind logs it, marked if f is added; so are its failure, a file with
// other hard links (singleLink), an added file with a symlink on its way (configFile.open), and a file
// that can't be read: each keeps the previous config. A file with other links is moved aside, the
// config last taken up put back in its place (putBack). A missing file is applyIfGone's.
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
		f.logEntry(log).WithError(f.putBack(st, err)).Error(f.kind.failedMsg)
		return
	}
	content, err := io.ReadAll(file)
	if err != nil {
		f.warnUnreadable(log, changed, err)
		return
	}
	f.unreadable = nil
	f.lastMod = changed
	f.content = content
	if err := g.apply(log, f); err != nil {
		f.logEntry(log).WithError(err).Error(f.kind.failedMsg)
	}
}

// warnUnreadable logs once per unreadable edit, or once until recovery if its modification time is
// unknown.
func (f *configFile) warnUnreadable(log *logrus.Logger, changed time.Time, err error) {
	if f.unreadable == nil || !f.unreadable.Equal(changed) {
		f.logEntry(log).WithError(err).Error(f.kind.failedMsg)
	}
	f.unreadable = &changed
}

// applyIfGone handles the config file, f, found missing. A base file's absence is ignored: atomic-
// rename saves make it momentarily disappear, and with a genuinely deleted one, the config in
// effect stays, as there is nothing else to go on. An added file missing adds nothing, so what it
// added is taken away -- once it is still missing at the next poll, past any atomic save. One
// missing all along is left be, but for a refusal of what was there instead, before anything was
// read from it (a symlink, a file it couldn't read), which no longer stands: it is confirmed gone
// at once, as nothing is taken away. Should taking it away fail, as a relay that doesn't come up
// fails it, it is tried again at each poll, the failure logged once, for what the file added not to
// outlive it.
func (g *configFiles) applyIfGone(log *logrus.Logger, f *configFile) {
	if !f.added {
		return
	}
	if f.lastMod.IsZero() {
		if f.unreadable != nil {
			f.unreadable = nil
			f.logEntry(log).Info(f.kind.okMsg)
		}
		return
	}
	if !f.missing {
		f.missing = true
		f.unreadable = nil
		return
	}
	f.content = nil
	if err := g.apply(log, f); err != nil {
		if !f.goneFailed {
			f.logEntry(log).WithError(err).Error(f.kind.failedMsg)
		}
		f.goneFailed = true
		return
	}
	f.goneFailed = false
	f.missing = false
	f.lastMod = time.Time{}
}

// apply takes up the config on a change to f (takeOnChange), logging its success as f's kind logs
// it. On failure, the previous config stays, and the refusal is returned, for the caller to log.
// On success, an edit to the other file refused before is tried again with it, as one
// refused for what f had is taken up now f has changed, if the edit is still current. A successful
// retry is logged. A failed retry leaves the original refusal in effect.
func (g *configFiles) apply(log *logrus.Logger, f *configFile) error {
	if err := g.takeOnChange(log, f); err != nil {
		return err
	}
	f.logEntry(log).Info(f.kind.okMsg)
	other := g.other(f)
	if other.currentPending() && g.takeOnChange(log, other) == nil {
		other.logEntry(log).Info(other.kind.okMsg)
	}
	return nil
}

// takeOnChange takes up the config on a change to f: f's content as last read, with the other
// file's as last taken up, recording f's as accepted on success. An edit refused to one is not
// taken up with an edit to the other, which is then taken or refused on its own merits.
func (g *configFiles) takeOnChange(log *logrus.Logger, f *configFile) error {
	base, added := f.content, g.added.acceptedOrNil()
	if f.added {
		base, added = g.base.accepted, f.content
	}
	if err := g.take(base, added, f.warn(log)); err != nil {
		return err
	}
	f.accepted = f.content
	return nil
}

// other is the file f is taken up with: the added file for the base one, and the reverse.
func (g *configFiles) other(f *configFile) *configFile {
	if f.added {
		return g.base
	}
	return g.added
}

// warn logs a warning on taking up the config file as its reloads are logged.
func (f *configFile) warn(log *logrus.Logger) func(error) {
	return func(warning error) { f.logEntry(log).Warn(warning.Error()) }
}

// logEntry is the log entry for the config file: its path under its kind's key, what the user knows
// it as ("what"), and its name for a banner to show ("name"), for the log's formatter and banners to
// say as they are (.internal/format-reload.jq, .internal/chopi-proxy.sh's notify_reload). One added
// to the base config is the workspace's own, named with its dir, which says whose it is.
func (f *configFile) logEntry(log *logrus.Logger) *logrus.Entry {
	what, name := f.kind.name, filepath.Base(f.path)
	if f.added {
		what = "workspace " + what
		name = filepath.Join(filepath.Base(filepath.Dir(f.path)), name)
	}
	return log.WithFields(logrus.Fields{f.kind.key: f.path, "what": what, "name": name})
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
	f.content = f.accepted
	if f.accepted == nil {
		f.lastMod = time.Time{}
		return fmt.Errorf("%w; moved it to %s for review, leaving none, as none was taken up", refusal, aside)
	}
	if err := writeAtomically(f.path, string(f.accepted), st.Mode().Perm()); err != nil {
		return fmt.Errorf("%w; moved it to %s for review, but could not put back the config last taken up: %v", refusal, aside, err)
	}
	f.lastMod = modTime(f.path)
	return fmt.Errorf("%w; moved it to %s for review, and put back the config last taken up", refusal, aside)
}

// singleLink refuses a config file with more than one hard link:
// the sandbox denies changes to it by path, so a sandboxed command may have written it through
// another link. chopi refuses one on the files in use before launch (preflight_proxy_config_links),
// and the proxy as it starts (newConfigFile); this is for one made since.
func singleLink(path string, st fs.FileInfo) error {
	if sys := st.Sys().(*syscall.Stat_t); sys.Nlink > 1 {
		return fmt.Errorf("%s has %d hard links, which a sandboxed command may write through", path, sys.Nlink)
	}
	return nil
}

// newConfigFiles is the config files of kind -- the base file, and the one added to it, if any (""
// for none) -- as the proxy takes them up as it starts, their config not yet taken up
// (takeUpAtStart).
func newConfigFiles(kind configKind, base, added string) (*configFiles, error) {
	baseFile, err := newConfigFile(base, kind, false)
	if err != nil {
		return nil, err
	}
	files := &configFiles{base: baseFile}
	if added != "" {
		if files.added, err = newConfigFile(added, kind, true); err != nil {
			return nil, err
		}
	}
	return files, nil
}

// takeUp is newConfigFiles, exiting the proxy on a refusal.
func takeUp(kind configKind, base, added string) *configFiles {
	files, err := newConfigFiles(kind, base, added)
	if err != nil {
		fail("%v", err)
	}
	return files
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
	rulesFiles := takeUp(rulesKind, path, "")
	allowlistFiles := takeUp(allowlistKind, opts.allowlist, "")

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

	rules, err := parseRules(conf, rulesFiles.base.content)
	if err != nil {
		fail("could not load the egress ACL: %v", err)
	}
	holder := &swappableACL{allowGitHub: os.Getenv(gitHubExfiltrationOverride) != ""}
	if err := holder.take(rules, func(warning error) { complain("warning: %v", warning) }); err != nil {
		fail("refusing to run: %v\n\n%s", err, gitHubExfiltrationAdvice(path, opts.allowlist))
	}
	rulesFiles.base.accepted = rulesFiles.base.content
	conf.EgressACL = holder
	rulesFiles.take = takeRules(conf, holder)

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
	initialConfig, notes, err := relayConf.render(stop, allowlistFiles.base.content)
	if err != nil {
		if stop.Err() != nil {
			// Stopped as it rendered, maybe at a keychain prompt: nothing else is up yet.
			os.Exit(0)
		}
		fail("%v", err)
	}
	allowlistFiles.accept()
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
	go rulesFiles.watch(conf.Log)
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
	allowlistFiles.take = func(base, _ []byte, _ func(error)) error { return relaySup.reload(base) }
	go allowlistFiles.watch(conf.Log)

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

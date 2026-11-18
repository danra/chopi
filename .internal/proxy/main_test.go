package main

import (
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/sirupsen/logrus"
	logrustest "github.com/sirupsen/logrus/hooks/test"
	"github.com/stripe/smokescreen/pkg/smokescreen"
	acl "github.com/stripe/smokescreen/pkg/smokescreen/acl/v1"
)

// A minimal valid rules file allowing exactly one host.
func rulesAllowing(host string) string {
	return fmt.Sprintf(`version: v1
services: []
default:
  name: default
  action: enforce
  allowed_domains:
    - %s
`, host)
}

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(content)
}

func mtimeOf(t *testing.T, path string) time.Time {
	t.Helper()
	st, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	return st.ModTime()
}

func setMtime(t *testing.T, path string, to time.Time) {
	t.Helper()
	if err := os.Chtimes(path, to, to); err != nil {
		t.Fatal(err)
	}
}

// skipIfRoot skips a test relying on a file's mode to make it unreadable, which root reads anyway.
func skipIfRoot(t *testing.T) {
	t.Helper()
	if os.Getuid() == 0 {
		t.Skip("root reads a file whatever its mode")
	}
}

func chmod(t *testing.T, path string, mode os.FileMode) {
	t.Helper()
	if err := os.Chmod(path, mode); err != nil {
		t.Fatal(err)
	}
}

// reloadIfChanged reloads the rules if f, the rules file, changed since last taken up, as its watch
// does each tick.
func reloadIfChanged(conf *smokescreen.Config, holder *swappableACL, f *configFile) {
	f.applyIfChanged(conf.Log, takeRules(conf, holder, f))
}

// testSetup returns a config whose log entries are captured by the returned hook, a holder
// loaded from the given rules file, and the file, as taken up.
func testSetup(t *testing.T, path string) (*smokescreen.Config, *swappableACL, *configFile, *logrustest.Hook) {
	t.Helper()
	conf := smokescreen.NewConfig()
	logger, hook := logrustest.NewNullLogger()
	conf.Log = logger
	file, err := newConfigFile(path, rulesKind)
	if err != nil {
		t.Fatalf("initial check: %v", err)
	}
	rules, err := parseRules(conf, file.accepted)
	if err != nil {
		t.Fatalf("initial load: %v", err)
	}
	holder := &swappableACL{}
	if err := holder.take(rules, func(error) {}); err != nil {
		t.Fatalf("initial take: %v", err)
	}
	return conf, holder, file, hook
}

// reloaded expects the last log entry to be a successful reload's.
func reloaded(t *testing.T, hook *logrustest.Hook) {
	t.Helper()
	if last := hook.LastEntry(); last == nil || last.Message != rulesReloaded {
		t.Fatalf("expected a reloaded log entry, got %+v", last)
	}
}

// reloadFailure is the error of the last log entry, which it expects to be a refused reload's.
func reloadFailure(t *testing.T, hook *logrustest.Hook) error {
	t.Helper()
	last := hook.LastEntry()
	if last == nil || last.Message != rulesReloadFailed {
		t.Fatalf("expected a reload-failed log entry, got %+v", last)
	}
	err, _ := last.Data["error"].(error)
	if err == nil {
		t.Fatalf("expected the reload-failed log entry to carry an error, got %+v", last.Data)
	}
	return err
}

func decide(t *testing.T, holder *swappableACL, host string) acl.DecisionResult {
	t.Helper()
	d, err := holder.Decide(acl.DecideArgs{Host: host})
	if err != nil {
		t.Fatalf("Decide(%q): %v", host, err)
	}
	return d.Result
}

func TestReloadSwapsRules(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rules.yaml")
	writeFile(t, path, rulesAllowing("old.example"))
	conf, holder, file, hook := testSetup(t, path)
	lastMod := file.lastMod

	if got := decide(t, holder, "old.example"); got != acl.Allow {
		t.Fatalf("old.example before reload: got %v, want Allow", got)
	}
	if got := decide(t, holder, "new.example"); got != acl.Deny {
		t.Fatalf("new.example before reload: got %v, want Deny", got)
	}

	writeFile(t, path, rulesAllowing("new.example"))
	setMtime(t, path, lastMod.Add(time.Second))
	reloadIfChanged(conf, holder, file)
	newMod := file.lastMod
	if !newMod.After(lastMod) {
		t.Fatalf("mtime not advanced: %v -> %v", lastMod, newMod)
	}
	if got := decide(t, holder, "new.example"); got != acl.Allow {
		t.Fatalf("new.example after reload: got %v, want Allow", got)
	}
	if got := decide(t, holder, "old.example"); got != acl.Deny {
		t.Fatalf("old.example after reload: got %v, want Deny", got)
	}
	reloaded(t, hook)
}

func TestReloadFailureKeepsPreviousRules(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rules.yaml")
	writeFile(t, path, rulesAllowing("old.example"))
	conf, holder, file, hook := testSetup(t, path)
	lastMod := file.lastMod

	writeFile(t, path, "version: v9\n")
	setMtime(t, path, lastMod.Add(time.Second))
	reloadIfChanged(conf, holder, file)
	failedMod := file.lastMod
	if got := decide(t, holder, "old.example"); got != acl.Allow {
		t.Fatalf("old.example after failed reload: got %v, want Allow (previous rules kept)", got)
	}
	reloadFailure(t, hook)

	// The failed mtime is recorded: the broken file is not re-tried (and re-logged)
	// every tick, only when it changes again.
	hook.Reset()
	reloadIfChanged(conf, holder, file)
	if !file.lastMod.Equal(failedMod) {
		t.Fatalf("mtime moved without a file change: %v -> %v", failedMod, file.lastMod)
	}
	if len(hook.Entries) != 0 {
		t.Fatalf("unexpected log entries on an unchanged broken file: %+v", hook.Entries)
	}

	// Fixing the file recovers.
	writeFile(t, path, rulesAllowing("fixed.example"))
	setMtime(t, path, failedMod.Add(time.Second))
	reloadIfChanged(conf, holder, file)
	if got := decide(t, holder, "fixed.example"); got != acl.Allow {
		t.Fatalf("fixed.example after recovery: got %v, want Allow", got)
	}
}

// unreadableEdit makes the rules file unreadable, as edited at mod, and checks the poll that sees
// it logs a reload failure.
func unreadableEdit(t *testing.T, conf *smokescreen.Config, holder *swappableACL, file *configFile,
	hook *logrustest.Hook, mod time.Time) {
	t.Helper()
	chmod(t, file.path, 0)
	setMtime(t, file.path, mod)
	reloadIfChanged(conf, holder, file)
	reloadFailure(t, hook)
}

// An edit the proxy can't read, for the file's mode, is taken up once the mode is fixed, though a
// chmod changes no modification time.
func TestAnEditMadeReadableIsTakenUp(t *testing.T) {
	skipIfRoot(t)
	path := filepath.Join(t.TempDir(), "rules.yaml")
	writeFile(t, path, rulesAllowing("old.example"))
	conf, holder, file, hook := testSetup(t, path)

	writeFile(t, path, rulesAllowing("new.example"))
	unreadableEdit(t, conf, holder, file, hook, file.lastMod.Add(time.Second))
	// Tried again on the next poll, its being unreadable isn't logged again.
	hook.Reset()
	reloadIfChanged(conf, holder, file)
	if len(hook.Entries) != 0 {
		t.Fatalf("unexpected log entries on a file still unreadable: %+v", hook.Entries)
	}

	chmod(t, path, 0o644)
	reloadIfChanged(conf, holder, file)
	reloaded(t, hook)
	if got := decide(t, holder, "new.example"); got != acl.Allow {
		t.Fatalf("new.example once the file is readable: got %v, want Allow", got)
	}
}

// What a refusal puts back is the config in effect, though the file changed as apply read it.
func TestARefusalPutsBackTheConfigInEffect(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "rules.yaml")
	writeFile(t, path, rulesAllowing("old.example"))
	conf, holder, file, _ := testSetup(t, path)

	writeFile(t, path, rulesAllowing("a.example"))
	setMtime(t, path, file.lastMod.Add(time.Second))
	take := takeRules(conf, holder, file)
	file.applyIfChanged(conf.Log, func(content []byte) error {
		writeFile(t, path, rulesAllowing("b.example"))
		return take(content)
	})
	if got := decide(t, holder, "a.example"); got != acl.Allow {
		t.Fatalf("a.example, as the watcher read it: got %v, want Allow", got)
	}

	writeThroughOtherLink(t, path, filepath.Join(dir, "other-link.yaml"), rulesAllowing("c.example"),
		file.lastMod.Add(time.Hour))
	reloadIfChanged(conf, holder, file)
	if got := readFile(t, path); got != rulesAllowing("a.example") {
		t.Fatalf("the put-back file should allow a.example, the config in effect, got:\n%s", got)
	}
}

// Each edit that can't be read is logged, though the previous one couldn't be read either: the user
// is told the new one wasn't taken up.
func TestASecondUnreadableEditIsLogged(t *testing.T) {
	skipIfRoot(t)
	path := filepath.Join(t.TempDir(), "rules.yaml")
	writeFile(t, path, rulesAllowing("old.example"))
	conf, holder, file, hook := testSetup(t, path)
	mod := file.lastMod

	unreadableEdit(t, conf, holder, file, hook, mod.Add(time.Second))

	hook.Reset()
	unreadableEdit(t, conf, holder, file, hook, mod.Add(2*time.Second))
}

// An edit that can't be read after a refused one is logged, though the refused change couldn't be
// put back.
func TestUnreadableAfterARefusalIsLogged(t *testing.T) {
	skipIfRoot(t)
	dir := t.TempDir()
	path := filepath.Join(dir, "rules.yaml")
	writeFile(t, path, rulesAllowing("old.example"))
	conf, holder, file, hook := testSetup(t, path)
	mod := file.lastMod

	unreadableEdit(t, conf, holder, file, hook, mod.Add(time.Second))

	// Refused, and not put back: its directory can't take the move aside.
	chmod(t, path, 0o644)
	other := filepath.Join(dir, "other-link.yaml")
	writeThroughOtherLink(t, path, other, rulesAllowing("new.example"), mod.Add(2*time.Second))
	chmod(t, dir, 0o555)
	t.Cleanup(func() { chmod(t, dir, 0o755) })
	hook.Reset()
	reloadIfChanged(conf, holder, file)
	if err := reloadFailure(t, hook); !strings.Contains(err.Error(), "could not move it aside") {
		t.Fatalf("expected the refused file not to be moved aside, got %v", err)
	}

	chmod(t, dir, 0o755)
	if err := os.Remove(other); err != nil {
		t.Fatal(err)
	}
	hook.Reset()
	unreadableEdit(t, conf, holder, file, hook, mod.Add(3*time.Second))
}

// A config file with another hard link, which the sandbox profile can't see by its path, may have
// been written through it by a sandboxed command: its change is refused, the previous rules kept, and
// it is moved aside for review, what was last taken up put back in its place with no other
// links. So what was written through the other link is taken up neither once that link is gone,
// nor on a restart.
func TestReloadRefusesAFileWithOtherLinks(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "rules.yaml")
	writeFile(t, path, rulesAllowing("old.example"))
	conf, holder, file, hook := testSetup(t, path)
	lastMod := file.lastMod

	other := filepath.Join(dir, "other-link.yaml")
	writeThroughOtherLink(t, path, other, rulesAllowing("new.example"), lastMod.Add(time.Second))
	reloadIfChanged(conf, holder, file)
	refusedMod := file.lastMod
	if got := decide(t, holder, "new.example"); got != acl.Deny {
		t.Fatalf("new.example after a change through another link: got %v, want Deny", got)
	}
	if got := decide(t, holder, "old.example"); got != acl.Allow {
		t.Fatalf("old.example after a refused reload: got %v, want Allow (previous rules kept)", got)
	}
	err := reloadFailure(t, hook)
	if !strings.Contains(err.Error(), "2 hard links") {
		t.Fatalf("the error should name the hard links, got %v", err)
	}

	// Put back, with no other links, and moved aside, named in the error.
	if got := readFile(t, path); got != rulesAllowing("old.example") {
		t.Fatalf("the rules file should hold the rules last taken up, got:\n%s", got)
	}
	if st, err := os.Stat(path); err != nil || singleLink(path, st) != nil {
		t.Fatalf("the put-back rules file should have no other links: %v", err)
	}
	asides, _ := filepath.Glob(path + ".refused-*")
	if len(asides) != 1 {
		t.Fatalf("expected the refused file moved aside, beside it, got %v", asides)
	}
	if got := readFile(t, asides[0]); got != rulesAllowing("new.example") {
		t.Fatalf("the file moved aside should hold what was written through the other link, got:\n%s", got)
	}
	if !strings.Contains(err.Error(), asides[0]) {
		t.Fatalf("the error should say where the refused file went, got %v", err)
	}
	if !refusedMod.Equal(mtimeOf(t, path)) {
		t.Fatalf("the put-back file's mtime should be taken up: got %v, want %v", refusedMod, mtimeOf(t, path))
	}

	// What was written through the other link never comes back: not once that link is gone.
	if err := os.Remove(other); err != nil {
		t.Fatal(err)
	}
	hook.Reset()
	reloadIfChanged(conf, holder, file)
	if !file.lastMod.Equal(refusedMod) {
		t.Fatalf("mtime moved without a file change: %v -> %v", refusedMod, file.lastMod)
	}
	if len(hook.Entries) != 0 {
		t.Fatalf("the put-back file should not be taken up again, got %+v", hook.Entries)
	}
	writeFile(t, path, rulesAllowing("fixed.example"))
	setMtime(t, path, refusedMod.Add(time.Second))
	reloadIfChanged(conf, holder, file)
	if got := decide(t, holder, "fixed.example"); got != acl.Allow {
		t.Fatalf("fixed.example after a change with no other links: got %v, want Allow", got)
	}
	// A later refusal puts back what was taken up last, not what the proxy started with.
	fixedMod := file.lastMod
	writeThroughOtherLink(t, path, other, rulesAllowing("new.example"), fixedMod.Add(time.Second))
	reloadIfChanged(conf, holder, file)
	if got := readFile(t, path); got != rulesAllowing("fixed.example") {
		t.Fatalf("the rules file should hold the rules last taken up, got:\n%s", got)
	}
}

// writeThroughOtherLink links other to path, writes content through other, and sets path's mtime
// to mod, for a reload to see the change.
func writeThroughOtherLink(t *testing.T, path, other, content string, mod time.Time) {
	t.Helper()
	if err := os.Link(path, other); err != nil {
		t.Fatal(err)
	}
	writeFile(t, other, content)
	setMtime(t, path, mod)
}

// As the proxy starts, a hard-linked config file is refused, whichever it is.
func TestStartRefusesAFileWithOtherLinks(t *testing.T) {
	dir := t.TempDir()
	rules := filepath.Join(dir, "rules.yaml")
	allowlist := filepath.Join(dir, "allowlist")
	writeFile(t, rules, rulesAllowing("old.example"))
	writeFile(t, allowlist, "")
	for path, kind := range map[string]configKind{rules: rulesKind, allowlist: allowlistKind} {
		if _, err := newConfigFile(path, kind); err != nil {
			t.Fatalf("a config file with no other links: got %v, want no error", err)
		}
	}
	if err := os.Link(allowlist, filepath.Join(dir, "other-link")); err != nil {
		t.Fatal(err)
	}
	_, err := newConfigFile(allowlist, allowlistKind)
	if err == nil || !strings.Contains(err.Error(), allowlist) || !strings.Contains(err.Error(), "2 hard links") {
		t.Fatalf("a hard-linked allowlist: got %v, want an error naming it and its hard links", err)
	}
}

// As the proxy starts, a config file it can't read, missing or for its mode, is refused, the error
// naming it: one taken up as empty would start a session on a config other than the user's, and,
// should the file be fixed by a chmod, which changes no modification time, on it for good.
func TestStartRefusesAFileItCantRead(t *testing.T) {
	skipIfRoot(t)
	dir := t.TempDir()
	unreadable := filepath.Join(dir, "allowlist")
	writeFile(t, unreadable, "owner/repo\n")
	chmod(t, unreadable, 0)
	for _, path := range []string{unreadable, filepath.Join(dir, "missing")} {
		if _, err := newConfigFile(path, allowlistKind); err == nil || !strings.Contains(err.Error(), path) {
			t.Fatalf("%s: got %v, want an error naming it", path, err)
		}
	}
}

func TestMissingFileKeepsPreviousRules(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rules.yaml")
	writeFile(t, path, rulesAllowing("old.example"))
	conf, holder, file, hook := testSetup(t, path)
	lastMod := file.lastMod

	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	reloadIfChanged(conf, holder, file)
	if !file.lastMod.Equal(lastMod) {
		t.Fatalf("mtime moved on a missing file: %v -> %v", lastMod, file.lastMod)
	}
	if len(hook.Entries) != 0 {
		t.Fatalf("unexpected log entries for a missing file: %+v", hook.Entries)
	}
	if got := decide(t, holder, "old.example"); got != acl.Allow {
		t.Fatalf("rules dropped on a missing file: got %v, want Allow", got)
	}

	// A recreated file reloads as usual.
	writeFile(t, path, rulesAllowing("new.example"))
	setMtime(t, path, lastMod.Add(time.Second))
	reloadIfChanged(conf, holder, file)
	if got := decide(t, holder, "new.example"); got != acl.Allow {
		t.Fatalf("new.example after the file reappeared: got %v, want Allow", got)
	}
}

func TestUnreadableFileIsSurfacedOnce(t *testing.T) {
	dir := t.TempDir()
	// A path whose parent is a regular file, not a directory, makes os.Stat return
	// ENOTDIR: a non-ENOENT error standing in for any genuine stat failure (a permission
	// change, an I/O error) that a merely-missing file must be told apart from.
	notDir := filepath.Join(dir, "notdir")
	writeFile(t, notDir, "x")
	path := filepath.Join(notDir, "rules.yaml")

	conf := smokescreen.NewConfig()
	logger, hook := logrustest.NewNullLogger()
	conf.Log = logger
	holder := &swappableACL{} // untouched: a stat error returns before any load or swap
	file := &configFile{path: path, kind: rulesKind}

	// First failing tick surfaces the error and sets warned; the mtime does not move.
	reloadIfChanged(conf, holder, file)
	if file.warned == nil {
		t.Fatal("a non-ENOENT stat error should set warned")
	}
	if !file.lastMod.IsZero() {
		t.Fatalf("mtime should not advance on a stat error, got %v", file.lastMod)
	}
	reloadFailure(t, hook) // the stat error attached, so the rendered line can name it

	// A persistent error does not re-log while warned stays set.
	hook.Reset()
	reloadIfChanged(conf, holder, file)
	if file.warned == nil {
		t.Fatal("warned should stay set while the stat keeps failing")
	}
	if len(hook.Entries) != 0 {
		t.Fatalf("a persistent stat error should not re-log every tick, got %+v", hook.Entries)
	}

	// Repairing the path reloads and clears warned.
	if err := os.Remove(notDir); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(notDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeFile(t, path, rulesAllowing("ok.example"))
	reloadIfChanged(conf, holder, file)
	if file.warned != nil {
		t.Fatal("a healthy stat should clear warned")
	}
	if got := decide(t, holder, "ok.example"); got != acl.Allow {
		t.Fatalf("rules should reload after the path is repaired: got %v, want Allow", got)
	}
}

// reloadTo sets up rules allowing old.example, then reloads them as the given rules, allowing
// GitHub's domains if allowGitHub.
func reloadTo(t *testing.T, rules string, allowGitHub bool) (*swappableACL, *logrustest.Hook) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "rules.yaml")
	writeFile(t, path, rulesAllowing("old.example"))
	conf, holder, file, hook := testSetup(t, path)
	holder.allowGitHub = allowGitHub
	lastMod := file.lastMod

	writeFile(t, path, rules)
	setMtime(t, path, lastMod.Add(time.Second))
	reloadIfChanged(conf, holder, file)
	return holder, hook
}

// Rules allowing github.com or api.github.com let a sandboxed command reach GitHub directly,
// bypassing the relays and the repos allowlist they enforce: an edit that allows them is refused
// like a broken one, the previous rules kept -- whatever form the allowing takes.
func TestReloadRefusesRulesAllowingGitHub(t *testing.T) {
	for _, allowing := range []string{"github.com", "api.github.com", `"*.github.com"`} {
		t.Run(allowing, func(t *testing.T) {
			holder, hook := reloadTo(t, rulesAllowing(allowing), false)
			if got := decide(t, holder, "old.example"); got != acl.Allow {
				t.Fatalf("old.example after a refused reload: got %v, want Allow (previous rules kept)", got)
			}
			if err := reloadFailure(t, hook); !strings.Contains(err.Error(), "github.com") {
				t.Fatalf("the error should name the GitHub domain allowed, got %v", err)
			}
		})
	}
}

// The override that lets a session start with rules allowing GitHub's domains lets a reload take
// them up too, with a warning in the log.
func TestReloadTakesUpRulesAllowingGitHubWithTheOverride(t *testing.T) {
	holder, hook := reloadTo(t, rulesAllowing("github.com"), true)
	if got := decide(t, holder, "github.com"); got != acl.Allow {
		t.Fatalf("github.com after a reload with the override: got %v, want Allow", got)
	}
	reloaded(t, hook)
	if !slices.ContainsFunc(hook.Entries, func(e logrus.Entry) bool {
		return e.Level == logrus.WarnLevel && strings.Contains(e.Message, "allow github.com") &&
			strings.Contains(e.Message, gitHubExfiltrationOverride+" is set")
	}) {
		t.Fatalf("expected a warning that the rules allow github.com, naming the override, got %+v", hook.Entries)
	}
}

func TestGitHubExfiltration(t *testing.T) {
	template := readFile(t, filepath.Join("../..", rulesTemplate))
	for _, tc := range []struct{ name, rules, want string }{
		{"a pre-relay rules file names both domains", rulesAllowing("api.anthropic.com") +
			"    - github.com\n    - api.github.com\n    - raw.githubusercontent.com\n", "github.com, api.github.com"},
		{"the shipped template is clean", template, ""},
		{"a service's rule counts too", `version: v1
services:
  - name: svc
    project: p
    action: enforce
    allowed_domains:
      - api.github.com
`, "api.github.com"},
		{"the global allow list counts too", rulesAllowing("api.anthropic.com") +
			"global_allow_list:\n  - github.com\n", "github.com"},
		{"an open policy allows them without naming them", `version: v1
services: []
default:
  name: default
  action: open
`, "github.com, *.github.com"},
		{"the upload host counts", rulesAllowing(`uploads.github.com`), "uploads.github.com"},
		{"the gist host counts", rulesAllowing(`gist.github.com`), "gist.github.com"},
		{"a subdomain glob counts, as one", rulesAllowing(`"*.github.com"`), "the rules allow *.github.com:"},
		{"a read-only subdomain named alone doesn't", rulesAllowing("codeload.github.com"), ""},
		{"the global deny list wins over the global allow list", rulesAllowing("api.anthropic.com") +
			"global_allow_list:\n  - github.com\nglobal_deny_list:\n  - github.com\n", ""},
		{"lookalike domains don't match", rulesAllowing("raw.githubusercontent.com") +
			"    - mygithub.com\n    - github.com.evil.example\n", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			rules, err := parseRules(smokescreen.NewConfig(), []byte(tc.rules))
			if err != nil {
				t.Fatalf("load: %v", err)
			}
			err = gitHubExfiltration(rules)
			switch {
			case tc.want == "" && err != nil:
				t.Fatalf("want no refusal, got %v", err)
			case tc.want != "" && (err == nil || !strings.Contains(err.Error(), tc.want)):
				t.Fatalf("want a refusal naming %q, got %v", tc.want, err)
			}
		})
	}
}

// The egress ACL file is taken out of smokescreen's args, in either flag form, for smokescreen not
// to read it too.
func TestTakeEgressACLPath(t *testing.T) {
	for _, args := range [][]string{
		{"--listen-ip", "127.0.0.1", "--egress-acl-file", "/rules.yaml", "--deny-range", "10.0.0.0/8"},
		{"--listen-ip", "127.0.0.1", "--egress-acl-file=/rules.yaml", "--deny-range", "10.0.0.0/8"},
	} {
		path, rest := takeEgressACLPath(args)
		want := []string{"--listen-ip", "127.0.0.1", "--deny-range", "10.0.0.0/8"}
		if path != "/rules.yaml" || !slices.Equal(rest, want) {
			t.Fatalf("%q: got %q, %q; want /rules.yaml, %q", args, path, rest, want)
		}
	}
}

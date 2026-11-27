package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/sirupsen/logrus"
	logrustest "github.com/sirupsen/logrus/hooks/test"
	"github.com/stripe/smokescreen/pkg/smokescreen"
	acl "github.com/stripe/smokescreen/pkg/smokescreen/acl/v1"
)

// A minimal network config allowing exactly one host.
func networkAllowing(host string) string {
	return fmt.Sprintf("allowed_domains:\n  - %s\n", host)
}

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// realTempDir is t.TempDir(), its links resolved, as an added file's path is given (configFile.open).
func realTempDir(t *testing.T) string {
	t.Helper()
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return dir
}

// networkTemplatePath is chopi's network config template, from this package's dir.
const networkTemplatePath = "../../config/templates/network.template.yaml"

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

// rewrite writes content to f and has rules apply it.
func rewrite(t *testing.T, files *configFiles, f *configFile, log *logrus.Logger, content string) {
	t.Helper()
	writeFile(t, f.path, content)
	files.applyIfChanged(log, f)
}

// testSetup returns a config whose log entries the returned hook captures, a taker loaded from the
// network config file at path, and that file. The file added to it is missing.
func testSetup(t *testing.T, path string) (*smokescreen.Config, *networkTaker, *configFiles, *configFile, *logrustest.Hook) {
	t.Helper()
	conf, taker, files, hook := setupWith(t, path, missingAdded(t))
	return conf, taker, files, files.base, hook
}

// setupWith is testSetup for the base network config file at base, and the one added to it at
// added. It returns the files as the proxy watches them.
func setupWith(t *testing.T, base, added string) (*smokescreen.Config, *networkTaker, *configFiles, *logrustest.Hook) {
	t.Helper()
	conf, taker, files, hook := untakenSetup(t, base, added)
	if err := files.takeUp(nil, func(error) {}, func(error) {}); err != nil {
		t.Fatalf("initial take: %v", err)
	}
	return conf, taker, files, hook
}

// missingAdded is the path of an added config file that is missing, at a real path, as chopi gives
// one (configFile.open).
func missingAdded(t *testing.T) string {
	t.Helper()
	return filepath.Join(realTempDir(t), "ws.yaml")
}

// untakenSetup is setupWith but for taking up the rules, left to the test, for the test to set the
// taker's relays or check what it served.
func untakenSetup(t *testing.T, base, added string) (*smokescreen.Config, *networkTaker, *configFiles, *logrustest.Hook) {
	t.Helper()
	conf := smokescreen.NewConfig()
	logger, hook := logrustest.NewNullLogger()
	conf.Log = logger
	taker := newNetworkTaker(conf, false)
	files, err := newConfigFiles(base, added, taker.take)
	if err != nil {
		t.Fatalf("initial check: %v", err)
	}
	return conf, taker, files, hook
}

// reloaded expects the last log entry to be a successful reload's.
func reloaded(t *testing.T, hook *logrustest.Hook) {
	t.Helper()
	if last := hook.LastEntry(); last == nil || last.Message != networkReloaded {
		t.Fatalf("expected a reloaded log entry, got %+v", last)
	}
}

// reloadFailure is the error of the last log entry, which it expects to be a refused reload's.
func reloadFailure(t *testing.T, hook *logrustest.Hook) error {
	t.Helper()
	last := hook.LastEntry()
	if last == nil || last.Message != networkReloadFailed {
		t.Fatalf("expected a reload-failed log entry, got %+v", last)
	}
	err, _ := last.Data["error"].(error)
	if err == nil {
		t.Fatalf("expected the reload-failed log entry to carry an error, got %+v", last.Data)
	}
	return err
}

func decide(t *testing.T, taker *networkTaker, host string) acl.DecisionResult {
	t.Helper()
	d, err := taker.Decide(acl.DecideArgs{Host: host})
	if err != nil {
		t.Fatalf("Decide(%q): %v", host, err)
	}
	return d.Result
}

// wantDecisions checks that taker decides each host as want says. A failure names when, if it isn't
// empty.
func wantDecisions(t *testing.T, taker *networkTaker, when string, want map[string]acl.DecisionResult) {
	t.Helper()
	if when != "" {
		when = " " + when
	}
	for host, w := range want {
		if got := decide(t, taker, host); got != w {
			t.Errorf("%s%s: got %v, want %v", host, when, got, w)
		}
	}
}

func TestReloadSwapsRules(t *testing.T) {
	path := filepath.Join(t.TempDir(), "network.yaml")
	writeFile(t, path, networkAllowing("old.example"))
	conf, taker, files, file, hook := testSetup(t, path)
	lastMod := file.lastMod

	if got := decide(t, taker, "old.example"); got != acl.Allow {
		t.Fatalf("old.example before reload: got %v, want Allow", got)
	}
	if got := decide(t, taker, "new.example"); got != acl.Deny {
		t.Fatalf("new.example before reload: got %v, want Deny", got)
	}

	rewrite(t, files, file, conf.Log, networkAllowing("new.example"))
	newMod := file.lastMod
	if !newMod.After(lastMod) {
		t.Fatalf("mtime not advanced: %v -> %v", lastMod, newMod)
	}
	if got := decide(t, taker, "new.example"); got != acl.Allow {
		t.Fatalf("new.example after reload: got %v, want Allow", got)
	}
	if got := decide(t, taker, "old.example"); got != acl.Deny {
		t.Fatalf("old.example after reload: got %v, want Deny", got)
	}
	reloaded(t, hook)
}

func TestReloadFailureKeepsPreviousRules(t *testing.T) {
	path := filepath.Join(t.TempDir(), "network.yaml")
	writeFile(t, path, networkAllowing("old.example"))
	conf, taker, files, file, hook := testSetup(t, path)

	rewrite(t, files, file, conf.Log, "version: v9\n")
	failedMod := file.lastMod
	if got := decide(t, taker, "old.example"); got != acl.Allow {
		t.Fatalf("old.example after failed reload: got %v, want Allow (previous rules kept)", got)
	}
	reloadFailure(t, hook)

	// The failed mtime is recorded: the broken file is not re-tried (and re-logged)
	// every tick, only when it changes again.
	hook.Reset()
	files.applyIfChanged(conf.Log, file)
	if !file.lastMod.Equal(failedMod) {
		t.Fatalf("mtime moved without a file change: %v -> %v", failedMod, file.lastMod)
	}
	if len(hook.Entries) != 0 {
		t.Fatalf("unexpected log entries on an unchanged broken file: %+v", hook.Entries)
	}

	// Fixing the file recovers.
	rewrite(t, files, file, conf.Log, networkAllowing("fixed.example"))
	if got := decide(t, taker, "fixed.example"); got != acl.Allow {
		t.Fatalf("fixed.example after recovery: got %v, want Allow", got)
	}
}

// unreadableEdit makes the network config file unreadable, and checks that the poll that sees it
// logs a reload failure.
func unreadableEdit(t *testing.T, log *logrus.Logger, files *configFiles, file *configFile,
	hook *logrustest.Hook) {
	t.Helper()
	chmod(t, file.path, 0)
	files.applyIfChanged(log, file)
	reloadFailure(t, hook)
}

// An edit the proxy can't read, for the file's mode, is taken up once the mode is fixed, though a
// chmod changes no modification time.
func TestAnEditMadeReadableIsTakenUp(t *testing.T) {
	skipIfRoot(t)
	path := filepath.Join(t.TempDir(), "network.yaml")
	writeFile(t, path, networkAllowing("old.example"))
	conf, taker, files, file, hook := testSetup(t, path)

	writeFile(t, path, networkAllowing("new.example"))
	unreadableEdit(t, conf.Log, files, file, hook)
	// Tried again on the next poll, its being unreadable isn't logged again.
	hook.Reset()
	files.applyIfChanged(conf.Log, file)
	if len(hook.Entries) != 0 {
		t.Fatalf("unexpected log entries on a file still unreadable: %+v", hook.Entries)
	}

	chmod(t, path, 0o644)
	files.applyIfChanged(conf.Log, file)
	reloaded(t, hook)
	if got := decide(t, taker, "new.example"); got != acl.Allow {
		t.Fatalf("new.example once the file is readable: got %v, want Allow", got)
	}
}

func TestRestoringAccessToUnchangedRulesClearsWarning(t *testing.T) {
	skipIfRoot(t)
	dir := t.TempDir()
	path := filepath.Join(dir, "network.yaml")
	writeFile(t, path, networkAllowing("base.example"))
	conf, taker, files, file, hook := testSetup(t, path)
	t.Cleanup(func() { chmod(t, dir, 0o700) })

	chmod(t, dir, 0)
	files.applyIfChanged(conf.Log, file)
	if err := reloadFailure(t, hook); !errors.Is(err, os.ErrPermission) {
		t.Fatalf("expected a permission error, got %v", err)
	}

	hook.Reset()
	chmod(t, dir, 0o700)
	files.applyIfChanged(conf.Log, file)
	reloaded(t, hook)
	if got := decide(t, taker, "base.example"); got != acl.Allow {
		t.Fatalf("base.example after restoring access: got %v, want Allow", got)
	}

	hook.Reset()
	files.applyIfChanged(conf.Log, file)
	if len(hook.Entries) != 0 {
		t.Fatalf("unexpected log entries after recovery: %+v", hook.Entries)
	}
}

// What a refusal puts back is the config in effect, though the file changed as apply read it.
func TestARefusalPutsBackTheConfigInEffect(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "network.yaml")
	writeFile(t, path, networkAllowing("old.example"))
	conf, taker, files, file, _ := testSetup(t, path)

	writeFile(t, path, networkAllowing("a.example"))
	take := files.take
	files.take = func(files []configContent, resave bool, warn func(error), done func(error)) error {
		writeFile(t, path, networkAllowing("b.example"))
		return take(files, resave, warn, done)
	}
	files.applyIfChanged(conf.Log, file)
	files.take = take
	if got := decide(t, taker, "a.example"); got != acl.Allow {
		t.Fatalf("a.example, as the watcher read it: got %v, want Allow", got)
	}

	writeThroughOtherLink(t, path, filepath.Join(dir, "other-link.yaml"), networkAllowing("c.example"))
	files.applyIfChanged(conf.Log, file)
	if got := readFile(t, path); got != networkAllowing("a.example") {
		t.Fatalf("the put-back file should allow a.example, the config in effect, got:\n%s", got)
	}
}

// Each edit that can't be read is logged, though the previous one couldn't be read either: the user
// is told the new one wasn't taken up.
func TestASecondUnreadableEditIsLogged(t *testing.T) {
	skipIfRoot(t)
	path := filepath.Join(t.TempDir(), "network.yaml")
	writeFile(t, path, networkAllowing("old.example"))
	conf, _, files, file, hook := testSetup(t, path)

	unreadableEdit(t, conf.Log, files, file, hook)

	// Edited again, with no poll seeing it readable in between.
	chmod(t, path, 0o644)
	writeFile(t, path, networkAllowing("new.example"))
	hook.Reset()
	unreadableEdit(t, conf.Log, files, file, hook)
}

// An edit that can't be read after a refused one is logged, though the refused change couldn't be
// put back.
func TestUnreadableAfterARefusalIsLogged(t *testing.T) {
	skipIfRoot(t)
	dir := t.TempDir()
	path := filepath.Join(dir, "network.yaml")
	writeFile(t, path, networkAllowing("old.example"))
	conf, _, files, file, hook := testSetup(t, path)

	unreadableEdit(t, conf.Log, files, file, hook)

	// Refused, and not put back: its directory can't take the move aside.
	chmod(t, path, 0o644)
	other := filepath.Join(dir, "other-link.yaml")
	writeThroughOtherLink(t, path, other, networkAllowing("new.example"))
	chmod(t, dir, 0o555)
	t.Cleanup(func() { chmod(t, dir, 0o755) })
	hook.Reset()
	files.applyIfChanged(conf.Log, file)
	if err := reloadFailure(t, hook); !strings.Contains(err.Error(), "could not move it aside") {
		t.Fatalf("expected the refused file not to be moved aside, got %v", err)
	}

	chmod(t, dir, 0o755)
	if err := os.Remove(other); err != nil {
		t.Fatal(err)
	}
	hook.Reset()
	unreadableEdit(t, conf.Log, files, file, hook)
}

// A config file with another hard link, which the sandbox profile can't see by its path, may have
// been written through it by a sandboxed command: its change is refused, the previous rules kept, and
// it is moved aside for review, what was last taken up put back in its place with no other
// links. So what was written through the other link is taken up neither once that link is gone,
// nor on a restart.
func TestReloadRefusesAFileWithOtherLinks(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "network.yaml")
	writeFile(t, path, networkAllowing("old.example"))
	conf, taker, files, file, hook := testSetup(t, path)

	other := filepath.Join(dir, "other-link.yaml")
	writeThroughOtherLink(t, path, other, networkAllowing("new.example"))
	files.applyIfChanged(conf.Log, file)
	refusedMod := file.lastMod
	if got := decide(t, taker, "new.example"); got != acl.Deny {
		t.Fatalf("new.example after a change through another link: got %v, want Deny", got)
	}
	if got := decide(t, taker, "old.example"); got != acl.Allow {
		t.Fatalf("old.example after a refused reload: got %v, want Allow (previous rules kept)", got)
	}
	err := reloadFailure(t, hook)
	if !strings.Contains(err.Error(), "2 hard links") {
		t.Fatalf("the error should name the hard links, got %v", err)
	}

	// Put back, with no other links, and moved aside, named in the error.
	if got := readFile(t, path); got != networkAllowing("old.example") {
		t.Fatalf("the network config file should hold the config last taken up, got:\n%s", got)
	}
	if st, err := os.Stat(path); err != nil || singleLink(path, st) != nil {
		t.Fatalf("the put-back network config file should have no other links: %v", err)
	}
	asides, _ := filepath.Glob(path + ".refused-*")
	if len(asides) != 1 {
		t.Fatalf("expected the refused file moved aside, beside it, got %v", asides)
	}
	if got := readFile(t, asides[0]); got != networkAllowing("new.example") {
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
	files.applyIfChanged(conf.Log, file)
	if !file.lastMod.Equal(refusedMod) {
		t.Fatalf("mtime moved without a file change: %v -> %v", refusedMod, file.lastMod)
	}
	if len(hook.Entries) != 0 {
		t.Fatalf("the put-back file should not be taken up again, got %+v", hook.Entries)
	}
	rewrite(t, files, file, conf.Log, networkAllowing("fixed.example"))
	if got := decide(t, taker, "fixed.example"); got != acl.Allow {
		t.Fatalf("fixed.example after a change with no other links: got %v, want Allow", got)
	}
	// A later refusal puts back what was taken up last, not what the proxy started with.
	writeThroughOtherLink(t, path, other, networkAllowing("new.example"))
	files.applyIfChanged(conf.Log, file)
	if got := readFile(t, path); got != networkAllowing("fixed.example") {
		t.Fatalf("the network config file should hold the config last taken up, got:\n%s", got)
	}
}

// writeThroughOtherLink links other to path and writes content through other.
func writeThroughOtherLink(t *testing.T, path, other, content string) {
	t.Helper()
	if err := os.Link(path, other); err != nil {
		t.Fatal(err)
	}
	writeFile(t, other, content)
}

// As the proxy starts, a hard-linked config file is refused, whichever it is, as is a missing base
// one; an added one may be missing.
func TestStartRefusesAFileWithOtherLinks(t *testing.T) {
	dir := realTempDir(t)
	network := filepath.Join(dir, "network.yaml")
	writeFile(t, network, networkAllowing("old.example"))
	for _, added := range []bool{false, true} {
		if _, err := newConfigFile(network, added); err != nil {
			t.Fatalf("a config file with no other links (added: %t): got %v, want no error", added, err)
		}
	}
	missing := filepath.Join(dir, "missing")
	if _, err := newConfigFile(missing, true); err != nil {
		t.Fatalf("a missing added config file: got %v, want no error", err)
	}
	if _, err := newConfigFile(missing, false); err == nil {
		t.Fatal("a missing base config file: got no error")
	}
	if err := os.Link(network, filepath.Join(dir, "other-link")); err != nil {
		t.Fatal(err)
	}
	for _, added := range []bool{false, true} {
		_, err := newConfigFile(network, added)
		if err == nil || !strings.Contains(err.Error(), network) || !strings.Contains(err.Error(), "2 hard links") {
			t.Fatalf("a hard-linked config file (added: %t): got %v, want an error naming it and its hard links", added, err)
		}
	}
}

// As the proxy starts, a config file it can't read, missing or for its mode, is refused, the error
// naming it: one taken up as empty would start a session on a config other than the user's, and,
// should the file be fixed by a chmod, which changes no modification time, on it for good.
func TestStartRefusesAFileItCantRead(t *testing.T) {
	skipIfRoot(t)
	dir := t.TempDir()
	unreadable := filepath.Join(dir, "network.yaml")
	writeFile(t, unreadable, "github_allowlist: [owner/repo]\n")
	chmod(t, unreadable, 0)
	for _, path := range []string{unreadable, filepath.Join(dir, "missing")} {
		if _, err := newConfigFile(path, false); err == nil || !strings.Contains(err.Error(), path) {
			t.Fatalf("%s: got %v, want an error naming it", path, err)
		}
	}
}

func TestConfigFIFOIsRefusedAndReloadRecovers(t *testing.T) {
	path := filepath.Join(realTempDir(t), "network.yaml")
	writeFile(t, path, networkAllowing("old.example"))
	conf, taker, files, file, hook := testSetup(t, path)
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := syscall.Mkfifo(path, 0o600); err != nil {
		t.Fatal(err)
	}

	for _, added := range []bool{false, true} {
		if _, err := newConfigFile(path, added); err == nil || !strings.Contains(err.Error(), "not a regular file") {
			t.Fatalf("starting with a FIFO (added: %t): got %v, want a non-regular file error", added, err)
		}
	}
	files.applyIfChanged(conf.Log, file)
	reloadFailure(t, hook)
	if got := decide(t, taker, "old.example"); got != acl.Allow {
		t.Fatalf("old.example after FIFO refusal: got %v, want Allow", got)
	}

	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	writeFile(t, path, networkAllowing("new.example"))
	hook.Reset()
	files.applyIfChanged(conf.Log, file)
	reloaded(t, hook)
	if got := decide(t, taker, "new.example"); got != acl.Allow {
		t.Fatalf("new.example after replacing the FIFO: got %v, want Allow", got)
	}
}

func TestMissingFileKeepsPreviousRules(t *testing.T) {
	path := filepath.Join(t.TempDir(), "network.yaml")
	writeFile(t, path, networkAllowing("old.example"))
	conf, taker, files, file, hook := testSetup(t, path)
	lastMod := file.lastMod

	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	files.applyIfChanged(conf.Log, file)
	if !file.lastMod.Equal(lastMod) {
		t.Fatalf("mtime moved on a missing file: %v -> %v", lastMod, file.lastMod)
	}
	if len(hook.Entries) != 0 {
		t.Fatalf("unexpected log entries for a missing file: %+v", hook.Entries)
	}
	if got := decide(t, taker, "old.example"); got != acl.Allow {
		t.Fatalf("rules dropped on a missing file: got %v, want Allow", got)
	}

	// A recreated file reloads as usual.
	rewrite(t, files, file, conf.Log, networkAllowing("new.example"))
	if got := decide(t, taker, "new.example"); got != acl.Allow {
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
	path := filepath.Join(notDir, "network.yaml")

	conf := smokescreen.NewConfig()
	logger, hook := logrustest.NewNullLogger()
	conf.Log = logger
	taker := newNetworkTaker(conf, false) // untouched: a stat error returns before any load or swap
	file := &configFile{path: path}
	added := &configFile{path: missingAdded(t), added: true}
	files := &configFiles{base: file, added: added, take: taker.take}

	// First failing tick surfaces the error and sets unreadable; the mtime does not move.
	files.applyIfChanged(conf.Log, file)
	if file.unreadable == nil {
		t.Fatal("a non-ENOENT stat error should set unreadable")
	}
	if !file.lastMod.IsZero() {
		t.Fatalf("mtime should not advance on a stat error, got %v", file.lastMod)
	}
	reloadFailure(t, hook) // the stat error attached, so the rendered line can name it

	// A persistent error does not re-log while unreadable stays set.
	hook.Reset()
	files.applyIfChanged(conf.Log, file)
	if file.unreadable == nil {
		t.Fatal("unreadable should stay set while the stat keeps failing")
	}
	if len(hook.Entries) != 0 {
		t.Fatalf("a persistent stat error should not re-log every tick, got %+v", hook.Entries)
	}

	// Repairing the path reloads and clears unreadable.
	if err := os.Remove(notDir); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(notDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeFile(t, path, networkAllowing("ok.example"))
	files.applyIfChanged(conf.Log, file)
	if file.unreadable != nil {
		t.Fatal("a healthy stat should clear unreadable")
	}
	if got := decide(t, taker, "ok.example"); got != acl.Allow {
		t.Fatalf("rules should reload after the path is repaired: got %v, want Allow", got)
	}
}

// reloadTo sets up rules allowing old.example, then reloads them as to, allowing
// GitHub's domains if allowGitHub.
func reloadTo(t *testing.T, to string, allowGitHub bool) (*networkTaker, *logrustest.Hook) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "network.yaml")
	writeFile(t, path, networkAllowing("old.example"))
	conf, taker, files, hook := setupWith(t, path, missingAdded(t))
	taker.allowGitHub = allowGitHub
	rewrite(t, files, files.base, conf.Log, to)
	return taker, hook
}

// Rules allowing github.com or api.github.com let a sandboxed command reach GitHub directly,
// bypassing the relays and the repos allowlist they enforce: an edit that allows them is refused
// like a broken one, the previous rules kept -- whatever form the allowing takes.
func TestReloadRefusesRulesAllowingGitHub(t *testing.T) {
	for _, allowing := range []string{"github.com", "api.github.com", `"*.github.com"`} {
		t.Run(allowing, func(t *testing.T) {
			taker, hook := reloadTo(t, networkAllowing(allowing), false)
			if got := decide(t, taker, "old.example"); got != acl.Allow {
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
	taker, hook := reloadTo(t, networkAllowing("github.com"), true)
	if got := decide(t, taker, "github.com"); got != acl.Allow {
		t.Fatalf("github.com after a reload with the override: got %v, want Allow", got)
	}
	reloaded(t, hook)
	if !slices.ContainsFunc(hook.Entries, func(e logrus.Entry) bool {
		return e.Level == logrus.WarnLevel && strings.Contains(e.Message, "allows github.com") &&
			strings.Contains(e.Message, gitHubExfiltrationOverride+" is set")
	}) {
		t.Fatalf("expected a warning that the rules allow github.com, naming the override, got %+v", hook.Entries)
	}
}

func TestGitHubExfiltration(t *testing.T) {
	template := readFile(t, networkTemplatePath)
	for _, tc := range []struct{ name, rules, want string }{
		{"a pre-relay config names both domains", networkAllowing("api.anthropic.com") +
			"  - github.com\n  - api.github.com\n  - raw.githubusercontent.com\n", "github.com, api.github.com"},
		{"the shipped template is clean", template, ""},
		{"the upload host counts", networkAllowing(`uploads.github.com`), "uploads.github.com"},
		{"the gist host counts", networkAllowing(`gist.github.com`), "gist.github.com"},
		{"a subdomain glob counts, as one", networkAllowing(`"*.github.com"`), "network.yaml allows *.github.com:"},
		{"a read-only subdomain named alone doesn't", networkAllowing("codeload.github.com"), ""},
		{"the deny list wins over the allowed domains", networkAllowing("github.com") +
			"global_deny_list:\n  - github.com\n", ""},
		{"lookalike domains don't match", networkAllowing("raw.githubusercontent.com") +
			"  - mygithub.com\n  - github.com.evil.example\n", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			n, err := loadNetwork(smokescreen.NewConfig(), []configContent{newConfigContent("network.yaml", []byte(tc.rules))})
			if err != nil {
				t.Fatalf("load: %v", err)
			}
			switch {
			case tc.want == "" && len(n.exfiltration) != 0:
				t.Fatalf("want no refusal, got %v", n.exfiltration)
			case tc.want != "" && (len(n.exfiltration) != 1 || !strings.Contains(n.exfiltration[0].Error(), tc.want)):
				t.Fatalf("want a refusal naming %q, got %v", tc.want, n.exfiltration)
			}
		})
	}
}

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

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

// testSetup returns a config whose log entries are captured by the returned hook, and
// a holder loaded from the given rules file.
func testSetup(t *testing.T, path string) (*smokescreen.Config, *swappableACL, *configFile, *logrustest.Hook) {
	t.Helper()
	conf := smokescreen.NewConfig()
	logger, hook := logrustest.NewNullLogger()
	conf.Log = logger
	rules, err := loadRules(conf, path)
	if err != nil {
		t.Fatalf("initial load: %v", err)
	}
	holder := &swappableACL{}
	holder.current.Store(rules)
	file, err := newConfigFile(path)
	if err != nil {
		t.Fatalf("initial check: %v", err)
	}
	return conf, holder, file, hook
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
	lastMod := mtimeOf(t, path)

	if got := decide(t, holder, "old.example"); got != acl.Allow {
		t.Fatalf("old.example before reload: got %v, want Allow", got)
	}
	if got := decide(t, holder, "new.example"); got != acl.Deny {
		t.Fatalf("new.example before reload: got %v, want Deny", got)
	}

	writeFile(t, path, rulesAllowing("new.example"))
	setMtime(t, path, lastMod.Add(time.Second))
	newMod, _ := reloadIfChanged(conf, holder, file, lastMod, false)
	if !newMod.After(lastMod) {
		t.Fatalf("mtime not advanced: %v -> %v", lastMod, newMod)
	}
	if got := decide(t, holder, "new.example"); got != acl.Allow {
		t.Fatalf("new.example after reload: got %v, want Allow", got)
	}
	if got := decide(t, holder, "old.example"); got != acl.Deny {
		t.Fatalf("old.example after reload: got %v, want Deny", got)
	}
	if last := hook.LastEntry(); last == nil || last.Message != "egress ACL reloaded" {
		t.Fatalf("expected an 'egress ACL reloaded' log entry, got %+v", last)
	}
}

func TestReloadFailureKeepsPreviousRules(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rules.yaml")
	writeFile(t, path, rulesAllowing("old.example"))
	conf, holder, file, hook := testSetup(t, path)
	lastMod := mtimeOf(t, path)

	writeFile(t, path, "version: v9\n")
	setMtime(t, path, lastMod.Add(time.Second))
	failedMod, _ := reloadIfChanged(conf, holder, file, lastMod, false)
	if got := decide(t, holder, "old.example"); got != acl.Allow {
		t.Fatalf("old.example after failed reload: got %v, want Allow (previous rules kept)", got)
	}
	if last := hook.LastEntry(); last == nil || last.Message != "egress ACL reload failed; keeping the previous rules" {
		t.Fatalf("expected a reload-failed log entry, got %+v", last)
	}

	// The failed mtime is recorded: the broken file is not re-tried (and re-logged)
	// every tick, only when it changes again.
	hook.Reset()
	if again, _ := reloadIfChanged(conf, holder, file, failedMod, false); !again.Equal(failedMod) {
		t.Fatalf("mtime moved without a file change: %v -> %v", failedMod, again)
	}
	if len(hook.Entries) != 0 {
		t.Fatalf("unexpected log entries on an unchanged broken file: %+v", hook.Entries)
	}

	// Fixing the file recovers.
	writeFile(t, path, rulesAllowing("fixed.example"))
	setMtime(t, path, failedMod.Add(time.Second))
	reloadIfChanged(conf, holder, file, failedMod, false)
	if got := decide(t, holder, "fixed.example"); got != acl.Allow {
		t.Fatalf("fixed.example after recovery: got %v, want Allow", got)
	}
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
	lastMod := mtimeOf(t, path)

	other := filepath.Join(dir, "other-link.yaml")
	writeThroughOtherLink(t, path, other, rulesAllowing("new.example"), lastMod.Add(time.Second))
	refusedMod, _ := reloadIfChanged(conf, holder, file, lastMod, false)
	if got := decide(t, holder, "new.example"); got != acl.Deny {
		t.Fatalf("new.example after a change through another link: got %v, want Deny", got)
	}
	if got := decide(t, holder, "old.example"); got != acl.Allow {
		t.Fatalf("old.example after a refused reload: got %v, want Allow (previous rules kept)", got)
	}
	last := hook.LastEntry()
	if last == nil || last.Message != rulesReloadFailed {
		t.Fatalf("expected a reload-failed log entry, got %+v", last)
	}
	err, _ := last.Data["error"].(error)
	if err == nil || !strings.Contains(err.Error(), "2 hard links") {
		t.Fatalf("the error should name the hard links, got %+v", last.Data["error"])
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
	if again, _ := reloadIfChanged(conf, holder, file, refusedMod, false); !again.Equal(refusedMod) {
		t.Fatalf("mtime moved without a file change: %v -> %v", refusedMod, again)
	}
	if len(hook.Entries) != 0 {
		t.Fatalf("the put-back file should not be taken up again, got %+v", hook.Entries)
	}
	writeFile(t, path, rulesAllowing("fixed.example"))
	setMtime(t, path, refusedMod.Add(time.Second))
	reloadIfChanged(conf, holder, file, refusedMod, false)
	if got := decide(t, holder, "fixed.example"); got != acl.Allow {
		t.Fatalf("fixed.example after a change with no other links: got %v, want Allow", got)
	}
	// A later refusal puts back what was taken up last, not what the proxy started with.
	fixedMod := mtimeOf(t, path)
	writeThroughOtherLink(t, path, other, rulesAllowing("new.example"), fixedMod.Add(time.Second))
	reloadIfChanged(conf, holder, file, fixedMod, false)
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

// As the proxy starts, a hard-linked config file is refused, whichever it is; a missing one is
// left for its loading to report.
func TestStartRefusesAFileWithOtherLinks(t *testing.T) {
	dir := t.TempDir()
	rules := filepath.Join(dir, "rules.yaml")
	allowlist := filepath.Join(dir, "allowlist")
	writeFile(t, rules, rulesAllowing("old.example"))
	writeFile(t, allowlist, "")
	for _, path := range []string{rules, allowlist, filepath.Join(dir, "missing")} {
		if _, err := newConfigFile(path); err != nil {
			t.Fatalf("a config file with no other links: got %v, want no error", err)
		}
	}
	if err := os.Link(allowlist, filepath.Join(dir, "other-link")); err != nil {
		t.Fatal(err)
	}
	_, err := newConfigFile(allowlist)
	if err == nil || !strings.Contains(err.Error(), allowlist) || !strings.Contains(err.Error(), "2 hard links") {
		t.Fatalf("a hard-linked allowlist: got %v, want an error naming it and its hard links", err)
	}
}

func TestMissingFileKeepsPreviousRules(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rules.yaml")
	writeFile(t, path, rulesAllowing("old.example"))
	conf, holder, file, hook := testSetup(t, path)
	lastMod := mtimeOf(t, path)

	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if got, _ := reloadIfChanged(conf, holder, file, lastMod, false); !got.Equal(lastMod) {
		t.Fatalf("mtime moved on a missing file: %v -> %v", lastMod, got)
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
	reloadIfChanged(conf, holder, file, lastMod, false)
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
	file := &configFile{path: path}

	// First failing tick surfaces the error and reports warned; the mtime does not move.
	mod, warned := reloadIfChanged(conf, holder, file, time.Time{}, false)
	if !warned {
		t.Fatal("a non-ENOENT stat error should report warned = true")
	}
	if !mod.Equal(time.Time{}) {
		t.Fatalf("mtime should not advance on a stat error, got %v", mod)
	}
	last := hook.LastEntry()
	if last == nil || last.Message != "egress ACL reload failed; keeping the previous rules" {
		t.Fatalf("expected the reload-failed log entry, got %+v", last)
	}
	if last.Data["error"] == nil {
		t.Fatal("the stat error should be attached so the rendered line can name it")
	}

	// A persistent error does not re-log while warned stays set.
	hook.Reset()
	if _, warned = reloadIfChanged(conf, holder, file, time.Time{}, warned); !warned {
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
	if _, warned = reloadIfChanged(conf, holder, file, time.Time{}, warned); warned {
		t.Fatal("a healthy stat should clear warned")
	}
	if got := decide(t, holder, "ok.example"); got != acl.Allow {
		t.Fatalf("rules should reload after the path is repaired: got %v, want Allow", got)
	}
}

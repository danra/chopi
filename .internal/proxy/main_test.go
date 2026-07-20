package main

import (
	"fmt"
	"os"
	"path/filepath"
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
func testSetup(t *testing.T, path string) (*smokescreen.Config, *swappableACL, *logrustest.Hook) {
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
	return conf, holder, hook
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
	conf, holder, hook := testSetup(t, path)
	lastMod := mtimeOf(t, path)

	if got := decide(t, holder, "old.example"); got != acl.Allow {
		t.Fatalf("old.example before reload: got %v, want Allow", got)
	}
	if got := decide(t, holder, "new.example"); got != acl.Deny {
		t.Fatalf("new.example before reload: got %v, want Deny", got)
	}

	writeFile(t, path, rulesAllowing("new.example"))
	setMtime(t, path, lastMod.Add(time.Second))
	newMod, _ := reloadIfChanged(conf, holder, path, lastMod, false)
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
	conf, holder, hook := testSetup(t, path)
	lastMod := mtimeOf(t, path)

	writeFile(t, path, "version: v9\n")
	setMtime(t, path, lastMod.Add(time.Second))
	failedMod, _ := reloadIfChanged(conf, holder, path, lastMod, false)
	if got := decide(t, holder, "old.example"); got != acl.Allow {
		t.Fatalf("old.example after failed reload: got %v, want Allow (previous rules kept)", got)
	}
	if last := hook.LastEntry(); last == nil || last.Message != "egress ACL reload failed; keeping the previous rules" {
		t.Fatalf("expected a reload-failed log entry, got %+v", last)
	}

	// The failed mtime is recorded: the broken file is not re-tried (and re-logged)
	// every tick, only when it changes again.
	hook.Reset()
	if again, _ := reloadIfChanged(conf, holder, path, failedMod, false); !again.Equal(failedMod) {
		t.Fatalf("mtime moved without a file change: %v -> %v", failedMod, again)
	}
	if len(hook.Entries) != 0 {
		t.Fatalf("unexpected log entries on an unchanged broken file: %+v", hook.Entries)
	}

	// Fixing the file recovers.
	writeFile(t, path, rulesAllowing("fixed.example"))
	setMtime(t, path, failedMod.Add(time.Second))
	reloadIfChanged(conf, holder, path, failedMod, false)
	if got := decide(t, holder, "fixed.example"); got != acl.Allow {
		t.Fatalf("fixed.example after recovery: got %v, want Allow", got)
	}
}

func TestMissingFileKeepsPreviousRules(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rules.yaml")
	writeFile(t, path, rulesAllowing("old.example"))
	conf, holder, hook := testSetup(t, path)
	lastMod := mtimeOf(t, path)

	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if got, _ := reloadIfChanged(conf, holder, path, lastMod, false); !got.Equal(lastMod) {
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
	reloadIfChanged(conf, holder, path, lastMod, false)
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

	// First failing tick surfaces the error and reports warned; the mtime does not move.
	mod, warned := reloadIfChanged(conf, holder, path, time.Time{}, false)
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
	if _, warned = reloadIfChanged(conf, holder, path, time.Time{}, warned); !warned {
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
	if _, warned = reloadIfChanged(conf, holder, path, time.Time{}, warned); warned {
		t.Fatal("a healthy stat should clear warned")
	}
	if got := decide(t, holder, "ok.example"); got != acl.Allow {
		t.Fatalf("rules should reload after the path is repaired: got %v, want Allow", got)
	}
}

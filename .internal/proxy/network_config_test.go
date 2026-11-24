package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/sirupsen/logrus"
	logrustest "github.com/sirupsen/logrus/hooks/test"
	"github.com/stripe/smokescreen/pkg/smokescreen"
	acl "github.com/stripe/smokescreen/pkg/smokescreen/acl/v1"
)

// addedSetup is testSetup for base rules allowing base.example, with rules added at a path in the
// same dir, ws, written with content unless it is "" (left missing).
func addedSetup(t *testing.T, content string) (conf *smokescreen.Config, taker *networkTaker, files *configFiles, ws *configFile, hook *logrustest.Hook) {
	t.Helper()
	basePath, addedPath := addedFiles(t, networkAllowing("base.example"), content)
	conf, taker, files, hook = setupWith(t, basePath, addedPath)
	return conf, taker, files, files.added, hook
}

// addedFiles are the paths of the base rules, written with base, and of rules added in the same
// dir, written with content unless it is "" (left missing).
func addedFiles(t *testing.T, base, content string) (basePath, addedPath string) {
	t.Helper()
	dir := realTempDir(t)
	basePath, addedPath = filepath.Join(dir, "network.yaml"), filepath.Join(dir, "ws.yaml")
	writeFile(t, basePath, base)
	if content != "" {
		writeFile(t, addedPath, content)
	}
	return basePath, addedPath
}

// wantNoReload checks polling f the given number of times logs nothing, failing with why.
func wantNoReload(t *testing.T, files *configFiles, f *configFile, log *logrus.Logger, hook *logrustest.Hook, polls int, why string) {
	t.Helper()
	hook.Reset()
	for range polls {
		files.applyIfChanged(log, f)
	}
	if len(hook.Entries) != 0 {
		t.Fatalf("%s: %+v", why, hook.Entries)
	}
}

// mustRemove removes path.
func mustRemove(t *testing.T, path string) {
	t.Helper()
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
}

// mustSymlink makes link a symlink to target.
func mustSymlink(t *testing.T, target, link string) {
	t.Helper()
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
}

// wantReloadFailure checks the last log entry is a refused reload's, its error containing substr,
// as want describes.
func wantReloadFailure(t *testing.T, hook *logrustest.Hook, substr, want string) {
	t.Helper()
	if err := reloadFailure(t, hook); !strings.Contains(err.Error(), substr) {
		t.Fatalf("got %v, want %s", err, want)
	}
}

// wantGlobalDenied checks the taker denies host for the global deny list, as a known denial.
func wantGlobalDenied(t *testing.T, taker *networkTaker, host string) {
	t.Helper()
	if d, _ := taker.Decide(acl.DecideArgs{Host: host}); d.Result != acl.Deny || d.Reason != "host matched rule in global deny list" {
		t.Errorf("%s: got %v (%q), want denied for the global deny list", host, d.Result, d.Reason)
	}
}

func TestAddedNetworkAddsToTheBase(t *testing.T) {
	_, taker, _, _, _ := addedSetup(t, "allowed_domains:\n  - ws.example\nglobal_deny_list:\n  - quiet.example\n")
	wantDecisions(t, taker, "", map[string]acl.DecisionResult{
		"base.example":  acl.Allow,
		"ws.example":    acl.Allow,
		"other.example": acl.Deny,
	})
	wantGlobalDenied(t, taker, "quiet.example")
}

func TestMissingAddedNetworkAddsNothingUntilMade(t *testing.T) {
	conf, taker, files, ws, _ := addedSetup(t, "")
	wantDecisions(t, taker, "with no added rules", map[string]acl.DecisionResult{"base.example": acl.Allow})

	// Made mid-session, it is taken up: a missing file's modification time is zero.
	rewrite(t, files, ws, conf.Log, "allowed_domains: [ws.example]\n")
	wantDecisions(t, taker, "once the added rules are made", map[string]acl.DecisionResult{
		"ws.example":   acl.Allow,
		"base.example": acl.Allow,
	})
}

// An added file's reload is logged as the workspace's own, named with its dir; a base file's, as
// the user knows it, by its name alone.
func TestAddedNetworkReloadIsLoggedAsTheWorkspaces(t *testing.T) {
	conf, taker, files, ws, hook := addedSetup(t, "allowed_domains: [old.example]\n")
	rewrite(t, files, ws, conf.Log, "allowed_domains: [new.example]\n")
	reloaded(t, hook)
	wantName := filepath.Join(filepath.Base(filepath.Dir(ws.path)), "ws.yaml")
	if data := hook.LastEntry().Data; data["what"] != "workspace network config" || data["name"] != wantName {
		t.Errorf("logged as %v, named %v: want the workspace network config, named %s", data["what"], data["name"], wantName)
	}
	rewrite(t, files, files.base, conf.Log, networkAllowing("base.example"))
	reloaded(t, hook)
	if data := hook.LastEntry().Data; data["what"] != "network config" || data["name"] != "network.yaml" {
		t.Errorf("the base logged as %v, named %v: want the network config, named network.yaml", data["what"], data["name"])
	}
	wantDecisions(t, taker, "after the reload", map[string]acl.DecisionResult{
		"new.example": acl.Allow,
		"old.example": acl.Deny,
	})
}

func TestAddedNetworkRefusesWhatCouldLoosenTheBase(t *testing.T) {
	for name, content := range map[string]string{
		"a default rule":  "default:\n  name: default\n  action: open\n",
		"services":        "services: []\n",
		"a global allow":  "global_allow_list: [any.example]\n",
		"an unknown key":  "allowed_domain: [typo.example]\n",
		"github.com":      "allowed_domains: [github.com]\n",
		"a *.github.com":  "allowed_domains: ['*.github.com']\n",
		"not a host list": "allowed_domains: ws.example\n",
		"a bad repo":      "github_allowlist: [owner]\n",
	} {
		t.Run(name, func(t *testing.T) {
			conf, taker, files, ws, hook := addedSetup(t, "allowed_domains: [old.example]\n")
			rewrite(t, files, ws, conf.Log, content)
			reloadFailure(t, hook)
			wantDecisions(t, taker, "after a refused reload", map[string]acl.DecisionResult{"old.example": acl.Allow})
		})
	}
}

// An added file may have no symlink on its way, the file's or a dir's, even one leading nowhere. As
// the proxy starts, the refusal names the file, for the user to know whose to fix.
func TestAddedFilesMayNotBeSymlinks(t *testing.T) {
	dir := realTempDir(t)
	target := filepath.Join(dir, "elsewhere")
	if err := os.Mkdir(target, 0o755); err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(target, "ws"), "")
	for _, c := range []struct{ name, path, link, to string }{
		{"the file", filepath.Join(dir, "ws"), filepath.Join(dir, "ws"), filepath.Join(target, "ws")},
		{"its dir", filepath.Join(dir, "dir", "ws"), filepath.Join(dir, "dir"), target},
		{"a link leading nowhere", filepath.Join(dir, "nowhere", "ws"), filepath.Join(dir, "nowhere"), filepath.Join(dir, "missing")},
	} {
		mustSymlink(t, c.to, c.link)
		if _, err := newConfigFile(c.path, true); err == nil || !strings.Contains(err.Error(), "symlink") {
			t.Errorf("%s: got %v, want an added file with a symlink on its way refused", c.name, err)
		}
	}
	base := filepath.Join(dir, "network.yaml")
	writeFile(t, base, networkAllowing("base.example"))
	if _, err := newConfigFiles(base, filepath.Join(dir, "ws"), nil); err == nil || !strings.Contains(err.Error(), filepath.Join(dir, "ws")) {
		t.Errorf("as the proxy starts: got %v, want the added file's refusal, naming it", err)
	}
}

// An added file's dir made mid-session as a symlink, which could lead out of the dir chopi keeps
// sandboxed commands from changing, is refused.
func TestAddedNetworkThroughADirLinkedSinceIsRefused(t *testing.T) {
	conf, taker, files, ws, hook := addedSetup(t, "")
	dir := filepath.Join(filepath.Dir(ws.path), "ws")
	ws.path = filepath.Join(dir, "network.yaml") // in a dir that was missing when the proxy started
	elsewhere := realTempDir(t)
	writeFile(t, filepath.Join(elsewhere, "network.yaml"), "allowed_domains: [evil.example]\n")
	mustSymlink(t, elsewhere, dir)
	files.applyIfChanged(conf.Log, ws)
	wantReloadFailure(t, hook, "symlink", "the linked dir refused")
	wantDecisions(t, taker, "", map[string]acl.DecisionResult{"evil.example": acl.Deny})
}

// A link leading nowhere put in place of an added file is refused, keeping what the file added,
// rather than taken for the file missing, taking it away.
func TestAddedNetworkReplacedByADanglingLinkIsKept(t *testing.T) {
	conf, taker, files, ws, hook := addedSetup(t, "global_deny_list: [quiet.example]\n")
	mustRemove(t, ws.path)
	mustSymlink(t, ws.path+".missing", ws.path)
	hook.Reset()
	files.applyIfChanged(conf.Log, ws)
	files.applyIfChanged(conf.Log, ws)
	wantReloadFailure(t, hook, "symlink", "the link leading nowhere refused")
	wantGlobalDenied(t, taker, "quiet.example")
}

// The relays are rendered again only when the GitHub allowlist changes, or on a save with no edit.
// A save with no edit takes up a token gh replaced. An edit to the hosts alone never waits on the
// token, nor fails for it.
//
// The rules take effect at once, and the reload is logged once the relays come up. Relays that
// don't come up keep the previous allowlist, and the reload is logged as a failure. The next save
// tries again.
func TestTheRelaysReloadWithTheAllowlist(t *testing.T) {
	conf, taker, files, ws, hook := addedSetup(t, "allowed_domains: [ws.example]\n")
	var rendered [][]string
	var failing bool
	fakeRelays(taker, func(_ context.Context, allowlist []string) error {
		rendered = append(rendered, allowlist)
		if failing {
			return errors.New("caddy did not come up")
		}
		return nil
	})

	rewrite(t, files, ws, conf.Log, "allowed_domains: [new.example]\n")
	reloaded(t, hook)
	if len(rendered) != 0 {
		t.Fatalf("an edit to the hosts alone rendered the relays: %v", rendered)
	}
	hook.Reset()
	rewrite(t, files, ws, conf.Log, "allowed_domains: [new.example]\ngithub_allowlist: [o/r]\n")
	if last := hook.LastEntry(); last != nil {
		t.Fatalf("an allowlist edit logged before the relays came up: %+v", last)
	}
	settle(t, taker)
	reloaded(t, hook)
	if len(rendered) != 1 || !slices.Equal(rendered[0], []string{"o/r"}) {
		t.Fatalf("an allowlist edit: rendered %v, want once, with the workspace's o/r", rendered)
	}
	setMtime(t, ws.path, mtimeOf(t, ws.path).Add(time.Second))
	files.applyIfChanged(conf.Log, ws)
	settle(t, taker)
	if len(rendered) != 2 {
		t.Fatalf("a save with no edit: rendered %d times, want again", len(rendered))
	}

	failing = true
	rewrite(t, files, ws, conf.Log, "allowed_domains: [newer.example]\ngithub_allowlist: [o/other]\n")
	wantDecisions(t, taker, "as the relays reload", map[string]acl.DecisionResult{
		"new.example":   acl.Deny,
		"newer.example": acl.Allow,
	})
	settle(t, taker)
	wantReloadFailure(t, hook, "caddy did not come up", "the relays' failure logged")
	if !slices.Equal(taker.served(), []string{"o/r"}) {
		t.Fatalf("after the relays failed, served %v, want the previous o/r", taker.served())
	}
	failing = false
	rewrite(t, files, ws, conf.Log, "allowed_domains: [newest.example]\ngithub_allowlist: [o/other]\n")
	settle(t, taker)
	reloaded(t, hook)
	if !slices.Equal(taker.served(), []string{"o/other"}) {
		t.Fatalf("an edit after the relays failed: served %v, want o/other tried again", taker.served())
	}
}

// A render that waits, e.g. at a keychain prompt, holds up neither the polls nor the rules. A hosts
// edit takes effect at once, and is logged at once. A newer allowlist edit cancels the waiting
// render, and the relays serve the newer allowlist, whatever order the reloads end in.
func TestAWaitingRenderHoldsUpNothing(t *testing.T) {
	conf, taker, files, ws, hook := addedSetup(t, "allowed_domains: [ws.example]\n")
	cancelled := make(chan []string, 2)
	release := make(chan struct{})
	fakeRelays(taker, func(ctx context.Context, allowlist []string) error {
		if slices.Equal(allowlist, []string{"o/newer"}) {
			return nil
		}
		select {
		case <-ctx.Done():
			cancelled <- allowlist
			return ctx.Err()
		case <-release:
			return nil
		}
	})

	rewrite(t, files, ws, conf.Log, "allowed_domains: [ws.example]\ngithub_allowlist: [o/r]\n")
	hook.Reset()
	rewrite(t, files, ws, conf.Log, "allowed_domains: [hosts.example]\ngithub_allowlist: [o/r]\n")
	reloaded(t, hook)
	wantDecisions(t, taker, "as the render waits", map[string]acl.DecisionResult{
		"ws.example":    acl.Deny,
		"hosts.example": acl.Allow,
	})

	rewrite(t, files, ws, conf.Log, "allowed_domains: [hosts.example]\ngithub_allowlist: [o/newer]\n")
	select {
	case got := <-cancelled:
		if !slices.Equal(got, []string{"o/r"}) {
			t.Fatalf("cancelled the render for %v, want o/r's", got)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("a newer allowlist edit left the waiting render running")
	}
	settle(t, taker)
	settle(t, taker)
	reloaded(t, hook)
	if !slices.Equal(taker.served(), []string{"o/newer"}) {
		t.Fatalf("served %v, want the newest edit's o/newer", taker.served())
	}
}

// A reload that a newer one cancels after the reload's last check for cancellation still brings its
// relays up. If the newer reload's relays don't come up, the relays serve the cancelled reload's
// allowlist. An edit back to the allowlist from before both reloads differs from the cancelled
// reload's, so it renders the relays again.
func TestACancelledReloadThatCameUpIsServed(t *testing.T) {
	conf, taker, files, ws, hook := addedSetup(t, "allowed_domains: [ws.example]\n")
	release := make(chan struct{})
	var rendered [][]string
	fakeRelays(taker, func(_ context.Context, allowlist []string) error {
		switch {
		case slices.Equal(allowlist, []string{"o/r"}):
			<-release // the reload is past its last check for cancellation, and comes up
			return nil
		case slices.Equal(allowlist, []string{"o/newer"}):
			return errors.New("caddy did not come up")
		}
		rendered = append(rendered, allowlist)
		return nil
	})

	rewrite(t, files, ws, conf.Log, "allowed_domains: [ws.example]\ngithub_allowlist: [o/r]\n")
	rewrite(t, files, ws, conf.Log, "allowed_domains: [ws.example]\ngithub_allowlist: [o/newer]\n")
	settle(t, taker)
	wantReloadFailure(t, hook, "caddy did not come up", "the newer reload's failure logged")
	close(release)
	settle(t, taker)
	if !slices.Equal(taker.served(), []string{"o/r"}) {
		t.Fatalf("served %v, want the cancelled reload's o/r, as it came up", taker.served())
	}

	rewrite(t, files, ws, conf.Log, "allowed_domains: [ws.example]\n")
	settle(t, taker)
	if len(rendered) != 1 || len(rendered[0]) != 0 {
		t.Fatalf("an edit back to no allowlist: rendered %v, want once, with none", rendered)
	}
}

// fakeRelays sets the taker's relays to reload. As with the relays' supervisor
// (relaySupervisor.served), the relays serve the last GitHub allowlist that reload returned nil
// for. Until then, they serve the allowlist taken up as the proxy started.
func fakeRelays(taker *networkTaker, reload func(ctx context.Context, allowlist []string) error) {
	var served atomic.Pointer[[]string]
	served.Store(&taker.initial)
	taker.relays = func(ctx context.Context, allowlist []string) error {
		err := reload(ctx, allowlist)
		if err == nil {
			served.Store(&allowlist)
		}
		return err
	}
	taker.served = func() []string { return *served.Load() }
}

// settle waits for the next reload of the relays to end, and runs what that reload has the watcher
// do (configFiles.watch).
func settle(t *testing.T, taker *networkTaker) {
	t.Helper()
	select {
	case s := <-taker.settled:
		s()
	case <-time.After(5 * time.Second):
		t.Fatal("no reload of the relays ended")
	}
}

// A deleted added file takes away what it added -- once still missing at the next poll, past the
// moment an atomic save has it missing.
func TestDeletedAddedNetworkIsTakenAway(t *testing.T) {
	conf, taker, files, ws, hook := addedSetup(t, "allowed_domains: [ws.example]\n")
	mustRemove(t, ws.path)
	hook.Reset()
	files.applyIfChanged(conf.Log, ws)
	// An atomic save may be under way.
	wantDecisions(t, taker, "at the first poll missing", map[string]acl.DecisionResult{"ws.example": acl.Allow})
	files.applyIfChanged(conf.Log, ws)
	reloaded(t, hook)
	wantDecisions(t, taker, "once the added rules are gone", map[string]acl.DecisionResult{
		"ws.example":   acl.Deny,
		"base.example": acl.Allow,
	})

	// Gone, nothing more is taken up, until it is made again.
	wantNoReload(t, files, ws, conf.Log, hook, 2, "a gone added file taken up again")
	rewrite(t, files, ws, conf.Log, "allowed_domains: [again.example]\n")
	wantDecisions(t, taker, "once the added rules are made again", map[string]acl.DecisionResult{"again.example": acl.Allow})
}

// A broken added file, deleted, is confirmed gone, its refusal no longer standing, though it took
// nothing away.
func TestDeletedBrokenAddedNetworkIsConfirmedGone(t *testing.T) {
	conf, taker, files, ws, hook := addedSetup(t, "")
	rewrite(t, files, ws, conf.Log, "allowed_domain: [typo.example]\n")
	reloadFailure(t, hook)
	mustRemove(t, ws.path)
	files.applyIfChanged(conf.Log, ws)
	files.applyIfChanged(conf.Log, ws)
	reloaded(t, hook)
	wantDecisions(t, taker, "once gone", map[string]acl.DecisionResult{"base.example": acl.Allow, "typo.example": acl.Deny})
}

// Taking away a deleted added file may be refused, e.g. when the base allows a GitHub host that
// only the added file denied. The proxy then tries again at each poll, and logs the failure once.
//
// The retries go on until what the file added is taken away. Otherwise, what it added would stay in
// effect, and a base reload would take it up again.
func TestDeletedAddedNetworkFailingToBeTakenAwayIsRetried(t *testing.T) {
	basePath, addedPath := addedFiles(t, "allowed_domains: [base.example, github.com]\n",
		"allowed_domains: [ws.example]\nglobal_deny_list: [github.com]\n")
	conf, taker, files, hook := setupWith(t, basePath, addedPath)
	ws := files.added
	mustRemove(t, ws.path)
	hook.Reset()
	files.applyIfChanged(conf.Log, ws)
	files.applyIfChanged(conf.Log, ws)
	wantReloadFailure(t, hook, "github.com", "the base, alone, refused for allowing github.com")
	wantDecisions(t, taker, "as taking them away fails", map[string]acl.DecisionResult{"ws.example": acl.Allow})

	wantNoReload(t, files, ws, conf.Log, hook, 2, "a failure to take away the added rules logged again")

	rewrite(t, files, files.base, conf.Log, networkAllowing("base.example"))
	files.applyIfChanged(conf.Log, ws)
	reloaded(t, hook)
	wantDecisions(t, taker, "once taking them away succeeds", map[string]acl.DecisionResult{
		"ws.example":   acl.Deny,
		"base.example": acl.Allow,
		"github.com":   acl.Deny,
	})
}

// An added file first made mid-session as a symlink, refused before anything was taken up from it,
// deleted, is confirmed gone, its refusal no longer standing.
func TestDeletedLinkInPlaceOfMissingAddedNetworkIsConfirmedGone(t *testing.T) {
	conf, taker, files, ws, hook := addedSetup(t, "")
	elsewhere := filepath.Join(realTempDir(t), "network.yaml")
	writeFile(t, elsewhere, "allowed_domains: [evil.example]\n")
	mustSymlink(t, elsewhere, ws.path)
	files.applyIfChanged(conf.Log, ws)
	wantReloadFailure(t, hook, "symlink", "the link refused")
	mustRemove(t, ws.path)
	// Nothing to take away, it is confirmed gone at once.
	files.applyIfChanged(conf.Log, ws)
	reloaded(t, hook)
	wantDecisions(t, taker, "once gone", map[string]acl.DecisionResult{"base.example": acl.Allow, "evil.example": acl.Deny})

	wantNoReload(t, files, ws, conf.Log, hook, 1, "a gone link confirmed gone again")
}

// A base edit refused for the added rules is taken up with the edit to the added rules that lets it,
// and a later poll of the base takes up nothing more: the two are taken up as one, as a session
// starting would take them up.
func TestBaseEditRefusedForTheAddedNetworkIsTakenUpOnceItAllowsIt(t *testing.T) {
	// The added rules allow a GitHub host the base denies. A base edit that stops denying it lets
	// the host through.
	basePath, addedPath := addedFiles(t, networkAllowing("base.example")+"global_deny_list: [api.github.com]\n",
		"allowed_domains: [ws.example, api.github.com]\n")
	conf, taker, files, hook := setupWith(t, basePath, addedPath)
	ws := files.added
	rewrite(t, files, files.base, conf.Log, networkAllowing("new.example"))
	wantReloadFailure(t, hook, "api.github.com", "the base edit refused for the added rules")
	wantDecisions(t, taker, "after the refused base edit", map[string]acl.DecisionResult{"ws.example": acl.Allow})
	wantNoReload(t, files, files.base, conf.Log, hook, 1, "an unchanged refused base edit taken up again")

	rewrite(t, files, ws, conf.Log, "global_deny_list: [quiet.example]\n")
	reloaded(t, hook)
	wantDecisions(t, taker, "once the added rules allow the base edit", map[string]acl.DecisionResult{
		"new.example":  acl.Allow,
		"base.example": acl.Deny,
		"ws.example":   acl.Deny,
	})

	wantNoReload(t, files, files.base, conf.Log, hook, 1, "a base edit taken up again")
}

// An atomic save, which has the added file missing for a moment, takes nothing away.
func TestAddedNetworkMissingForAPollIsKept(t *testing.T) {
	conf, taker, files, ws, hook := addedSetup(t, "allowed_domains: [ws.example]\n")
	if err := os.Rename(ws.path, ws.path+".saving"); err != nil {
		t.Fatal(err)
	}
	hook.Reset()
	files.applyIfChanged(conf.Log, ws)
	if err := os.Rename(ws.path+".saving", ws.path); err != nil {
		t.Fatal(err)
	}
	files.applyIfChanged(conf.Log, ws)
	files.applyIfChanged(conf.Log, ws)
	// Taken up again or not, as it is, it is not taken away.
	for _, e := range hook.Entries {
		if e.Message != networkReloaded {
			t.Fatalf("an added file missing for a poll was taken away: %+v", hook.Entries)
		}
	}
	wantDecisions(t, taker, "after an added file missing for a poll", map[string]acl.DecisionResult{"ws.example": acl.Allow})
}

// A reload of the base rules takes up the added ones as last read, not as the file now is: only the
// added file's own reload, which refuses one with other hard links, reads it.
func TestBaseReloadTakesTheAddedNetworkAsTakenUp(t *testing.T) {
	conf, taker, files, ws, _ := addedSetup(t, "allowed_domains: [ws.example]\n")
	other := filepath.Join(filepath.Dir(ws.path), "other-link.yaml")
	writeThroughOtherLink(t, ws.path, other, "allowed_domains: [evil.example]\n")

	rewrite(t, files, files.base, conf.Log, networkAllowing("new.example"))
	// evil.example is written through another link of the added rules; ws.example is as they were
	// taken up.
	wantDecisions(t, taker, "after the base reload", map[string]acl.DecisionResult{
		"new.example":  acl.Allow,
		"evil.example": acl.Deny,
		"ws.example":   acl.Allow,
	})
}

// An added file first made mid-session, with other hard links, is moved aside, leaving none, as
// none was taken up.
func TestNewAddedNetworkWithOtherLinksIsMovedAside(t *testing.T) {
	conf, taker, files, ws, hook := addedSetup(t, "")
	writeFile(t, ws.path, "allowed_domains: [evil.example]\n")
	if err := os.Link(ws.path, ws.path+".other"); err != nil {
		t.Fatal(err)
	}
	files.applyIfChanged(conf.Log, ws)
	wantReloadFailure(t, hook, "leaving none", "the file moved aside, leaving none")
	if _, err := os.Stat(ws.path); err == nil {
		t.Fatal("the refused added file was left in place")
	}
	wantDecisions(t, taker, "", map[string]acl.DecisionResult{"evil.example": acl.Deny})
}

// The base rules' deny list applies to the hosts the added rules allow, as it does to the base's
// own. The added rules can't make an exception to it.
func TestAddedNetworkCantAllowWhatTheBaseDenies(t *testing.T) {
	base := networkAllowing("base.example") + "global_deny_list:\n  - '*.telemetry.example'\n"
	basePath, addedPath := addedFiles(t, base, "allowed_domains:\n  - intake.telemetry.example\n  - '*.example'\n")
	_, taker, _, _ := setupWith(t, basePath, addedPath)
	wantDecisions(t, taker, "", map[string]acl.DecisionResult{
		"intake.telemetry.example": acl.Deny,
		"x.telemetry.example":      acl.Deny,
		"other.example":            acl.Allow,
		"base.example":             acl.Allow,
	})
	basePath, addedPath = addedFiles(t, networkAllowing("base.example")+"global_deny_list: [base.example]\n", "")
	_, taker, _, _ = setupWith(t, basePath, addedPath)
	wantGlobalDenied(t, taker, "base.example")
}

// A refused edit to the added file doesn't hold up a base edit: the base file is taken up with the
// added one as last taken up.
func TestBrokenAddedNetworkDoesntHoldUpTheBaseReload(t *testing.T) {
	conf, taker, files, ws, hook := addedSetup(t, "allowed_domains: [ws.example]\n")
	rewrite(t, files, ws, conf.Log, "allowed_domain: [typo.example]\n")
	reloadFailure(t, hook)

	rewrite(t, files, files.base, conf.Log, networkAllowing("new.example"))
	reloaded(t, hook)
	wantDecisions(t, taker, "after the base reload", map[string]acl.DecisionResult{"new.example": acl.Allow, "ws.example": acl.Allow})

	rewrite(t, files, ws, conf.Log, "allowed_domains: [fixed.example]\n")
	reloaded(t, hook)
	wantDecisions(t, taker, "once the added file is fixed", map[string]acl.DecisionResult{
		"new.example":   acl.Allow,
		"fixed.example": acl.Allow,
		"ws.example":    acl.Deny,
	})
}

func TestBaseReloadDoesNotRetryUnreadableAddedNetwork(t *testing.T) {
	skipIfRoot(t)
	basePath, addedPath := addedFiles(t, networkAllowing("base.example"), "")
	conf, taker, files, hook := setupWith(t, basePath, addedPath)
	rewrite(t, files, files.added, conf.Log, "allowed_domains: [ws.example, api.github.com]\n")
	wantReloadFailure(t, hook, "api.github.com", "the added rules require the base to deny api.github.com")

	chmod(t, addedPath, 0)
	rewrite(t, files, files.base, conf.Log, networkAllowing("base.example")+"global_deny_list: [api.github.com]\n")
	files.applyIfChanged(conf.Log, files.added)
	wantReloadFailure(t, hook, "permission denied", "the added rules are unreadable")
	wantDecisions(t, taker, "while the added rules are unreadable", map[string]acl.DecisionResult{
		"base.example": acl.Allow,
		"ws.example":   acl.Deny,
	})

	chmod(t, addedPath, 0o644)
	files.applyIfChanged(conf.Log, files.added)
	reloaded(t, hook)
	wantDecisions(t, taker, "after the added rules become readable", map[string]acl.DecisionResult{
		"ws.example": acl.Allow,
	})
}

func TestRestoringAccessToUnchangedWorkspaceNetworkClearsWarning(t *testing.T) {
	skipIfRoot(t)
	basePath, addedPath := addedFiles(t, networkAllowing("base.example"), "")
	parent := filepath.Join(filepath.Dir(addedPath), "workspace")
	if err := os.Mkdir(parent, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { chmod(t, parent, 0o700) })
	addedPath = filepath.Join(parent, "network.yaml")
	writeFile(t, addedPath, "allowed_domains: [ws.example]\n")
	conf, taker, files, hook := setupWith(t, basePath, addedPath)

	chmod(t, parent, 0)
	files.applyIfChanged(conf.Log, files.added)
	wantReloadFailure(t, hook, "permission denied", "the workspace rules are unreadable")

	hook.Reset()
	chmod(t, parent, 0o700)
	files.applyIfChanged(conf.Log, files.added)
	reloaded(t, hook)
	wantDecisions(t, taker, "after access is restored", map[string]acl.DecisionResult{"ws.example": acl.Allow})
	wantNoReload(t, files, files.added, conf.Log, hook, 1, "recovery is logged once")

	rewrite(t, files, files.added, conf.Log, "allowed_domains: [\n")
	reloadFailure(t, hook)
	chmod(t, parent, 0)
	files.applyIfChanged(conf.Log, files.added)
	wantReloadFailure(t, hook, "permission denied", "the refused edit is unreadable")

	hook.Reset()
	chmod(t, parent, 0o700)
	files.applyIfChanged(conf.Log, files.added)
	wantReloadFailure(t, hook, "a network config may only have", "the edit is still invalid")
	wantDecisions(t, taker, "after access to the refused edit is restored", map[string]acl.DecisionResult{"ws.example": acl.Allow})
}

// An edit refused for what the other file had is taken up once that file changes for the edit to
// fit. Here, the added rules are refused for allowing a GitHub host. They are taken up with the
// base edit that denies the host, and their reload is logged after the base edit's.
func TestRefusedAddedNetworkIsRetriedOnABaseEdit(t *testing.T) {
	basePath, addedPath := addedFiles(t, networkAllowing("base.example"), "")
	conf, taker, files, hook := setupWith(t, basePath, addedPath)
	writeFile(t, addedPath, "allowed_domains: [ws.example, api.github.com]\n")
	files.applyIfChanged(conf.Log, files.added)
	wantReloadFailure(t, hook, "api.github.com", "the added rules refused for allowing api.github.com")

	hook.Reset()
	rewrite(t, files, files.base, conf.Log, networkAllowing("base.example")+"global_deny_list: [api.github.com]\n")
	if len(hook.Entries) != 2 || hook.Entries[0].Data["network"] != basePath ||
		hook.Entries[1].Data["network"] != addedPath || hook.Entries[1].Message != networkReloaded {
		t.Fatalf("want the base reload, then the added file's; got %+v", hook.Entries)
	}
	wantDecisions(t, taker, "after the base edit", map[string]acl.DecisionResult{"ws.example": acl.Allow, "base.example": acl.Allow})
}

// A broken added file, or one allowing GitHub, keeps the proxy from starting, as a broken base file
// does: every session of a workspace runs on what its others accept, for their reloads' banners to
// speak for them all. The refusal names the added file, for the user to know whose config to fix; a
// broken base file's names the base, whatever the added file holds.
func TestBrokenAddedNetworkKeepsTheProxyFromStarting(t *testing.T) {
	for name, tc := range map[string]struct {
		base, added string
		isAdded     bool
	}{
		"an unknown key":  {networkAllowing("base.example"), "allowed_domain: [typo.example]\n", true},
		"github.com":      {networkAllowing("base.example"), "allowed_domains: [github.com, ws.example]\n", true},
		"the base broken": {"version: v1\nservices: [\n", "allowed_domains: [ws.example]\n", false},
	} {
		t.Run(name, func(t *testing.T) {
			base, added := addedFiles(t, tc.base, tc.added)
			_, _, files, _ := untakenSetup(t, base, added)
			err := files.takeUp(nil, func(error) {}, func(error) {})
			named, other := base, added
			if tc.isAdded {
				named, other = added, base
			}
			if err == nil || !strings.Contains(err.Error(), named) || strings.Contains(err.Error(), other) {
				t.Errorf("got %v, want a refusal naming %s alone", err, named)
			}
		})
	}
}

// When both files allow GitHub hosts, each gets a refusal of its own, naming the file and the hosts
// that file allows. With the override, the proxy takes both up, with a warning for each refusal.
func TestAddedNetworkAllowingGitHubBeyondTheBase(t *testing.T) {
	base := []byte(networkAllowing("github.com"))
	added := []byte("allowed_domains: [api.github.com]\n")
	n, err := loadNetwork(smokescreen.NewConfig(), []configContent{newConfigContent("/network.yaml", base), newConfigContent("/ws.yaml", added)})
	if err != nil {
		t.Fatal(err)
	}
	refusals := n.exfiltration
	var got []string
	for _, refusal := range refusals {
		got = append(got, refusal.Error())
	}
	if len(refusals) != 2 || refusals[0].path != "/network.yaml" || !slices.Equal(refusals[0].allowed, []string{"github.com"}) ||
		refusals[1].path != "/ws.yaml" || !slices.Equal(refusals[1].allowed, []string{"api.github.com"}) {
		t.Errorf("got %q, want the base refused for github.com, and the added file for api.github.com alone", got)
	}
}

// The added global_deny_list denies a host on it, as a known denial, even when the base's
// allowed_domains or the added ones allow the host.
func TestAddedGlobalDenyListWinsOverAllows(t *testing.T) {
	_, taker, _, _, _ := addedSetup(t, "allowed_domains: [ws.example]\nglobal_deny_list: [base.example, ws.example]\n")
	wantGlobalDenied(t, taker, "base.example")
	wantGlobalDenied(t, taker, "ws.example")
}

// A host glob smokescreen refuses in the added rules is refused naming the added file, once, and the
// list it is on, for the user to know what to fix: smokescreen's own refusal of an empty one names
// neither.
func TestAddedNetworkBadGlobsNameTheFileAndList(t *testing.T) {
	for name, tc := range map[string]struct{ content, list string }{
		"an empty allowed domain": {"allowed_domains: ['']\n", "allowed_domains"},
		"an empty denied domain":  {"global_deny_list: ['']\n", "global_deny_list"},
		"a match-all":             {"allowed_domains: ['*']\n", "allowed_domains"},
		"a mid-domain glob":       {"global_deny_list: ['a.*.example']\n", "global_deny_list"},
		"a repo with no owner":    {"github_allowlist: [repo]\n", "github_allowlist"},
		"a repo with a newline":   {"github_allowlist: [\"o/r\\nevil/*\"]\n", "github_allowlist"},
	} {
		t.Run(name, func(t *testing.T) {
			_, err := loadNetwork(smokescreen.NewConfig(), []configContent{newConfigContent("/network.yaml", []byte(networkAllowing("base.example"))), newConfigContent("/ws.yaml", []byte(tc.content))})
			if err == nil || strings.Count(err.Error(), "/ws.yaml") != 1 || !strings.Contains(err.Error(), tc.list) {
				t.Errorf("got %v, want a refusal naming /ws.yaml once, and %s", err, tc.list)
			}
		})
	}
}

// The test covers every way of spreading GitHub hosts, and one other host, over the allowed_domains
// and global_deny_list of the base network config and the added one.
//
// A config's rules are refused exactly when they let through a GitHub host taking writes, whichever
// file allows the host and whatever the other file holds. Each refusal names a file that allows a
// host that gets through.
func TestNetworkLettingGitHubThroughIsRefused(t *testing.T) {
	hosts := []string{"github.com", "api.github.com", "*.github.com", "ok.example"}
	var allows [][]string // every subset of hosts
	for mask := 0; mask < 1<<len(hosts); mask++ {
		var allow []string
		for i, host := range hosts {
			if mask&(1<<i) != 0 {
				allow = append(allow, host)
			}
		}
		allows = append(allows, allow)
	}
	denies := [][]string{nil, {"github.com"}, {"api.github.com"}, {"*.github.com"}}
	for _, baseAllow := range allows {
		for _, baseDeny := range denies {
			for _, addedAllow := range allows {
				for _, addedDeny := range denies {
					base, added := hostsWith(baseAllow, baseDeny), hostsWith(addedAllow, addedDeny)
					n, err := loadNetwork(smokescreen.NewConfig(), []configContent{
						newConfigContent("/network.yaml", []byte(base)), newConfigContent("/ws.yaml", []byte(added))})
					if err != nil {
						t.Fatalf("%v:\n--- base\n%s--- added\n%s", err, base, added)
					}
					rules, refusals := n.rules, n.exfiltration
					through := gitHubThrough(rules)
					if (len(through) > 0) != (len(refusals) > 0) {
						t.Errorf("letting %v through, refused %v:\n--- base\n%s--- added\n%s", through, refusals, base, added)
					}
					for _, refusal := range refusals {
						if !slices.ContainsFunc(refusal.allowed, func(host string) bool {
							return slices.Contains(through, host) || host == "*.github.com"
						}) {
							t.Errorf("%v refused for none of %v, which get through:\n--- base\n%s--- added\n%s", refusal, through, base, added)
						}
					}
				}
			}
		}
	}
}

// gitHubThrough is the GitHub hosts taking writes that rules let through. A subdomain no one would
// name (gitHubProbeForAGlob) stands for any subdomain a glob lets through.
func gitHubThrough(rules *acl.ACL) []string {
	var through []string
	for _, host := range append([]string{"github.com", gitHubProbeForAGlob}, gitHubWriteSubdomains...) {
		if d, _ := rules.Decide(acl.DecideArgs{Host: host}); d.Result == acl.Allow {
			through = append(through, host)
		}
	}
	return through
}

// hostsWith is a network config allowing allow and denying deny.
func hostsWith(allow, deny []string) string {
	return "allowed_domains: [" + quoted(allow) + "]\nglobal_deny_list: [" + quoted(deny) + "]\n"
}

// quoted is hosts as a YAML flow list's items.
func quoted(hosts []string) string {
	items := make([]string, len(hosts))
	for i, host := range hosts {
		items[i] = `"` + host + `"`
	}
	return strings.Join(items, ", ")
}

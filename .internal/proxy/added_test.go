package main

import (
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/sirupsen/logrus"
	logrustest "github.com/sirupsen/logrus/hooks/test"
	"github.com/stripe/smokescreen/pkg/smokescreen"
	acl "github.com/stripe/smokescreen/pkg/smokescreen/acl/v1"
)

// addedSetup is testSetup for base rules allowing base.example, with rules added at a path in the
// same dir, ws, written with content unless it is "" (left missing).
func addedSetup(t *testing.T, content string) (conf *smokescreen.Config, holder *swappableACL, rules *configFiles, ws *configFile, hook *logrustest.Hook) {
	t.Helper()
	basePath, addedPath := addedFiles(t, rulesAllowing("base.example"), content)
	conf, holder, rules, hook = setupWith(t, basePath, addedPath)
	return conf, holder, rules, rules.added, hook
}

// addedFiles are the paths of the base rules, written with base, and of rules added in the same
// dir, written with content unless it is "" (left missing).
func addedFiles(t *testing.T, base, content string) (basePath, addedPath string) {
	t.Helper()
	dir := realTempDir(t)
	basePath, addedPath = filepath.Join(dir, "rules.yaml"), filepath.Join(dir, "ws.yaml")
	writeFile(t, basePath, base)
	if content != "" {
		writeFile(t, addedPath, content)
	}
	return basePath, addedPath
}

// wantNoReload checks polling f the given number of times logs nothing, failing with why.
func wantNoReload(t *testing.T, rules *configFiles, f *configFile, log *logrus.Logger, hook *logrustest.Hook, polls int, why string) {
	t.Helper()
	hook.Reset()
	for range polls {
		rules.applyIfChanged(log, f)
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

// wantGlobalDenied checks the holder denies host for the global deny list, as a known denial.
func wantGlobalDenied(t *testing.T, holder *swappableACL, host string) {
	t.Helper()
	if d, _ := holder.Decide(acl.DecideArgs{Host: host}); d.Result != acl.Deny || d.Reason != knownDenyReason {
		t.Errorf("%s: got %v (%q), want denied for the global deny list", host, d.Result, d.Reason)
	}
}

func TestAddedRulesAddToTheBase(t *testing.T) {
	_, holder, _, _, _ := addedSetup(t, "allowed_domains:\n  - ws.example\nglobal_deny_list:\n  - quiet.example\n")
	wantDecisions(t, holder, "", map[string]acl.DecisionResult{
		"base.example":  acl.Allow,
		"ws.example":    acl.Allow,
		"other.example": acl.Deny,
	})
	wantGlobalDenied(t, holder, "quiet.example")
}

func TestMissingAddedRulesAddNothingUntilMade(t *testing.T) {
	conf, holder, rules, ws, _ := addedSetup(t, "")
	wantDecisions(t, holder, "with no added rules", map[string]acl.DecisionResult{"base.example": acl.Allow})

	// Made mid-session, it is taken up: a missing file's modification time is zero.
	rewrite(t, rules, ws, conf.Log, "allowed_domains: [ws.example]\n")
	wantDecisions(t, holder, "once the added rules are made", map[string]acl.DecisionResult{
		"ws.example":   acl.Allow,
		"base.example": acl.Allow,
	})
}

// An added file's reload is logged as the workspace's own, named with its dir; a base file's, as
// the user knows it, by its name alone.
func TestAddedRulesReloadIsLoggedAsTheWorkspaces(t *testing.T) {
	conf, holder, rules, ws, hook := addedSetup(t, "allowed_domains: [old.example]\n")
	rewrite(t, rules, ws, conf.Log, "allowed_domains: [new.example]\n")
	reloaded(t, hook)
	wantName := filepath.Join(filepath.Base(filepath.Dir(ws.path)), "ws.yaml")
	if data := hook.LastEntry().Data; data["what"] != "workspace rules" || data["name"] != wantName || data["added"] != true {
		t.Errorf("logged as %v, named %v, added %v: want the workspace rules, named %s, added", data["what"], data["name"], data["added"], wantName)
	}
	rewrite(t, rules, rules.base, conf.Log, rulesAllowing("base.example"))
	reloaded(t, hook)
	if data := hook.LastEntry().Data; data["what"] != "rules" || data["name"] != "rules.yaml" || data["added"] != false {
		t.Errorf("the base logged as %v, named %v, added %v: want the rules, named rules.yaml, not added", data["what"], data["name"], data["added"])
	}
	wantDecisions(t, holder, "after the reload", map[string]acl.DecisionResult{
		"new.example": acl.Allow,
		"old.example": acl.Deny,
	})
}

func TestAddedRulesRefuseWhatCouldLoosenTheBase(t *testing.T) {
	for name, content := range map[string]string{
		"a default rule":  "default:\n  name: default\n  action: open\n",
		"services":        "services: []\n",
		"a global allow":  "global_allow_list: [any.example]\n",
		"an unknown key":  "allowed_domain: [typo.example]\n",
		"github.com":      "allowed_domains: [github.com]\n",
		"a *.github.com":  "allowed_domains: ['*.github.com']\n",
		"not a host list": "allowed_domains: ws.example\n",
	} {
		t.Run(name, func(t *testing.T) {
			conf, holder, rules, ws, hook := addedSetup(t, "allowed_domains: [old.example]\n")
			rewrite(t, rules, ws, conf.Log, content)
			reloadFailure(t, hook)
			wantDecisions(t, holder, "after a refused reload", map[string]acl.DecisionResult{"old.example": acl.Allow})
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
		if _, err := newConfigFile(c.path, rulesKind, true); err == nil || !strings.Contains(err.Error(), "symlink") {
			t.Errorf("%s: got %v, want an added file with a symlink on its way refused", c.name, err)
		}
	}
	base := filepath.Join(dir, "rules.yaml")
	writeFile(t, base, rulesAllowing("base.example"))
	if _, err := newConfigFiles(rulesKind, base, filepath.Join(dir, "ws")); err == nil || !strings.Contains(err.Error(), filepath.Join(dir, "ws")) {
		t.Errorf("as the proxy starts: got %v, want the added file's refusal, naming it", err)
	}
}

// An added file's dir made mid-session as a symlink, which could lead out of the dir chopi keeps
// sandboxed commands from changing, is refused.
func TestAddedRulesThroughADirLinkedSinceAreRefused(t *testing.T) {
	conf, holder, rules, ws, hook := addedSetup(t, "")
	dir := filepath.Join(filepath.Dir(ws.path), "ws")
	ws.path = filepath.Join(dir, "rules.yaml") // in a dir missing as the proxy started
	elsewhere := realTempDir(t)
	writeFile(t, filepath.Join(elsewhere, "rules.yaml"), "allowed_domains: [evil.example]\n")
	mustSymlink(t, elsewhere, dir)
	rules.applyIfChanged(conf.Log, ws)
	wantReloadFailure(t, hook, "symlink", "the linked dir refused")
	wantDecisions(t, holder, "", map[string]acl.DecisionResult{"evil.example": acl.Deny})
}

// A link leading nowhere put in place of an added file is refused, keeping what the file added,
// rather than taken for the file missing, taking it away.
func TestAddedRulesReplacedByADanglingLinkAreKept(t *testing.T) {
	conf, holder, rules, ws, hook := addedSetup(t, "global_deny_list: [quiet.example]\n")
	mustRemove(t, ws.path)
	mustSymlink(t, ws.path+".missing", ws.path)
	hook.Reset()
	rules.applyIfChanged(conf.Log, ws)
	rules.applyIfChanged(conf.Log, ws)
	wantReloadFailure(t, hook, "symlink", "the link leading nowhere refused")
	wantGlobalDenied(t, holder, "quiet.example")
}

func TestAddedAllowedDomainsNeedABaseDefaultRule(t *testing.T) {
	base, added := []byte(rulesWithoutDefault), []byte("allowed_domains: [ws.example]\n")
	if _, _, err := loadRules(smokescreen.NewConfig(), "/rules.yaml", "/ws.yaml", base, added); err == nil || !strings.Contains(err.Error(), "no default rule") {
		t.Errorf("got %v, want a refusal naming the missing default rule", err)
	}
}

// A deleted added file takes away what it added -- once still missing at the next poll, past the
// moment an atomic save has it missing.
func TestDeletedAddedRulesAreTakenAway(t *testing.T) {
	conf, holder, rules, ws, hook := addedSetup(t, "allowed_domains: [ws.example]\n")
	mustRemove(t, ws.path)
	hook.Reset()
	rules.applyIfChanged(conf.Log, ws)
	// An atomic save may be under way.
	wantDecisions(t, holder, "at the first poll missing", map[string]acl.DecisionResult{"ws.example": acl.Allow})
	rules.applyIfChanged(conf.Log, ws)
	reloaded(t, hook)
	wantDecisions(t, holder, "once the added rules are gone", map[string]acl.DecisionResult{
		"ws.example":   acl.Deny,
		"base.example": acl.Allow,
	})

	// Gone, nothing more is taken up, until it is made again.
	wantNoReload(t, rules, ws, conf.Log, hook, 2, "a gone added file taken up again")
	rewrite(t, rules, ws, conf.Log, "allowed_domains: [again.example]\n")
	wantDecisions(t, holder, "once the added rules are made again", map[string]acl.DecisionResult{"again.example": acl.Allow})
}

// A broken added file, deleted, is confirmed gone, its refusal no longer standing, though it took
// nothing away.
func TestDeletedBrokenAddedRulesAreConfirmedGone(t *testing.T) {
	conf, holder, rules, ws, hook := addedSetup(t, "")
	rewrite(t, rules, ws, conf.Log, "allowed_domain: [typo.example]\n")
	reloadFailure(t, hook)
	mustRemove(t, ws.path)
	rules.applyIfChanged(conf.Log, ws)
	rules.applyIfChanged(conf.Log, ws)
	reloaded(t, hook)
	wantDecisions(t, holder, "once gone", map[string]acl.DecisionResult{"base.example": acl.Allow, "typo.example": acl.Deny})
}

// A deleted added file whose taking away fails -- as a relay that doesn't come up fails it -- is
// tried again at each poll, the failure logged once, until what it added is taken away: never
// left standing, for a base reload to take up again.
func TestDeletedAddedRulesFailingToBeTakenAwayAreRetried(t *testing.T) {
	conf, holder, rules, ws, hook := addedSetup(t, "allowed_domains: [ws.example]\n")
	take, failing := rules.take, true
	rules.take = func(base, added []byte, warn func(error)) error {
		if failing {
			return errors.New("relay did not come up")
		}
		return take(base, added, warn)
	}
	mustRemove(t, ws.path)
	hook.Reset()
	rules.applyIfChanged(conf.Log, ws)
	rules.applyIfChanged(conf.Log, ws)
	reloadFailure(t, hook)
	wantDecisions(t, holder, "as taking them away fails", map[string]acl.DecisionResult{"ws.example": acl.Allow})

	wantNoReload(t, rules, ws, conf.Log, hook, 2, "a failure to take away the added rules logged again")

	failing = false
	rules.applyIfChanged(conf.Log, ws)
	reloaded(t, hook)
	wantDecisions(t, holder, "once taking them away succeeds", map[string]acl.DecisionResult{"ws.example": acl.Deny})
	rewrite(t, rules, rules.base, conf.Log, rulesAllowing("base.example"))
	wantDecisions(t, holder, "after a base reload", map[string]acl.DecisionResult{
		"ws.example":   acl.Deny,
		"base.example": acl.Allow,
	})
}

// An added file first made mid-session as a symlink, refused before anything was taken up from it,
// deleted, is confirmed gone, its refusal no longer standing.
func TestDeletedLinkInPlaceOfMissingAddedRulesIsConfirmedGone(t *testing.T) {
	conf, holder, rules, ws, hook := addedSetup(t, "")
	elsewhere := filepath.Join(realTempDir(t), "rules.yaml")
	writeFile(t, elsewhere, "allowed_domains: [evil.example]\n")
	mustSymlink(t, elsewhere, ws.path)
	rules.applyIfChanged(conf.Log, ws)
	wantReloadFailure(t, hook, "symlink", "the link refused")
	mustRemove(t, ws.path)
	// Nothing to take away, it is confirmed gone at once.
	rules.applyIfChanged(conf.Log, ws)
	reloaded(t, hook)
	wantDecisions(t, holder, "once gone", map[string]acl.DecisionResult{"base.example": acl.Allow, "evil.example": acl.Deny})

	wantNoReload(t, rules, ws, conf.Log, hook, 1, "a gone link confirmed gone again")
}

// A base edit refused for the added rules is taken up with the edit to the added rules that lets it,
// and a later poll of the base takes up nothing more: the two are taken up as one, as a session
// starting would take them up.
func TestBaseEditRefusedForTheAddedRulesIsTakenUpOnceTheyAllowIt(t *testing.T) {
	conf, holder, rules, ws, hook := addedSetup(t, "allowed_domains: [ws.example]\n")
	rewrite(t, rules, rules.base, conf.Log, rulesWithoutDefault)
	wantReloadFailure(t, hook, "no default rule", "the base edit refused for the added rules")
	wantDecisions(t, holder, "after the refused base edit", map[string]acl.DecisionResult{"ws.example": acl.Allow})
	wantNoReload(t, rules, rules.base, conf.Log, hook, 1, "an unchanged refused base edit taken up again")

	rewrite(t, rules, ws, conf.Log, "global_deny_list: [quiet.example]\n")
	reloaded(t, hook)
	wantDecisions(t, holder, "once the added rules allow the base edit", map[string]acl.DecisionResult{
		"base.example": acl.Deny,
		"ws.example":   acl.Deny,
	})

	wantNoReload(t, rules, rules.base, conf.Log, hook, 1, "a base edit taken up again")
}

// An atomic save, which has the added file missing for a moment, takes nothing away.
func TestAddedRulesMissingForAPollAreKept(t *testing.T) {
	conf, holder, rules, ws, hook := addedSetup(t, "allowed_domains: [ws.example]\n")
	if err := os.Rename(ws.path, ws.path+".saving"); err != nil {
		t.Fatal(err)
	}
	hook.Reset()
	rules.applyIfChanged(conf.Log, ws)
	if err := os.Rename(ws.path+".saving", ws.path); err != nil {
		t.Fatal(err)
	}
	rules.applyIfChanged(conf.Log, ws)
	rules.applyIfChanged(conf.Log, ws)
	// Taken up again or not, as it is, it is not taken away.
	for _, e := range hook.Entries {
		if e.Message != rulesReloaded {
			t.Fatalf("an added file missing for a poll was taken away: %+v", hook.Entries)
		}
	}
	wantDecisions(t, holder, "after an added file missing for a poll", map[string]acl.DecisionResult{"ws.example": acl.Allow})
}

// A reload of the base rules takes up the added ones as last read, not as the file now is: only the
// added file's own reload, which refuses one with other hard links, reads it.
func TestBaseReloadTakesTheAddedRulesAsTakenUp(t *testing.T) {
	conf, holder, rules, ws, _ := addedSetup(t, "allowed_domains: [ws.example]\n")
	other := filepath.Join(filepath.Dir(ws.path), "other-link.yaml")
	writeThroughOtherLink(t, ws.path, other, "allowed_domains: [evil.example]\n")

	rewrite(t, rules, rules.base, conf.Log, rulesAllowing("new.example"))
	// evil.example is written through another link of the added rules; ws.example is as they were
	// taken up.
	wantDecisions(t, holder, "after the base reload", map[string]acl.DecisionResult{
		"new.example":  acl.Allow,
		"evil.example": acl.Deny,
		"ws.example":   acl.Allow,
	})
}

// An added file first made mid-session, with other hard links, is moved aside, leaving none, as
// none was taken up.
func TestNewAddedRulesWithOtherLinksAreMovedAside(t *testing.T) {
	conf, holder, rules, ws, hook := addedSetup(t, "")
	writeFile(t, ws.path, "allowed_domains: [evil.example]\n")
	if err := os.Link(ws.path, ws.path+".other"); err != nil {
		t.Fatal(err)
	}
	rules.applyIfChanged(conf.Log, ws)
	wantReloadFailure(t, hook, "leaving none", "the file moved aside, leaving none")
	if _, err := os.Stat(ws.path); err == nil {
		t.Fatal("the refused added file was left in place")
	}
	wantDecisions(t, holder, "", map[string]acl.DecisionResult{"evil.example": acl.Deny})
}

// The base rules' deny list holds against the hosts the added rules allow: unlike the base rules'
// own, the added ones can't make an exception to it.
func TestAddedRulesCantAllowWhatTheBaseDenies(t *testing.T) {
	base := rulesAllowing("base.example") + "global_deny_list:\n  - '*.telemetry.example'\n"
	basePath, addedPath := addedFiles(t, base, "allowed_domains:\n  - intake.telemetry.example\n  - '*.example'\n")
	_, holder, _, _ := setupWith(t, basePath, addedPath)
	wantDecisions(t, holder, "", map[string]acl.DecisionResult{
		"intake.telemetry.example": acl.Deny,
		"x.telemetry.example":      acl.Deny,
		"other.example":            acl.Allow,
		"base.example":             acl.Allow,
	})
}

// A refused edit to the added file doesn't hold up a base edit: the base file is taken up with the
// added one as last taken up.
func TestBrokenAddedRulesDontHoldUpTheBaseReload(t *testing.T) {
	conf, holder, rules, ws, hook := addedSetup(t, "allowed_domains: [ws.example]\n")
	rewrite(t, rules, ws, conf.Log, "allowed_domain: [typo.example]\n")
	reloadFailure(t, hook)

	rewrite(t, rules, rules.base, conf.Log, rulesAllowing("new.example"))
	reloaded(t, hook)
	wantDecisions(t, holder, "after the base reload", map[string]acl.DecisionResult{"new.example": acl.Allow, "ws.example": acl.Allow})

	rewrite(t, rules, ws, conf.Log, "allowed_domains: [fixed.example]\n")
	reloaded(t, hook)
	wantDecisions(t, holder, "once the added file is fixed", map[string]acl.DecisionResult{
		"new.example":   acl.Allow,
		"fixed.example": acl.Allow,
		"ws.example":    acl.Deny,
	})
}

func TestBaseReloadDoesNotRetryUnreadableAddedRules(t *testing.T) {
	skipIfRoot(t)
	basePath, addedPath := addedFiles(t, rulesWithoutDefault, "")
	conf, holder, rules, hook := setupWith(t, basePath, addedPath)
	rewrite(t, rules, rules.added, conf.Log, "allowed_domains: [ws.example]\n")
	wantReloadFailure(t, hook, "no default rule", "the added rules require a default rule")

	chmod(t, addedPath, 0)
	rewrite(t, rules, rules.base, conf.Log, rulesAllowing("base.example"))
	rules.applyIfChanged(conf.Log, rules.added)
	wantReloadFailure(t, hook, "permission denied", "the added rules are unreadable")
	wantDecisions(t, holder, "while the added rules are unreadable", map[string]acl.DecisionResult{
		"base.example": acl.Allow,
		"ws.example":   acl.Deny,
	})

	chmod(t, addedPath, 0o644)
	rules.applyIfChanged(conf.Log, rules.added)
	reloaded(t, hook)
	wantDecisions(t, holder, "after the added rules become readable", map[string]acl.DecisionResult{
		"ws.example": acl.Allow,
	})
}

func TestRestoringAccessToUnchangedWorkspaceRulesClearsWarning(t *testing.T) {
	skipIfRoot(t)
	basePath, addedPath := addedFiles(t, rulesAllowing("base.example"), "")
	parent := filepath.Join(filepath.Dir(addedPath), "workspace")
	if err := os.Mkdir(parent, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { chmod(t, parent, 0o700) })
	addedPath = filepath.Join(parent, "rules.yaml")
	writeFile(t, addedPath, "allowed_domains: [ws.example]\n")
	conf, holder, rules, hook := setupWith(t, basePath, addedPath)

	chmod(t, parent, 0)
	rules.applyIfChanged(conf.Log, rules.added)
	wantReloadFailure(t, hook, "permission denied", "the workspace rules are unreadable")

	hook.Reset()
	chmod(t, parent, 0o700)
	rules.applyIfChanged(conf.Log, rules.added)
	reloaded(t, hook)
	wantDecisions(t, holder, "after access is restored", map[string]acl.DecisionResult{"ws.example": acl.Allow})
	wantNoReload(t, rules, rules.added, conf.Log, hook, 1, "recovery is logged once")

	rewrite(t, rules, rules.added, conf.Log, "allowed_domains: [\n")
	reloadFailure(t, hook)
	chmod(t, parent, 0)
	rules.applyIfChanged(conf.Log, rules.added)
	wantReloadFailure(t, hook, "permission denied", "the refused edit is unreadable")

	hook.Reset()
	chmod(t, parent, 0o700)
	rules.applyIfChanged(conf.Log, rules.added)
	wantReloadFailure(t, hook, "added rules may only have", "the edit is still invalid")
	wantDecisions(t, holder, "after access to the refused edit is restored", map[string]acl.DecisionResult{"ws.example": acl.Allow})
}

// An edit refused for what the other file had is taken up once that file changes for it to fit:
// the added rules refused for the base's lacking a default rule are taken up with the base edit
// adding one, their reload logged after the base edit's.
func TestRefusedAddedRulesAreRetriedOnABaseEdit(t *testing.T) {
	basePath, addedPath := addedFiles(t, rulesWithoutDefault, "")
	conf, holder, rules, hook := setupWith(t, basePath, addedPath)
	writeFile(t, addedPath, "allowed_domains: [ws.example]\n")
	rules.applyIfChanged(conf.Log, rules.added)
	wantReloadFailure(t, hook, "no default rule", "the added rules refused for the base's lacking a default rule")

	hook.Reset()
	rewrite(t, rules, rules.base, conf.Log, rulesAllowing("base.example"))
	if len(hook.Entries) != 2 || hook.Entries[0].Data["rules"] != basePath ||
		hook.Entries[1].Data["rules"] != addedPath || hook.Entries[1].Message != rulesReloaded {
		t.Fatalf("want the base reload, then the added file's; got %+v", hook.Entries)
	}
	wantDecisions(t, holder, "after the base edit", map[string]acl.DecisionResult{"ws.example": acl.Allow, "base.example": acl.Allow})
}

// A broken added file, or one allowing GitHub, keeps the proxy from starting, as a broken base file
// does: every session of a workspace runs on what its others accept, for their reloads' banners to
// speak for them all. The refusal names the added file, for the user to know whose config to fix; a
// broken base file's names the base, whatever the added file holds.
func TestBrokenAddedRulesKeepTheProxyFromStarting(t *testing.T) {
	for name, tc := range map[string]struct {
		base, added string
		isAdded     bool
	}{
		"an unknown key":  {rulesAllowing("base.example"), "allowed_domain: [typo.example]\n", true},
		"github.com":      {rulesAllowing("base.example"), "allowed_domains: [github.com, ws.example]\n", true},
		"the base broken": {"version: v1\nservices: [\n", "allowed_domains: [ws.example]\n", false},
	} {
		t.Run(name, func(t *testing.T) {
			base, added := addedFiles(t, tc.base, tc.added)
			_, _, rules, _ := untakenSetup(t, base, added)
			err := rules.takeUpAtStart(func(error) {})
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

// Added rules opening GitHub hosts beyond those the base allows are refused naming the added file,
// even with the base's own refused -- the override taking both up, with a warning each -- and only
// for the hosts the added rules open.
func TestAddedRulesAllowingGitHubBeyondTheBase(t *testing.T) {
	base := []byte(rulesAllowing("github.com"))
	added := []byte("allowed_domains: [api.github.com]\n")
	_, refusals, err := loadRules(smokescreen.NewConfig(), "/rules.yaml", "/ws.yaml", base, added)
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, refusal := range refusals {
		got = append(got, refusal.Error())
	}
	if len(refusals) != 2 || refusals[0].path != "/rules.yaml" || !slices.Equal(refusals[0].allowed, []string{"github.com"}) ||
		refusals[1].path != "/ws.yaml" || !slices.Equal(refusals[1].allowed, []string{"api.github.com"}) {
		t.Errorf("got %q, want the base refused for github.com, and the added file for api.github.com alone", got)
	}
}

// A host on the added global_deny_list is denied, as a known denial, whatever allows it: the base's
// default rule and the added allowed_domains alike, which smokescreen would check first.
func TestAddedGlobalDenyListWinsOverAllows(t *testing.T) {
	_, holder, _, _, _ := addedSetup(t, "allowed_domains: [ws.example]\nglobal_deny_list: [base.example, ws.example]\n")
	wantGlobalDenied(t, holder, "base.example")
	wantGlobalDenied(t, holder, "ws.example")
}

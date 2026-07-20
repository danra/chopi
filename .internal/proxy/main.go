// chopi-smokescreen -- Stripe's smokescreen egress proxy, embedded as a library and
// extended to hot-reload the --egress-acl-file rules.
//
//   - Flags and log output are identical to the standalone smokescreen binary.
//   - The rules file is polled for changes, with a new valid rules set immediately
//     and atomically swapped in.

package main

import (
	"errors"
	"io/fs"
	"log"
	"net/http"
	"os"
	"strings"
	"sync/atomic"
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

func logRulesError(rulesLogEntry *logrus.Entry, err error) {
	rulesLogEntry.WithError(err).Error("egress ACL reload failed; keeping the previous rules")
}

func reloadIfChanged(conf *smokescreen.Config, holder *swappableACL, path string, lastMod time.Time, warned bool) (newLastMod time.Time, newWarned bool) {
	st, err := os.Stat(path)
	rulesLogEntry := conf.Log.WithField("rules", path)
	if err != nil {
		// A load failure keeps the previous rules.
		if errors.Is(err, fs.ErrNotExist) {
			// Ignore missing rules file: atomic-rename saves make it momentarily disappear,
			// and the edge-case of a genuinely deleted file once rules are already loaded is
			// also harmless.
			return lastMod, warned
		}
		// Warn on other errors (once, until rules become valid again)
		if !warned {
			logRulesError(rulesLogEntry, err)
		}
		return lastMod, true
	}
	if st.ModTime().Equal(lastMod) {
		return lastMod, false
	}
	rules, err := loadRules(conf, path)
	if err != nil {
		logRulesError(rulesLogEntry, err)
		return st.ModTime(), false
	}
	holder.current.Store(rules)
	rulesLogEntry.Info("egress ACL reloaded")
	return st.ModTime(), false
}

func watchRules(conf *smokescreen.Config, holder *swappableACL, path string, lastMod time.Time) {
	warned := false
	for range time.Tick(reloadPollInterval) {
		lastMod, warned = reloadIfChanged(conf, holder, path, lastMod, warned)
	}
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

func main() {
	path := egressACLPath(os.Args[1:])
	var lastMod time.Time
	if path != "" {
		if st, err := os.Stat(path); err == nil {
			lastMod = st.ModTime()
		}
	}

	conf, err := cmd.NewConfiguration(nil, nil)
	if err != nil {
		logrus.Fatalf("Could not create configuration: %v", err)
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
		conf.Log.Fatal("--egress-acl-file not found on the command line; chopi requires a hot-reloadable egress ACL")
	}

	rules, ok := conf.EgressACL.(*acl.ACL)
	if !ok {
		conf.Log.Fatal("expected NewConfiguration to have loaded the egress ACL")
	}
	holder := &swappableACL{}
	holder.current.Store(rules)
	conf.EgressACL = holder
	go watchRules(conf, holder, path, lastMod)

	smokescreen.StartWithConfig(conf, nil)
}

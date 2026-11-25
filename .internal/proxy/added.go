package main

// The rules: chopi's base rules (--rules), and a workspace's own (--add-rules), adding to them for
// the workspace's sessions alone, both of one format; and likewise a GitHub allowlist added to the
// base one (--add-github-allowlist). An added file may be missing, which adds nothing, and may
// appear, or go, mid-session: it is watched as the base ones are.

import (
	"fmt"

	"github.com/stripe/smokescreen/pkg/smokescreen"
	acl "github.com/stripe/smokescreen/pkg/smokescreen/acl/v1"
	"gopkg.in/yaml.v2"
)

// rulesConfig is all a rules file may hold, the base one and one added to it alike. Nothing in it
// can loosen how the proxy enforces: every file's hosts go on the one global allow list, beneath the
// one global deny list (newRules), so a file adding to the base widens only what the sessions given
// it reach, and narrows it as it pleases.
type rulesConfig struct {
	AllowedDomains []string `yaml:"allowed_domains"`
	GlobalDenyList []string `yaml:"global_deny_list"`
}

// parseRules parses content, the rules at path: none for nil content. A key other than
// rulesConfig's is refused, rather than silently ignored -- smokescreen's own format's included,
// which the rules no longer take -- as is a host that isn't one. Each refusal names the file and the
// list, for the user to know what to fix.
func parseRules(path string, content []byte) (rulesConfig, error) {
	var c rulesConfig
	if err := yaml.UnmarshalStrict(content, &c); err != nil {
		return c, fmt.Errorf("%s: %w (rules may only have allowed_domains and global_deny_list)", path, err)
	}
	for _, hosts := range []struct {
		list  string
		globs []string
	}{{"allowed_domains", c.AllowedDomains}, {"global_deny_list", c.GlobalDenyList}} {
		for _, glob := range hosts.globs {
			// smokescreen's own refusal names the list, given as its service, but for that of an
			// empty glob, which names nothing.
			if glob == "" {
				return c, fmt.Errorf("%s: %s: a host cannot be empty", path, hosts.list)
			}
			if err := (*acl.ACL)(nil).ValidateDomainGlob(hosts.list, glob); err != nil {
				return c, fmt.Errorf("%s: %w", path, err)
			}
		}
	}
	return c, nil
}

// newRules is the rules allowing allowed and denying deny, deny winning: smokescreen checks its global
// deny list before its global allow list, and the default rule, which chopi's requests have no
// role but go to, allows nothing of its own and enforces.
func newRules(conf *smokescreen.Config, allowed, deny []string) (*acl.ACL, error) {
	return acl.New(conf.Log, &acl.YAMLConfig{
		Version:         "v1",
		Services:        []acl.YAMLRule{},
		Default:         &acl.YAMLRule{Name: "default", Action: "enforce"},
		GlobalAllowList: allowed,
		GlobalDenyList:  deny,
	}, conf.DisabledAclPolicyActions)
}

// loadRules loads the rules from the contents of the base rules file, at basePath, and of the one
// added to it, at addedPath: nil content for one missing. The paths are for errors to name, each
// naming the file to fix. It returns too the rules' gitHubExfiltration refusals, for the caller to
// decide on, each naming a file allowing its hosts: every file allowing any is refused, for all of
// them to be fixed at once.
func loadRules(conf *smokescreen.Config, basePath, addedPath string, baseContent, addedContent []byte) (*acl.ACL, []*exfiltrationError, error) {
	type file struct {
		path   string
		config rulesConfig
	}
	var files []file
	var allowed, deny []string
	for _, f := range []struct {
		path    string
		content []byte
	}{{basePath, baseContent}, {addedPath, addedContent}} {
		c, err := parseRules(f.path, f.content)
		if err != nil {
			return nil, nil, err
		}
		files = append(files, file{f.path, c})
		allowed = append(allowed, c.AllowedDomains...)
		deny = append(deny, c.GlobalDenyList...)
	}
	rules, err := newRules(conf, allowed, deny)
	if err != nil {
		return nil, nil, err
	}
	// Each file allows a subset of what the files together allow, beneath the same deny list: when
	// they together allow no GitHub host, no file does, and one rule set is all it takes to know.
	if gitHubExfiltration(rules, "") == nil {
		return rules, nil, nil
	}
	var refusals []*exfiltrationError
	for _, f := range files {
		fileRules, err := newRules(conf, f.config.AllowedDomains, deny)
		if err != nil {
			return nil, nil, err
		}
		if e := gitHubExfiltration(fileRules, f.path); e != nil {
			refusals = append(refusals, e)
		}
	}
	return rules, refusals, nil
}

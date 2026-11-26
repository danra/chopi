package main

// The network config is chopi's base network.yaml (--network), plus a workspace's own
// (--add-network), which adds to it for the workspace's sessions alone. Each file names the hosts
// the proxy allows and denies, and the GitHub repos the relays credential.
//
// The added file may be missing, which adds nothing. It may also appear or go mid-session: the
// proxy watches it as it watches the base file.

import (
	"fmt"
	"regexp"

	"github.com/stripe/smokescreen/pkg/smokescreen"
	acl "github.com/stripe/smokescreen/pkg/smokescreen/acl/v1"
	"gopkg.in/yaml.v2"
)

// networkConfig is all a network config file may hold. Nothing in it can loosen how the proxy
// enforces the rules: every file's hosts go on one global allow list, and the one global deny list
// overrides it (newRules). So a file adding to the base config affects only the sessions given it:
// it can widen what they reach, and narrow it freely.
type networkConfig struct {
	AllowedDomains  []string `yaml:"allowed_domains"`
	GlobalDenyList  []string `yaml:"global_deny_list"`
	GitHubAllowlist []string `yaml:"github_allowlist"`
}

// networkKeys lists networkConfig's keys, for an error to say what a file may hold.
const networkKeys = "allowed_domains, global_deny_list and github_allowlist"

// allowlistEntry matches a GitHub allowlist entry: owner/repo, or owner/* for all the owner's
// repos. github-relays-caddyfile.sh's is_allowlist_entry, which renders the relays from the
// entries, checks the same. It is a sanity check that keeps a config value safe, and doesn't
// follow GitHub's actual naming rules.
var allowlistEntry = regexp.MustCompile(`^[A-Za-z0-9._-]+/([A-Za-z0-9._-]+|\*)$`)

// parseNetwork parses content, the network config at path. Nil content is an empty config.
//
// It refuses a key networkConfig lacks, rather than silently ignoring it. It also refuses an
// invalid host or GitHub allowlist entry. Each refusal names the file and the list, so the user
// knows what to fix.
func parseNetwork(path string, content []byte) (networkConfig, error) {
	var c networkConfig
	if err := yaml.UnmarshalStrict(content, &c); err != nil {
		return c, fmt.Errorf("%s: %w (a network config may only have %s)", path, err, networkKeys)
	}
	for _, hosts := range []struct {
		list  string
		globs []string
	}{{"allowed_domains", c.AllowedDomains}, {"global_deny_list", c.GlobalDenyList}} {
		for _, glob := range hosts.globs {
			// smokescreen's own refusal names the list, passed as its service. Its refusal of an
			// empty glob names nothing, so refuse that here.
			if glob == "" {
				return c, fmt.Errorf("%s: %s: a host cannot be empty", path, hosts.list)
			}
			if err := (*acl.ACL)(nil).ValidateDomainGlob(hosts.list, glob); err != nil {
				return c, fmt.Errorf("%s: %w", path, err)
			}
		}
	}
	for _, entry := range c.GitHubAllowlist {
		if !allowlistEntry.MatchString(entry) {
			return c, fmt.Errorf("%s: github_allowlist: %q needs owner/repo or owner/*, using only A-Za-z0-9._-", path, entry)
		}
	}
	return c, nil
}

// newRules returns the rules allowing allowed and denying deny, with deny winning: smokescreen
// checks its global deny list before its global allow list. chopi's requests have no role, so they
// go to the default rule, which allows nothing of its own and enforces.
func newRules(conf *smokescreen.Config, allowed, deny []string) (*acl.ACL, error) {
	return acl.New(conf.Log, &acl.YAMLConfig{
		Version:         "v1",
		Services:        []acl.YAMLRule{},
		Default:         &acl.YAMLRule{Name: "default", Action: "enforce"},
		GlobalAllowList: allowed,
		GlobalDenyList:  deny,
	}, conf.DisabledAclPolicyActions)
}

// configContent is a network config file's content, with its path for errors to name. content is
// nil for a missing added file. config is the parsed content (parseNetwork), parsed as it is read,
// and err is parseNetwork's refusal.
type configContent struct {
	path    string
	content []byte
	config  networkConfig
	err     error
}

// newConfigContent parses content, the content of the network config file at path.
func newConfigContent(path string, content []byte) configContent {
	c, err := parseNetwork(path, content)
	return configContent{path: path, content: content, config: c, err: err}
}

// network is the config taken up from the network config files: the rules, the GitHub allowlist
// the relays are rendered from, and the rules' gitHubExfiltration refusals, for the caller to
// decide on. The allowlist joins every file's entries, in order.
type network struct {
	rules        *acl.ACL
	exfiltration []*exfiltrationError
	allowlist    []string
}

// loadNetwork loads the network config from the parsed contents of its files, the base file first.
//
// Each gitHubExfiltration refusal names a file that allows the refused hosts. loadNetwork refuses
// every file that allows any, so the user can fix them all at once.
func loadNetwork(conf *smokescreen.Config, files []configContent) (*network, error) {
	var allowed, deny []string
	n := &network{}
	for _, f := range files {
		if f.err != nil {
			return nil, f.err
		}
		allowed = append(allowed, f.config.AllowedDomains...)
		deny = append(deny, f.config.GlobalDenyList...)
		n.allowlist = append(n.allowlist, f.config.GitHubAllowlist...)
	}
	rules, err := newRules(conf, allowed, deny)
	if err != nil {
		return nil, err
	}
	n.rules = rules
	// If the files together allow no GitHub host, no file alone does, so there is no file to name.
	if gitHubExfiltration(rules, "") == nil {
		return n, nil
	}
	for _, f := range files {
		rules, err := newRules(conf, f.config.AllowedDomains, deny)
		if err != nil {
			return nil, err
		}
		if e := gitHubExfiltration(rules, f.path); e != nil {
			n.exfiltration = append(n.exfiltration, e)
		}
	}
	return n, nil
}

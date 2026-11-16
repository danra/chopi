package main

// Added config: proxy rules that add to the base ones, the --add-rules -- chopi's for a workspace's
// own, for its sessions alone. The file may be missing, which adds nothing, and may
// appear, or go, mid-session: it is watched as the base ones are.

import (
	"fmt"
	"slices"

	"github.com/stripe/smokescreen/pkg/smokescreen"
	acl "github.com/stripe/smokescreen/pkg/smokescreen/acl/v1"
	"gopkg.in/yaml.v2"
)

// addedRules is all an added rules file may hold: hosts added to the base rules' global allow list,
// and hosts to deny whatever allows them (ruleSet). Nothing in it can loosen how the base enforces --
// smokescreen checks the allow list beneath the deny lists, and only for a service with a rule -- so
// added rules widen only what the sessions given them reach, and narrow it as they please.
type addedRules struct {
	AllowedDomains []string `yaml:"allowed_domains"`
	GlobalDenyList []string `yaml:"global_deny_list"`
}

// parseAddedRules parses content, the added rules at path: none for nil content. A key other than
// addedRules' is refused, rather than silently ignored.
func parseAddedRules(path string, content []byte) (addedRules, error) {
	var rules addedRules
	if err := yaml.UnmarshalStrict(content, &rules); err != nil {
		return rules, fmt.Errorf("%s: %w (added rules may only have allowed_domains and global_deny_list)", path, err)
	}
	return rules, nil
}

// ruleSet is the rules taken up: the base rules, the added allowed_domains on their global allow
// list, and the added global_deny_list, deny. smokescreen checks a global deny list only beneath a
// rule's own allowed_domains, so a host the base allows would pass it: deny is checked after them
// instead, a host on it denied whatever allows it, as a workspace denying a host means to.
type ruleSet struct {
	*acl.ACL
	deny []string
}

// knownDenyReason is smokescreen's reason for a host on the global deny list, which the log's
// formatter takes for a denial the user listed (.internal/known-deny.jq): one on deny is the same.
const knownDenyReason = "host matched rule in global deny list"

func (r *ruleSet) Decide(args acl.DecideArgs) (acl.Decision, error) {
	d, err := r.ACL.Decide(args)
	if err == nil && slices.ContainsFunc(r.deny, func(glob string) bool { return acl.HostMatchesGlob(args.Host, glob) }) {
		d.Result, d.Reason, d.MitmConfig = acl.Deny, knownDenyReason, nil
	}
	return d, err
}

// yamlRules loads rules from their YAML content, as smokescreen's acl.YAMLLoader does from a file.
type yamlRules []byte

func (content yamlRules) Load() (*acl.ACL, error) {
	var config acl.YAMLConfig
	if err := yaml.Unmarshal(content, &config); err != nil {
		return nil, err
	}
	if config.Version != "v1" {
		return nil, fmt.Errorf("expected version \"v1\" got %#v", config.Version)
	}
	return config.Load()
}

// loadRules loads the rules from the contents of the base rules file, at basePath, and of the one
// added to it, at addedPath, if any: nil content for one missing -- as smokescreen would, with conf.
// The paths are for errors to name, each naming the file to fix. It returns too the rules'
// gitHubExfiltration refusals, for the caller to decide on: the base rules', if any, then that of
// the GitHub hosts the added ones allow beyond them, if any, naming the added file.
func loadRules(conf *smokescreen.Config, basePath, addedPath string, baseContent, addedContent []byte) (*ruleSet, []*exfiltrationError, error) {
	base, err := acl.New(conf.Log, yamlRules(baseContent), conf.DisabledAclPolicyActions)
	if err != nil {
		return nil, nil, fmt.Errorf("%s: %w", basePath, err)
	}
	added, err := parseAddedRules(addedPath, addedContent)
	if err != nil {
		return nil, nil, err
	}
	for _, glob := range slices.Concat(added.AllowedDomains, added.GlobalDenyList) {
		if err := base.ValidateDomainGlob(addedPath, glob); err != nil {
			return nil, nil, err
		}
	}
	// chopi's requests have no role, so smokescreen takes them to the default rule: without one, it
	// denies them before the allow list could allow the added hosts.
	if len(added.AllowedDomains) > 0 && base.DefaultRule == nil {
		return nil, nil, fmt.Errorf("%s: no default rule in %s for its allowed_domains to add to", addedPath, basePath)
	}
	rules := &ruleSet{ACL: base}
	var refusals []*exfiltrationError
	baseRefusal := gitHubExfiltration(rules, basePath)
	if baseRefusal != nil {
		refusals = append(refusals, baseRefusal)
	}
	rules.deny = added.GlobalDenyList
	if len(added.AllowedDomains) == 0 {
		// The added deny list only narrows what the base allows: no GitHub host beyond its refusal.
		return rules, refusals, nil
	}
	base.GlobalAllowList = append(base.GlobalAllowList, added.AllowedDomains...)
	if all := gitHubExfiltration(rules, addedPath); all != nil {
		if baseRefusal != nil {
			all.allowed = slices.DeleteFunc(all.allowed, func(host string) bool {
				return slices.Contains(baseRefusal.allowed, host)
			})
		}
		if len(all.allowed) > 0 {
			refusals = append(refusals, all)
		}
	}
	return rules, refusals, nil
}

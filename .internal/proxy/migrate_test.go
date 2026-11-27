package main

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// oldSmokescreenRules is proxy rules in smokescreen's format, laid out as chopi's template for them
// was, with hosts the user added.
const oldSmokescreenRules = `# Smokescreen proxy rules: allowlist + known denylist
version: v1

services: []

default:
  name: default
  action: enforce
  allowed_domains:
    - api.anthropic.com

    # *INTENTIONALLY NOT ALLOWED* to prevent trivial exfiltration
    # - github.com

    - pypi.org
    # mine
    - example.com

# Hosts listed here are refused like any other non-allowed host
global_deny_list:
    # Claude Code telemetry destination
    - "*.datadoghq.com"
    - github.com
`

// oldAllowlist is a GitHub allowlist laid out as chopi's template for it was, with entries the user
// added.
const oldAllowlist = `# chopi GitHub allowlist
#
# Examples (uncomment / edit):
# owner/*
# owner/repo
acme/*
# work
foo/bar  # why
`

func readTemplate(t *testing.T) (string, networkTemplate) {
	t.Helper()
	template := readFile(t, networkTemplatePath)
	tmpl, err := splitTemplate(template)
	if err != nil {
		t.Fatal(err)
	}
	return template, tmpl
}

func TestMigrateNetwork(t *testing.T) {
	template, tmpl := readTemplate(t)
	got, err := migrateNetwork(template, &oldFile{"rules", oldSmokescreenRules}, oldAllowlist)
	if err != nil {
		t.Fatal(err)
	}
	want := tmpl.header + `

allowed_domains:
  - api.anthropic.com

  # *INTENTIONALLY NOT ALLOWED* to prevent trivial exfiltration
  # - github.com

  - pypi.org
  # mine
  - example.com

# Hosts listed here are refused like any other non-allowed host
global_deny_list:
    # Claude Code telemetry destination
    - "*.datadoghq.com"
    - github.com

` + tmpl.comments + `github_allowlist:
  - acme/*
  # work
  - foo/bar  # why
`
	if got != want {
		t.Fatalf("got:\n%s\nwant:\n%s", got, want)
	}
}

func TestMigrateNetworkLayouts(t *testing.T) {
	template, tmpl := readTemplate(t)
	for name, tc := range map[string]struct {
		rules   string
		allowed []string
	}{
		"rules already in the network config's format": {
			rules:   "# chopi proxy rules\nallowed_domains:\n  - a.example\nglobal_deny_list: [d.example]\n",
			allowed: []string{"a.example"},
		},
		"sequences at their key's indent": {
			rules:   "version: v1\nservices: []\ndefault:\n  action: enforce\n  allowed_domains:\n  - a.example\n  - b.example\nglobal_deny_list:\n- d.example\n",
			allowed: []string{"a.example", "b.example"},
		},
		"non-empty services, which never applied": {
			rules:   "version: v1\nservices:\n  - name: x\n    action: enforce\n    allowed_domains: [s.example]\ndefault:\n  action: enforce\n  allowed_domains: [a.example]\n",
			allowed: []string{"a.example"},
		},
	} {
		t.Run(name, func(t *testing.T) {
			got, err := migrateNetwork(template, &oldFile{"rules", tc.rules}, "")
			if err != nil {
				t.Fatal(err)
			}
			c, err := parseNetwork("got", []byte(got))
			if err != nil {
				t.Fatal(err)
			}
			if !slices.Equal(c.AllowedDomains, tc.allowed) {
				t.Fatalf("allowed_domains %q, want %q", c.AllowedDomains, tc.allowed)
			}
			// No allowlist entries: the template's section, examples and all.
			if !strings.HasSuffix(got, tmpl.comments+tmpl.github) {
				t.Fatalf("want the template's github_allowlist section:\n%s", got)
			}
		})
	}
}

func TestRewriteRulesKeepsTrailingComments(t *testing.T) {
	for name, tc := range map[string]struct{ rules, want string }{
		"in global_deny_list": {
			rules: "global_deny_list:\n  - d.example\n  # - e.example  (later)\n",
			want:  "global_deny_list:\n  - d.example\n  # - e.example  (later)",
		},
		"in the default rule, and at the top level": {
			rules: "version: v1\nservices: []\ndefault:\n  action: enforce\n  allowed_domains:\n" +
				"    - a.example\n    # - b.example  (later)\n# end\n",
			want: "allowed_domains:\n  - a.example\n  # - b.example  (later)\n# end",
		},
	} {
		t.Run(name, func(t *testing.T) {
			if got := rewriteRules(tc.rules); got != tc.want {
				t.Fatalf("got:\n%s\nwant:\n%s", got, tc.want)
			}
		})
	}
}

func TestMigrateNetworkWithoutRules(t *testing.T) {
	template, tmpl := readTemplate(t)
	got, err := migrateNetwork(template, nil, "acme/*\n")
	if err != nil {
		t.Fatal(err)
	}
	if want := tmpl.hosts + tmpl.comments + "github_allowlist:\n  - acme/*\n"; got != want {
		t.Fatalf("got:\n%s\nwant:\n%s", got, want)
	}
}

func TestMigrateNetworkRefusals(t *testing.T) {
	template, _ := readTemplate(t)
	// v1 is smokescreen rules with no services, and rest.
	v1 := func(rest string) string { return "version: v1\nservices: []\n" + rest }
	// ruleFor is a default rule allowing allowed.
	ruleFor := func(allowed string) string {
		return "default:\n  action: enforce\n  allowed_domains: [" + allowed + "]\n"
	}
	rule := ruleFor("a.example")
	// overlap is smokescreen rules whose default rule allows allowed, and whose deny list has denied.
	overlap := func(allowed, denied string) string {
		return v1(ruleFor(allowed) + "global_deny_list: [" + denied + "]\n")
	}
	for name, tc := range map[string]struct{ rules, allowlist, want string }{
		"an open default rule": {
			rules: v1("default:\n  action: open\n  allowed_domains: [a.example]\n"), want: `action is "open"`,
		},
		"a key the network config has no place for": {
			rules: "global_allow_list: [a.example]\n", want: "global_allow_list",
		},
		"a default rule key the network config has no place for": {
			rules: v1("default:\n  allowed_ips: [10.0.0.1]\n"), want: "allowed_ips",
		},
		// The rewrite drops a default rule on one line whole, so the check catches the lost host.
		"a default rule in flow style": {
			rules: v1("default: {action: enforce, allowed_domains: [a.example]}\n"), want: "the migrated allowed_domains",
		},
		// smokescreen checks the default rule's hosts before the global deny list, and the network
		// config's hosts after it, so a host on both would go from allowed to denied.
		"a default rule host the deny list also has": {
			rules: overlap("a.example", "a.example"), want: `"a.example"`,
		},
		"a default rule host under a wildcard of the deny list": {
			rules: overlap("a.b.example", "'*.b.example'"), want: `"*.b.example"`,
		},
		"a default rule wildcard over a host of the deny list": {
			rules: overlap("'*.example'", "a.b.example"), want: `"a.b.example"`,
		},
		"a default rule wildcard under a wildcard of the deny list": {
			rules: overlap("'*.b.example'", "'*.example'"), want: `"*.example"`,
		},
		// chopi's requests have no role, and smokescreen files a service with no name under the
		// empty role, so such a service, not the default rule, decided them.
		"a service with no name": {
			rules: "version: v1\nservices:\n- action: enforce\n  allowed_domains: [s.example]\n" + rule,
			want:  "no name",
		},
		"a service with an empty name": {
			rules: "version: v1\nservices:\n- name: ''\n  action: enforce\n  allowed_domains: [s.example]\n" + rule,
			want:  "no name",
		},
		// smokescreen's loader has no top-level allowed_domains, so it never allowed those hosts.
		"allowed_domains at the top level of smokescreen's format": {
			rules: v1("default:\n  action: enforce\nallowed_domains: [a.example]\n"),
			want:  "allowed_domains",
		},
		// smokescreen's loader refused rules with no version, or another than v1, or no services,
		// so chopi's proxy didn't start, and allowed nothing.
		"a default rule with no version": {
			rules: rule, want: "no version",
		},
		"services with no version": {
			rules: "services: []\nallowed_domains: [a.example]\n", want: "no version",
		},
		"a version other than v1": {
			rules: "version: v2\nservices: []\n" + rule, want: `"v2"`,
		},
		"a default rule with no action": {
			rules: v1("default:\n  allowed_domains: [a.example]\n"), want: "unknown action",
		},
		"no services": {
			rules: "version: v1\n" + rule, want: "services",
		},
		"a github_allowlist in the rules": {
			rules: "allowed_domains: [a.example]\ngithub_allowlist: [acme/*]\n", want: "github_allowlist",
		},
		"an invalid allowlist entry": {
			rules: "allowed_domains: [a.example]\n", allowlist: "not an entry\n", want: "github_allowlist",
		},
	} {
		t.Run(name, func(t *testing.T) {
			got, err := migrateNetwork(template, &oldFile{"rules", tc.rules}, tc.allowlist)
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("want a refusal containing %q, got %v:\n%s", tc.want, err, got)
			}
		})
	}
}

// The network config takes the permissions the old files share, so one the user kept private stays
// private.
func TestMigrateNetworkFilesKeepsTheOldFilesPermissions(t *testing.T) {
	for name, tc := range map[string]struct{ rules, allowlist, want fs.FileMode }{
		"both readable by all": {0o644, 0o644, 0o644},
		"a private allowlist":  {0o644, 0o600, 0o600},
		"private proxy rules":  {0o600, 0o644, 0o600},
	} {
		t.Run(name, func(t *testing.T) {
			dir := realTempDir(t)
			rules, allowlist := filepath.Join(dir, "rules"), filepath.Join(dir, "allowlist")
			writeFile(t, rules, "allowed_domains: [a.example]\n")
			chmod(t, rules, tc.rules)
			writeFile(t, allowlist, "acme/*\n")
			chmod(t, allowlist, tc.allowlist)
			out := filepath.Join(dir, "network.yaml")
			if err := migrateNetworkFiles(networkTemplatePath, rules, allowlist, out); err != nil {
				t.Fatal(err)
			}
			st, err := os.Stat(out)
			if err != nil {
				t.Fatal(err)
			}
			if got := st.Mode().Perm(); got != tc.want {
				t.Fatalf("mode %v, want %v", got, tc.want)
			}
		})
	}
}

// The installer names both old files, and either may be missing.
func TestMigrateNetworkFilesSkipsAMissingOldFile(t *testing.T) {
	dir := realTempDir(t)
	rules := filepath.Join(dir, "rules")
	writeFile(t, rules, "allowed_domains: [a.example]\n")
	out := filepath.Join(dir, "network.yaml")
	if err := migrateNetworkFiles(networkTemplatePath, rules, filepath.Join(dir, "allowlist"), out); err != nil {
		t.Fatal(err)
	}
	got, err := parseNetwork(out, []byte(readFile(t, out)))
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(got.AllowedDomains, []string{"a.example"}) || len(got.GitHubAllowlist) != 0 {
		t.Fatalf("got %+v", got)
	}
}

// The proxy refuses a config file with other hard links, which a sandboxed command may have written
// through, so the migration doesn't carry one's content into a network config it would take.
func TestMigrateNetworkFilesRefusesAHardLinkedOldFile(t *testing.T) {
	for _, old := range []string{"rules", "allowlist"} {
		t.Run(old, func(t *testing.T) {
			dir := realTempDir(t)
			rules, allowlist := filepath.Join(dir, "rules"), filepath.Join(dir, "allowlist")
			writeFile(t, rules, "allowed_domains: [a.example]\n")
			writeFile(t, allowlist, "acme/*\n")
			if err := os.Link(filepath.Join(dir, old), filepath.Join(dir, "link")); err != nil {
				t.Fatal(err)
			}
			out := filepath.Join(dir, "network.yaml")
			err := migrateNetworkFiles(networkTemplatePath, rules, allowlist, out)
			if err == nil || !strings.Contains(err.Error(), "hard links") {
				t.Fatalf("got %v, want a refusal naming the hard links", err)
			}
			if _, err := os.Stat(out); !errors.Is(err, fs.ErrNotExist) {
				t.Fatalf("want no network config, got %v", err)
			}
		})
	}
}

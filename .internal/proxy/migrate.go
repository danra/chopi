package main

// migrate-network moves chopi's own proxy rules (config/proxy-rules.yaml) and GitHub allowlist
// (config/github-allowlist), which the network config replaced, into a network config:
//
//	chopi-smokescreen migrate-network --template FILE [--rules FILE] [--allowlist FILE] --out FILE
//
// It takes whichever of the two files is there, and writes the network config to --out, whole or
// not at all. The installer runs it (migrate_legacy_network_files).
//
// The rules may be in smokescreen's format, which chopi took until it built the rules itself, or
// already in the network config's. The new file keeps the rules' comments: it rewrites the rules
// line by line rather than re-encoding what it parses. Then it parses both, and refuses unless the
// new file allows and denies the same as the old rules, and credentials the entries the old
// allowlist held. So a layout the rewrite doesn't foresee fails, and the user moves the files by
// hand, rather than losing a host.
//
// The header and the github_allowlist comments come from the network config template --template.
// Without the proxy rules, the hosts are the template's.

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"slices"
	"strings"

	"github.com/sirupsen/logrus"
	acl "github.com/stripe/smokescreen/pkg/smokescreen/acl/v1"
	"gopkg.in/yaml.v2"
)

// migrateNetworkCommand is the argument that runs migrate-network instead of the proxy.
const migrateNetworkCommand = "migrate-network"

// runMigrateNetwork runs migrate-network on args, the arguments after its name. It returns the exit
// code.
func runMigrateNetwork(args []string, stderr io.Writer) int {
	flags := flag.NewFlagSet(migrateNetworkCommand, flag.ContinueOnError)
	flags.SetOutput(stderr)
	template := flags.String("template", "", "the network config template")
	rules := flags.String("rules", "", "the old proxy rules, if any")
	allowlist := flags.String("allowlist", "", "the old GitHub allowlist, if any")
	out := flags.String("out", "", "the network config to write")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	if *template == "" || *out == "" || flags.NArg() != 0 {
		fmt.Fprintln(stderr, "usage: chopi-smokescreen migrate-network --template FILE [--rules FILE] [--allowlist FILE] --out FILE")
		return 2
	}
	if err := migrateNetworkFiles(*template, *rules, *allowlist, *out); err != nil {
		fmt.Fprintln(stderr, "chopi-smokescreen: can't migrate:", err)
		return 1
	}
	return 0
}

// migrateNetworkFiles writes the network config migrated from the template at templatePath and
// the old files at rulesPath and allowlistPath, each skipped if "" or missing, to out. It refuses an
// old file with other hard links, as the proxy does its config files (readChecked). It takes the
// permissions the old files share, up to 0644, so one the user kept private stays private.
func migrateNetworkFiles(templatePath, rulesPath, allowlistPath, out string) error {
	template, err := os.ReadFile(templatePath)
	if err != nil {
		return err
	}
	perm := fs.FileMode(0o644)
	// readOld returns the old file at path, or nil if there is none.
	readOld := func(path string) (*oldFile, error) {
		if path == "" {
			return nil, nil
		}
		text, st, err := (&configFile{path: path}).readChecked()
		if errors.Is(err, fs.ErrNotExist) {
			return nil, nil
		}
		if err != nil {
			return nil, err
		}
		perm &= st.Mode().Perm()
		return &oldFile{path, string(text)}, nil
	}
	rules, err := readOld(rulesPath)
	if err != nil {
		return err
	}
	allowlist, err := readOld(allowlistPath)
	if err != nil {
		return err
	}
	var allowlistText string
	if allowlist != nil {
		allowlistText = allowlist.text
	}
	migrated, err := migrateNetwork(string(template), rules, allowlistText)
	if err != nil {
		return err
	}
	return writeAtomically(out, migrated, perm)
}

// oldFile is an old file, the proxy rules or the GitHub allowlist: its path, for errors to name,
// and its text.
type oldFile struct{ path, text string }

// migrateNetwork returns the network config holding the proxy rules rules, nil if there are none,
// and the GitHub allowlist allowlist, from the network config template template. With no rules, it
// takes the template's hosts; with no allowlist entries, the template's github_allowlist section.
func migrateNetwork(template string, rules *oldFile, allowlist string) (string, error) {
	tmpl, err := splitTemplate(template)
	if err != nil {
		return "", err
	}
	// The check below: the new file must allow, deny and credential exactly what the old ones did.
	// Without rules, the hosts are the template's own lines, unchanged, so only the rewritten rules
	// need their hosts checked.
	section, entries := allowlistSection(tmpl, allowlist)
	hosts := tmpl.hosts
	var allowed, denied []string
	if rules != nil {
		if allowed, denied, err = parseOldRules(rules.text); err != nil {
			return "", fmt.Errorf("%s: %w", rules.path, err)
		}
		hosts = tmpl.header + "\n\n" + rewriteRules(rules.text) + "\n\n"
	}
	out := collapseBlankLines(hosts + section)

	got, err := parseNetwork("the migrated network config", []byte(out))
	if err != nil {
		return "", err
	}
	check := func(name string, got, want []string) error {
		if slices.Equal(got, want) {
			return nil
		}
		return fmt.Errorf("the migrated %s would be %q, not %q", name, got, want)
	}
	err = check("github_allowlist", got.GitHubAllowlist, entries)
	if rules != nil {
		err = errors.Join(err, check("allowed_domains", got.AllowedDomains, allowed),
			check("global_deny_list", got.GlobalDenyList, denied))
	}
	if err != nil {
		return "", err
	}
	return out, nil
}

// networkTemplate is the parts of the network config template the migration takes.
type networkTemplate struct {
	header   string // the leading comments
	hosts    string // everything before the github_allowlist comments
	comments string // the comments right before github_allowlist
	github   string // from github_allowlist on: the key and its examples
}

func splitTemplate(text string) (networkTemplate, error) {
	lines := strings.SplitAfter(text, "\n")
	key := slices.IndexFunc(lines, func(l string) bool { return strings.HasPrefix(l, "github_allowlist:") })
	if key < 0 {
		return networkTemplate{}, errors.New("the template has no github_allowlist")
	}
	start := key
	for start > 0 && isComment(lines[start-1]) {
		start--
	}
	end := slices.IndexFunc(lines, func(l string) bool { return !isComment(l) })
	if end < 0 {
		end = len(lines)
	}
	return networkTemplate{
		header:   strings.TrimRight(strings.Join(lines[:end], ""), "\n"),
		hosts:    strings.Join(lines[:start], ""),
		comments: strings.Join(lines[start:key], ""),
		github:   strings.Join(lines[key:], ""),
	}, nil
}

// rewriteRules returns the proxy rules text in the network config's format, its comments kept but
// for the leading ones, the header, which the template's replaces. It takes the hosts from
// smokescreen's default rule up to the top level, and drops every other key. parseOldRules refuses
// rules where those held something chopi applied, and keys it doesn't know.
func rewriteRules(text string) string {
	lines := strings.Split(strings.TrimRight(text, "\n"), "\n")
	// Skip the header.
	for len(lines) > 0 && isBlankOrComment(lines[0]) {
		lines = lines[1:]
	}
	var out, pending []string // pending: comment and blank lines, which go with the next line
	inDefault, keep, childIndent := false, false, -1
	flush := func() {
		// Comments at the top level stay whatever follows them; indented ones go with the line.
		for _, p := range pending {
			if keep || !strings.HasPrefix(p, " ") {
				out = append(out, dedentLine(p, max(childIndent, 0)))
			}
		}
		pending = nil
	}
	for _, line := range lines {
		if isBlankOrComment(line) {
			pending = append(pending, line)
			continue
		}
		trimmed := strings.TrimSpace(line)
		indent := leadingSpaces(line)
		key, _, _ := strings.Cut(trimmed, ":")
		// A sequence item may sit at its key's own indent.
		item := strings.HasPrefix(trimmed, "-")
		switch {
		case indent == 0 && !item:
			inDefault, childIndent = key == "default", -1
			keep = key == "allowed_domains" || key == "global_deny_list"
		case inDefault:
			if childIndent < 0 {
				childIndent = indent
			}
			if indent == childIndent && !item {
				keep = key == "allowed_domains"
			}
		}
		flush()
		if keep {
			out = append(out, dedentLine(line, max(childIndent, 0)))
		}
	}
	// The trailing ones, with the section they end.
	flush()
	return strings.Join(out, "\n")
}

// dedentLine takes up to n leading spaces off line.
func dedentLine(line string, n int) string {
	return line[min(n, leadingSpaces(line)):]
}

func leadingSpaces(line string) int {
	return len(line) - len(strings.TrimLeft(line, " "))
}

// allowlistSection returns the network config's github_allowlist section holding the entries of
// the GitHub allowlist allowlist, with the template's comments, and those entries, as the relays
// took them: each line, its comment and surrounding whitespace dropped, unless that leaves it
// empty. Comments after the first entry stay, those on an entry's line included. Those before it,
// the old template's header and examples, go. An allowlist with no entries gives the template's
// section, with its examples.
func allowlistSection(tmpl networkTemplate, allowlist string) (section string, entries []string) {
	var items []string
	for _, line := range strings.Split(allowlist, "\n") {
		entry, comment, hasComment := strings.Cut(line, "#")
		entry = strings.TrimSpace(entry)
		if entry == "" && len(items) == 0 {
			continue
		}
		item := "  "
		if entry != "" {
			entries = append(entries, entry)
			item += "- " + entry + "  "
		}
		if hasComment {
			item += "#" + comment
		}
		items = append(items, strings.TrimRight(item, " "))
	}
	if len(items) == 0 {
		return tmpl.comments + tmpl.github, nil
	}
	return tmpl.comments + "github_allowlist:\n" + strings.Join(items, "\n") + "\n", entries
}

// smokescreenRules is the old proxy rules in smokescreen's format, which its loader took with
// version v1 and services, if empty, and nothing else. chopi's requests, having no role, went to
// the default rule, so named services never applied. One with no name did: smokescreen files it
// under the empty role, ahead of the default rule.
type smokescreenRules struct {
	Version  string `yaml:"version"`
	Services []struct {
		Name string                 `yaml:"name"`
		Rest map[string]interface{} `yaml:",inline"`
	} `yaml:"services"`
	// Not smokescreen's acl.YAMLRule, so that the strict parse refuses its keys the network config
	// can't express, such as mitm_domains.
	Default struct {
		Name           string   `yaml:"name"`
		Project        string   `yaml:"project"`
		Action         string   `yaml:"action"`
		AllowedDomains []string `yaml:"allowed_domains"`
	} `yaml:"default"`
	GlobalDenyList []string `yaml:"global_deny_list"`
}

// parseOldRules returns the hosts the old proxy rules text allows and denies: in smokescreen's
// format if it has a version, or else the network config's, without github_allowlist. It refuses
// rules smokescreen's loader refused, as they allowed nothing, and those the network config can't
// express: a default rule that doesn't enforce, or allows a host the deny list also matches.
func parseOldRules(text string) (allowed, deny []string, err error) {
	var version struct {
		Version *string `yaml:"version"`
	}
	if err := yaml.Unmarshal([]byte(text), &version); err != nil {
		return nil, nil, err
	}
	if version.Version == nil {
		r, err := parseNetwork("with no version, which smokescreen's format needs, the rules are in the network config's format", []byte(text))
		if err != nil {
			return nil, nil, err
		}
		if len(r.GitHubAllowlist) > 0 {
			return nil, nil, errors.New("the rules have a github_allowlist, which went in the GitHub allowlist file")
		}
		return r.AllowedDomains, r.GlobalDenyList, nil
	}
	var r smokescreenRules
	if err := yaml.UnmarshalStrict([]byte(text), &r); err != nil {
		return nil, nil, fmt.Errorf("with a version, the rules are in smokescreen's format: %w", err)
	}
	if r.Version != "v1" {
		return nil, nil, fmt.Errorf("version %q, which smokescreen refused: it takes v1", r.Version)
	}
	// Rules smokescreen's loader refused, chopi's proxy didn't start with, so they allowed nothing.
	var cfg acl.YAMLConfig
	if err := yaml.Unmarshal([]byte(text), &cfg); err != nil {
		return nil, nil, err
	}
	quiet := logrus.New()
	quiet.SetOutput(io.Discard)
	if _, err := acl.New(quiet, &cfg, nil); err != nil {
		return nil, nil, fmt.Errorf("smokescreen refused these rules, so chopi's proxy didn't start with them: %w", err)
	}
	if r.Default.Action != "" && r.Default.Action != "enforce" {
		return nil, nil, fmt.Errorf("the default rule's action is %q; the network config always enforces", r.Default.Action)
	}
	for _, s := range r.Services {
		if s.Name == "" {
			return nil, nil, errors.New("a service has no name, so it applied instead of the default rule; the network config has no services")
		}
	}
	// smokescreen checks the default rule's hosts before the global deny list, but the
	// network config's after it (newRules), so such a host would go from allowed to denied.
	for _, a := range r.Default.AllowedDomains {
		for _, d := range r.GlobalDenyList {
			if globsOverlap(a, d) {
				return nil, nil, fmt.Errorf("the default rule allows %q, which global_deny_list's %q matches too; in the network config the deny list wins, so drop one of them first", a, d)
			}
		}
	}
	return r.Default.AllowedDomains, r.GlobalDenyList, nil
}

// globsOverlap reports whether some host matches both smokescreen domain globs a and b. A glob
// is a host, matching itself, or *.host, matching the host's subdomains. If any host matches
// both, then one glob's own host does, or for two wildcards, a subdomain of the narrower one's.
func globsOverlap(a, b string) bool {
	sample := func(glob string) string {
		if domain, ok := strings.CutPrefix(glob, "*."); ok {
			return "x." + domain
		}
		return glob
	}
	return acl.HostMatchesGlob(sample(a), b) || acl.HostMatchesGlob(sample(b), a)
}

func isComment(line string) bool {
	return strings.HasPrefix(strings.TrimSpace(line), "#")
}

func isBlankOrComment(line string) bool {
	return strings.TrimSpace(line) == "" || isComment(line)
}

// collapseBlankLines leaves at most one blank line in a row in text, and none at its start.
func collapseBlankLines(text string) string {
	var out []string
	for _, line := range strings.Split(strings.TrimRight(text, "\n"), "\n") {
		if strings.TrimSpace(line) == "" {
			if len(out) == 0 || out[len(out)-1] == "" {
				continue
			}
			line = ""
		}
		out = append(out, line)
	}
	return strings.Join(out, "\n") + "\n"
}

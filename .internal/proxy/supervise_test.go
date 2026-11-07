package main

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

func TestParseOptionsSplitsChopisFlagsFromSmokescreens(t *testing.T) {
	opts, err := parseOptions([]string{"--relay-log", "/l", "--gh-sock", "/s", "--ports-file", "/p",
		"--github-allowlist", "/a", "--relay-config", "/r", "--", "--config-file", "/c"})
	if err != nil {
		t.Fatal(err)
	}
	if opts.relayLog != "/l" || opts.ghSock != "/s" || opts.portsFile != "/p" ||
		opts.allowlist != "/a" || opts.relayConfig != "/r" {
		t.Errorf("parsed %+v", opts)
	}
	if !slices.Equal(opts.smokeArgs, []string{"--config-file", "/c"}) {
		t.Errorf("smokescreen's flags %q", opts.smokeArgs)
	}
}

func TestParseOptionsRefuses(t *testing.T) {
	all := []string{"--relay-log", "/l", "--gh-sock", "/s", "--ports-file", "/p",
		"--github-allowlist", "/a", "--relay-config", "/r"}
	// Each of chopi's flags left out in turn.
	for i := 0; i < len(all); i += 2 {
		args := append(slices.Clone(all[:i]), all[i+2:]...)
		if _, err := parseOptions(append(args, "--")); err == nil {
			t.Errorf("accepted without %s", all[i])
		}
	}
	for _, args := range [][]string{
		all, // no smokescreen flags
		append(slices.Clone(all), "--bogus", "1", "--"), // unknown
		{"--relay-log"}, // no value
	} {
		if _, err := parseOptions(args); err == nil {
			t.Errorf("%q: accepted", args)
		}
	}
}

func TestTakeEnvTakesTheSetOnesOut(t *testing.T) {
	t.Setenv("CHOPI_TEST_SET", "v")
	t.Setenv("CHOPI_TEST_EMPTY", "")
	os.Unsetenv("CHOPI_TEST_UNSET")
	got := takeEnv("CHOPI_TEST_SET", "CHOPI_TEST_EMPTY", "CHOPI_TEST_UNSET")
	if !slices.Equal(got, []string{"CHOPI_TEST_SET=v", "CHOPI_TEST_EMPTY="}) {
		t.Errorf("took %q", got)
	}
	for _, name := range []string{"CHOPI_TEST_SET", "CHOPI_TEST_EMPTY"} {
		if _, set := os.LookupEnv(name); set {
			t.Errorf("%s left in the environment", name)
		}
	}
}

func TestRelayConfigRendersWithItsEnv(t *testing.T) {
	dir := t.TempDir()
	cmd := filepath.Join(dir, "render")
	writeFile(t, cmd, "#!/bin/sh\necho note >&2\nprintf '%s:%s' \"$1\" \"$CHOPI_TEST_TOKEN\"\n")
	os.Chmod(cmd, 0o755)
	config, notes, err := relayConfig{cmd: cmd, allowlist: "/the/allowlist",
		env: []string{"CHOPI_TEST_TOKEN=t"}}.render()
	if err != nil || string(config) != "/the/allowlist:t" || notes != "note" {
		t.Errorf("rendered %q, notes %q, err %v", config, notes, err)
	}
}

func TestRelayConfigSaysWhyItFailed(t *testing.T) {
	cmd := filepath.Join(t.TempDir(), "render")
	writeFile(t, cmd, "#!/bin/sh\necho partial\necho 'no token' >&2\nexit 1\n")
	os.Chmod(cmd, 0o755)
	config, notes, err := relayConfig{cmd: cmd, allowlist: "/a"}.render()
	if err == nil || !strings.Contains(err.Error(), "no token") || config != nil || notes != "" {
		t.Errorf("rendered %q, notes %q, err %v: want no config, and why", config, notes, err)
	}
}

func TestOutputSinceIsTheRestOnOneLine(t *testing.T) {
	path := filepath.Join(t.TempDir(), "log")
	writeFile(t, path, "old\nnew line\n  and more\n")
	if got := outputSince(path, 4); got != "new line and more" {
		t.Errorf("got %q", got)
	}
	if got := outputSince(filepath.Join(t.TempDir(), "missing"), 0); got != "" {
		t.Errorf("got %q from no file", got)
	}
}

func TestReportPortsWritesThemAndNothingElse(t *testing.T) {
	dir := t.TempDir()
	if err := reportPorts(filepath.Join(dir, "ports"), ports{proxy: 24760, relay: 24761}); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(filepath.Join(dir, "ports"))
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "proxy 24760\nrelay 24761\n" {
		t.Errorf("ports file holds %q", got)
	}
	entries, _ := os.ReadDir(dir)
	if len(entries) != 1 {
		t.Errorf("dir holds %d entries, want just the ports file: the temporary must not be left behind", len(entries))
	}
}

func TestReadPortsReadsWhatReportPortsWrote(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ports")
	if err := reportPorts(path, ports{proxy: 24760, relay: 24761}); err != nil {
		t.Fatal(err)
	}
	if got := readPorts(path); got != (ports{proxy: 24760, relay: 24761}) {
		t.Errorf("read %v", got)
	}
}

func TestReadPortsSkipsWhatIsNoPort(t *testing.T) {
	dir := t.TempDir()
	if got := readPorts(filepath.Join(dir, "missing")); got != (ports{}) {
		t.Errorf("read %v from no file", got)
	}
	path := filepath.Join(dir, "ports")
	writeFile(t, path, "proxy 0\nrelay 70000\nother x\ngit 24762\n")
	if got := readPorts(path); got != (ports{}) {
		t.Errorf("read %v, want no port", got)
	}
	writeFile(t, path, "relay x\nproxy 24760\n")
	if got := readPorts(path); got != (ports{proxy: 24760}) {
		t.Errorf("read %v, want just the proxy's port", got)
	}
}

func TestListenAPIRelayExplainsASocketPathTooLong(t *testing.T) {
	sock := "/" + strings.Repeat("d", maxSocketPath)
	_, err := listenAPIRelay(sock)
	if err == nil || !strings.Contains(err.Error(), "past the 103 macOS allows") {
		t.Errorf("got %v, want the length limit named: bind itself only says \"invalid argument\"", err)
	}
}

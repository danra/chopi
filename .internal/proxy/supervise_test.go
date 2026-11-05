package main

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

func TestParseOptionsSplitsChopisFlagsFromSmokescreens(t *testing.T) {
	opts, err := parseOptions([]string{"--relay-log", "/l", "--gh-sock", "/s",
		"--ports-file", "/p", "--", "--config-file", "/c"})
	if err != nil {
		t.Fatal(err)
	}
	if opts.relayLog != "/l" || opts.ghSock != "/s" || opts.portsFile != "/p" {
		t.Errorf("parsed %+v", opts)
	}
	if !slices.Equal(opts.smokeArgs, []string{"--config-file", "/c"}) {
		t.Errorf("smokescreen's flags %q", opts.smokeArgs)
	}
}

func TestParseOptionsRefuses(t *testing.T) {
	for _, args := range [][]string{
		{"--relay-log", "/l", "--gh-sock", "/s", "--ports-file", "/p"},                       // no smokescreen flags
		{"--gh-sock", "/s", "--ports-file", "/p", "--"},                                      // no --relay-log
		{"--relay-log", "/l", "--ports-file", "/p", "--"},                                    // no --gh-sock
		{"--relay-log", "/l", "--gh-sock", "/s", "--"},                                       // no --ports-file
		{"--relay-log", "/l", "--gh-sock", "/s", "--ports-file", "/p", "--bogus", "1", "--"}, // unknown
		{"--relay-log"}, // no value
	} {
		if _, err := parseOptions(args); err == nil {
			t.Errorf("%q: accepted", args)
		}
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

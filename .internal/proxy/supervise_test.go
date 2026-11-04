package main

import (
	"net"
	"slices"
	"strings"
	"testing"
)

func TestParseOptionsSplitsChopisFlagsFromSmokescreens(t *testing.T) {
	opts, err := parseOptions([]string{"--relay-log", "/l", "--git-port", "4761", "--gh-sock", "/s",
		"--", "--listen-ip", "127.0.0.1"})
	if err != nil {
		t.Fatal(err)
	}
	if opts.relayLog != "/l" || opts.gitPort != 4761 || opts.ghSock != "/s" {
		t.Errorf("parsed %+v", opts)
	}
	if !slices.Equal(opts.smokeArgs, []string{"--listen-ip", "127.0.0.1"}) {
		t.Errorf("smokescreen's flags %q", opts.smokeArgs)
	}
}

func TestParseOptionsRefuses(t *testing.T) {
	for _, args := range [][]string{
		{"--relay-log", "/l", "--git-port", "0", "--gh-sock", "/s"},                       // no smokescreen flags
		{"--git-port", "0", "--gh-sock", "/s", "--"},                                      // no --relay-log
		{"--relay-log", "/l", "--gh-sock", "/s", "--"},                                    // no --git-port
		{"--relay-log", "/l", "--git-port", "0", "--"},                                    // no --gh-sock
		{"--relay-log", "/l", "--git-port", "x", "--gh-sock", "/s", "--"},                 // not a port
		{"--relay-log", "/l", "--git-port", "65536", "--gh-sock", "/s", "--"},             // not a port
		{"--relay-log", "/l", "--git-port", "0", "--gh-sock", "/s", "--bogus", "1", "--"}, // unknown
		{"--relay-log"}, // no value
	} {
		if _, err := parseOptions(args); err == nil {
			t.Errorf("%q: accepted", args)
		}
	}
}

func TestListenRelaysExplainsASocketPathTooLong(t *testing.T) {
	sock := "/" + strings.Repeat("d", maxSocketPath)
	_, err := listenRelays(0, sock)
	if err == nil || !strings.Contains(err.Error(), "past the 103 macOS allows") {
		t.Errorf("got %v, want the length limit named: bind itself only says \"invalid argument\"", err)
	}
}

func TestListenRelaysRefusesAPortTaken(t *testing.T) {
	other, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close()
	// Under /tmp, not t.TempDir(): that nests under the test's name, past the length macOS allows
	// a unix socket's path.
	sock := "/tmp/chopi-test-taken.sock"
	_, err = listenRelays(other.Addr().(*net.TCPAddr).Port, sock)
	if err == nil || !strings.Contains(err.Error(), "address already in use") {
		t.Errorf("got %v, want the git relay's port refused: another process's listener must not pass for ours", err)
	}
}

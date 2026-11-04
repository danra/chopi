package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

func TestParseOptionsSplitsChopisFlagsFromSmokescreens(t *testing.T) {
	opts, err := parseOptions([]string{"--dir", "/d", "--parent", "42", "--relay-log", "/l",
		"--", "--config-file", "/c"})
	if err != nil {
		t.Fatal(err)
	}
	if opts.dir != "/d" || opts.parent != 42 || opts.relayLog != "/l" {
		t.Errorf("parsed %+v", opts)
	}
	if !slices.Equal(opts.smokeArgs, []string{"--config-file", "/c"}) {
		t.Errorf("smokescreen's flags %q", opts.smokeArgs)
	}
}

func TestParseOptionsRefuses(t *testing.T) {
	for _, args := range [][]string{
		{"--dir", "/d", "--parent", "42", "--relay-log", "/l"},                       // no smokescreen flags
		{"--parent", "42", "--relay-log", "/l", "--"},                                // no --dir
		{"--dir", "/d", "--relay-log", "/l", "--"},                                   // no --parent
		{"--dir", "/d", "--parent", "42", "--"},                                      // no --relay-log
		{"--dir", "/d", "--parent", "x", "--relay-log", "/l", "--"},                  // not a pid
		{"--dir", "/d", "--parent", "-1", "--relay-log", "/l", "--"},                 // not a pid
		{"--dir", "/d", "--parent", "42", "--relay-log", "/l", "--bogus", "1", "--"}, // unknown
		{"--dir"}, // no value
	} {
		if _, err := parseOptions(args); err == nil {
			t.Errorf("%q: accepted", args)
		}
	}
}

func TestWatchExitClosesOnceTheProcessExits(t *testing.T) {
	child := exec.Command("sleep", "30")
	if err := child.Start(); err != nil {
		t.Fatal(err)
	}
	exited, err := watchExit(child.Process.Pid)
	if err != nil {
		t.Fatal(err)
	}
	select {
	case <-exited:
		t.Fatal("closed while the process runs")
	case <-time.After(100 * time.Millisecond):
	}
	child.Process.Kill()
	select {
	case <-exited:
	case <-time.After(5 * time.Second):
		t.Fatal("not closed after the process exited")
	}
	child.Wait()
}

func TestWatchExitClosesForAProcessAlreadyGone(t *testing.T) {
	child := exec.Command("true")
	if err := child.Run(); err != nil {
		t.Fatal(err)
	}
	exited, err := watchExit(child.Process.Pid)
	if err != nil {
		t.Fatal(err)
	}
	select {
	case <-exited:
	case <-time.After(5 * time.Second):
		t.Fatal("not closed for a process already gone")
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

func TestListenAPIRelayExplainsASocketPathTooLong(t *testing.T) {
	sock := "/" + strings.Repeat("d", maxSocketPath)
	_, err := listenAPIRelay(sock)
	if err == nil || !strings.Contains(err.Error(), "past the 103 macOS allows") {
		t.Errorf("got %v, want the length limit named: bind itself only says \"invalid argument\"", err)
	}
}

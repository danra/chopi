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
		"--", "--listen-ip", "127.0.0.1"})
	if err != nil {
		t.Fatal(err)
	}
	if opts.dir != "/d" || opts.parent != 42 || opts.relayLog != "/l" {
		t.Errorf("parsed %+v", opts)
	}
	if !slices.Equal(opts.smokeArgs, []string{"--listen-ip", "127.0.0.1"}) {
		t.Errorf("smokescreen's flags %q", opts.smokeArgs)
	}
}

func TestParseOptionsKeepsTheRelayLogFresh(t *testing.T) {
	opts, err := parseOptions([]string{"--dir", "/d", "--parent", "42", "--relay-log", "/l",
		"--keep-fresh", "/a", "--keep-fresh", "/b", "--"})
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(opts.keepFresh, []string{"/a", "/b", "/l"}) {
		t.Errorf("kept fresh %q", opts.keepFresh)
	}
}

func TestKeepFreshTouchesItsFiles(t *testing.T) {
	path := filepath.Join(t.TempDir(), "log")
	writeFile(t, path, "")
	old := time.Now().Add(-30 * 24 * time.Hour)
	setMtime(t, path, old)
	go keepFresh([]string{path}, 10*time.Millisecond)
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if mtimeOf(t, path).After(old.Add(time.Hour)) {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Error("not touched")
}

func TestParseOptionsRefuses(t *testing.T) {
	for _, args := range [][]string{
		{"--dir", "/d", "--parent", "42", "--relay-log", "/l"},                       // no smokescreen flags
		{"--parent", "42", "--relay-log", "/l", "--"},                                // no --dir
		{"--dir", "/d", "--parent", "x", "--relay-log", "/l", "--"},                  // not a pid
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
	if err := reportPorts(dir, 24760, 24761); err != nil {
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

func TestListenRelaysExplainsASocketPathTooLong(t *testing.T) {
	dir := "/" + strings.Repeat("d", maxSocketPath)
	_, err := listenRelays(dir)
	if err == nil || !strings.Contains(err.Error(), "past the 103 macOS allows") {
		t.Errorf("got %v, want the length limit named: bind itself only says \"invalid argument\"", err)
	}
}

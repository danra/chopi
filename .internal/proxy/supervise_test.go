package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestParseOptionsSplitsChopisFlagsFromSmokescreens(t *testing.T) {
	opts, err := parseOptions([]string{"--dir", "/d", "--parent", "42", "--relay-log", "/l",
		"--github-allowlist", "/a", "--relay-config", "/r", "--", "--config-file", "/c"})
	if err != nil {
		t.Fatal(err)
	}
	if opts.dir != "/d" || opts.parent != 42 || opts.relayLog != "/l" ||
		opts.allowlist != "/a" || opts.relayConfig != "/r" {
		t.Errorf("parsed %+v", opts)
	}
	if !slices.Equal(opts.smokeArgs, []string{"--config-file", "/c"}) {
		t.Errorf("smokescreen's flags %q", opts.smokeArgs)
	}
}

func TestParseOptionsRefuses(t *testing.T) {
	all := []string{"--dir", "/d", "--parent", "42", "--relay-log", "/l",
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
		{"--dir", "/d", "--parent", "x", "--relay-log", "/l", "--github-allowlist", "/a",
			"--relay-config", "/r", "--"}, // not a pid
		{"--dir", "/d", "--parent", "-1", "--relay-log", "/l", "--github-allowlist", "/a",
			"--relay-config", "/r", "--"}, // not a pid
		{"--dir"}, // no value
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
		env: []string{"CHOPI_TEST_TOKEN=t"}}.render(context.Background())
	if err != nil || string(config) != "/the/allowlist:t" || notes != "note" {
		t.Errorf("rendered %q, notes %q, err %v", config, notes, err)
	}
}

func TestRelayConfigSaysWhyItFailed(t *testing.T) {
	cmd := filepath.Join(t.TempDir(), "render")
	writeFile(t, cmd, "#!/bin/sh\necho partial\necho 'no token' >&2\nexit 1\n")
	os.Chmod(cmd, 0o755)
	config, notes, err := relayConfig{cmd: cmd, allowlist: "/a"}.render(context.Background())
	if err == nil || !strings.Contains(err.Error(), "no token") || config != nil || notes != "" {
		t.Errorf("rendered %q, notes %q, err %v: want no config, and why", config, notes, err)
	}
}

func TestRelayConfigRenderStopsWithItsChildren(t *testing.T) {
	cmd, pidFile := stuckRender(t)
	ctx, cancel := context.WithCancel(context.Background())
	rendered := make(chan error, 1)
	go func() {
		_, _, err := relayConfig{cmd: cmd, allowlist: "/a"}.render(ctx)
		rendered <- err
	}()
	pid := awaitPid(t, pidFile)
	cancel()
	select {
	case err := <-rendered:
		if err == nil {
			t.Error("a cancelled render succeeded")
		}
	case <-time.After(renderCancelGrace + 3*time.Second):
		t.Fatal("the render outlived its cancel")
	}
	if !pidGone(pid) {
		syscall.Kill(pid, syscall.SIGKILL)
		t.Fatal("the render's child outlived its cancel")
	}
}

func TestStopAllStopsAReloadsRender(t *testing.T) {
	cmd, pidFile := stuckRender(t)
	s := newRelaySupervisor(nil, filepath.Join(t.TempDir(), "log"), relayConfig{cmd: cmd, allowlist: "/a"}, nil)
	reloaded := make(chan error, 1)
	go func() { reloaded <- s.reload() }()
	pid := awaitPid(t, pidFile)
	s.stopAll()
	// Checked at once, not waited for: stopAll returns only once the render's group is gone.
	if syscall.Kill(pid, 0) == nil {
		syscall.Kill(pid, syscall.SIGKILL)
		t.Fatal("the render's child outlived stopAll")
	}
	if err := <-reloaded; err == nil {
		t.Error("a reload stopped as it rendered succeeded")
	}
	if err := s.reload(); err == nil {
		t.Error("a reload after stopAll succeeded")
	}
}

// stuckRender writes a render command whose child waits as gh would at a keychain prompt, holding
// the output pipe, and writes its pid to pidFile.
func stuckRender(t *testing.T) (cmd, pidFile string) {
	dir := t.TempDir()
	cmd, pidFile = filepath.Join(dir, "render"), filepath.Join(dir, "pid")
	writeFile(t, cmd, "#!/bin/sh\nsleep 30 &\necho $! >'"+pidFile+"'\nwait\n")
	os.Chmod(cmd, 0o755)
	return cmd, pidFile
}

// awaitPid returns the pid a stuckRender command writes to pidFile once its child has started.
func awaitPid(t *testing.T, pidFile string) int {
	t.Helper()
	var pid int
	for deadline := time.Now().Add(5 * time.Second); pid == 0; time.Sleep(10 * time.Millisecond) {
		if time.Now().After(deadline) {
			t.Fatal("the render's child never started")
		}
		got, _ := os.ReadFile(pidFile)
		fmt.Sscan(string(got), &pid)
	}
	return pid
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

func TestWatchExitCancelsOnceTheProcessExits(t *testing.T) {
	child := exec.Command("sleep", "30")
	if err := child.Start(); err != nil {
		t.Fatal(err)
	}
	exited, err := watchExit(context.Background(), child.Process.Pid)
	if err != nil {
		t.Fatal(err)
	}
	select {
	case <-exited.Done():
		t.Fatal("cancelled while the process runs")
	case <-time.After(100 * time.Millisecond):
	}
	child.Process.Kill()
	select {
	case <-exited.Done():
	case <-time.After(5 * time.Second):
		t.Fatal("not cancelled after the process exited")
	}
	child.Wait()
}

func TestWatchExitCancelsForAProcessAlreadyGone(t *testing.T) {
	child := exec.Command("true")
	if err := child.Run(); err != nil {
		t.Fatal(err)
	}
	exited, err := watchExit(context.Background(), child.Process.Pid)
	if err != nil {
		t.Fatal(err)
	}
	select {
	case <-exited.Done():
	case <-time.After(5 * time.Second):
		t.Fatal("not cancelled for a process already gone")
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

package main

import (
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// The test binary doubles as the processes the supervisor tests run: chopi-smokescreen itself, and
// the caddy it starts, found on PATH as a script that runs this binary again.
func TestMain(m *testing.M) {
	switch os.Getenv("CHOPI_TEST_ROLE") {
	case "supervisor":
		// Past the "slow" fake Caddy's stop, short of making a "stubborn" one's test wait long.
		caddyStopTimeout = time.Second
		main()
		os.Exit(0)
	case "caddy":
		fakeCaddy()
		os.Exit(0)
	}
	os.Exit(m.Run())
}

// fakeCaddy stands in for Caddy: it records its config (stdin) and pid in CHOPI_TEST_STATE, then
// serves "git" on the inherited git relay listener and "api" on the API relay's -- or, as
// CHOPI_TEST_CADDY says, fails to start ("fail"), exits after its first request ("die"), takes a
// while to stop on a TERM ("slow"), or ignores it ("stubborn").
func fakeCaddy() {
	state := os.Getenv("CHOPI_TEST_STATE")
	config, _ := io.ReadAll(os.Stdin)
	os.WriteFile(filepath.Join(state, "caddy-config"), config, 0o600)
	os.WriteFile(filepath.Join(state, "caddy-pid"), []byte(strconv.Itoa(os.Getpid())), 0o600)
	plan := os.Getenv("CHOPI_TEST_CADDY")
	switch plan {
	case "fail":
		fmt.Println("caddy says: bad config")
		os.Exit(1)
	case "slow":
		term := make(chan os.Signal, 1)
		signal.Notify(term, syscall.SIGTERM)
		go func() {
			<-term
			time.Sleep(500 * time.Millisecond)
			os.Exit(0)
		}()
	case "stubborn":
		signal.Ignore(syscall.SIGTERM)
	}
	served := make(chan struct{}, 1)
	serve := func(envFD, answer string) {
		fd, _ := strconv.Atoi(os.Getenv(envFD))
		listener, err := net.FileListener(os.NewFile(uintptr(fd), envFD))
		if err != nil {
			fmt.Println("caddy:", err)
			os.Exit(1)
		}
		http.Serve(listener, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			fmt.Fprint(w, answer)
			select {
			case served <- struct{}{}:
			default:
			}
		}))
	}
	go serve("CHOPI_GH_FD", "api")
	go serve("CHOPI_GIT_FD", "git port "+os.Getenv("CHOPI_GIT_PORT"))
	if plan == "die" {
		<-served // the supervisor's readiness probe
		<-served // the test's
		time.Sleep(100 * time.Millisecond)
		os.Exit(1)
	}
	select {}
}

type supervisorRun struct {
	cmd    *exec.Cmd
	dir    string
	state  string
	parent *exec.Cmd
	stderr *strings.Builder
	exited chan struct{}
}

// startSupervisor runs chopi-smokescreen with a fake caddy behaving as caddyPlan says, and a
// `sleep` as the parent it watches.
func startSupervisor(t *testing.T, caddyPlan string) *supervisorRun {
	t.Helper()
	return startSupervisorIn(t, supervisorDir(t), caddyPlan)
}

// supervisorDir makes a dir for supervisors to run in, one after another: its fake caddy, rules,
// and run dir.
func supervisorDir(t *testing.T) string {
	t.Helper()
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	// Under /tmp, not t.TempDir(): that nests under the test's name, past the length macOS allows
	// a unix socket's path.
	tmp, err := os.MkdirTemp("/tmp", "chopi-test-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(tmp) })
	for _, d := range []string{"bin", "dir", "state"} {
		if err := os.Mkdir(filepath.Join(tmp, d), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	caddy := filepath.Join(tmp, "bin", "caddy")
	writeFile(t, caddy, "#!/bin/sh\nCHOPI_TEST_ROLE=caddy exec '"+exe+"' \"$@\"\n")
	os.Chmod(caddy, 0o755)
	writeFile(t, filepath.Join(tmp, "rules.yaml"), rulesAllowing("example.com"))
	return tmp
}

// startSupervisorIn runs chopi-smokescreen in tmp, a supervisorDir, as startSupervisor does.
func startSupervisorIn(t *testing.T, tmp, caddyPlan string) *supervisorRun {
	t.Helper()
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	bin := filepath.Join(tmp, "bin")
	state := filepath.Join(tmp, "state")
	rules := filepath.Join(tmp, "rules.yaml")
	config, err := filepath.Abs("../smokescreen-config.yaml")
	if err != nil {
		t.Fatal(err)
	}

	dir := filepath.Join(tmp, "dir")
	parent := exec.Command("sleep", "30")
	if err := parent.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { parent.Process.Kill(); parent.Wait() })

	run := &supervisorRun{dir: dir, state: state, parent: parent, stderr: &strings.Builder{},
		exited: make(chan struct{})}
	run.cmd = exec.Command(exe, "--dir", dir, "--parent", strconv.Itoa(parent.Process.Pid),
		"--relay-log", filepath.Join(tmp, "caddy.log"), "--",
		"--config-file", config, "--egress-acl-file", rules)
	run.cmd.Env = append(os.Environ(), "CHOPI_TEST_ROLE=supervisor", "CHOPI_TEST_STATE="+state,
		"CHOPI_TEST_CADDY="+caddyPlan, "PATH="+bin+":"+os.Getenv("PATH"))
	run.cmd.Stdin = strings.NewReader("THE CADDY CONFIG")
	run.cmd.Stderr = run.stderr
	if err := run.cmd.Start(); err != nil {
		t.Fatal(err)
	}
	go func() {
		run.cmd.Wait()
		close(run.exited)
	}()
	t.Cleanup(func() {
		run.cmd.Process.Kill()
		if pid, err := run.caddyPID(); err == nil {
			syscall.Kill(pid, syscall.SIGKILL)
		}
	})
	return run
}

// awaitPorts waits for the supervisor to report its ports, failing the test if it exits first.
func (run *supervisorRun) awaitPorts(t *testing.T) ports {
	t.Helper()
	deadline := time.After(20 * time.Second)
	for {
		if data, err := os.ReadFile(filepath.Join(run.dir, "ports")); err == nil {
			var up ports
			for _, line := range strings.Split(string(data), "\n") {
				var name string
				var port int
				fmt.Sscan(line, &name, &port)
				switch name {
				case "proxy":
					up.proxy = port
				case "relay":
					up.relay = port
				}
			}
			return up
		}
		select {
		case <-run.exited:
			t.Fatalf("the supervisor exited before reporting its ports (stderr: %s)", run.stderr)
		case <-deadline:
			t.Fatal("the supervisor did not report its ports")
		case <-time.After(50 * time.Millisecond):
		}
	}
}

func (run *supervisorRun) awaitExit(t *testing.T) int {
	t.Helper()
	select {
	case <-run.exited:
		return run.cmd.ProcessState.ExitCode()
	case <-time.After(10 * time.Second):
		t.Fatal("the supervisor did not exit")
		return -1
	}
}

// caddyPID reads the fake caddy's PID, which it records once it runs.
func (run *supervisorRun) caddyPID() (int, error) {
	data, err := os.ReadFile(filepath.Join(run.state, "caddy-pid"))
	if err != nil {
		return 0, err
	}
	return strconv.Atoi(string(data))
}

// caddyGone reports whether the fake caddy has exited.
func (run *supervisorRun) caddyGone(t *testing.T) bool {
	t.Helper()
	for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); {
		if run.caddyGoneNow(t) {
			return true
		}
		time.Sleep(50 * time.Millisecond)
	}
	return false
}

// directClient goes straight to its URL, whatever http_proxy the user's environment has.
var directClient = &http.Client{Transport: &http.Transport{Proxy: nil}}

func get(t *testing.T, client *http.Client, url string) string {
	t.Helper()
	resp, err := client.Get(url)
	if err != nil {
		t.Fatalf("GET %s: %v", url, err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	return string(body)
}

func TestSupervisorServesAndStopsWithItsParent(t *testing.T) {
	t.Parallel()
	run := startSupervisor(t, "")
	up := run.awaitPorts(t)

	if got := get(t, directClient, fmt.Sprintf("http://127.0.0.1:%d/", up.relay)); got != fmt.Sprintf("git port %d", up.relay) {
		t.Errorf("the git relay answers %q: caddy must serve it, knowing its port", got)
	}
	viaSocket := &http.Client{Transport: &http.Transport{Proxy: nil,
		Dial: func(_, _ string) (net.Conn, error) { return net.Dial("unix", filepath.Join(run.dir, "gh.sock")) }}}
	if got := get(t, viaSocket, "http://api.github.localhost/"); got != "api" {
		t.Errorf("the API relay's socket answers %q: caddy must serve it", got)
	}
	if conn, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", up.proxy)); err != nil {
		t.Errorf("the outgoing proxy doesn't listen: %v", err)
	} else {
		conn.Close()
	}
	if config, _ := os.ReadFile(filepath.Join(run.state, "caddy-config")); string(config) != "THE CADDY CONFIG" {
		t.Errorf("caddy got config %q, want the supervisor's stdin", config)
	}

	run.parent.Process.Kill()
	if status := run.awaitExit(t); status != 0 {
		t.Errorf("exit status %d once the parent is gone", status)
	}
	if !run.caddyGone(t) {
		t.Error("caddy outlives the supervisor")
	}
	if _, err := os.Stat(run.dir); !os.IsNotExist(err) {
		t.Errorf("the dir is left behind once the parent is gone (%v)", err)
	}
}

func TestSupervisorStopsCaddyOnTERM(t *testing.T) {
	t.Parallel()
	run := startSupervisor(t, "")
	run.awaitPorts(t)
	run.cmd.Process.Signal(syscall.SIGTERM)
	run.awaitExit(t)
	if !run.caddyGone(t) {
		t.Error("caddy outlives the supervisor")
	}
}

// caddyGoneNow reports whether the fake caddy has exited, without waiting for it.
func (run *supervisorRun) caddyGoneNow(t *testing.T) bool {
	t.Helper()
	pid, err := run.caddyPID()
	if err != nil {
		t.Fatal("caddy never ran")
	}
	return syscall.Kill(pid, 0) != nil
}

// The supervisor's exit says the relays are down: Caddy must be gone by then.
func TestSupervisorWaitsForCaddyToStop(t *testing.T) {
	t.Parallel()
	run := startSupervisor(t, "slow")
	run.awaitPorts(t)
	run.cmd.Process.Signal(syscall.SIGTERM)
	run.awaitExit(t)
	if !run.caddyGoneNow(t) {
		t.Error("the supervisor exited with caddy still stopping")
	}
}

func TestSupervisorKillsACaddyThatWontStop(t *testing.T) {
	t.Parallel()
	run := startSupervisor(t, "stubborn")
	run.awaitPorts(t)
	run.cmd.Process.Signal(syscall.SIGTERM)
	run.awaitExit(t)
	if !run.caddyGoneNow(t) {
		t.Error("caddy ignored the TERM and outlives the supervisor")
	}
}

func TestSupervisorStopsOnceCaddyExits(t *testing.T) {
	t.Parallel()
	run := startSupervisor(t, "die")
	up := run.awaitPorts(t)
	get(t, directClient, fmt.Sprintf("http://127.0.0.1:%d/", up.relay))
	if status := run.awaitExit(t); status == 0 {
		t.Error("exit status 0 after caddy died: nothing is left serving the relays")
	}
}

func TestSupervisorReportsACaddyThatFailsToStart(t *testing.T) {
	t.Parallel()
	run := startSupervisor(t, "fail")
	if status := run.awaitExit(t); status == 0 {
		t.Fatal("exit status 0 for a caddy that failed to start")
	}
	if !strings.Contains(run.stderr.String(), "did not come up") ||
		!strings.Contains(run.stderr.String(), "caddy says: bad config") {
		t.Errorf("stderr %q, want the failure and caddy's log", run.stderr)
	}
	if _, err := os.Stat(filepath.Join(run.dir, "ports")); !os.IsNotExist(err) {
		t.Error("ports reported for a proxy that didn't start")
	}
}

package main

import (
	"bufio"
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
	sock   string
	state  string
	stderr *strings.Builder
	ports  chan map[string]int // the ports the ready line names, once it's out
	exited chan struct{}
}

// readyLine is the line the supervisor says it serves with, on stdout.
var readyLine = "[chopi-smokescreen] outgoing proxy on 127.0.0.1:%d, GitHub relay on 127.0.0.1:%d, GitHub API relay on %s"

// startSupervisor runs chopi-smokescreen, on ports the kernel picks, with a fake caddy behaving as
// caddyPlan says.
func startSupervisor(t *testing.T, caddyPlan string) *supervisorRun {
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
	bin := filepath.Join(tmp, "bin")
	state := filepath.Join(tmp, "state")
	for _, d := range []string{bin, state} {
		if err := os.Mkdir(d, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	writeFile(t, filepath.Join(bin, "caddy"), "#!/bin/sh\nCHOPI_TEST_ROLE=caddy exec '"+exe+"' \"$@\"\n")
	os.Chmod(filepath.Join(bin, "caddy"), 0o755)
	rules := filepath.Join(tmp, "rules.yaml")
	writeFile(t, rules, rulesAllowing("example.com"))
	config, err := filepath.Abs("../smokescreen-config.yaml")
	if err != nil {
		t.Fatal(err)
	}

	run := &supervisorRun{sock: filepath.Join(tmp, "gh.sock"), state: state, stderr: &strings.Builder{},
		ports: make(chan map[string]int, 1), exited: make(chan struct{})}
	run.cmd = exec.Command(exe, "--relay-log", filepath.Join(tmp, "caddy.log"), "--git-port", "0",
		"--gh-sock", run.sock, "--",
		"--config-file", config, "--listen-ip", "127.0.0.1", "--listen-port", "0",
		"--egress-acl-file", rules)
	run.cmd.Env = append(os.Environ(), "CHOPI_TEST_ROLE=supervisor", "CHOPI_TEST_STATE="+state,
		"CHOPI_TEST_CADDY="+caddyPlan, "PATH="+bin+":"+os.Getenv("PATH"))
	run.cmd.Stdin = strings.NewReader("THE CADDY CONFIG")
	run.cmd.Stderr = run.stderr
	stdout, err := run.cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := run.cmd.Start(); err != nil {
		t.Fatal(err)
	}
	go func() {
		scanner := bufio.NewScanner(stdout)
		for scanner.Scan() {
			var proxy, relay int
			var sock string
			if n, _ := fmt.Sscanf(scanner.Text(), readyLine, &proxy, &relay, &sock); n == 3 {
				run.ports <- map[string]int{"proxy": proxy, "relay": relay}
			}
		}
	}()
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

// awaitPorts waits for the supervisor to say it serves, and where, failing the test if it exits
// first.
func (run *supervisorRun) awaitPorts(t *testing.T) map[string]int {
	t.Helper()
	select {
	case ports := <-run.ports:
		return ports
	case <-run.exited:
		t.Fatalf("the supervisor exited before serving (stderr: %s)", run.stderr)
	case <-time.After(20 * time.Second):
		t.Fatal("the supervisor did not say it serves")
	}
	return nil
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

func TestSupervisorServesAndStopsOnINT(t *testing.T) {
	run := startSupervisor(t, "")
	ports := run.awaitPorts(t)

	if got := get(t, directClient, fmt.Sprintf("http://127.0.0.1:%d/", ports["relay"])); got != fmt.Sprintf("git port %d", ports["relay"]) {
		t.Errorf("the git relay answers %q: caddy must serve it, knowing its port", got)
	}
	viaSocket := &http.Client{Transport: &http.Transport{Proxy: nil,
		Dial: func(_, _ string) (net.Conn, error) { return net.Dial("unix", run.sock) }}}
	if got := get(t, viaSocket, "http://api.github.localhost/"); got != "api" {
		t.Errorf("the API relay's socket answers %q: caddy must serve it", got)
	}
	if conn, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", ports["proxy"])); err != nil {
		t.Errorf("the outgoing proxy doesn't listen: %v", err)
	} else {
		conn.Close()
	}
	if config, _ := os.ReadFile(filepath.Join(run.state, "caddy-config")); string(config) != "THE CADDY CONFIG" {
		t.Errorf("caddy got config %q, want the supervisor's stdin", config)
	}

	// A Ctrl-C, as the terminal sends it.
	run.cmd.Process.Signal(syscall.SIGINT)
	if status := run.awaitExit(t); status != 0 {
		t.Errorf("exit status %d once stopped", status)
	}
	if !run.caddyGone(t) {
		t.Error("caddy outlives the supervisor")
	}
	if _, err := os.Stat(run.sock); !os.IsNotExist(err) {
		t.Errorf("the API relay's socket is left behind (%v)", err)
	}
}

func TestSupervisorStopsCaddyOnTERM(t *testing.T) {
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

// The socket and the ports file name Caddy's relays: they go only once Caddy is gone.
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
	run := startSupervisor(t, "die")
	ports := run.awaitPorts(t)
	get(t, directClient, fmt.Sprintf("http://127.0.0.1:%d/", ports["relay"]))
	if status := run.awaitExit(t); status == 0 {
		t.Error("exit status 0 after caddy died: nothing is left serving the relays")
	}
}

func TestSupervisorReportsACaddyThatFailsToStart(t *testing.T) {
	run := startSupervisor(t, "fail")
	if status := run.awaitExit(t); status == 0 {
		t.Fatal("exit status 0 for a caddy that failed to start")
	}
	if !strings.Contains(run.stderr.String(), "did not come up") ||
		!strings.Contains(run.stderr.String(), "caddy says: bad config") {
		t.Errorf("stderr %q, want the failure and caddy's log", run.stderr)
	}
	select {
	case <-run.ports:
		t.Error("said it serves, for a proxy that didn't start")
	default:
	}
}

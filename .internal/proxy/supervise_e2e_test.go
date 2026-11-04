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

// fakeCaddy stands in for Caddy: it records its config (stdin), pid and GH_TOKEN in
// CHOPI_TEST_STATE, then serves "git" on the inherited git relay listener and "api" on the API
// relay's, and says so to its --pingback address, as Caddy does -- or, as CHOPI_TEST_CADDY says, or
// a config holding "CADDY-FAILS", fails to start ("fail"), exits after its first request ("die"),
// takes a while to stop on a TERM ("slow"), or ignores it ("stubborn").
func fakeCaddy() {
	state := os.Getenv("CHOPI_TEST_STATE")
	config, _ := io.ReadAll(os.Stdin)
	os.WriteFile(filepath.Join(state, "caddy-config"), config, 0o600)
	os.WriteFile(filepath.Join(state, "caddy-pid"), []byte(strconv.Itoa(os.Getpid())), 0o600)
	token, set := os.LookupEnv("GH_TOKEN")
	if !set {
		token = "(unset)"
	}
	os.WriteFile(filepath.Join(state, "caddy-token"), []byte(token), 0o600)
	plan := os.Getenv("CHOPI_TEST_CADDY")
	if strings.Contains(string(config), "CADDY-FAILS") {
		plan = "fail"
	}
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
		go http.Serve(listener, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			fmt.Fprintf(w, "%s from %d", answer, os.Getpid())
			select {
			case served <- struct{}{}:
			default:
			}
		}))
	}
	serve("CHOPI_GH_FD", "api")
	serve("CHOPI_GIT_FD", "git port "+os.Getenv("CHOPI_GIT_PORT"))
	for i, arg := range os.Args {
		if arg == "--pingback" && i+1 < len(os.Args) {
			if conn, err := net.Dial("tcp", os.Args[i+1]); err == nil {
				conn.Close()
			}
		}
	}
	if plan == "die" {
		<-served // the test's request
		time.Sleep(100 * time.Millisecond)
		os.Exit(1)
	}
	select {}
}

type supervisorRun struct {
	cmd       *exec.Cmd
	dir       string
	allowlist string // what the fake render prints as Caddy's config
	logFile   string // the supervisor's stdout
	state     string
	stderr    *strings.Builder
	exited    chan struct{}
}

// startSupervisor runs chopi-smokescreen with a fake caddy behaving as caddyPlan says.
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
	for _, d := range []string{"bin", "dir", "state"} {
		if err := os.Mkdir(filepath.Join(tmp, d), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	bin := filepath.Join(tmp, "bin")
	state := filepath.Join(tmp, "state")
	caddy := filepath.Join(bin, "caddy")
	writeFile(t, caddy, "#!/bin/sh\nCHOPI_TEST_ROLE=caddy exec '"+exe+"' \"$@\"\n")
	os.Chmod(caddy, 0o755)
	// The relays' config is the "allowlist" as it is, unless it holds RENDER-FAILS; the render
	// records the GH_TOKEN it gets.
	render := filepath.Join(bin, "render")
	writeFile(t, render, `#!/bin/sh
printf '%s' "${GH_TOKEN-(unset)}" > "$CHOPI_TEST_STATE/render-token"
case "$(cat "$1")" in
    *RENDER-FAILS*) echo "render says: no token" >&2; exit 1 ;;
esac
echo "render says: a note" >&2
cat "$1"
`)
	os.Chmod(render, 0o755)
	rules := filepath.Join(tmp, "rules.yaml")
	writeFile(t, rules, rulesAllowing("example.com"))
	writeFile(t, filepath.Join(tmp, "allowlist"), "THE CADDY CONFIG")
	config, err := filepath.Abs("../smokescreen-config.yaml")
	if err != nil {
		t.Fatal(err)
	}

	dir := filepath.Join(tmp, "dir")
	run := &supervisorRun{dir: dir, allowlist: filepath.Join(tmp, "allowlist"),
		logFile: filepath.Join(tmp, "supervisor.log"), state: state,
		stderr: &strings.Builder{}, exited: make(chan struct{})}
	run.cmd = exec.Command(exe, "--dir", dir,
		"--relay-log", filepath.Join(tmp, "caddy.log"),
		"--github-allowlist", run.allowlist, "--relay-config", render, "--",
		"--config-file", config, "--egress-acl-file", rules)
	run.cmd.Env = append(os.Environ(), "CHOPI_TEST_ROLE=supervisor", "CHOPI_TEST_STATE="+state,
		"CHOPI_TEST_CADDY="+caddyPlan, "PATH="+bin+":"+os.Getenv("PATH"), "GH_TOKEN=the-token")
	logFile, err := os.Create(run.logFile)
	if err != nil {
		t.Fatal(err)
	}
	defer logFile.Close()
	run.cmd.Stdout = logFile
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
			var p ports
			fmt.Sscanf(string(data), "proxy %d\nrelay %d\n", &p.proxy, &p.relay)
			return p
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
	return pidGone(run.mustCaddyPID(t))
}

// directClient goes straight to its URL, whatever http_proxy the user's environment has.
var directClient = &http.Client{Transport: &http.Transport{Proxy: nil}}

// apiClient goes to the API relay's socket, whatever the URL's host.
func (run *supervisorRun) apiClient() *http.Client {
	return &http.Client{Transport: &http.Transport{Proxy: nil,
		Dial: func(_, _ string) (net.Conn, error) { return net.Dial("unix", filepath.Join(run.dir, "gh.sock")) }}}
}

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

func TestSupervisorServesAndStopsOnTERM(t *testing.T) {
	t.Parallel()
	run := startSupervisor(t, "")
	up := run.awaitPorts(t)

	if got := get(t, directClient, fmt.Sprintf("http://127.0.0.1:%d/", up.relay)); !strings.HasPrefix(got, fmt.Sprintf("git port %d from", up.relay)) {
		t.Errorf("the git relay answers %q: caddy must serve it, knowing its port", got)
	}
	if got := get(t, run.apiClient(), "http://api.github.localhost/"); !strings.HasPrefix(got, "api from") {
		t.Errorf("the API relay's socket answers %q: caddy must serve it", got)
	}
	if conn, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", up.proxy)); err != nil {
		t.Errorf("the outgoing proxy doesn't listen: %v", err)
	} else {
		conn.Close()
	}
	if config, _ := os.ReadFile(filepath.Join(run.state, "caddy-config")); string(config) != "THE CADDY CONFIG" {
		t.Errorf("caddy got config %q, want the render's output", config)
	}
	if log, _ := os.ReadFile(run.logFile); !strings.Contains(string(log), "render says: a note") {
		t.Errorf("the log lacks the render's note:\n%s", log)
	}
	if strings.Contains(run.stderr.String(), "render says: a note") {
		t.Errorf("stderr %q: a session that starts says nothing", run.stderr)
	}
	if token, _ := os.ReadFile(filepath.Join(run.state, "render-token")); string(token) != "the-token" {
		t.Errorf("the render got GH_TOKEN %q, want the supervisor's", token)
	}
	if token, _ := os.ReadFile(filepath.Join(run.state, "caddy-token")); string(token) != "(unset)" {
		t.Errorf("caddy got GH_TOKEN %q: the token is the render's alone", token)
	}

	// chopi's, as the session ends.
	run.cmd.Process.Signal(syscall.SIGTERM)
	if status := run.awaitExit(t); status != 0 {
		t.Errorf("exit status %d once stopped", status)
	}
	if !run.caddyGone(t) {
		t.Error("caddy outlives the supervisor")
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
	return syscall.Kill(run.mustCaddyPID(t), 0) != nil
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

// awaitLog waits for the supervisor's log to hold want, returning the log.
func (run *supervisorRun) awaitLog(t *testing.T, want string) string {
	t.Helper()
	for deadline := time.Now().Add(10 * time.Second); time.Now().Before(deadline); {
		if log, _ := os.ReadFile(run.logFile); strings.Contains(string(log), want) {
			return string(log)
		}
		time.Sleep(50 * time.Millisecond)
	}
	log, _ := os.ReadFile(run.logFile)
	t.Fatalf("the log never says %q:\n%s", want, log)
	return ""
}

func (run *supervisorRun) editAllowlist(t *testing.T, content string) {
	t.Helper()
	writeFile(t, run.allowlist, content)
}

// pidGone reports whether the process pid has exited, waiting for it a while.
func pidGone(pid int) bool {
	for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); {
		if syscall.Kill(pid, 0) != nil {
			return true
		}
		time.Sleep(50 * time.Millisecond)
	}
	return false
}

func (run *supervisorRun) mustCaddyPID(t *testing.T) int {
	t.Helper()
	pid, err := run.caddyPID()
	if err != nil {
		t.Fatal("caddy never ran")
	}
	return pid
}

// Running chopi sessions are confined to the relays' port and socket: an allowlist edit must
// reach them there.
func TestSupervisorReloadsTheAllowlistOnTheSameListeners(t *testing.T) {
	t.Parallel()
	run := startSupervisor(t, "")
	up := run.awaitPorts(t)
	first := run.mustCaddyPID(t)

	run.editAllowlist(t, "THE NEW CADDY CONFIG")
	log := run.awaitLog(t, allowlistReloaded)
	if config, _ := os.ReadFile(filepath.Join(run.state, "caddy-config")); string(config) != "THE NEW CADDY CONFIG" {
		t.Errorf("caddy got config %q after the edit", config)
	}
	if !strings.Contains(log, "render says: a note") {
		t.Errorf("the log lacks the render's note:\n%s", log)
	}
	second := run.mustCaddyPID(t)
	if second == first {
		t.Fatal("no new caddy started")
	}
	if !pidGone(first) {
		t.Error("the replaced caddy is still up, with no request left to finish")
	}
	if got := get(t, directClient, fmt.Sprintf("http://127.0.0.1:%d/", up.relay)); got != fmt.Sprintf("git port %d from %d", up.relay, second) {
		t.Errorf("the git relay's port answers %q: the new caddy must serve it", got)
	}
	if got := get(t, run.apiClient(), "http://api.github.localhost/"); got != fmt.Sprintf("api from %d", second) {
		t.Errorf("the API relay's socket answers %q: the new caddy must serve it", got)
	}
	select {
	case <-run.exited:
		t.Fatalf("the supervisor stopped as the replaced caddy did (stderr: %s)", run.stderr)
	default:
	}
}

// A save with no edit takes up the allowlist as it is -- clearing a failure banner -- on the Caddy
// already serving it.
func TestSupervisorKeepsTheCaddyOnASaveWithNoEdit(t *testing.T) {
	t.Parallel()
	run := startSupervisor(t, "")
	run.awaitPorts(t)
	first := run.mustCaddyPID(t)

	setMtime(t, run.allowlist, mtimeOf(t, run.allowlist).Add(time.Second))
	run.awaitLog(t, allowlistReloaded)
	if pid := run.mustCaddyPID(t); pid != first {
		t.Errorf("caddy %d replaced by %d, for the config it already served", first, pid)
	}
}

func TestSupervisorKeepsTheRelaysOnAFailedReload(t *testing.T) {
	t.Parallel()
	run := startSupervisor(t, "")
	up := run.awaitPorts(t)
	serving := run.mustCaddyPID(t)
	relay := fmt.Sprintf("http://127.0.0.1:%d/", up.relay)

	for _, c := range []struct{ config, says string }{
		{"RENDER-FAILS", "render says: no token"},
		{"CADDY-FAILS", "caddy says: bad config"},
	} {
		run.editAllowlist(t, c.config)
		log := run.awaitLog(t, c.says)
		if !strings.Contains(log, allowlistReloadFailed) {
			t.Errorf("%s: the log lacks the failure:\n%s", c.config, log)
		}
		if got := get(t, directClient, relay); got != fmt.Sprintf("git port %d from %d", up.relay, serving) {
			t.Errorf("%s: the relay answers %q: the caddy serving must stay", c.config, got)
		}
	}
	run.editAllowlist(t, "THE FIXED CADDY CONFIG")
	run.awaitLog(t, allowlistReloaded)
	if !pidGone(serving) {
		t.Error("the caddy serving stays once a fixed allowlist replaces it")
	}
}

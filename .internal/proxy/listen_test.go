package main

import (
	"net"
	"testing"

	"github.com/stripe/smokescreen/pkg/smokescreen"
)

func TestUseListenerRecordsThePort(t *testing.T) {
	listener, err := listenLoopback(0)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	conf := smokescreen.NewConfig()
	conf.Port = 4750 // smokescreen's default, what it gets without --listen-port
	useListener(conf, listener)

	addr := listener.Addr().(*net.TCPAddr)
	if addr.Port == 0 || int(conf.Port) != addr.Port {
		t.Errorf("listening on port %d with conf.Port %d: the self-connection check needs the real port", addr.Port, conf.Port)
	}
	if !addr.IP.Equal(net.IPv4(127, 0, 0, 1)) {
		t.Errorf("listening on %s, want 127.0.0.1", addr.IP)
	}
}

// freePort returns a loopback port nothing listens on, as of the call.
func freePort(t *testing.T) int {
	t.Helper()
	listener, err := listenLoopback(0)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	return portOf(listener)
}

func TestListenLoopbackPortsTakesThePreferredOnes(t *testing.T) {
	preferred := []int{freePort(t), freePort(t)}
	listeners, err := listenLoopbackPorts(preferred)
	if err != nil {
		t.Fatal(err)
	}
	for i, l := range listeners {
		defer l.Close()
		if portOf(l) != preferred[i] {
			t.Errorf("listener %d on port %d, want the free preferred %d", i, portOf(l), preferred[i])
		}
	}
}

func TestListenLoopbackPortsPicksAnotherForOneTaken(t *testing.T) {
	other, err := listenLoopback(0)
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close()
	free := freePort(t)
	listeners, err := listenLoopbackPorts([]int{portOf(other), free, 0})
	if err != nil {
		t.Fatal(err)
	}
	for _, l := range listeners {
		defer l.Close()
	}
	if p := portOf(listeners[0]); p == portOf(other) || p == free || p == 0 {
		t.Errorf("listener for a taken port on %d: want one the kernel picks, not another process's", p)
	}
	if portOf(listeners[1]) != free {
		t.Errorf("listener on %d, want the free preferred %d: one taken port must not move the others", portOf(listeners[1]), free)
	}
	if p := portOf(listeners[2]); p == 0 || p == free || p == portOf(listeners[0]) {
		t.Errorf("listener for no preference on %d", p)
	}
}

package main

import (
	"net"
	"testing"

	"github.com/stripe/smokescreen/pkg/smokescreen"
)

func TestUseListenerRecordsThePort(t *testing.T) {
	listener, err := listenLoopback()
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

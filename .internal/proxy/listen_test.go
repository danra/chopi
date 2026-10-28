package main

import (
	"net"
	"testing"

	"github.com/stripe/smokescreen/pkg/smokescreen"
)

func TestListenOnPickedPortRecordsThePort(t *testing.T) {
	conf := smokescreen.NewConfig()
	conf.Ip = "127.0.0.1"
	conf.Port = 0
	if err := listenOnPickedPort(conf); err != nil {
		t.Fatal(err)
	}
	defer conf.Listener.Close()

	addr := conf.Listener.Addr().(*net.TCPAddr)
	if addr.Port == 0 || int(conf.Port) != addr.Port {
		t.Errorf("listening on port %d with conf.Port %d: the self-connection check needs the real port", addr.Port, conf.Port)
	}
	if !addr.IP.Equal(net.IPv4(127, 0, 0, 1)) {
		t.Errorf("listening on %s, want 127.0.0.1", addr.IP)
	}
}

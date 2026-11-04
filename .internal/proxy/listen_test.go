package main

import (
	"net"
	"strings"
	"testing"

	"github.com/stripe/smokescreen/pkg/smokescreen"
)

func TestListenOnPickedPortRecordsThePort(t *testing.T) {
	conf := smokescreen.NewConfig()
	conf.Ip = "127.0.0.1"
	conf.Port = 0
	if err := listen(conf); err != nil {
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

func TestListenRefusesAPortTaken(t *testing.T) {
	other, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close()
	conf := smokescreen.NewConfig()
	conf.Ip = "127.0.0.1"
	conf.Port = uint16(other.Addr().(*net.TCPAddr).Port)
	if err := listen(conf); err == nil || !strings.Contains(err.Error(), "address already in use") {
		if err == nil {
			conf.Listener.Close()
		}
		t.Errorf("got %v, want the port refused: another process's listener must not pass for ours", err)
	}
}

package tailnetkit

import (
	"context"
	"io"
	"net"
	"testing"
	"time"
)

// echoDial stands in for the tailnet: each dial gets a connection to an echo server.
func echoDial(t *testing.T) func(context.Context, string, string) (net.Conn, error) {
	t.Helper()
	ln, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() { io.Copy(c, c); c.Close() }()
		}
	}()
	return func(ctx context.Context, network, address string) (net.Conn, error) {
		var d net.Dialer
		return d.DialContext(ctx, "tcp4", ln.Addr().String())
	}
}

func roundTrip(t *testing.T, c net.Conn) {
	t.Helper()
	c.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err := c.Write([]byte("ping")); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 4)
	if _, err := io.ReadFull(c, buf); err != nil || string(buf) != "ping" {
		t.Fatalf("echo: %q, %v", buf, err)
	}
}

func TestDialLoopbackOnlyTakesTheClientPort(t *testing.T) {
	dial := echoDial(t)
	client, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)}) // reserves a port, like a bound socket
	if err != nil {
		t.Fatal(err)
	}
	clientPort := client.Addr().(*net.TCPAddr).Port
	client.Close()

	port, err := dialLoopback(dial, "mac.example.ts.net", 22, 5*time.Second, clientPort)
	if err != nil {
		t.Fatal(err)
	}
	target := &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1), Port: port}
	// Another socket (another app) is turned away.
	intruder, err := net.DialTCP("tcp4", nil, target)
	if err != nil {
		t.Fatal(err)
	}
	intruder.SetReadDeadline(time.Now().Add(5 * time.Second))
	if n, err := intruder.Read(make([]byte, 1)); err == nil {
		t.Fatalf("the intruder read %d bytes", n)
	}
	intruder.Close()
	// The socket from the client port gets the connection.
	c, err := net.DialTCP("tcp4", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1), Port: clientPort}, target)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	roundTrip(t, c)
	// The listener is gone after that.
	if c2, err := net.DialTimeout("tcp4", target.String(), time.Second); err == nil {
		c2.Close()
		t.Fatal("the port still takes connections")
	}
}

func TestDialLoopbackFirstConnection(t *testing.T) {
	port, err := dialLoopback(echoDial(t), "100.64.0.1", 22, 5*time.Second, 0)
	if err != nil {
		t.Fatal(err)
	}
	c, err := net.Dial("tcp4", (&net.TCPAddr{IP: net.IPv4(127, 0, 0, 1), Port: port}).String())
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	roundTrip(t, c)
}

func TestDialLoopbackClosesTheRemoteWithoutAConnection(t *testing.T) {
	old := acceptWindow
	acceptWindow = 200 * time.Millisecond
	defer func() { acceptWindow = old }()
	closed := make(chan struct{})
	dial := func(context.Context, string, string) (net.Conn, error) {
		a, b := net.Pipe()
		go func() { io.Copy(io.Discard, b); close(closed) }()
		return a, nil
	}
	if _, err := dialLoopback(dial, "100.64.0.1", 22, time.Second, 0); err != nil {
		t.Fatal(err)
	}
	select {
	case <-closed:
	case <-time.After(5 * time.Second):
		t.Fatal("the tailnet connection stayed open")
	}
}

func TestDialLoopbackRejectsBadPorts(t *testing.T) {
	dial := echoDial(t)
	for _, ports := range [][2]int{{0, 0}, {70000, 0}, {22, -1}, {22, 70000}} {
		if _, err := dialLoopback(dial, "host", ports[0], time.Second, ports[1]); err == nil {
			t.Errorf("ports %v were taken", ports)
		}
	}
}

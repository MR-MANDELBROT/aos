package tailnetkit

import (
	"context"
	"errors"
	"net"
	"strconv"
	"time"

	"dev.marquart/aos/tailnet"
)

// acceptWindow is how long Dial's local port waits for the app's connection.
var acceptWindow = 15 * time.Second

// dialLoopback connects to host:port with dial (the node's, through the tailnet), then offers that connection on a
// new listener on 127.0.0.1 and returns its port. The listener takes one connection within acceptWindow and closes:
// a connection from clientPort when that is > 0 (the app binds its socket first and passes its port, so no other app
// on the device can take the connection), else the first one from a loopback address. Without a connection in time
// the tailnet connection closes.
func dialLoopback(dial func(ctx context.Context, network, address string) (net.Conn, error), host string, port int,
	timeout time.Duration, clientPort int) (int, error) {
	if port <= 0 || port > 65535 {
		return -1, errors.New("tailnetkit: bad port")
	}
	if clientPort < 0 || clientPort > 65535 {
		return -1, errors.New("tailnetkit: bad client port")
	}
	if timeout <= 0 {
		timeout = 15 * time.Second
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	remote, err := dial(ctx, "tcp", net.JoinHostPort(host, strconv.Itoa(port)))
	if err != nil {
		return -1, err
	}
	ln, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		remote.Close()
		return -1, err
	}
	go acceptOne(ln, remote, clientPort)
	return ln.Addr().(*net.TCPAddr).Port, nil
}

func acceptOne(ln *net.TCPListener, remote net.Conn, clientPort int) {
	defer ln.Close()
	ln.SetDeadline(time.Now().Add(acceptWindow))
	for {
		local, err := ln.AcceptTCP()
		if err != nil {
			remote.Close()
			return
		}
		peer, _ := local.RemoteAddr().(*net.TCPAddr)
		if peer == nil || !peer.IP.IsLoopback() || clientPort > 0 && peer.Port != clientPort {
			local.Close()
			continue
		}
		ln.Close()
		local.SetNoDelay(true)
		tailnet.Splice(local, remote)
		return
	}
}

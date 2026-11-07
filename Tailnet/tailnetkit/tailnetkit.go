//go:build darwin || ios

// Package tailnetkit is aOS's Tailscale node for the iPhone app, bound with gomobile into Tailnetkit.xcframework
// (Tailnet/build.sh ios). The app keeps the node's state in its own container (with file protection, not in
// backups), signs it in with the person's Tailscale account in a web authentication session, and dials the Mac's
// node through it: DialFD hands over a connected socket that SwiftNIO takes as its channel.
//
// Only types gomobile can bind appear here: strings, ints, errors and the Node handle.
package tailnetkit

import (
	"context"
	"errors"
	"net"
	"os"
	"strconv"
	"sync"
	"time"

	"golang.org/x/sys/unix"

	"dev.marquart/aos/tailnet"
)

// Node is one embedded tailnet node.
type Node struct {
	mu   sync.Mutex
	node *tailnet.Node
}

// NewNode prepares a node with its state in dir (an absolute path the app created). controlURL is empty for
// Tailscale's coordination server.
func NewNode(dir, hostname, controlURL string) (*Node, error) {
	if !tailnet.BuiltForAOS() {
		return nil, errors.New("Tailnetkit was built without aOS's build tags")
	}
	n, err := tailnet.New(tailnet.Config{Dir: dir, Hostname: hostname, ControlURL: controlURL})
	if err != nil {
		return nil, err
	}
	return &Node{node: n}, nil
}

func (n *Node) current() (*tailnet.Node, error) {
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.node == nil {
		return nil, net.ErrClosed
	}
	return n.node, nil
}

// Start starts the node without waiting (a node that isn't signed in reports NeedsLogin and a sign-in URL).
func (n *Node) Start() error {
	node, err := n.current()
	if err != nil {
		return err
	}
	return node.Start()
}

// StatusJSON is Tailscale's status JSON (the format of `tailscale status --json`).
func (n *Node) StatusJSON() (string, error) {
	node, err := n.current()
	if err != nil {
		return "", err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	data, err := node.StatusJSON(ctx)
	return string(data), err
}

// Login asks for a new sign-in URL.
func (n *Node) Login() error {
	node, err := n.current()
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	return node.Login(ctx)
}

// Logout removes the node from the tailnet. The app then closes it and deletes its state.
func (n *Node) Logout() error {
	node, err := n.current()
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	return node.Logout(ctx)
}

// Close stops the node.
func (n *Node) Close() error {
	n.mu.Lock()
	node := n.node
	n.node = nil
	n.mu.Unlock()
	if node == nil {
		return nil
	}
	return node.Close()
}

// DialFD connects to host:port through the tailnet (host: a tailnet address or MagicDNS name) and returns one end
// of a connected socket pair; the other end is spliced to the tailnet connection. The caller owns the descriptor
// and closes it.
func (n *Node) DialFD(host string, port int, timeoutMillis int) (int, error) {
	node, err := n.current()
	if err != nil {
		return -1, err
	}
	if port <= 0 || port > 65535 {
		return -1, errors.New("tailnetkit: bad port")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutMillis)*time.Millisecond)
	defer cancel()
	conn, err := node.Dial(ctx, "tcp", net.JoinHostPort(host, strconv.Itoa(port)))
	if err != nil {
		return -1, err
	}
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_STREAM, 0)
	if err != nil {
		conn.Close()
		return -1, err
	}
	for _, fd := range fds {
		unix.CloseOnExec(fd)
		// A write after the other side closed returns EPIPE instead of ending the app with SIGPIPE.
		unix.SetsockoptInt(fd, unix.SOL_SOCKET, unix.SO_NOSIGPIPE, 1)
	}
	file := os.NewFile(uintptr(fds[0]), "tailnet")
	local, err := net.FileConn(file)
	file.Close()
	if err != nil {
		unix.Close(fds[1])
		conn.Close()
		return -1, err
	}
	go tailnet.Splice(local, conn)
	return fds[1], nil
}

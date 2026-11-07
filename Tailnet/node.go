// Package tailnet is aOS's own Tailscale node, built on tsnet: userspace networking, no VPN, no network extension,
// no system settings. The same code runs on the Mac and on the iPhone (Docs/DESIGN.md, "Reaching the Mac on the
// go"):
//
//   - on the Mac in aos-tailnet, which aOS's root helper starts as the hidden user _aostailnet: the node makes the
//     Mac's SSH server (127.0.0.1:22) reachable on port 22 of its tailnet address, and nothing else;
//   - on the iPhone in the Tailnetkit framework (package tailnetkit): the app dials the Mac through it.
//
// What the node can do is also limited at build time: Tailnet/build.sh leaves out the peer API server, Taildrop,
// Tailscale SSH, the web client and the other features that would offer something on the tailnet (TAGS there). A
// binary built without them refuses to start (BuiltForAOS).
package tailnet

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"sync"
	"time"

	"tailscale.com/envknob"
	"tailscale.com/feature/buildfeatures"
	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/tsnet"
)

// Config describes one node.
type Config struct {
	// Dir holds the node's state, among it its keys. It is created with mode 0700.
	Dir string
	// Hostname is the name the node registers with; aOS uses "aos-<device>".
	Hostname string
	// ControlURL is empty for Tailscale's coordination server; the tests use their own.
	ControlURL string
	// Logf gets the backend's verbose log, without sign-in URLs (nil: discarded).
	Logf func(format string, args ...any)

	// Store and Ephemeral are for the tests (state in memory, the node goes away when it closes).
	Store     ipn.StateStore
	Ephemeral bool
}

// Node is one running tsnet server.
type Node struct {
	cfg Config
	srv *tsnet.Server

	mu        sync.Mutex
	listeners []net.Listener
	closed    bool
}

// BuiltForAOS reports whether this binary was built with aOS's build tags: without the peer API server (it would
// listen on the node's tailnet address), Taildrop, Tailscale SSH, the web client, Taildrive, the relay server, routes,
// exit nodes and remote configuration. (Serve stays in: tsnet itself needs it; the node never gets a serve
// configuration, so it serves nothing.)
func BuiltForAOS() bool {
	return !buildfeatures.HasPeerAPIServer && !buildfeatures.HasTaildrop && !buildfeatures.HasSSH &&
		!buildfeatures.HasWebClient && !buildfeatures.HasRelayServer && !buildfeatures.HasDrive &&
		!buildfeatures.HasAdvertiseExitNode && !buildfeatures.HasAdvertiseRoutes && !buildfeatures.HasRemoteConfig &&
		!buildfeatures.HasLogTail
}

var hostnamePattern = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`)

// ValidHostname reports whether name is a DNS label aOS may register: 1 to 63 lowercase letters, digits and
// hyphens, not starting or ending with a hyphen.
func ValidHostname(name string) bool { return hostnamePattern.MatchString(name) }

// New checks the configuration and prepares the node; Start starts it.
func New(cfg Config) (*Node, error) {
	if cfg.Dir == "" || !filepath.IsAbs(cfg.Dir) {
		return nil, errors.New("tailnet: the state folder must be an absolute path")
	}
	if !ValidHostname(cfg.Hostname) {
		return nil, fmt.Errorf("tailnet: %q is not a valid host name", cfg.Hostname)
	}
	// aOS doesn't send Tailscale its logs (log.tailscale.com): the node is aOS's, not a Tailscale client the person
	// could ask Tailscale's support about. Process wide, before anything of tsnet runs.
	envknob.SetNoLogsNoSupport()
	if err := os.MkdirAll(cfg.Dir, 0o700); err != nil {
		return nil, err
	}
	if err := os.Chmod(cfg.Dir, 0o700); err != nil {
		return nil, err
	}
	logf := redacting(cfg.Logf)
	srv := &tsnet.Server{
		Dir:        cfg.Dir,
		Hostname:   cfg.Hostname,
		ControlURL: cfg.ControlURL,
		Store:      cfg.Store,
		Ephemeral:  cfg.Ephemeral,
		Logf:       logf,
		// The messages "for the user" carry the sign-in URL every few seconds; the app gets it from Status.
		UserLogf: logf,
	}
	return &Node{cfg: cfg, srv: srv}, nil
}

// Start starts the node without waiting: a node that isn't signed in yet reports NeedsLogin and a sign-in URL in
// Status.
func (n *Node) Start() error { return n.srv.Start() }

// Status is Tailscale's own status (the format of `tailscale status --json`).
func (n *Node) Status(ctx context.Context) (*ipnstate.Status, error) {
	lc, err := n.srv.LocalClient()
	if err != nil {
		return nil, err
	}
	return lc.Status(ctx)
}

// StatusJSON is Status as JSON.
func (n *Node) StatusJSON(ctx context.Context) ([]byte, error) {
	st, err := n.Status(ctx)
	if err != nil {
		return nil, err
	}
	return json.Marshal(st)
}

// Login asks the coordination server for a new sign-in URL (it appears in Status).
func (n *Node) Login(ctx context.Context) error {
	lc, err := n.srv.LocalClient()
	if err != nil {
		return err
	}
	return lc.StartLoginInteractive(ctx)
}

// Logout signs the node out: the coordination server removes it from the tailnet and its key is no longer valid.
// The caller then closes the node and deletes its folder.
func (n *Node) Logout(ctx context.Context) error {
	lc, err := n.srv.LocalClient()
	if err != nil {
		return err
	}
	return lc.Logout(ctx)
}

// Dial connects to address (host:port; a tailnet address or MagicDNS name) through the tailnet. It waits until the
// node runs, as long as ctx allows.
func (n *Node) Dial(ctx context.Context, network, address string) (net.Conn, error) {
	return n.srv.Dial(ctx, network, address)
}

// Forward makes TCP port `port` of the node's tailnet addresses (IPv4 and IPv6) lead to target, one connection
// per connection. aOS forwards 22 to 127.0.0.1:22, the Mac's own SSH server. tsnet answers only ports with a
// listener; every other port is refused.
func (n *Node) Forward(port uint16, target string) error {
	return n.ForwardTo(port, func() string { return target })
}

// ForwardTo is Forward with the target looked up for each connection (the iPhone's end-to-end test points it at
// its own SSH server; aos-tailnet uses Forward with the fixed target).
func (n *Node) ForwardTo(port uint16, target func() string) error {
	ln, err := n.srv.Listen("tcp", fmt.Sprintf(":%d", port))
	if err != nil {
		return err
	}
	n.mu.Lock()
	if n.closed {
		n.mu.Unlock()
		ln.Close()
		return net.ErrClosed
	}
	n.listeners = append(n.listeners, ln)
	n.mu.Unlock()
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go forward(conn, target(), n.logf)
		}
	}()
	return nil
}

func forward(in net.Conn, target string, logf func(string, ...any)) {
	out, err := net.DialTimeout("tcp", target, 10*time.Second)
	if err != nil {
		logf("forward to %s: %v", target, err)
		in.Close()
		return
	}
	if tcp, ok := out.(*net.TCPConn); ok {
		tcp.SetKeepAlive(true)
		tcp.SetKeepAlivePeriod(30 * time.Second)
	}
	Splice(in, out)
}

// Splice copies both ways until both directions ended (or one ended and the other stayed idle for a minute), then
// closes both connections.
func Splice(a, b net.Conn) {
	done := make(chan struct{}, 2)
	copyHalf := func(dst, src net.Conn) {
		io.Copy(dst, src)
		if cw, ok := dst.(interface{ CloseWrite() error }); ok {
			cw.CloseWrite()
		} else {
			dst.Close()
		}
		done <- struct{}{}
	}
	go copyHalf(a, b)
	go copyHalf(b, a)
	<-done
	select {
	case <-done:
	case <-time.After(time.Minute):
	}
	a.Close()
	b.Close()
}

func (n *Node) logf(format string, args ...any) {
	if n.cfg.Logf != nil {
		redacting(n.cfg.Logf)(format, args...)
	}
}

// Close stops the node and its listeners.
func (n *Node) Close() error {
	n.mu.Lock()
	if n.closed {
		n.mu.Unlock()
		return nil
	}
	n.closed = true
	listeners := n.listeners
	n.listeners = nil
	n.mu.Unlock()
	for _, ln := range listeners {
		ln.Close()
	}
	return n.srv.Close()
}

var urlPattern = regexp.MustCompile(`https?://\S+`)

// redacting wraps logf so that no URL reaches the log: a sign-in URL lets whoever opens it first put the node into
// their tailnet.
func redacting(logf func(string, ...any)) func(string, ...any) {
	if logf == nil {
		return func(string, ...any) {}
	}
	return func(format string, args ...any) {
		logf("%s", Redact(fmt.Sprintf(format, args...)))
	}
}

// Redact replaces every URL in line with "<url>".
func Redact(line string) string { return urlPattern.ReplaceAllString(line, "<url>") }

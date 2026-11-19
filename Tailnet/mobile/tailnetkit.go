// Package tailnetkit (folder Tailnet/mobile) is aOS's Tailscale node for the Android app: package tailnet behind an
// API gomobile can bind (Java package dev.marquart.aos.tailnetkit). The Android counterpart of the iPhone's
// Tailnetkit (Tailnet/tailnetkit, a C library).
//
// It is bound in one library together with Open Screen Sharing's libsharing (Android/Tools/go-android.sh, aosgo.aar),
// not on its own: on Android 10 and later every Go runtime keeps its goroutine pointer in the same thread-local slot
// (TLS_SLOT_APP, Go's runtime/cgo/gcc_android.c), so two Go libraries in one process crash as soon as one thread calls
// into both. (On the iPhone each runtime finds its own slot, so there the two stay separate.)
//
// The node offers nothing on the tailnet (Tailnet/build.sh's build tags; NewNode refuses a build without them). The
// app dials the Mac through it: Dial connects through the tailnet and hands the connection over as a one-time TCP
// listener on 127.0.0.1, which a JVM SSH library can connect to.
package tailnetkit

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"net/url"
	"slices"
	"strings"
	"sync"
	"time"

	"tailscale.com/ipn"

	"dev.marquart/aos/tailnet"
)

// Logger gets the node's log, one line per call, with every URL replaced by "<url>" (a sign-in URL lets whoever opens
// it first put the node into their tailnet). It runs on Go threads; android.util.Log is fine there.
type Logger interface {
	Log(line string)
}

// Listener hears about a node's state. OnState runs on a Go thread (never the main thread); the app posts onward.
type Listener interface {
	OnState(state *State)
}

// State is a node's state: what the iPhone app reads from Tailscale's status.
type State struct {
	// BackendState is Tailscale's state: NoState, NeedsLogin, NeedsMachineAuth, Stopped, Starting, Running.
	BackendState string
	// authURL is the sign-in page (AuthURL): a method, not a field, so that gomobile's toString leaves it out.
	authURL string
	// Tailnet is the tailnet's name (often the account's e-mail address or domain), else "".
	Tailnet string
	// MagicDNSSuffix is the tailnet's MagicDNS suffix, such as "tail1234.ts.net", else "".
	MagicDNSSuffix string
	// DNSName is this node's MagicDNS name without the final dot, else "".
	DNSName string
	// Addresses are this node's tailnet addresses, comma-separated, IPv4 first.
	Addresses string
	// KeyExpiry is when the node's key expires (RFC 3339), else "".
	KeyExpiry string
	// Health lists Tailscale's health problems, one per line.
	Health string
	// Error is the last critical message (from Tailscale or the watch), else "".
	Error string
}

// AuthURL is the sign-in page while the node needs one, else "". Open it only if IsSignInPage says so: whoever
// completes it first puts the node into their tailnet, so it never belongs in a log (State's toString leaves it out).
func (s *State) AuthURL() string { return s.authURL }

// IsRunning reports whether the node is signed in and connected.
func (s *State) IsRunning() bool { return s.BackendState == ipn.Running.String() }

// NeedsLogin reports whether the node waits for a sign-in.
func (s *State) NeedsLogin() bool { return s.BackendState == ipn.NeedsLogin.String() }

// BuiltForAOS reports whether the library was built with aOS's build tags (without Tailscale's servers on the
// tailnet); NewNode refuses to run otherwise.
func BuiltForAOS() bool { return tailnet.BuiltForAOS() }

// IsSignInPage reports whether page is one of Tailscale's own sign-in pages (https, tailscale.com): only those open.
func IsSignInPage(page string) bool {
	u, err := url.Parse(page)
	if err != nil || u.Scheme != "https" {
		return false
	}
	host := strings.ToLower(u.Hostname())
	return host == "tailscale.com" || strings.HasSuffix(host, ".tailscale.com")
}

// Node is one Tailscale node. Its methods block (up to 10 to 20 seconds, Dial up to its timeout): call them off the
// main thread.
type Node struct {
	node *tailnet.Node

	mu      sync.Mutex
	cancel  context.CancelFunc // ends the watch
	started bool
	closed  bool
	problem string // the last critical message from the IPN bus or the watch
}

// NewNode prepares a node with its state (its keys among it) in dir, an absolute path the app keeps out of backups
// (for example Context.getNoBackupFilesDir() + "/Tailnet"; created with mode 0700). hostname is a DNS label (aOS:
// "aos-" and the device's name). controlURL is "" for Tailscale's coordination server (tests pass their own).
// logger (may be null) gets the node's verbose log.
func NewNode(dir, hostname, controlURL string, logger Logger) (*Node, error) {
	if !tailnet.BuiltForAOS() {
		return nil, errors.New("tailnetkit was built without aOS's build tags")
	}
	config := tailnet.Config{Dir: dir, Hostname: hostname, ControlURL: controlURL}
	if logger != nil {
		config.Logf = func(format string, args ...any) { logger.Log(fmt.Sprintf(format, args...)) }
	}
	n, err := tailnet.New(config)
	if err != nil {
		return nil, err
	}
	return &Node{node: n}, nil
}

// Start starts the node without waiting (a node that isn't signed in reports NeedsLogin and a sign-in URL). The
// listener (may be null) gets the state now and whenever it changes. Starting again does nothing.
func (n *Node) Start(listener Listener) error {
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.closed {
		return net.ErrClosed
	}
	if n.started {
		return nil
	}
	if err := n.node.Start(); err != nil {
		return err
	}
	n.started = true
	if listener != nil {
		ctx, cancel := context.WithCancel(context.Background())
		n.cancel = cancel
		go n.watch(ctx, listener)
	}
	return nil
}

// State is the node's current state.
func (n *Node) State() (*State, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return n.state(ctx)
}

// StatusJSON is Tailscale's whole status (the format of `tailscale status --json`, as the iPhone app reads it).
func (n *Node) StatusJSON() (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	data, err := n.node.StatusJSON(ctx)
	return string(data), err
}

// Login asks for a new sign-in URL (it comes with the next state).
func (n *Node) Login() error {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	return n.node.Login(ctx)
}

// Logout signs the node out: it leaves the tailnet. Then the app closes it and deletes its folder.
func (n *Node) Logout() error {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	return n.node.Logout(ctx)
}

// Dial connects to host:port through the tailnet (host: a tailnet address or MagicDNS name; it waits until the node
// runs, as long as timeoutMillis allows) and returns a port on 127.0.0.1 that leads to that connection. The port takes
// one connection within 15 seconds and closes. With clientPort > 0 it takes only a connection from that local port:
// bind the socket to 127.0.0.1 first and pass its port, then no other app on the device can take the connection.
func (n *Node) Dial(host string, port, timeoutMillis, clientPort int32) (int32, error) {
	local, err := dialLoopback(n.node.Dial, host, int(port), time.Duration(timeoutMillis)*time.Millisecond, int(clientPort))
	return int32(local), err
}

// Close stops the node and its watch; it is unusable afterwards. Safe to call more than once and from the listener.
func (n *Node) Close() {
	n.mu.Lock()
	if n.closed {
		n.mu.Unlock()
		return
	}
	n.closed = true
	cancel := n.cancel
	n.cancel = nil
	n.mu.Unlock()
	if cancel != nil {
		cancel()
	}
	n.node.Close()
}

func (n *Node) state(ctx context.Context) (*State, error) {
	st, err := n.node.Status(ctx)
	if err != nil {
		return nil, err
	}
	s := &State{BackendState: st.BackendState, authURL: st.AuthURL, Health: strings.Join(st.Health, "\n")}
	if t := st.CurrentTailnet; t != nil {
		s.Tailnet, s.MagicDNSSuffix = t.Name, t.MagicDNSSuffix
	}
	if self := st.Self; self != nil {
		s.DNSName = strings.TrimSuffix(self.DNSName, ".")
		if self.KeyExpiry != nil {
			s.KeyExpiry = self.KeyExpiry.UTC().Format(time.RFC3339)
		}
	}
	addresses := slices.Clone(st.TailscaleIPs)
	slices.SortStableFunc(addresses, func(a, b netip.Addr) int {
		switch {
		case a.Is4() && !b.Is4():
			return -1
		case b.Is4() && !a.Is4():
			return 1
		}
		return 0
	})
	texts := make([]string, len(addresses))
	for i, a := range addresses {
		texts[i] = a.String()
	}
	s.Addresses = strings.Join(texts, ",")
	n.mu.Lock()
	s.Error = n.problem
	n.mu.Unlock()
	return s, nil
}

// watch follows the node's IPN bus and hands the state to listener whenever it changed, on this goroutine. Nothing
// is locked meanwhile: the listener may call anything, Close too.
func (n *Node) watch(ctx context.Context, listener Listener) {
	var last []byte
	send := func() {
		stateCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
		s, err := n.state(stateCtx)
		cancel()
		if err != nil || ctx.Err() != nil {
			return
		}
		data, _ := json.Marshal(struct {
			*State
			AuthURL string
		}{s, s.authURL})
		if string(data) == string(last) {
			return
		}
		last = data
		listener.OnState(s)
	}
	fail := func(err error) {
		if ctx.Err() != nil {
			return
		}
		n.mu.Lock()
		n.problem = err.Error()
		n.mu.Unlock()
		send()
	}
	lc, err := n.node.LocalClient()
	if err != nil {
		fail(err)
		return
	}
	for ctx.Err() == nil {
		watcher, err := lc.WatchIPNBus(ctx, ipn.NotifyInitialState|ipn.NotifyInitialHealthState)
		if err != nil {
			fail(err)
			select {
			case <-ctx.Done():
			case <-time.After(2 * time.Second):
			}
			continue
		}
		for {
			notify, err := watcher.Next()
			if err != nil {
				watcher.Close()
				fail(err)
				select {
				case <-ctx.Done():
				case <-time.After(2 * time.Second):
				}
				break
			}
			n.mu.Lock()
			if notify.ErrMessage != nil {
				n.problem = *notify.ErrMessage
			}
			if notify.LoginFinished != nil || notify.State != nil && *notify.State == ipn.Running {
				n.problem = ""
			}
			n.mu.Unlock()
			send()
		}
	}
}

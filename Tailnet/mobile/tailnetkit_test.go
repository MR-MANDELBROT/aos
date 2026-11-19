package tailnetkit

import (
	"context"
	"io"
	"net"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"tailscale.com/ipn/store/mem"

	"dev.marquart/aos/tailnet"
	"dev.marquart/aos/tailnet/internal/testnet"
)

// Against Tailscale's test coordination server on 127.0.0.1 (no account, no internet), like Tailnet's own tests. Run
// with Tailnet/build.sh test (the build tags matter).

type logger chan string

func (l logger) Log(line string) {
	select {
	case l <- line:
	default:
	}
}

type listener chan *State

func (l listener) OnState(s *State) { l <- s }

func next(t *testing.T, states listener, want func(*State) bool) *State {
	t.Helper()
	deadline := time.After(60 * time.Second)
	for {
		select {
		case s := <-states:
			if want(s) {
				return s
			}
		case <-deadline:
			t.Fatal("the expected state didn't come")
		}
	}
}

func TestSignInDialAndSignOut(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	controlURL, control := testnet.StartControl(t, true)

	// The Mac: aOS's node with port 22 forwarded to an echo server.
	echo, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer echo.Close()
	go func() {
		for {
			c, err := echo.Accept()
			if err != nil {
				return
			}
			go func() { io.Copy(c, c); c.Close() }()
		}
	}()
	mac, err := tailnet.New(tailnet.Config{Dir: filepath.Join(t.TempDir(), "mac"), Hostname: "aos-mac",
		ControlURL: controlURL, Store: new(mem.Store), Ephemeral: true})
	if err != nil {
		t.Fatal(err)
	}
	defer mac.Close()
	if err := mac.Start(); err != nil {
		t.Fatal(err)
	}
	if err := mac.Forward(22, echo.Addr().String()); err != nil {
		t.Fatal(err)
	}
	var macIP string
	for macIP == "" {
		st, err := mac.Status(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if st.AuthURL != "" {
			control.CompleteAuth(st.AuthURL)
		}
		for _, ip := range st.TailscaleIPs {
			if ip.Is4() {
				macIP = ip.String()
			}
		}
		if macIP == "" {
			select {
			case <-ctx.Done():
				t.Fatal("the Mac's node didn't come up")
			case <-time.After(50 * time.Millisecond):
			}
		}
	}

	// The phone: this package, as the app uses it.
	if !BuiltForAOS() {
		t.Fatal("not built with aOS's build tags")
	}
	logged := make(logger, 4096)
	node, err := NewNode(filepath.Join(t.TempDir(), "phone"), "aos-phone", controlURL, logged)
	if err != nil {
		t.Fatal(err)
	}
	defer node.Close()
	states := make(listener, 64)
	if err := node.Start(states); err != nil {
		t.Fatal(err)
	}
	if err := node.Start(states); err != nil {
		t.Fatalf("starting again: %v", err)
	}
	waiting := next(t, states, func(s *State) bool { return s.NeedsLogin() && s.AuthURL() != "" })
	if !strings.HasPrefix(waiting.AuthURL(), controlURL) || IsSignInPage(waiting.AuthURL()) {
		t.Fatalf("sign-in URL %q", waiting.AuthURL())
	}
	if !control.CompleteAuth(waiting.AuthURL()) {
		t.Fatal("the coordination server didn't know the sign-in URL")
	}
	running := next(t, states, func(s *State) bool { return s.IsRunning() && s.Addresses != "" })
	if !strings.HasPrefix(running.DNSName, "aos-phone.") || running.AuthURL() != "" || strings.HasPrefix(running.Addresses, "fd7a") {
		t.Fatalf("running: %+v", running)
	}
	if json, err := node.StatusJSON(); err != nil || !strings.Contains(json, `"BackendState":"Running"`) {
		t.Fatalf("status JSON: %v %.200s", err, json)
	}

	// Dial the Mac's port 22 from a socket bound first; another socket is turned away.
	client, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	clientPort := client.Addr().(*net.TCPAddr).Port
	client.Close()
	port, err := node.Dial(macIP, 22, 20000, int32(clientPort))
	if err != nil {
		t.Fatal(err)
	}
	target := &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1), Port: int(port)}
	if intruder, err := net.DialTCP("tcp4", nil, target); err == nil {
		intruder.SetReadDeadline(time.Now().Add(5 * time.Second))
		if n, err := intruder.Read(make([]byte, 1)); err == nil {
			t.Fatalf("another socket read %d bytes", n)
		}
		intruder.Close()
	}
	conn, err := net.DialTCP("tcp4", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1), Port: clientPort}, target)
	if err != nil {
		t.Fatal(err)
	}
	conn.SetDeadline(time.Now().Add(10 * time.Second))
	if _, err := conn.Write([]byte("ping")); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 4)
	if _, err := io.ReadFull(conn, buf); err != nil || string(buf) != "ping" {
		t.Fatalf("through the tailnet: %q, %v", buf, err)
	}
	conn.Close()

	// A port nobody listens on is refused.
	if _, err := node.Dial(macIP, 8022, 5000, 0); err == nil {
		t.Error("port 8022 of the Mac answered")
	}

	// Signing out: the node needs a sign-in again.
	if err := node.Logout(); err != nil {
		t.Fatal(err)
	}
	next(t, states, func(s *State) bool { return s.NeedsLogin() })
	node.Close()
	node.Close()
	lines := 0
	for drained := false; !drained; {
		select {
		case line := <-logged:
			lines++
			if strings.Contains(line, "http://") || strings.Contains(line, "https://") {
				t.Errorf("a URL in the log: %q", line)
			}
		default:
			drained = true
		}
	}
	if lines == 0 {
		t.Error("nothing logged")
	}
	if _, err := node.State(); err == nil {
		t.Error("a closed node still reports a state")
	}
}

func TestIsSignInPage(t *testing.T) {
	for page, want := range map[string]bool{
		"https://login.tailscale.com/a/1234": true,
		"https://tailscale.com/x":            true,
		"http://login.tailscale.com/a/1234":  false,
		"https://tailscale.com.example/a":    false,
		"https://evil.example/tailscale.com": false,
		"":                                   false,
	} {
		if got := IsSignInPage(page); got != want {
			t.Errorf("IsSignInPage(%q) = %v", page, got)
		}
	}
}

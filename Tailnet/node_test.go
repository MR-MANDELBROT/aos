package tailnet

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"net"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"tailscale.com/ipn/ipnstate"
	"tailscale.com/ipn/store/mem"
	"tailscale.com/tstest/integration/testcontrol"

	"dev.marquart/aos/tailnet/internal/testnet"
)

// The tests run against Tailscale's own test coordination server and a DERP server on 127.0.0.1 (what tsnet's own
// tests use): no account, no internet. Run them with Tailnet/build.sh test (the build tags matter).

func startControl(t *testing.T, requireAuth bool) (string, *testcontrol.Server) {
	return testnet.StartControl(t, requireAuth)
}

func newNode(t *testing.T, controlURL, hostname string) *Node {
	t.Helper()
	node, err := New(Config{
		Dir:        filepath.Join(t.TempDir(), hostname),
		Hostname:   hostname,
		ControlURL: controlURL,
		Store:      new(mem.Store),
		Ephemeral:  true,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { node.Close() })
	if err := node.Start(); err != nil {
		t.Fatal(err)
	}
	return node
}

func waitForState(t *testing.T, ctx context.Context, node *Node, want string) *ipnstate.Status {
	t.Helper()
	for {
		st, err := node.Status(ctx)
		if err == nil && st.BackendState == want && (want != "Running" || len(st.TailscaleIPs) > 0) {
			return st
		}
		select {
		case <-ctx.Done():
			state := "?"
			if st != nil {
				state = st.BackendState
			}
			t.Fatalf("%s didn't reach %s (last state %s)", node.cfg.Hostname, want, state)
		case <-time.After(50 * time.Millisecond):
		}
	}
}

// A stand-in for the Mac's sshd: a banner, then an echo.
func fakeSSHServer(t *testing.T) net.Listener {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
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
			go func() {
				defer c.Close()
				io.WriteString(c, "SSH-2.0-aos-test\r\n")
				io.Copy(c, c)
			}()
		}
	}()
	return ln
}

func TestBuiltWithAOSTags(t *testing.T) {
	if !BuiltForAOS() {
		t.Fatal("built without aOS's build tags: run the tests with Tailnet/build.sh test")
	}
}

// The Mac's node joins the tailnet, a second node dials its port 22 and reaches the local server behind it, and no
// other port of the Mac's node answers.
func TestOnlyPort22ReachesTheMac(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	controlURL, _ := startControl(t, false)
	sshd := fakeSSHServer(t)

	mac := newNode(t, controlURL, "aos-mac")
	if err := mac.Forward(22, sshd.Addr().String()); err != nil {
		t.Fatal(err)
	}
	macStatus := waitForState(t, ctx, mac, "Running")
	phone := newNode(t, controlURL, "aos-phone")
	waitForState(t, ctx, phone, "Running")

	var mac4, mac6 string
	for _, ip := range macStatus.TailscaleIPs {
		if ip.Is4() {
			mac4 = ip.String()
		} else {
			mac6 = ip.String()
		}
	}
	if mac4 == "" || mac6 == "" {
		t.Fatalf("the Mac's node has no IPv4 or IPv6 address: %v", macStatus.TailscaleIPs)
	}

	expectSSH := func(address string) {
		t.Helper()
		conn, err := phone.Dial(ctx, "tcp", address)
		if err != nil {
			t.Fatalf("dial %s: %v", address, err)
		}
		defer conn.Close()
		conn.SetDeadline(time.Now().Add(15 * time.Second))
		reader := bufio.NewReader(conn)
		banner, err := reader.ReadString('\n')
		if err != nil || banner != "SSH-2.0-aos-test\r\n" {
			t.Fatalf("%s: banner %q, %v", address, banner, err)
		}
		io.WriteString(conn, "hello\n")
		echo, err := reader.ReadString('\n')
		if err != nil || echo != "hello\n" {
			t.Fatalf("%s: echo %q, %v", address, echo, err)
		}
	}
	expectSSH(net.JoinHostPort(mac4, "22"))
	expectSSH(net.JoinHostPort(mac6, "22"))
	expectSSH("aos-mac." + testnet.MagicDNSDomain + ":22")

	// Nothing else: a few ports services like to use, the web client's and the WireGuard port.
	for _, ip := range []string{mac4, mac6} {
		for _, port := range []string{"21", "23", "80", "443", "445", "548", "3283", "5252", "5900", "8080", "41641"} {
			dialCtx, dialCancel := context.WithTimeout(ctx, 5*time.Second)
			conn, err := phone.Dial(dialCtx, "tcp", net.JoinHostPort(ip, port))
			dialCancel()
			if err == nil {
				conn.Close()
				t.Errorf("port %s of the Mac's node at %s answers", port, ip)
			}
		}
	}

	// Every TCP port of both addresses (65535 each, in parallel, about a second): only 22 answers.
	for _, ip := range []string{mac4, mac6} {
		if open := scanTCP(ctx, phone, ip); !slices.Equal(open, []int{22}) {
			t.Errorf("open TCP ports of the Mac's node at %s: %v (only 22 should be)", ip, open)
		}
	}

	// The checks above would notice an open port: one more forward, and it answers and shows in the scan.
	if err := mac.Forward(8022, sshd.Addr().String()); err != nil {
		t.Fatal(err)
	}
	expectSSH(net.JoinHostPort(mac4, "8022"))
	if open := scanTCP(ctx, phone, mac4); !slices.Equal(open, []int{22, 8022}) {
		t.Errorf("the scan should find 22 and 8022: %v", open)
	}

	// No peer API (it would listen on the node's address): the phone sees none for the Mac.
	phoneStatus, err := phone.Status(ctx)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, peer := range phoneStatus.Peer {
		if peer.HostName != "aos-mac" {
			continue
		}
		found = true
		if len(peer.PeerAPIURL) > 0 {
			t.Errorf("the Mac's node offers a peer API: %v", peer.PeerAPIURL)
		}
	}
	if !found {
		t.Fatal("the phone doesn't see the Mac's node")
	}
}

// scanTCP dials every port of ip through node and returns the ones that accepted.
func scanTCP(ctx context.Context, node *Node, ip string) []int {
	ports := make(chan int)
	var mu sync.Mutex
	var open []int
	var wg sync.WaitGroup
	for range 256 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for port := range ports {
				dialCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
				conn, err := node.Dial(dialCtx, "tcp", net.JoinHostPort(ip, strconv.Itoa(port)))
				cancel()
				if err == nil {
					conn.Close()
					mu.Lock()
					open = append(open, port)
					mu.Unlock()
				}
			}
		}()
	}
	for port := 1; port <= 65535; port++ {
		ports <- port
	}
	close(ports)
	wg.Wait()
	slices.Sort(open)
	return open
}

// A node that isn't signed in reports a sign-in URL; once the coordination server accepted the sign-in, it runs.
func TestInteractiveSignIn(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	controlURL, control := startControl(t, true)
	node := newNode(t, controlURL, "aos-mac")

	var authURL string
	for authURL == "" {
		st, err := node.Status(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if st.BackendState == "Running" {
			t.Fatal("running without a sign-in")
		}
		authURL = st.AuthURL
		if authURL == "" {
			select {
			case <-ctx.Done():
				t.Fatal("no sign-in URL")
			case <-time.After(50 * time.Millisecond):
			}
		}
	}
	if !strings.HasPrefix(authURL, controlURL) {
		t.Fatalf("sign-in URL %q isn't the coordination server's", authURL)
	}
	if !control.CompleteAuth(authURL) {
		t.Fatal("the coordination server didn't know the sign-in URL")
	}
	st := waitForState(t, ctx, node, "Running")
	if st.AuthURL != "" {
		t.Errorf("sign-in URL still there after signing in: %q", st.AuthURL)
	}
	if st.Self == nil || st.Self.HostName != "aos-mac" {
		t.Errorf("self: %+v", st.Self)
	}

	// Signing out removes the node: it needs a sign-in again.
	if err := node.Logout(ctx); err != nil {
		t.Fatal(err)
	}
	waitForState(t, ctx, node, "NeedsLogin")
}

// The helper's line protocol, against a real node.
func TestServeAnswersStatusAndRefusesUnknownOps(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	controlURL, _ := startControl(t, false)
	node := newNode(t, controlURL, "aos-mac")
	waitForState(t, ctx, node, "Running")

	in := strings.NewReader("{\"id\":1,\"op\":\"status\"}\nnot json\n{\"id\":2,\"op\":\"forward\"}\n")
	var out strings.Builder
	if err := Serve(ctx, node, in, &out); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(out.String()), "\n")
	if len(lines) != 3 {
		t.Fatalf("answers: %q", out.String())
	}
	var status Response
	if err := json.Unmarshal([]byte(lines[0]), &status); err != nil || !status.OK || status.ID != 1 {
		t.Fatalf("status answer: %s", lines[0])
	}
	var st ipnstate.Status
	if err := json.Unmarshal(status.Status, &st); err != nil || st.BackendState != "Running" || st.Self == nil {
		t.Fatalf("status: %v %+v", err, st)
	}
	for _, line := range lines[1:] {
		var r Response
		if err := json.Unmarshal([]byte(line), &r); err != nil || r.OK {
			t.Errorf("should refuse: %s", line)
		}
	}
}

func TestValidHostname(t *testing.T) {
	for _, name := range []string{"aos-maxs-macbook-pro", "a", "aos-iphone-15", strings.Repeat("a", 63)} {
		if !ValidHostname(name) {
			t.Errorf("%q should be valid", name)
		}
	}
	for _, name := range []string{"", "-aos", "aos-", "AOS", "aos mac", "aos.mac", "aos_mac", strings.Repeat("a", 64), "max's"} {
		if ValidHostname(name) {
			t.Errorf("%q should be invalid", name)
		}
	}
	if _, err := New(Config{Dir: "relative", Hostname: "aos-mac"}); err == nil {
		t.Error("a relative state folder should be refused")
	}
}

func TestRedactRemovesURLs(t *testing.T) {
	line := "To start this tsnet server, restart with TS_AUTHKEY set, or go to: https://login.tailscale.com/a/abc123 now"
	got := Redact(line)
	if strings.Contains(got, "login.tailscale.com") || !strings.Contains(got, "<url>") {
		t.Errorf("not redacted: %q", got)
	}
}

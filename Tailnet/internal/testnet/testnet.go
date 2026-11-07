// Package testnet runs Tailscale's own test coordination server (tstest/integration/testcontrol) with a DERP and
// STUN server on 127.0.0.1, for the tests: no account, no internet.
package testnet

import (
	"crypto/tls"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"

	"tailscale.com/derp/derpserver"
	"tailscale.com/net/netns"
	"tailscale.com/net/stun/stuntest"
	"tailscale.com/tailcfg"
	"tailscale.com/tstest/integration/testcontrol"
	"tailscale.com/types/key"
	"tailscale.com/types/logger"
	"tailscale.com/types/nettype"
)

// MagicDNSDomain is the tailnet's DNS suffix.
const MagicDNSDomain = "tail-aos.ts.net"

// StartControl starts a coordination server; with requireAuth every node needs an interactive sign-in
// (control.CompleteAuth). It returns the server's URL.
func StartControl(t testing.TB, requireAuth bool) (string, *testcontrol.Server) {
	t.Helper()
	netns.SetEnabled(false)
	t.Cleanup(func() { netns.SetEnabled(true) })
	control := &testcontrol.Server{
		DERPMap:        runDERPAndSTUN(t),
		DNSConfig:      &tailcfg.DNSConfig{Proxied: true},
		MagicDNSDomain: MagicDNSDomain,
		RequireAuth:    requireAuth,
		Logf:           logger.Discard,
	}
	control.HTTPTestServer = httptest.NewUnstartedServer(control)
	control.HTTPTestServer.Start()
	t.Cleanup(control.HTTPTestServer.Close)
	return control.HTTPTestServer.URL, control
}

// runDERPAndSTUN is tstest/integration.RunDERPAndSTUN (that package can't be built with aOS's build tags: it
// pulls in Tailscale SSH).
func runDERPAndSTUN(t testing.TB) *tailcfg.DERPMap {
	t.Helper()
	d := derpserver.New(key.NewNode(), logger.Discard)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewUnstartedServer(derpserver.Handler(d))
	server.Listener.Close()
	server.Listener = ln
	server.Config.ErrorLog = logger.StdLogger(logger.Discard)
	server.Config.TLSNextProto = make(map[string]func(*http.Server, *tls.Conn, http.Handler))
	server.StartTLS()
	stunAddr, stunCleanup := stuntest.ServeWithPacketListener(t, nettype.Std{})
	t.Cleanup(func() {
		server.CloseClientConnections()
		server.Close()
		d.Close()
		stunCleanup()
	})
	return &tailcfg.DERPMap{Regions: map[tailcfg.DERPRegionID]*tailcfg.DERPRegion{
		1: {RegionID: 1, RegionCode: "test", Nodes: []*tailcfg.DERPNode{{
			Name: "t1", RegionID: 1, HostName: "127.0.0.1", IPv4: "127.0.0.1", IPv6: "none",
			STUNPort: stunAddr.Port, DERPPort: ln.Addr().(*net.TCPAddr).Port, InsecureForTests: true,
			STUNTestIP: "127.0.0.1",
		}}},
	}}
}

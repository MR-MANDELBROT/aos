// aos-tailnet-testnet runs a whole tailnet on 127.0.0.1 for the iPhone app's end-to-end test
// (iOS/Tools/test-tailnet.sh): Tailscale's own test coordination server (tstest/integration/testcontrol), a DERP
// server, and a "Mac" node running aOS's node code with port 22 forwarded. No account, no internet. The simulator
// shares this Mac's loopback, so the test's own SSH server and the iPhone app's real Tailnetkit node meet here.
//
// It prints its admin URL as the first line and runs until stdin ends. The admin endpoint (127.0.0.1 only):
//
//	GET  /info              {"control":"<coordination server>","mac":"<the Mac node's IPv4>","macName":"<MagicDNS name>"}
//	POST /forward?port=N    port 22 of the Mac node leads to 127.0.0.1:N from now on
//	POST /complete?url=U    completes the sign-in at U (every node has to sign in, like with Tailscale)
//
// Only for tests: it is never part of the app.
package main

import (
	"bufio"
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"sync/atomic"
	"time"

	"tailscale.com/derp/derpserver"
	"tailscale.com/ipn/store/mem"
	"tailscale.com/net/netns"
	"tailscale.com/tailcfg"
	"tailscale.com/tstest/integration/testcontrol"
	"tailscale.com/types/key"
	"tailscale.com/types/logger"

	"dev.marquart/aos/tailnet"
)

func main() {
	netns.SetEnabled(false)
	dir, err := os.MkdirTemp("", "aos-tailnet-testnet")
	if err != nil {
		log.Fatal(err)
	}
	defer os.RemoveAll(dir)

	// DERP over TLS with the test server's own certificate (the DERP map says InsecureForTests), no STUN: the nodes
	// meet through DERP on this Mac.
	derp := derpserver.New(key.NewNode(), logger.Discard)
	derpServer := httptest.NewUnstartedServer(derpserver.Handler(derp))
	derpServer.Config.ErrorLog = logger.StdLogger(logger.Discard)
	derpServer.Config.TLSNextProto = make(map[string]func(*http.Server, *tls.Conn, http.Handler))
	derpServer.StartTLS()
	defer derpServer.Close()
	derpPort := derpServer.Listener.Addr().(*net.TCPAddr).Port

	control := &testcontrol.Server{
		DERPMap: &tailcfg.DERPMap{Regions: map[tailcfg.DERPRegionID]*tailcfg.DERPRegion{
			1: {RegionID: 1, RegionCode: "test", Nodes: []*tailcfg.DERPNode{{
				Name: "t1", RegionID: 1, HostName: "127.0.0.1", IPv4: "127.0.0.1", IPv6: "none",
				STUNPort: -1, DERPPort: derpPort, InsecureForTests: true,
			}}},
		}},
		DNSConfig:      &tailcfg.DNSConfig{Proxied: true},
		MagicDNSDomain: "tail-aos.ts.net",
		RequireAuth:    true,
		Logf:           logger.Discard,
	}
	control.HTTPTestServer = httptest.NewUnstartedServer(control)
	control.HTTPTestServer.Start()
	defer control.HTTPTestServer.Close()
	controlURL := control.HTTPTestServer.URL

	var sshPort atomic.Int64
	mac, err := tailnet.New(tailnet.Config{
		Dir: filepath.Join(dir, "mac"), Hostname: "aos-mac", ControlURL: controlURL,
		Store: new(mem.Store), Ephemeral: true,
	})
	if err != nil {
		log.Fatal(err)
	}
	defer mac.Close()
	if err := mac.Start(); err != nil {
		log.Fatal(err)
	}
	if err := mac.ForwardTo(22, func() string { return "127.0.0.1:" + strconv.FormatInt(sshPort.Load(), 10) }); err != nil {
		log.Fatal(err)
	}
	// The Mac node signs in too.
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	var macIP, macName string
	for macIP == "" {
		st, err := mac.Status(ctx)
		if err != nil {
			log.Fatal(err)
		}
		switch {
		case st.BackendState == "Running" && len(st.TailscaleIPs) > 0:
			macIP = st.TailscaleIPs[0].String()
			if st.Self != nil {
				macName = st.Self.DNSName
			}
		case st.AuthURL != "":
			control.CompleteAuth(st.AuthURL)
		}
		select {
		case <-ctx.Done():
			log.Fatal("the Mac node didn't start")
		case <-time.After(50 * time.Millisecond):
		}
	}

	admin := http.NewServeMux()
	admin.HandleFunc("GET /info", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]string{"control": controlURL, "mac": macIP, "macName": macName})
	})
	admin.HandleFunc("POST /forward", func(w http.ResponseWriter, r *http.Request) {
		port, err := strconv.Atoi(r.URL.Query().Get("port"))
		if err != nil || port <= 0 || port > 65535 {
			http.Error(w, "bad port", http.StatusBadRequest)
			return
		}
		sshPort.Store(int64(port))
		io.WriteString(w, "ok\n")
	})
	admin.HandleFunc("POST /complete", func(w http.ResponseWriter, r *http.Request) {
		if !control.CompleteAuth(r.URL.Query().Get("url")) {
			http.Error(w, "unknown sign-in URL", http.StatusNotFound)
			return
		}
		io.WriteString(w, "ok\n")
	})
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		log.Fatal(err)
	}
	go http.Serve(ln, admin)
	fmt.Printf("http://%s\n", ln.Addr())

	// Until whoever started it closes stdin.
	bufio.NewReader(os.Stdin).ReadString(0)
}

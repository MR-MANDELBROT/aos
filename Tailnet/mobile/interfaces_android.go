package tailnetkit

import (
	"errors"
	"net"
	"net/netip"
	"time"

	"tailscale.com/net/netmon"
)

// Android denies apps the NETLINK_ROUTE socket and /proc/net (Tailscale issue 2293, golang/go#40569), so
// net.Interfaces fails and Tailscale's network monitor can't start. Tailscale's own Android app hands it the
// interfaces from Java; Tailscale's feature/androidbin (not linked into GOOS=android cgo builds) reports one made-up
// interface with the addresses the kernel would send from instead. That is enough for magicsock to find this
// device's endpoints, and it is what this library does: the same code as androidbin's buildSynthetic (Tailscale,
// BSD-3-Clause, tailscale.com v1.104.5 feature/androidbin/androidbin.go), so the app needs no network code of its own.
func init() {
	netmon.RegisterInterfaceGetter(syntheticInterfaces)
}

func syntheticInterfaces() ([]netmon.Interface, error) {
	var addrs []net.Addr
	// Dialing UDP sends nothing; the kernel only picks a route and a source address.
	if ip, ok := outboundIP("udp4", "8.8.8.8:53"); ok {
		addrs = append(addrs, &net.IPNet{IP: ip.AsSlice(), Mask: net.CIDRMask(32, 32)})
	}
	if ip, ok := outboundIP("udp6", "[2001:4860:4860::8888]:53"); ok {
		addrs = append(addrs, &net.IPNet{IP: ip.AsSlice(), Mask: net.CIDRMask(128, 128)})
	}
	if len(addrs) == 0 {
		return nil, errors.New("tailnetkit: no outbound routes found")
	}
	return []netmon.Interface{{
		Interface: &net.Interface{MTU: 1500, Name: "android", Flags: net.FlagUp | net.FlagRunning},
		AltAddrs:  addrs,
	}}, nil
}

// outboundIP is the source address the kernel picks for a socket to addr.
func outboundIP(network, addr string) (netip.Addr, bool) {
	d := net.Dialer{Timeout: 2 * time.Second}
	c, err := d.Dial(network, addr)
	if err != nil {
		return netip.Addr{}, false
	}
	defer c.Close()
	ua, ok := c.LocalAddr().(*net.UDPAddr)
	if !ok {
		return netip.Addr{}, false
	}
	ip, ok := netip.AddrFromSlice(ua.IP)
	if !ok {
		return netip.Addr{}, false
	}
	ip = ip.Unmap()
	if ip.IsLoopback() || ip.IsUnspecified() {
		return netip.Addr{}, false
	}
	return ip, true
}

package tailnet

import "tailscale.com/client/local"

// LocalClient is tsnet's LocalAPI client inside the process. The Android library (package Tailnet/mobile) watches the
// node's state on the IPN bus with it; the Mac and the iPhone don't use it.
func (n *Node) LocalClient() (*local.Client, error) { return n.srv.LocalClient() }

// aOS: aOS's Tailscale node (Tailnet/mobile, the Android app's tailnetkit) in aosgo's C API (aosgo.h, "tailnetkit").
// Nodes as handles; the listener and the log as C callbacks; the state as JSON.
//
// Part of aOS's desktop wrapper (Android/third_party/aosgo-desktop in aOS). Tailnet/mobile and tsnet are
// BSD-3-Clause; this file is in the GPL-3.0 library aosgo and GPL-3.0 like the rest of the wrapper.

package main

/*
#include <stdlib.h>
#include "aosgo.h"

static inline void aosgo_call_tailnet_log(aosgo_tailnet_log_fn fn, int64_t node, const char *line) { fn(node, line); }
static inline void aosgo_call_tailnet_state(aosgo_tailnet_state_fn fn, int64_t node, const char *state) {
	fn(node, state);
}
*/
import "C"

import (
	"errors"
	"fmt"
	"sync/atomic"

	tailnetkit "dev.marquart/aos/tailnet/mobile"
)

var nodes registry[*node]

type node struct {
	id     int64
	node   *tailnetkit.Node
	log    C.aosgo_tailnet_log_fn
	state  C.aosgo_tailnet_state_fn
	closed atomic.Bool
}

func lookupNode(handle C.int64_t) (*node, error) {
	n, found := nodes.get(int64(handle))
	if !found {
		return nil, fmt.Errorf("aosgo: no tailnet node %d", int64(handle))
	}
	return n, nil
}

// stateJSON is a State as aosgo_tailnet_state describes it.
func stateJSON(s *tailnetkit.State) string {
	return jsonText(map[string]any{
		"backendState":   s.BackendState,
		"running":        s.IsRunning(),
		"needsLogin":     s.NeedsLogin(),
		"authURL":        s.AuthURL(),
		"tailnet":        s.Tailnet,
		"magicDNSSuffix": s.MagicDNSSuffix,
		"dnsName":        s.DNSName,
		"addresses":      s.Addresses,
		"keyExpiry":      s.KeyExpiry,
		"health":         s.Health,
		"error":          s.Error,
	})
}

// nodeLogger is tailnetkit.Logger for the C log callback. The node's id is set once NewNode returned; lines before
// that carry 0.
type nodeLogger struct {
	fn C.aosgo_tailnet_log_fn
	n  atomic.Pointer[node]
}

func (l *nodeLogger) Log(line string) {
	var id int64
	if n := l.n.Load(); n != nil {
		if n.closed.Load() {
			return
		}
		id = n.id
	}
	text := cText(line)
	C.aosgo_call_tailnet_log(l.fn, C.int64_t(id), textPointer(text))
}

// nodeListener is tailnetkit.Listener for the C state callback.
type nodeListener struct{ n *node }

func (l nodeListener) OnState(state *tailnetkit.State) {
	if state == nil || l.n.closed.Load() {
		return
	}
	text := cText(stateJSON(state))
	C.aosgo_call_tailnet_state(l.n.state, C.int64_t(l.n.id), textPointer(text))
}

//export aosgo_tailnet_built_for_aos
func aosgo_tailnet_built_for_aos() C.int32_t {
	if tailnetkit.BuiltForAOS() {
		return 1
	}
	return 0
}

//export aosgo_tailnet_is_sign_in_page
func aosgo_tailnet_is_sign_in_page(url *C.char) C.int32_t {
	if tailnetkit.IsSignInPage(goString(url)) {
		return 1
	}
	return 0
}

//export aosgo_tailnet_new
func aosgo_tailnet_new(dir, hostname, controlURL *C.char, log C.aosgo_tailnet_log_fn, out **C.char) (result C.int64_t) {
	defer guard(out)
	result = -1
	n := &node{log: log}
	var logger tailnetkit.Logger
	var sink *nodeLogger
	if log != nil {
		sink = &nodeLogger{fn: log}
		logger = sink
	}
	created, err := tailnetkit.NewNode(goString(dir), goString(hostname), goString(controlURL), logger)
	if err != nil {
		fail(out, err)
		return
	}
	n.node = created
	n.id = nodes.add(n)
	if sink != nil {
		sink.n.Store(n)
	}
	return C.int64_t(n.id)
}

//export aosgo_tailnet_start
func aosgo_tailnet_start(handle C.int64_t, listener C.aosgo_tailnet_state_fn, out **C.char) (result C.int32_t) {
	defer guard(out)
	n, err := lookupNode(handle)
	if err != nil {
		return status(out, err)
	}
	if listener == nil {
		return status(out, n.node.Start(nil))
	}
	n.state = listener
	return status(out, n.node.Start(nodeListener{n}))
}

//export aosgo_tailnet_state
func aosgo_tailnet_state(handle C.int64_t, out **C.char) *C.char {
	defer guard(out)
	n, err := lookupNode(handle)
	if err != nil {
		fail(out, err)
		return nil
	}
	state, err := n.node.State()
	if err != nil {
		fail(out, err)
		return nil
	}
	return C.CString(stateJSON(state))
}

//export aosgo_tailnet_status_json
func aosgo_tailnet_status_json(handle C.int64_t, out **C.char) *C.char {
	defer guard(out)
	n, err := lookupNode(handle)
	if err != nil {
		fail(out, err)
		return nil
	}
	text, err := n.node.StatusJSON()
	if err != nil {
		fail(out, err)
		return nil
	}
	return C.CString(text)
}

//export aosgo_tailnet_login
func aosgo_tailnet_login(handle C.int64_t, out **C.char) (result C.int32_t) {
	defer guard(out)
	n, err := lookupNode(handle)
	if err != nil {
		return status(out, err)
	}
	return status(out, n.node.Login())
}

//export aosgo_tailnet_logout
func aosgo_tailnet_logout(handle C.int64_t, out **C.char) (result C.int32_t) {
	defer guard(out)
	n, err := lookupNode(handle)
	if err != nil {
		return status(out, err)
	}
	return status(out, n.node.Logout())
}

//export aosgo_tailnet_dial
func aosgo_tailnet_dial(handle C.int64_t, host *C.char, port, timeoutMillis, clientPort C.int32_t,
	out **C.char) (result C.int32_t) {
	defer guard(out)
	result = -1
	n, err := lookupNode(handle)
	if err != nil {
		fail(out, err)
		return
	}
	if goString(host) == "" {
		fail(out, errors.New("aosgo: no host to dial"))
		return
	}
	local, err := n.node.Dial(goString(host), int32(port), int32(timeoutMillis), int32(clientPort))
	if err != nil {
		fail(out, err)
		return
	}
	return C.int32_t(local)
}

//export aosgo_tailnet_close
func aosgo_tailnet_close(handle C.int64_t) {
	defer guard(nil)
	n, found := nodes.remove(int64(handle))
	if !found {
		return
	}
	n.closed.Store(true)
	n.node.Close()
}

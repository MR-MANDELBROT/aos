//go:build darwin || ios

// Tailnetkit is aOS's Tailscale node for the iPhone app: package tailnet as a C library (go build
// -buildmode=c-archive, Tailnet/build.sh ios), in Tailnetkit.xcframework with the header include/tailnetkit.h.
// A plain C interface on purpose: the app also holds Open Screen Sharing's gomobile library, and two gomobile
// libraries in one app define the same Objective-C classes (GoSeqRef, RefTracker, ...).
//
// The app keeps the node's state in its own container (with file protection, not in backups), signs it in with the
// person's Tailscale account in a web authentication session, and dials the Mac's node through it:
// tailnetkit_dial hands over a connected socket that SwiftNIO takes as its channel.
//
// Strings the library returns (the status, error messages) are the caller's to free with tailnetkit_free.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"errors"
	"net"
	"os"
	"strconv"
	"sync"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"

	"dev.marquart/aos/tailnet"
)

func main() {}

var (
	mu     sync.Mutex
	nodes  = map[C.int]*tailnet.Node{}
	nextID C.int
)

func node(handle C.int) (*tailnet.Node, error) {
	mu.Lock()
	defer mu.Unlock()
	n := nodes[handle]
	if n == nil {
		return nil, net.ErrClosed
	}
	return n, nil
}

// fail hands an error to the caller (if it asked for one) and returns -1.
func fail(err error, out **C.char) C.int {
	if out != nil {
		*out = C.CString(err.Error())
	}
	return -1
}

// tailnetkit_new prepares a node with its state in dir (an absolute path the app created); controlURL is empty
// for Tailscale's coordination server. Returns a handle (> 0) or -1.
//
//export tailnetkit_new
func tailnetkit_new(dir, hostname, controlURL *C.char, errOut **C.char) C.int {
	if !tailnet.BuiltForAOS() {
		return fail(errors.New("Tailnetkit was built without aOS's build tags"), errOut)
	}
	n, err := tailnet.New(tailnet.Config{Dir: C.GoString(dir), Hostname: C.GoString(hostname), ControlURL: C.GoString(controlURL)})
	if err != nil {
		return fail(err, errOut)
	}
	mu.Lock()
	defer mu.Unlock()
	nextID++
	nodes[nextID] = n
	return nextID
}

// tailnetkit_start starts the node without waiting (a node that isn't signed in reports NeedsLogin and a sign-in
// URL in its status). Returns 0 or -1.
//
//export tailnetkit_start
func tailnetkit_start(handle C.int, errOut **C.char) C.int {
	n, err := node(handle)
	if err == nil {
		err = n.Start()
	}
	if err != nil {
		return fail(err, errOut)
	}
	return 0
}

// tailnetkit_status_json returns Tailscale's status JSON (the format of `tailscale status --json`), or NULL.
//
//export tailnetkit_status_json
func tailnetkit_status_json(handle C.int, errOut **C.char) *C.char {
	n, err := node(handle)
	if err != nil {
		fail(err, errOut)
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	data, err := n.StatusJSON(ctx)
	if err != nil {
		fail(err, errOut)
		return nil
	}
	return C.CString(string(data))
}

// tailnetkit_login asks for a new sign-in URL. Returns 0 or -1.
//
//export tailnetkit_login
func tailnetkit_login(handle C.int, errOut **C.char) C.int {
	return call(handle, errOut, func(ctx context.Context, n *tailnet.Node) error { return n.Login(ctx) })
}

// tailnetkit_logout removes the node from the tailnet; the app then closes it and deletes its state. Returns 0 or
// -1.
//
//export tailnetkit_logout
func tailnetkit_logout(handle C.int, errOut **C.char) C.int {
	return call(handle, errOut, func(ctx context.Context, n *tailnet.Node) error { return n.Logout(ctx) })
}

func call(handle C.int, errOut **C.char, body func(context.Context, *tailnet.Node) error) C.int {
	n, err := node(handle)
	if err != nil {
		return fail(err, errOut)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if err := body(ctx, n); err != nil {
		return fail(err, errOut)
	}
	return 0
}

// tailnetkit_close stops the node; its handle is no longer valid.
//
//export tailnetkit_close
func tailnetkit_close(handle C.int) {
	mu.Lock()
	n := nodes[handle]
	delete(nodes, handle)
	mu.Unlock()
	if n != nil {
		n.Close()
	}
}

// tailnetkit_dial connects to host:port through the tailnet (host: a tailnet address or MagicDNS name) and returns
// one end of a connected socket pair whose other end is spliced to the tailnet connection, or -1. The caller owns
// the descriptor and closes it.
//
//export tailnetkit_dial
func tailnetkit_dial(handle C.int, host *C.char, port, timeoutMillis C.int, errOut **C.char) C.int {
	n, err := node(handle)
	if err != nil {
		return fail(err, errOut)
	}
	if port <= 0 || port > 65535 {
		return fail(errors.New("tailnetkit: bad port"), errOut)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutMillis)*time.Millisecond)
	defer cancel()
	conn, err := n.Dial(ctx, "tcp", net.JoinHostPort(C.GoString(host), strconv.Itoa(int(port))))
	if err != nil {
		return fail(err, errOut)
	}
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_STREAM, 0)
	if err != nil {
		conn.Close()
		return fail(err, errOut)
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
		return fail(err, errOut)
	}
	go tailnet.Splice(local, conn)
	return C.int(fds[1])
}

// tailnetkit_free frees a string the library returned.
//
//export tailnetkit_free
func tailnetkit_free(p *C.char) { C.free(unsafe.Pointer(p)) }

// aos-tailnet is aOS's Tailscale node on the Mac (package tailnet). aOS's root helper (aos-powerd) starts it as the
// hidden user _aostailnet, with its state (the node's keys) in /Library/Application Support/aOS/Tailscale (0700,
// that user), and talks to it over stdin and stdout (tailnet.Serve). It forwards port 22 of its tailnet addresses to
// 127.0.0.1:22, the Mac's own SSH server, and offers nothing else. It ends when stdin ends or on SIGTERM.
//
//	aos-tailnet serve --dir <state folder> --hostname <aos-name>
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"dev.marquart/aos/tailnet"
)

// The Mac's SSH server: the only thing the node makes reachable, on the same port.
const (
	sshPort   = 22
	sshTarget = "127.0.0.1:22"
)

func main() {
	if len(os.Args) < 2 || os.Args[1] != "serve" {
		fmt.Fprintln(os.Stderr, "usage: aos-tailnet serve --dir <state folder> --hostname <name>")
		os.Exit(2)
	}
	flags := flag.NewFlagSet("aos-tailnet", flag.ExitOnError)
	dir := flags.String("dir", "", "state folder (the node's keys)")
	hostname := flags.String("hostname", "", "name in the tailnet")
	controlURL := flags.String("control-url", "", "coordination server (tests only; empty: Tailscale's)")
	flags.Parse(os.Args[2:])

	if !tailnet.BuiltForAOS() {
		fail("built without aOS's build tags (build it with Tailnet/build.sh)")
	}
	if os.Geteuid() == 0 {
		fail("doesn't run as root (aOS's helper starts it as _aostailnet)")
	}
	// Everything this process writes is for itself only.
	syscall.Umask(0o077)

	logFile := &rotatingLog{path: filepath.Join(*dir, "aos-tailnet.log")}
	node, err := tailnet.New(tailnet.Config{
		Dir:        *dir,
		Hostname:   *hostname,
		ControlURL: *controlURL,
		Logf:       logFile.Printf,
	})
	if err != nil {
		fail(err.Error())
	}
	if err := node.Start(); err != nil {
		fail("start: " + tailnet.Redact(err.Error()))
	}
	if err := node.Forward(sshPort, sshTarget); err != nil {
		node.Close()
		fail("listen on port 22: " + err.Error())
	}
	note("started as %s, port %d forwarded to %s", *hostname, sshPort, sshTarget)

	ctx, cancel := context.WithCancel(context.Background())
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
	go func() {
		sig := <-signals
		note("stopping (%v)", sig)
		cancel()
		node.Close()
		os.Exit(0)
	}()

	tailnet.Serve(ctx, node, os.Stdin, os.Stdout)
	note("the helper went away, stopping")
	node.Close()
}

func note(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "aos-tailnet: %s\n", tailnet.Redact(fmt.Sprintf(format, args...)))
}

func fail(message string) {
	note("%s", message)
	os.Exit(1)
}

// rotatingLog keeps the node's verbose log in its own folder (only _aostailnet and root can read it), at most about
// two megabytes.
type rotatingLog struct {
	path string
	mu   sync.Mutex
	file *os.File
	size int64
}

func (l *rotatingLog) Printf(format string, args ...any) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.file == nil {
		f, err := os.OpenFile(l.path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
		if err != nil {
			return
		}
		l.file = f
		if info, err := f.Stat(); err == nil {
			l.size = info.Size()
		}
	}
	line := time.Now().Format(time.RFC3339) + " " + fmt.Sprintf(format, args...)
	if len(line) == 0 || line[len(line)-1] != '\n' {
		line += "\n"
	}
	n, _ := l.file.WriteString(line)
	l.size += int64(n)
	if l.size > 1<<20 {
		l.file.Close()
		l.file = nil
		os.Rename(l.path, l.path+".old")
	}
}

package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"tailscale.com/ipn/ipnstate"

	"dev.marquart/aos/tailnet"
	"dev.marquart/aos/tailnet/internal/testnet"
)

// The test binary stands in for aos-tailnet when AOS_TAILNET_MAIN is set (it was built with the same tags).
func TestMain(m *testing.M) {
	if os.Getenv("AOS_TAILNET_MAIN") == "1" {
		for i, arg := range os.Args {
			if arg == "--" {
				os.Args = append([]string{"aos-tailnet"}, os.Args[i+1:]...)
				break
			}
		}
		main()
		os.Exit(0)
	}
	os.Exit(m.Run())
}

func start(t *testing.T, args ...string) (*exec.Cmd, io.WriteCloser, *bufio.Reader, *bytes.Buffer) {
	t.Helper()
	cmd := exec.Command(os.Args[0], append([]string{"--"}, args...)...)
	cmd.Env = append(os.Environ(), "AOS_TAILNET_MAIN=1")
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	stderr := &bytes.Buffer{}
	cmd.Stderr = stderr
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { cmd.Process.Kill(); cmd.Wait() })
	return cmd, stdin, bufio.NewReader(stdout), stderr
}

// What aos-powerd does: start it with a state folder and a name, ask for the status over stdin until it runs, end
// it by closing stdin.
func TestServesTheHelperOverStdinAndStdout(t *testing.T) {
	controlURL, _ := testnet.StartControl(t, false)
	dir := filepath.Join(t.TempDir(), "Tailscale")
	cmd, stdin, stdout, stderr := start(t, "serve", "--dir", dir, "--hostname", "aos-test", "--control-url", controlURL)

	deadline := time.Now().Add(60 * time.Second)
	var st ipnstate.Status
	for id := 1; ; id++ {
		if time.Now().After(deadline) {
			t.Fatalf("not running in time; last state %q; stderr: %s", st.BackendState, stderr)
		}
		fmt.Fprintf(stdin, "{\"id\":%d,\"op\":\"status\"}\n", id)
		line, err := stdout.ReadBytes('\n')
		if err != nil {
			t.Fatalf("reading the answer: %v; stderr: %s", err, stderr)
		}
		var r tailnet.Response
		if err := json.Unmarshal(line, &r); err != nil || r.ID != int64(id) {
			t.Fatalf("answer %s: %v", line, err)
		}
		if r.OK {
			st = ipnstate.Status{}
			json.Unmarshal(r.Status, &st)
			if st.BackendState == "Running" && st.Self != nil && len(st.TailscaleIPs) > 0 {
				break
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	if st.Self.HostName != "aos-test" {
		t.Errorf("host name %q", st.Self.HostName)
	}

	// The state folder and the log are its own.
	if info, err := os.Stat(dir); err != nil || info.Mode().Perm() != 0o700 {
		t.Errorf("state folder: %v %v", info.Mode(), err)
	}
	entries, _ := os.ReadDir(dir)
	for _, entry := range entries {
		info, err := entry.Info()
		if err != nil {
			continue
		}
		if !info.IsDir() && info.Mode().Perm()&0o077 != 0 {
			t.Errorf("%s is readable by others: %v", entry.Name(), info.Mode())
		}
	}

	// The helper goes away: stdin ends and so does the node.
	stdin.Close()
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		if err != nil {
			t.Errorf("exit: %v; stderr: %s", err, stderr)
		}
	case <-time.After(20 * time.Second):
		t.Fatalf("didn't end after stdin closed; stderr: %s", stderr)
	}
	if bytes.Contains(stderr.Bytes(), []byte("http")) {
		t.Errorf("a URL reached stderr: %s", stderr)
	}
}

func TestRefusesBadHostnames(t *testing.T) {
	cmd, stdin, _, stderr := start(t, "serve", "--dir", filepath.Join(t.TempDir(), "s"), "--hostname", "Max's Mac")
	stdin.Close()
	if err := cmd.Wait(); err == nil {
		t.Fatalf("started with a bad host name; stderr: %s", stderr)
	}
}

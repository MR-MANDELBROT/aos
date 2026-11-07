package tailnet

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"sync"
	"time"
)

// The line protocol between aOS's root helper (aos-powerd) and aos-tailnet, over the child's stdin and stdout: one
// JSON object per line each way. Nothing else can reach it (no socket, no port). When stdin ends (the helper went
// away), aos-tailnet closes the node and exits.
//
//	{"id":1,"op":"status"}   -> {"id":1,"ok":true,"status":{...Tailscale's status JSON...}}
//	{"id":2,"op":"login"}    -> {"id":2,"ok":true}     a new sign-in URL (it shows in the status)
//	{"id":3,"op":"logout"}   -> {"id":3,"ok":true}     signed out; the helper then ends the process and deletes the state

// Request is one line from the helper.
type Request struct {
	ID int64  `json:"id"`
	Op string `json:"op"`
}

// Response answers one request.
type Response struct {
	ID     int64           `json:"id"`
	OK     bool            `json:"ok"`
	Error  string          `json:"error,omitempty"`
	Status json.RawMessage `json:"status,omitempty"`
}

// Controller is what Serve needs of a node (Node; a fake in tests).
type Controller interface {
	StatusJSON(ctx context.Context) ([]byte, error)
	Login(ctx context.Context) error
	Logout(ctx context.Context) error
}

// Serve answers requests from in on out until in ends. Requests run one after the other; each has 20 seconds.
func Serve(ctx context.Context, c Controller, in io.Reader, out io.Writer) error {
	var writeMu sync.Mutex
	write := func(r Response) {
		data, err := json.Marshal(r)
		if err != nil {
			data = []byte(`{"ok":false,"error":"encoding"}`)
		}
		writeMu.Lock()
		defer writeMu.Unlock()
		out.Write(append(data, '\n'))
	}
	scanner := bufio.NewScanner(in)
	scanner.Buffer(make([]byte, 64*1024), 64*1024)
	for scanner.Scan() {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		var req Request
		if err := json.Unmarshal(scanner.Bytes(), &req); err != nil {
			write(Response{OK: false, Error: "unreadable request"})
			continue
		}
		write(handle(ctx, c, req))
	}
	return scanner.Err()
}

func handle(ctx context.Context, c Controller, req Request) Response {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	switch req.Op {
	case "status":
		data, err := c.StatusJSON(ctx)
		if err != nil {
			return Response{ID: req.ID, Error: err.Error()}
		}
		return Response{ID: req.ID, OK: true, Status: data}
	case "login":
		if err := c.Login(ctx); err != nil {
			return Response{ID: req.ID, Error: err.Error()}
		}
		return Response{ID: req.ID, OK: true}
	case "logout":
		if err := c.Logout(ctx); err != nil {
			return Response{ID: req.ID, Error: err.Error()}
		}
		return Response{ID: req.ID, OK: true}
	default:
		return Response{ID: req.ID, Error: "unknown op"}
	}
}

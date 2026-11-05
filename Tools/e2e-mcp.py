#!/usr/bin/env python3
"""End-to-end test through the MCP server: open the workspace, use Chrome, close it.
Runs annex-mcp like an agent would (approval handled by "the agent", i.e. this script).
Usage: Tools/e2e-mcp.py OUT_DIR [MCP_BINARY]"""
import base64, json, os, subprocess, sys, time

args = [a for a in sys.argv[1:] if not a.startswith("--")]
elicit = "--elicit" in sys.argv
out = args[0]
binary = args[1] if len(args) > 1 else "/Applications/Annex.app/Contents/MacOS/annex-mcp"
os.makedirs(out, exist_ok=True)
env = dict(os.environ, ANNEX_APPROVAL="auto" if elicit else "agent", ANNEX_AGENT="e2e")
elicited = []
p = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env, text=True, bufsize=1)
n = 0
def rpc(method, params=None):
    global n
    n += 1
    p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": n, "method": method, "params": params or {}}) + "\n")
    p.stdin.flush()
    while True:
        m = json.loads(p.stdout.readline())
        if m.get("method") == "elicitation/create":
            # the "user" says yes
            elicited.append(m["params"]["message"])
            p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": m["id"], "result": {"action": "accept", "content": {"allow": True}}}) + "\n")
            p.stdin.flush()
            continue
        if m.get("id") == n:
            return m
step = 0
def tool(tool_name, **args):
    global step
    step += 1
    t0 = time.time()
    r = rpc("tools/call", {"name": tool_name, "arguments": args})["result"]
    text = r["content"][0]["text"]
    imgs = [c for c in r["content"] if c["type"] == "image"]
    path = ""
    if imgs:
        path = os.path.join(out, f"{step:02d}-{tool_name}.jpg")
        open(path, "wb").write(base64.b64decode(imgs[0]["data"]))
    print(f"{step:02d} {tool_name} {args} -> {'ERROR ' if r['isError'] else ''}{text.splitlines()[0]} ({time.time()-t0:.1f}s) {path}")
    return r

rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {"elicitation": {}} if elicit else {}, "clientInfo": {"name": "e2e"}})
tool("workspace_status")
r = tool("workspace_open", purpose="end-to-end test", minutes=10)
if elicited:
    print("   elicitation shown to the user:", elicited[0])
if r["isError"]:
    sys.exit(1)
tool("press_keys", keys="cmd+space")
tool("type_text", text="Google Chrome")
tool("press_keys", keys="return")
tool("wait", seconds=6)
tool("press_keys", keys="cmd+l")
tool("type_text", text="example.com\n")
tool("wait", seconds=4)
tool("type_text", text="Grüße 😀", image=False)
tool("screenshot", region=[0, 0, 640, 400])
open(os.path.join(out, "hello.txt"), "w").write("hello from the Mac\n")
tool("put_file", path=os.path.join(out, "hello.txt"))
tool("list_files")
tool("get_file", name="hello.txt", keep=False)
tool("workspace_close")
tool("workspace_status")

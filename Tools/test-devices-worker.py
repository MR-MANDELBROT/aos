# Tests how the device worker (App/Resources/aos-devices-worker.py) rides out outages, with fakes instead of an
# iPhone: the keepalive on a real socket, the retransmit budget inside the tunnel, a heartbeat outage that recovers,
# the tunnel's connection dying, the give-up backstop, an install cut off by an outage going back to the queue, and a
# refused app. Runs with the Python of aOS's device environment:
#
#   ~/Library/Application\ Support/aOS/Devices/env/bin/python -I Tools/test-devices-worker.py
import asyncio, importlib.util, json, socket, sys, tempfile, time
from pathlib import Path

sys.dont_write_bytecode = True
WORKER = sys.argv[1] if len(sys.argv) > 1 else str(Path(__file__).resolve().parent.parent / "App/Resources/aos-devices-worker.py")

spec = importlib.util.spec_from_file_location("worker", WORKER)
w = importlib.util.module_from_spec(spec)
spec.loader.exec_module(w)
results = []


def check(name, ok, detail=""):
    results.append(ok)
    print("OK  " if ok else "FAIL", name, detail)


# A: keepalive on the tunnel's socket
w.tolerate_outages()
w.tolerate_outages()  # idempotent
srv = socket.socket(); srv.bind(("127.0.0.1", 0)); srv.listen()
sock = socket.create_connection(srv.getsockname())
w.tunnel_service.OSUTIL.set_keepalive(sock)
TCP_KEEPALIVE, TCP_KEEPINTVL, TCP_KEEPCNT = 0x10, 0x101, 0x102
vals = (sock.getsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE) != 0, sock.getsockopt(socket.IPPROTO_TCP, TCP_KEEPALIVE),
        sock.getsockopt(socket.IPPROTO_TCP, TCP_KEEPINTVL), sock.getsockopt(socket.IPPROTO_TCP, TCP_KEEPCNT))
check("keepalive 30 s, every 15 s, 18 probes", vals == (True, 30, 15, 18), str(vals))
check("OSUTIL proxy forwards the rest", w.tunnel_service.OSUTIL.loopback_header is not None)
sock.close(); srv.close()

# B: inner retransmit budget reaches pmd-pytcp
sysctls = w.userspace_tunnel.throughput_sysctls()
check("sysctls keep pmd3's and add retransmit 12", sysctls.get("tcp.retransmit.max_count") == 12 and "tcp.rto.min_ms" in sysctls)
from pmd_pytcp.stack import sysctl
from pmd_pytcp.protocols.tcp import tcp__constants
sysctl.set("tcp.retransmit.max_count", sysctls["tcp.retransmit.max_count"])
check("pmd-pytcp takes it", tcp__constants.TCP__RETRANSMIT__MAX_COUNT == 12)


# Fakes for the session
class Lockdown:
    async def close(self): pass


class Rsd:
    def __init__(self):
        self.product_version, self.udid, self.lockdown, self.up, self.reopened = "27.2", "U", Lockdown(), True, 0
        self.install_cut = False

    async def get_value(self, domain=None, key=None):
        if not self.up:
            raise ConnectionError("no route")
        return "Test iPhone"

    async def start_lockdown_service(self, name):
        if not self.up:
            raise ConnectionError("no route")
        self.reopened += 1
        return "service"


async def create_using_remote(service, identifier=None):
    return Lockdown()


class Tunnel:
    current = None

    def __init__(self, serial=None, autopair=True):
        self.rsd = None
        Tunnel.current = self

    async def aopen(self):
        self.rsd = RSD
        return RSD

    async def aclose(self):
        self.rsd = None


class Installer:
    def __init__(self, lockdown):
        pass

    async def install_from_local(self, app):
        if RSD.install_cut:
            RSD.install_cut = False
            RSD.up = False
            raise ConnectionError("cut off")
        await asyncio.sleep(0.05)


w.create_using_remote = create_using_remote
w.userspace_tunnel.UserspaceRsdTunnel = Tunnel
w.InstallationProxyService = Installer
w.TICK, w.RETRY_EVERY, w.GIVE_UP_AFTER, w.PROBE_EVERY = 0.05, 0.1, 1.5, 999


def worker():
    root = Path(tempfile.mkdtemp())
    wk = w.Worker(root)
    wk.heartbeat_seconds = lambda: 0.2

    async def port_open(host, port=0, timeout=0):
        return True
    wk.port_open = port_open
    return wk, root



LOG = []
w.log = lambda *a: LOG.append(" ".join(str(x) for x in a))


async def scenario_recovers():
    global RSD
    RSD = Rsd()
    wk, root = worker()
    task = asyncio.create_task(wk.session("U", "100.1.2.3", "test"))
    await asyncio.sleep(0.5); RSD.up = False
    await asyncio.sleep(1.0)
    check("outage: still connected", wk.status["state"] == "connected" and not task.done())
    RSD.up = True
    await asyncio.sleep(0.5)
    check("recovery: answers again, fresh lockdown", any("answers again" in l for l in LOG) and RSD.reopened >= 1)
    Tunnel.current.rsd = None  # pymobiledevice3 tore it down (transport died)
    await asyncio.wait_for(task, 2)
    check("transport death ends it at once", wk.history[-1]["reason"] == "connection lost", wk.history[-1]["reason"])


async def scenario_gives_up():
    global RSD
    RSD = Rsd()
    wk, root = worker()
    task = asyncio.create_task(wk.session("U", "100.1.2.3", "test"))
    await asyncio.sleep(0.4); RSD.up = False
    t = time.time()
    await asyncio.wait_for(task, 5)
    reason = wk.history[-1]["reason"]
    check("no answer past the limit ends it", reason.startswith("no answer for"), f"{reason} after {time.time() - t:.1f}s")
    check("status back to searching", wk.status["state"] == "searching")


async def scenario_install_cut():
    global RSD
    RSD = Rsd()
    wk, root = worker()
    app = root / "Devices" / "Staging" / "job1" / "Mini.app"
    app.mkdir(parents=True)
    job = {"id": "job1", "app": str(app), "name": "Mini", "bundleId": "dev.x.mini", "state": "queued",
           "created": w.now_iso()}
    (root / "Devices" / "Jobs" / "job1.json").write_text(json.dumps(job))
    RSD.install_cut = True
    task = asyncio.create_task(wk.session("U", "100.1.2.3", "test"))
    await asyncio.sleep(0.6)
    j = json.loads((root / "Devices" / "Jobs" / "job1.json").read_text())
    check("cut-off install goes back to the queue", j["state"] == "queued" and j["attempts"] == 1 and app.exists(), j["state"])
    RSD.up = True
    await asyncio.sleep(0.8)
    j = json.loads((root / "Devices" / "Jobs" / "job1.json").read_text())
    check("installed after the outage", j["state"] == "done" and j["attempts"] == 2 and not app.parent.exists(),
          f'{j["state"]} attempts={j.get("attempts")}')
    wk.stopping = True
    await asyncio.wait_for(task, 2)


async def scenario_refused():
    global RSD
    RSD = Rsd()
    wk, root = worker()
    app = root / "Devices" / "Staging" / "job2" / "Bad.app"
    app.mkdir(parents=True)
    job = {"id": "job2", "app": str(app), "name": "Bad", "bundleId": "dev.x.bad", "state": "queued", "created": w.now_iso()}
    (root / "Devices" / "Jobs" / "job2.json").write_text(json.dumps(job))

    class Refusing:
        def __init__(self, lockdown): pass
        async def install_from_local(self, app): raise RuntimeError("ApplicationVerificationFailed")
    w.InstallationProxyService = Refusing
    task = asyncio.create_task(wk.session("U", "100.1.2.3", "test"))
    await asyncio.sleep(0.5)
    j = json.loads((root / "Devices" / "Jobs" / "job2.json").read_text())
    check("refused app fails, tunnel stays", j["state"] == "failed" and wk.status["state"] == "connected" and not task.done(),
          j.get("message", ""))
    wk.stopping = True
    await asyncio.wait_for(task, 2)
    w.InstallationProxyService = Installer


async def main():
    await scenario_recovers()
    await scenario_gives_up()
    await scenario_install_cut()
    await scenario_refused()

asyncio.run(main())
print("\n".join("  log: " + l for l in LOG[-12:]))
print("ALL OK" if all(results) else "SOME FAILED")
sys.exit(0 if all(results) else 1)

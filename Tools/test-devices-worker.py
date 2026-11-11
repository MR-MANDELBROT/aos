# Tests how the device worker (App/Resources/aos-devices-worker.py) rides out silence, with fakes instead of an iPhone:
# no keepalive on a real socket, the retransmit budget inside the tunnel, a long time offline without a single packet
# into the tunnel, coming back, the tunnel's connection dying, a tunnel that doesn't answer while the iPhone is online,
# an install cut off by an outage going back to the queue, and a refused app. Runs with the Python of aOS's device
# environment:
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


# A: no keepalive on the tunnel's socket (pymobiledevice3 asks for one, the worker turns it off)
w.tolerate_outages()
w.tolerate_outages()  # idempotent
srv = socket.socket(); srv.bind(("127.0.0.1", 0)); srv.listen()
sock = socket.create_connection(srv.getsockname())
sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
w.tunnel_service.OSUTIL.set_keepalive(sock)
check("no keepalive on the tunnel's connection", sock.getsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE) == 0)
check("OSUTIL proxy forwards the rest", w.tunnel_service.OSUTIL.loopback_header is not None)
sock.close(); srv.close()

# B: inner retransmit budget reaches pmd-pytcp
sysctls = w.userspace_tunnel.throughput_sysctls()
check("sysctls keep pmd3's and add retransmit 12", sysctls.get("tcp.retransmit.max_count") == 12 and "tcp.rto.min_ms" in sysctls)
from pmd_pytcp.stack import sysctl
from pmd_pytcp.protocols.tcp import tcp__constants
sysctl.set("tcp.retransmit.max_count", sysctls["tcp.retransmit.max_count"])
check("pmd-pytcp takes it", tcp__constants.TCP__RETRANSMIT__MAX_COUNT == 12)


# C: the real ping (this Mac answers itself; a documentation address doesn't)
async def pings():
    return await w.reachable("127.0.0.1", 1), await w.reachable("192.0.2.1", 1)
check("ping: answers / no answer", asyncio.run(pings()) == (True, False))


# Fakes for the session: `online` is whether pings get through, `tunnel` whether the tunnel answers.
class Lockdown:
    async def close(self): pass


class Rsd:
    def __init__(self):
        self.product_version, self.udid, self.lockdown, self.reopened = "27.2", "U", Lockdown(), 0
        self.online, self.tunnel, self.install_cut = True, True, False
        self.sent_while_offline = 0

    def _use(self):
        if not self.online:
            self.sent_while_offline += 1
        if not (self.online and self.tunnel):
            raise ConnectionError("no answer")

    async def get_value(self, domain=None, key=None):
        self._use()
        return "Test iPhone"

    async def start_lockdown_service(self, name):
        self._use()
        self.reopened += 1
        return "service"


async def create_using_remote(service, identifier=None):
    return Lockdown()


async def reachable(host, timeout=3):
    return RSD.online


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
        RSD._use()
        if RSD.install_cut:
            RSD.install_cut = False
            RSD.online = False
            raise ConnectionError("cut off")
        await asyncio.sleep(0.05)


w.create_using_remote = create_using_remote
w.reachable = reachable
w.userspace_tunnel.UserspaceRsdTunnel = Tunnel
w.InstallationProxyService = Installer
w.TICK, w.RETRY_EVERY, w.PROBE_EVERY = 0.02, 0.05, 999
LOG = []
w.log = lambda *a: LOG.append(" ".join(str(x) for x in a))


def worker():
    root = Path(tempfile.mkdtemp())
    wk = w.Worker(root)
    wk.heartbeat_seconds = lambda: 0.2

    async def port_open(host, port=0, timeout=0):
        return RSD.online
    wk.port_open = port_open
    return wk, root


def queue(root, job_id, name):
    app = root / "Devices" / "Staging" / job_id / f"{name}.app"
    app.mkdir(parents=True)
    job = {"id": job_id, "app": str(app), "name": name, "bundleId": f"dev.x.{name.lower()}", "state": "queued",
           "created": w.now_iso()}
    (root / "Devices" / "Jobs" / f"{job_id}.json").write_text(json.dumps(job))
    return app


def job(root, job_id):
    return json.loads((root / "Devices" / "Jobs" / f"{job_id}.json").read_text())


async def scenario_long_silence():
    global RSD
    RSD = Rsd()
    wk, root = worker()
    task = asyncio.create_task(wk.session("U", "100.1.2.3", "test"))
    await asyncio.sleep(0.5)
    RSD.online = False
    await asyncio.sleep(3.0)  # 60 retry cycles: hours, scaled down
    check("offline: the tunnel waits", wk.status["state"] == "connected" and wk.status["network"] == "offline"
          and not task.done())
    check("offline: not one packet into the tunnel", RSD.sent_while_offline == 0, f"{RSD.sent_while_offline} sent")
    queue(root, "j0", "Queued")
    await asyncio.sleep(0.3)
    check("offline: a new install waits", job(root, "j0")["state"] == "queued" and RSD.sent_while_offline == 0)
    RSD.online = True
    await asyncio.sleep(0.5)
    check("back online: network known again, install done",
          any("online again" in l for l in LOG) and wk.status["network"] == "wifi" and job(root, "j0")["state"] == "done",
          f'{wk.status["network"]}, {job(root, "j0")["state"]}')
    Tunnel.current.rsd = None  # pymobiledevice3 tore it down (the iPhone answered with a reset)
    await asyncio.wait_for(task, 2)
    check("transport death ends it at once", wk.history[-1]["reason"] == "connection lost", wk.history[-1]["reason"])


async def scenario_dead_tunnel_online():
    global RSD
    RSD = Rsd()
    wk, root = worker()
    task = asyncio.create_task(wk.session("U", "100.1.2.3", "test"))
    await asyncio.sleep(0.4)
    RSD.tunnel = False  # pings answer, the tunnel doesn't
    await asyncio.wait_for(task, 5)
    reason = wk.history[-1]["reason"]
    check("online but no answer through the tunnel ends it", reason.startswith("no answer through the tunnel"), reason)
    check("status back to searching", wk.status["state"] == "searching")


async def scenario_install_cut():
    global RSD
    RSD = Rsd()
    wk, root = worker()
    app = queue(root, "j1", "Mini")
    RSD.install_cut = True
    task = asyncio.create_task(wk.session("U", "100.1.2.3", "test"))
    await asyncio.sleep(0.6)
    j = job(root, "j1")
    check("cut-off install goes back to the queue", j["state"] == "queued" and j["attempts"] == 1 and app.exists(), j["state"])
    RSD.online = True
    await asyncio.sleep(0.8)
    j = job(root, "j1")
    check("installed once the iPhone is back", j["state"] == "done" and j["attempts"] == 2 and not app.parent.exists(),
          f'{j["state"]} attempts={j.get("attempts")}')
    wk.stopping = True
    await asyncio.wait_for(task, 2)


async def scenario_refused():
    global RSD
    RSD = Rsd()
    wk, root = worker()
    queue(root, "j2", "Bad")

    class Refusing:
        def __init__(self, lockdown): pass
        async def install_from_local(self, app): raise RuntimeError("ApplicationVerificationFailed")
    w.InstallationProxyService = Refusing
    task = asyncio.create_task(wk.session("U", "100.1.2.3", "test"))
    await asyncio.sleep(0.5)
    j = job(root, "j2")
    check("refused app fails, tunnel stays", j["state"] == "failed" and wk.status["state"] == "connected" and not task.done(),
          j.get("message", ""))
    wk.stopping = True
    await asyncio.wait_for(task, 2)
    w.InstallationProxyService = Installer


async def main():
    await scenario_long_silence()
    await scenario_dead_tunnel_online()
    await scenario_install_cut()
    await scenario_refused()

asyncio.run(main())
print("\n".join("  log: " + l for l in LOG[-14:]))
print("ALL OK" if all(results) else "SOME FAILED")
sys.exit(0 if all(results) else 1)

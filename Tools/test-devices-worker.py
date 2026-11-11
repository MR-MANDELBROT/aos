# Tests how the device worker (App/Resources/aos-devices-worker.py) keeps its tunnel quiet, with fakes instead of an
# iPhone: no keepalive on a real socket, the retransmit budget inside the tunnel, the real ping, nothing through the
# tunnel on cellular or offline (however long), one check after joining Wi-Fi, a dead tunnel found on Wi-Fi, the
# tunnel's connection dying, installs on cellular after steady pings and waiting while offline, an install cut off by
# an outage going back to the queue, and a refused app. Runs with the Python of aOS's device environment:
#
#   ~/Library/Application\ Support/aOS/Devices/env/bin/python -I Tools/test-devices-worker.py
import asyncio, importlib.util, json, socket, sys, tempfile
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


# Fakes. The iPhone: `online` (pings answer), `wifi` (its pairing port answers), `alive` (the tunnel answers).
class Phone:
    def __init__(self):
        self.online, self.wifi, self.alive = True, True, True
        self.uses, self.uses_away, self.open, self.connects = 0, 0, 0, 0
        self.install_cut = False

    def use(self):
        self.uses += 1
        if not (self.online and self.wifi):
            self.uses_away += 1  # through the tunnel while on cellular or offline
        if not (self.online and self.alive):
            raise ConnectionError("no answer")


class Rsd:
    """What `connect` gives: one use, then closed."""
    product_version = "27.2"

    async def get_value(self, domain=None, key=None):
        PHONE.use()
        return "Test iPhone"

    async def close(self):
        PHONE.open -= 1


class Base(Rsd):
    """The tunnel's first connection (aopen)."""


async def connect(base):
    PHONE.use()
    PHONE.connects += 1
    PHONE.open += 1
    return Rsd()


async def disconnect(rsd):
    await rsd.close()


async def reachable(host, timeout=3):
    return PHONE.online


class Tunnel:
    current = None

    def __init__(self, serial=None, autopair=True):
        self.rsd = None
        Tunnel.current = self

    async def aopen(self):
        PHONE.open += 1
        self.rsd = Base()
        return self.rsd

    async def aclose(self):
        self.rsd = None


class Installer:
    def __init__(self, lockdown):
        pass

    async def install_from_local(self, app):
        PHONE.use()
        if PHONE.install_cut:
            PHONE.install_cut = False
            PHONE.online = False
            raise ConnectionError("cut off")
        await asyncio.sleep(0.05)


w.connect, w.disconnect, w.reachable = connect, disconnect, reachable
w.userspace_tunnel.UserspaceRsdTunnel = Tunnel
w.InstallationProxyService = Installer
w.TICK, w.RETRY_EVERY, w.WIFI_SETTLE, w.RECHECK_ON_WIFI = 0.02, 0.05, 0.2, 999
LOG = []
w.log = lambda *a: LOG.append(" ".join(str(x) for x in a))


def worker():
    root = Path(tempfile.mkdtemp())
    wk = w.Worker(root)
    wk.ping_seconds = lambda: 0.1

    async def port_open(host, port=0, timeout=0):
        return PHONE.online and PHONE.wifi
    wk.port_open = port_open
    async def steady(host):
        return PHONE.online
    wk.steady = steady
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


async def scenario_quiet():
    global PHONE
    PHONE = Phone()
    wk, root = worker()
    task = asyncio.create_task(wk.session("U", "100.1.2.3", "test"))
    await asyncio.sleep(0.3)
    check("nothing stays open inside the tunnel", PHONE.open == 0, f"{PHONE.open} open")
    PHONE.wifi = False  # out of the door: cellular
    await asyncio.sleep(1.5)
    check("cellular: the tunnel waits, network known", wk.status["state"] == "connected"
          and wk.status["network"] == "cellular")
    PHONE.online = False
    await asyncio.sleep(3.0)  # many ping cycles: hours, scaled down
    check("offline: the tunnel waits", wk.status["network"] == "offline" and not task.done())
    check("cellular and offline: not one use of the tunnel", PHONE.uses_away == 0, f"{PHONE.uses_away} uses")
    PHONE.online = True
    await asyncio.sleep(1.0)
    check("back on cellular: still nothing through the tunnel", PHONE.uses_away == 0 and wk.status["network"] == "cellular")
    before = PHONE.connects
    PHONE.wifi = True  # home again
    await asyncio.sleep(0.1)
    check("joining Wi-Fi: no check before it settles", PHONE.connects == before)
    await asyncio.sleep(0.8)
    check("on Wi-Fi: one check", PHONE.connects - before == 1, f"{PHONE.connects - before} checks")
    await asyncio.sleep(0.8)
    check("on Wi-Fi: not checked again, nothing left open", PHONE.connects - before == 1 and PHONE.open == 0)
    Tunnel.current.rsd = None  # pymobiledevice3 tore it down (the iPhone answered with a reset)
    await asyncio.wait_for(task, 2)
    check("transport death ends it at once", wk.history[-1]["reason"] == "connection lost", wk.history[-1]["reason"])


async def scenario_dead_on_wifi():
    global PHONE
    PHONE = Phone()
    wk, root = worker()
    task = asyncio.create_task(wk.session("U", "100.1.2.3", "test"))
    await asyncio.sleep(0.3)
    PHONE.wifi = False
    await asyncio.sleep(0.5)
    PHONE.alive = False  # the iPhone dropped its side meanwhile (it restarted)
    PHONE.wifi = True
    await asyncio.wait_for(task, 5)
    reason = wk.history[-1]["reason"]
    check("dead tunnel found on Wi-Fi ends it (built again there)", reason == "no answer through the tunnel", reason)
    check("status back to searching", wk.status["state"] == "searching")


async def scenario_installs():
    global PHONE
    PHONE = Phone()
    wk, root = worker()
    task = asyncio.create_task(wk.session("U", "100.1.2.3", "test"))
    await asyncio.sleep(0.3)
    PHONE.wifi, PHONE.online = False, False
    await asyncio.sleep(0.6)
    queue(root, "j0", "Waits")
    await asyncio.sleep(0.6)
    check("offline: a new install waits, untouched", job(root, "j0")["state"] == "queued" and PHONE.uses_away == 0)
    PHONE.online = True  # on cellular
    await asyncio.sleep(0.8)
    j = job(root, "j0")
    check("on cellular: installed after steady pings", j["state"] == "done" and j["network"] == "cellular", j["state"])
    check("installs leave nothing open", PHONE.open == 0, f"{PHONE.open} open")
    app = queue(root, "j1", "Mini")
    PHONE.install_cut = True
    await asyncio.sleep(0.6)
    j = job(root, "j1")
    check("cut-off install goes back to the queue", j["state"] == "queued" and j["attempts"] == 1 and app.exists(), j["state"])
    PHONE.online = True
    await asyncio.sleep(0.8)
    j = job(root, "j1")
    check("installed once the iPhone is back", j["state"] == "done" and j["attempts"] == 2 and not app.parent.exists(),
          f'{j["state"]} attempts={j.get("attempts")}')
    wk.stopping = True
    await asyncio.wait_for(task, 2)


async def scenario_refused():
    global PHONE
    PHONE = Phone()
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
    await scenario_quiet()
    await scenario_dead_on_wifi()
    await scenario_installs()
    await scenario_refused()

asyncio.run(main())
print("\n".join("  log: " + l for l in LOG[-14:]))
print("ALL OK" if all(results) else "SOME FAILED")
sys.exit(0 if all(results) else 1)

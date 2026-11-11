"""aOS device worker: holds a CoreDevice tunnel to the person's iPhone and installs apps through it.

Started by aos-devices (a LaunchAgent of aOS) with the Python of aOS's device environment:

    python -I -u aos-devices-worker.py --root "<aOS root folder>"

Why a tunnel that is *held*: iOS opens its RemotePairing port (49152) only while the iPhone is associated with a
Wi-Fi network (any one). A tunnel built then over Tailscale keeps working when the iPhone moves to cellular, because
the iPhone's tailnet address stays the same. So the worker builds the tunnel whenever the port answers and keeps it
open with a light heartbeat; installs go through it, on Wi-Fi or on cellular (Docs/DESIGN.md, "Installing apps on the
iPhone").

Reads   <root>/settings.json           iphoneAddress (empty: found through the Tailscale app), iphoneHeartbeat (s)
        <root>/Devices/Jobs/<id>.json   install jobs written by aOS (state "queued"); the worker updates them
Writes  <root>/run/devices.json        the state, for the app, the iPhone app and the agent tools
"""

from __future__ import annotations

import argparse
import asyncio
import inspect
import json
import os
import shutil
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

from pymobiledevice3.pair_records import iter_remote_paired_identifiers
from pymobiledevice3.remote import userspace_tunnel
from pymobiledevice3.remote.tunnel_service import create_core_device_tunnel_service_using_remotepairing
from pymobiledevice3.services.installation_proxy import InstallationProxyService

PAIRING_PORT = 49152
TAILSCALE_TOOLS = [
    "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    "/usr/local/bin/tailscale",
    "/opt/homebrew/bin/tailscale",
]
TICK = 2.0  # seconds between looks at the job folder
PROBE_EVERY = 30.0  # seconds between looks at whether the iPhone is on Wi-Fi (its pairing port answers)
SEARCH_EVERY = 15.0  # seconds between attempts while no tunnel is up
JOBS_KEPT = 30
JOB_MAX_AGE = 7 * 24 * 3600


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def log(*parts: Any) -> None:
    print(time.strftime("%Y-%m-%d %H:%M:%S"), *parts, flush=True)


def write_json(path: Path, value: Any) -> None:
    """Atomically, readable only by the person."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(value, f, ensure_ascii=False, indent=1)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def read_json(path: Path) -> Optional[Any]:
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


class Worker:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.status_path = root / "run" / "devices.json"
        self.state_path = root / "Devices" / "state.json"
        self.jobs_dir = root / "Devices" / "Jobs"
        self.staging_dir = root / "Devices" / "Staging"
        self.jobs_dir.mkdir(parents=True, exist_ok=True)
        self.staging_dir.mkdir(parents=True, exist_ok=True)
        saved = read_json(self.state_path) or {}
        self.known: dict[str, str] = saved.get("addresses", {})  # udid -> address that worked last
        self.history: list[dict[str, Any]] = saved.get("history", [])[-10:]
        self.status: dict[str, Any] = {
            "version": 1,
            "pid": os.getpid(),
            "state": "starting",
            "message": "",
            "device": saved.get("device"),
            "since": None,
            "network": "unknown",
            "lastHeartbeat": None,
            "history": self.history,
            "jobs": [],
        }
        self.stopping = False

    # MARK: Status

    def publish(self, **changes: Any) -> None:
        self.status.update(changes)
        self.status["updated"] = now_iso()
        self.status["jobs"] = self.job_summaries()
        self.published_jobs = json.dumps(self.status["jobs"], sort_keys=True)
        write_json(self.status_path, self.status)

    def publish_if_jobs_changed(self) -> None:
        if json.dumps(self.job_summaries(), sort_keys=True) != getattr(self, "published_jobs", None):
            self.publish()

    def save_state(self) -> None:
        write_json(self.state_path, {"addresses": self.known, "history": self.history[-10:],
                                     "device": self.status.get("device")})

    # MARK: Settings

    def settings(self) -> dict[str, Any]:
        return read_json(self.root / "settings.json") or {}

    def heartbeat_seconds(self) -> float:
        value = self.settings().get("iphoneHeartbeat", 30)
        try:
            return float(min(max(int(value), 10), 300))
        except (TypeError, ValueError):
            return 30.0

    # MARK: Finding the iPhone

    def paired_identifiers(self) -> list[str]:
        """Devices this Mac holds a RemotePairing record for (pymobiledevice3's records in ~/.pymobiledevice3)."""
        return sorted(set(iter_remote_paired_identifiers()))

    def tailscale_candidates(self) -> list[tuple[str, str]]:
        """(address, name) of the iOS devices in the person's tailnet, online ones first. aOS's own nodes
        (names starting with aos-) are apps, not the iPhone's system VPN, and can't reach its pairing port."""
        tool = next((t for t in TAILSCALE_TOOLS if os.access(t, os.X_OK)), None)
        if not tool:
            return []
        try:
            out = subprocess.run([tool, "status", "--json"], capture_output=True, timeout=8,
                                 env={"PATH": "/usr/bin:/bin", "HOME": os.environ.get("HOME", "")}).stdout
            start = out.find(b"{")
            status = json.loads(out[start:]) if start >= 0 else {}
        except (OSError, subprocess.TimeoutExpired, ValueError):
            return []
        found = []
        for peer in (status.get("Peer") or {}).values():
            if (peer.get("OS") or "").lower() != "ios":
                continue
            name = peer.get("HostName") or ""
            if name.lower().startswith("aos-"):
                continue
            ips = [ip for ip in peer.get("TailscaleIPs") or [] if ":" not in ip]
            if ips:
                found.append((bool(peer.get("Online")), ips[0], name))
        found.sort(key=lambda f: not f[0])
        return [(ip, name) for _, ip, name in found]

    def candidates(self, udid: str) -> list[tuple[str, str]]:
        manual = (self.settings().get("iphoneAddress") or "").strip()
        if manual:
            return [(manual, manual)]
        result: list[tuple[str, str]] = []
        known = self.known.get(udid)
        tailnet = self.tailscale_candidates()
        if known:
            result.append((known, next((n for a, n in tailnet if a == known), known)))
        result += [c for c in tailnet if c[0] != known]
        return result

    @staticmethod
    async def port_open(host: str, port: int = PAIRING_PORT, timeout: float = 4.0) -> bool:
        try:
            _, writer = await asyncio.wait_for(asyncio.open_connection(host, port), timeout)
            writer.close()
            return True
        except (OSError, asyncio.TimeoutError):
            return False

    # MARK: Jobs

    def jobs(self) -> list[tuple[Path, dict[str, Any]]]:
        items = []
        for path in self.jobs_dir.glob("*.json"):
            job = read_json(path)
            if isinstance(job, dict) and job.get("id"):
                items.append((path, job))
        items.sort(key=lambda item: item[1].get("created", ""))
        return items

    def job_summaries(self) -> list[dict[str, Any]]:
        keys = ("id", "name", "bundleId", "version", "source", "state", "message", "created", "finished",
                "seconds", "network")
        jobs = [{k: job.get(k) for k in keys if job.get(k) is not None} for _, job in self.jobs()]
        return jobs[-JOBS_KEPT:][::-1]

    def prune_jobs(self) -> None:
        jobs = self.jobs()
        finished = [(p, j) for p, j in jobs if j.get("state") in ("done", "failed")]
        cutoff = time.time() - JOB_MAX_AGE
        for index, (path, job) in enumerate(finished):
            too_many = index < len(finished) - JOBS_KEPT
            try:
                old = datetime.fromisoformat(job.get("finished", "").replace("Z", "+00:00")).timestamp() < cutoff
            except ValueError:
                old = False
            if too_many or old:
                path.unlink(missing_ok=True)

    def update_job(self, path: Path, job: dict[str, Any], **changes: Any) -> None:
        job.update(changes)
        write_json(path, job)
        self.publish()

    async def run_jobs(self, rsd: Any, network: str) -> None:
        for path, job in self.jobs():
            if job.get("state") != "queued":
                continue
            app = Path(job.get("app", ""))
            if not app.exists():
                self.update_job(path, job, state="failed", message="The app to install is gone.", finished=now_iso())
                continue
            log("installing", job.get("name"), job.get("bundleId"), "over the tunnel,", network)
            self.update_job(path, job, state="installing", started=now_iso(), network=network)
            began = time.time()
            try:
                result = InstallationProxyService(lockdown=rsd).install_from_local(app)
                if inspect.isawaitable(result):
                    await result
                seconds = round(time.time() - began, 1)
                log("installed", job.get("name"), f"in {seconds}s")
                self.update_job(path, job, state="done", message="", finished=now_iso(), seconds=seconds)
            except Exception as error:  # the device refused the app, or the tunnel is gone
                log("install failed", job.get("name"), type(error).__name__, error)
                self.update_job(path, job, state="failed", message=describe(error), finished=now_iso(),
                                seconds=round(time.time() - began, 1))
                # Still there? Otherwise the session ends here and the worker looks for the iPhone again.
                await asyncio.wait_for(rsd.get_value(key="DeviceName"), 20)
            finally:
                staged = self.staging_dir / job["id"]
                if staged.exists():
                    shutil.rmtree(staged, ignore_errors=True)

    # MARK: The tunnel

    async def session(self, udid: str, host: str, name: str) -> None:
        async def provider(serial: str, autopair: bool, fallback: bool = True):
            service = await create_core_device_tunnel_service_using_remotepairing(udid, host, PAIRING_PORT,
                                                                                 autopair=False)
            return service, None

        userspace_tunnel._create_no_root_tunnel_provider = provider
        self.publish(state="connecting", message=f"{name} ({host})")
        began = time.time()
        tunnel = userspace_tunnel.UserspaceRsdTunnel(serial=udid, autopair=False)
        rsd = await asyncio.wait_for(tunnel.aopen(), 60)
        since = time.time()
        device_name = await asyncio.wait_for(rsd.get_value(key="DeviceName"), 20)
        device = {"udid": udid, "name": device_name, "ios": rsd.product_version, "address": host,
                  "addressName": name}
        self.known[udid] = host
        self.publish(state="connected", message="", device=device, since=now_iso(), network="wifi",
                     lastHeartbeat=now_iso())
        self.save_state()
        log(f"tunnel up to {device_name} (iOS {rsd.product_version}) via {name} {host} in {since - began:.1f}s")
        reason = "stopped"
        try:
            last_beat = last_probe = time.time()
            failures = 0
            while not self.stopping:
                now = time.time()
                if now - last_beat >= self.heartbeat_seconds():
                    last_beat = now
                    try:
                        await asyncio.wait_for(rsd.get_value(key="DeviceName"), 20)
                        failures = 0
                        self.publish(lastHeartbeat=now_iso())
                    except Exception as error:
                        failures += 1
                        log("heartbeat failed", failures, type(error).__name__, error)
                        if failures >= 3:
                            reason = f"no answer ({describe(error)})"
                            return
                if now - last_probe >= PROBE_EVERY:
                    last_probe = now
                    network = "wifi" if await self.port_open(host) else "cellular"
                    if network != self.status.get("network"):
                        log("iPhone now on", network, f"(tunnel up {int(now - since)}s)")
                        self.publish(network=network)
                await self.run_jobs(rsd, self.status.get("network", "unknown"))
                await asyncio.sleep(TICK)
        except Exception as error:
            reason = describe(error)
            raise
        finally:
            seconds = int(time.time() - since)
            log(f"tunnel closed after {seconds}s: {reason}")
            self.history.append({"from": datetime.fromtimestamp(since, timezone.utc).isoformat(timespec="seconds")
                                 .replace("+00:00", "Z"), "seconds": seconds, "reason": reason})
            self.history = self.history[-10:]
            self.save_state()
            self.publish(state="searching", since=None, network="unknown", history=self.history,
                         message="")
            try:
                await asyncio.wait_for(tunnel.aclose(), 10)
            except Exception:
                pass

    async def run(self) -> None:
        log("worker started, pid", os.getpid())
        self.prune_jobs()
        self.publish(state="searching")
        while not self.stopping:
            paired = self.paired_identifiers()
            if not paired:
                self.publish(state="notPaired", message="This Mac isn't paired with an iPhone yet.")
                await self.idle(SEARCH_EVERY)
                continue
            connected = False
            for udid in paired:
                for host, name in self.candidates(udid):
                    if self.stopping or not await self.port_open(host):
                        continue
                    try:
                        await self.session(udid, host, name)
                        connected = True
                    except Exception as error:
                        log("tunnel to", name, host, "failed:", type(error).__name__, error)
                        self.publish(state="searching", message=describe(error))
                    break
                if connected:
                    break
            if not connected and self.status.get("state") != "searching":
                self.publish(state="searching")
            self.prune_jobs()
            await self.idle(SEARCH_EVERY)
        self.publish(state="stopped", since=None)

    async def idle(self, seconds: float) -> None:
        """Waits, but keeps the job list in the status current (aOS shows queued jobs while there's no tunnel)."""
        end = time.time() + seconds
        while time.time() < end and not self.stopping:
            await asyncio.sleep(TICK)
            self.publish_if_jobs_changed()


def describe(error: BaseException) -> str:
    text = str(error).strip()
    return f"{type(error).__name__}: {text}" if text else type(error).__name__


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    args = parser.parse_args()
    worker = Worker(Path(args.root))
    loop = asyncio.new_event_loop()

    def stop(*_: Any) -> None:
        worker.stopping = True

    loop.add_signal_handler(signal.SIGTERM, stop)
    loop.add_signal_handler(signal.SIGINT, stop)
    try:
        loop.run_until_complete(worker.run())
    finally:
        loop.close()


if __name__ == "__main__":
    sys.exit(main())

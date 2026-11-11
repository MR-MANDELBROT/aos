"""aOS device setup: the steps on the iPhone itself, for Settings > Apps and the setup's step "Apps on your iPhone".

Run by aOS with the Python of its device environment, one command at a time; prints one JSON object:

    python -I aos-devices-setup.py status              iPhones on a cable (or Wi-Fi sync): trusted, Developer Mode
    python -I aos-devices-setup.py trust UDID          "Trust This Computer?" on the iPhone; waits for the answer
    python -I aos-devices-setup.py reveal UDID         shows the Developer Mode switch in Settings > Privacy & Security
    python -I aos-devices-setup.py remotepair UDID     the RemotePairing record the held tunnel uses (no prompt)

Errors come back as {"error": "...", "kind": "..."}; the exit status is 0 either way unless the arguments are wrong.
"""

from __future__ import annotations

import asyncio
import json
import sys
from typing import Any, Optional

from pymobiledevice3.exceptions import (
    PairingDialogResponsePendingError,
    PasswordRequiredError,
    RemotePairingCompletedError,
    UserDeniedPairingError,
)
from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.pair_records import iter_remote_paired_identifiers
from pymobiledevice3.remote.tunnel_service import RemotePairingLockdownService
from pymobiledevice3.services.amfi import AmfiService
from pymobiledevice3.usbmux import list_devices

TRUST_WAIT = 120  # seconds the person has to tap Trust and enter the passcode


def out(value: dict[str, Any]) -> None:
    print(json.dumps(value), flush=True)


def kind(error: BaseException) -> str:
    return type(error).__name__


async def lockdown(udid: str, autopair: bool = False, pair_timeout: Optional[float] = None) -> Any:
    devices = [d for d in await list_devices() if d.matches_udid(udid)]
    if not devices:
        raise LookupError("The iPhone isn't connected.")
    device = next((d for d in devices if d.is_usb), devices[0])
    return await create_using_usbmux(serial=device.serial, autopair=autopair, connection_type=device.connection_type,
                                     pair_timeout=pair_timeout)


async def status() -> dict[str, Any]:
    remote = set(iter_remote_paired_identifiers())
    found: dict[str, dict[str, Any]] = {}
    for device in await list_devices():
        udid = device.serial
        entry = found.get(udid)
        if entry and entry["connection"] == "USB":
            continue  # the same iPhone over Wi-Fi sync too: the cable wins
        info: dict[str, Any] = {"udid": udid, "connection": device.connection_type, "trusted": False,
                                "developerMode": None, "remotePaired": udid in remote}
        try:
            client = await create_using_usbmux(serial=udid, autopair=False, connection_type=device.connection_type)
            try:
                values = client.short_info
                info.update(name=values.get("DeviceName"), ios=values.get("ProductVersion"),
                            model=values.get("ProductType"), deviceClass=values.get("DeviceClass"))
                info["trusted"] = bool(client.paired)
                if client.paired:
                    info["developerMode"] = await client.get_developer_mode_status()
            finally:
                await client.close()
        except PasswordRequiredError:
            info["locked"] = True  # trusted once it's unlocked
        except Exception as error:  # e.g. the cable was just pulled
            info["problem"] = f"{kind(error)}: {error}"
        if info.get("deviceClass", "iPhone") in ("iPhone", "iPad", None):
            found[udid] = info
    return {"devices": list(found.values())}


async def trust(udid: str) -> dict[str, Any]:
    try:
        client = await lockdown(udid, autopair=True, pair_timeout=TRUST_WAIT)
        await client.close()
        return {"trusted": True}
    except UserDeniedPairingError:
        return {"error": "The iPhone said Don't Trust.", "kind": "denied"}
    except PairingDialogResponsePendingError:
        return {"error": "No answer on the iPhone yet.", "kind": "pending"}
    except PasswordRequiredError:
        return {"error": "Unlock the iPhone first.", "kind": "locked"}


async def reveal(udid: str) -> dict[str, Any]:
    client = await lockdown(udid)
    try:
        if await client.get_developer_mode_status():
            return {"developerMode": True}
        await AmfiService(client).reveal_developer_mode_option_in_ui()
        return {"developerMode": False, "revealed": True}
    finally:
        await client.close()


async def remotepair(udid: str) -> dict[str, Any]:
    client = await lockdown(udid)
    try:
        service = await RemotePairingLockdownService.create(client)
        try:
            await service.connect(autopair=True)
        except RemotePairingCompletedError:
            pass  # paired; the iPhone closes the connection after pair-setup
        finally:
            await service.close()
    finally:
        await client.close()
    return {"remotePaired": udid in set(iter_remote_paired_identifiers())}


def main() -> int:
    args = sys.argv[1:]
    commands = {"status": (status, 0), "trust": (trust, 1), "reveal": (reveal, 1), "remotepair": (remotepair, 1)}
    if not args or args[0] not in commands or len(args) - 1 != commands[args[0]][1]:
        print(__doc__, file=sys.stderr)
        return 2
    function, _ = commands[args[0]]
    try:
        out(asyncio.run(function(*args[1:])))
    except Exception as error:
        out({"error": str(error) or kind(error), "kind": kind(error)})
    return 0


if __name__ == "__main__":
    sys.exit(main())

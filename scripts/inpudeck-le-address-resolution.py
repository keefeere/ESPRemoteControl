#!/usr/bin/env python3
"""Restore BlueZ's missing LE address-resolution flag for bonded dual-mode peers.

BlueZ 5.87 does not push this flag for dual-mode devices with a stored IRK.
Run from bluetooth.service ExecStartPost, after bluetoothd has loaded its bonds.
This only changes kernel management flags; it does not scan or connect.
"""

import argparse
import configparser
from pathlib import Path
import re
import subprocess
import sys


FLAG = 0x04
STORAGE = Path("/var/lib/bluetooth")


def run(*args):
    return subprocess.run(args, text=True, capture_output=True, timeout=5)


def controller_address(adapter, execute=run):
    result = execute("btmgmt", "-i", adapter, "info")
    if result.returncode:
        raise RuntimeError(f"btmgmt info failed: {result.stderr.strip()}")
    match = re.search(r"\baddr ([0-9A-Fa-f:]{17})\b", result.stdout)
    if not match:
        raise RuntimeError("Controller address missing from btmgmt info")
    return match.group(1).upper()


def eligible(info):
    config = configparser.ConfigParser(interpolation=None)
    try:
        config.read(info)
        technologies = set(config.get("General", "SupportedTechnologies").split(";"))
        kind = config.get("General", "AddressType", fallback="").lower()
    except (configparser.Error, OSError):
        return None
    if not {"BR/EDR", "LE"} <= technologies:
        return None
    if not (config.has_section("IdentityResolvingKey") and
            config.has_section("LinkKey") and
            (config.has_section("LongTermKey") or
             config.has_section("PeripheralLongTermKey"))):
        return None
    return "2" if kind in ("static", "random") else "1" if kind == "public" else None


def apply(adapter, storage=STORAGE, execute=run):
    controller = controller_address(adapter, execute)
    directory = storage / controller
    if not directory.is_dir():
        raise RuntimeError(f"BlueZ bond directory missing: {directory}")
    changed = 0
    for info in sorted(directory.glob("*/info")):
        address = info.parent.name.upper()
        if not re.fullmatch(r"[0-9A-F]{2}(?::[0-9A-F]{2}){5}", address):
            continue
        address_type = eligible(info)
        if address_type is None:
            continue
        base = ("btmgmt", "-i", adapter)
        flags = execute(*base, "get-flags", "-t", address_type, address)
        match = re.search(r"Current Flags:\s*0x([0-9a-fA-F]+)", flags.stdout)
        current = int(match.group(1), 16) if match else 0
        if current & FLAG:
            continue
        result = execute(*base, "set-flags", "-t", address_type,
                         "-f", str(current | FLAG), address)
        if result.returncode:
            print(f"Address-resolution flag failed for {address}: "
                  f"{result.stderr.strip() or result.stdout.strip()}", file=sys.stderr)
            continue
        print(f"Address resolution enabled for bonded dual-mode peer {address}")
        changed += 1
    print(f"Address-resolution flags changed: {changed}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adapter", default="hci0")
    args = parser.parse_args()
    try:
        apply(args.adapter)
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"Address-resolution setup failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

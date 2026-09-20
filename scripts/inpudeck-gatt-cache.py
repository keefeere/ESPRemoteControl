#!/usr/bin/env python3
"""Manage the reversible BlueZ GATT-cache workaround for InpuDeck on Linux.

BlueZ's Cache=no setting is host-wide. A Bluetooth restart is needed to activate
it and disconnects all Bluetooth devices. Pairing keys are never touched.
"""

import argparse
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

CONFIG = Path("/etc/bluetooth/main.conf")
MARKER = "# Managed by InpuDeck: inpudeck-gatt-cache.py\n"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def atomic_write(path, data, mode):
    fd, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fchmod(stream.fileno(), mode)
        Path(temporary).replace(path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def enable_content(original):
    text = original.decode("utf-8")
    sections = list(re.finditer(r"(?m)^\[([^]\r\n]+)\]\s*$", text))
    gatt = next((match for match in sections if match.group(1).strip().lower() == "gatt"), None)
    if not gatt:
        return (text.rstrip("\n") + "\n\n[GATT]\n" + MARKER + "Cache=no\n").encode()
    end = next((match.start() for match in sections if match.start() > gatt.start()), len(text))
    body = text[gatt.end():end]
    if re.search(r"(?m)^\s*Cache\s*=", body):
        raise ValueError("[GATT] Cache is already configured; inspect it before changing host policy")
    return (text[:gatt.end()] + "\n" + MARKER + "Cache=no" + text[gatt.end():]).encode()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("status", "enable", "disable"))
    parser.add_argument("--restart", action="store_true", help="restart Bluetooth now; all devices briefly disconnect")
    parser.add_argument("--adopt-original", type=Path, help="adopt an existing Cache=no test using its exact pre-test backup")
    parser.add_argument("--config", type=Path, default=CONFIG, help=argparse.SUPPRESS)
    args = parser.parse_args()
    path = args.config
    backup = path.with_name(path.name + ".inpudeck-before-cache")
    stamp = path.with_name(path.name + ".inpudeck-cache-sha256")
    if args.action != "enable" and args.adopt_original:
        parser.error("--adopt-original requires enable")
    if args.action == "status" and args.restart:
        parser.error("status cannot restart Bluetooth")
    try:
        for item in (path, backup, stamp):
            if item.is_symlink():
                raise ValueError(f"Refusing symlink: {item}")
        current = path.read_bytes()
        managed = backup.exists() and stamp.exists()
        if backup.exists() != stamp.exists():
            raise ValueError("Incomplete InpuDeck backup; inspect it before proceeding")
        active = bool(re.search(rb"(?m)^\s*Cache\s*=\s*no\s*$", current))
        if args.action == "status":
            print(f"Configured Cache=no: {'yes' if active else 'no'}; managed by this helper: {'yes' if managed else 'no'}")
            print("The running daemon reads this setting only when Bluetooth starts.")
            return 0
        if os.geteuid() != 0 and path == CONFIG:
            raise PermissionError("Run with sudo to change the system configuration")
        mode = path.stat().st_mode & 0o777
        adopted = bool(args.adopt_original)
        if args.action == "enable":
            if managed:
                if digest(current) != stamp.read_text().strip():
                    raise ValueError("main.conf changed since installation; refusing to overwrite it")
                print("Already managed; no configuration change")
            else:
                if args.adopt_original:
                    original = args.adopt_original.read_bytes()
                    expected = enable_content(original)
                    # The manual test added the same setting without our comment.
                    if current != expected.replace(MARKER.encode(), b""):
                        raise ValueError("Current main.conf does not match the supplied pre-test backup")
                else:
                    original = current
                    expected = enable_content(original)
                atomic_write(backup, original, 0o600)
                try:
                    atomic_write(path, expected, mode)
                    atomic_write(stamp, (digest(expected) + "\n").encode(), 0o600)
                except Exception:
                    atomic_write(path, original, mode)
                    backup.unlink(missing_ok=True)
                    stamp.unlink(missing_ok=True)
                    raise
                print("Configured Cache=no; original main.conf backed up")
        else:
            if not managed:
                print("No helper-managed cache override; nothing removed")
            else:
                if digest(current) != stamp.read_text().strip():
                    raise ValueError("main.conf changed since installation; refusing to overwrite it")
                atomic_write(path, backup.read_bytes(), mode)
                backup.unlink()
                stamp.unlink()
                print("Restored original main.conf")
        if args.restart:
            print("Restarting Bluetooth; all connected Bluetooth devices will briefly disconnect.", flush=True)
            subprocess.run(("systemctl", "restart", "bluetooth.service"), check=True)
        else:
            if args.action == "enable" and adopted:
                print("Adopted the already-active test; only a comment changed, no restart needed")
            else:
                print("No Bluetooth restart; effective changes apply at its next start/reboot")
        return 0
    except (OSError, ValueError, UnicodeError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

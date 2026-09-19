#!/usr/bin/env python3
"""Idempotent setup of the BlueZ userspace experimental API, with explicit activation.

Only our systemd drop-ins are managed. No packages, main.conf, pairing records,
kernel settings, audio rules, or user services are changed.
"""

import argparse
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

UNIT = "bluetooth.service"
NAME = "90-esp-remote-le.conf"
LEGACY_NAME = "90-esp-remote-le-test.conf"
DAEMONS = ("/usr/libexec/bluetooth/bluetoothd", "/usr/lib/bluetooth/bluetoothd")
MARKER = "# Managed by ESP Remote: linux-le-setup.py\n"


def command(*args):
    return subprocess.run(args, check=True, text=True, capture_output=True).stdout.strip()


def daemon_from_exec(value):
    match = re.search(r"argv\[\]=(.*?) ;", value)
    if match:
        for daemon in DAEMONS:
            if match[1] in (daemon, daemon + " --experimental"):
                return daemon
    raise RuntimeError("Customized Bluetooth ExecStart; inspect it before adding --experimental.")


def content(daemon):
    return MARKER + f"[Service]\nExecStart=\nExecStart={daemon} --experimental\n"


def read_owned(path, legacy=False):
    if path.is_symlink():
        raise RuntimeError(f"Refusing to change a symlink: {path}")
    if not path.exists():
        return None
    text = path.read_text()
    allowed = {content(daemon) for daemon in DAEMONS}
    if legacy:
        allowed.update(content(daemon).removeprefix(MARKER) for daemon in DAEMONS)
    if text not in allowed:
        raise RuntimeError(f"File has local changes or belongs to another setup: {path}")
    return text


def write_file(path, text):
    if text is None:
        path.unlink(missing_ok=True)
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as file:
            temporary = Path(file.name)
            file.write(text)
            file.flush()
            os.fchmod(file.fileno(), 0o644)
        temporary.replace(path)
    finally:
        if temporary:
            temporary.unlink(missing_ok=True)


class Setup:
    def __init__(self, root=Path("/"), run=command):
        self.root = root
        self.run = run
        self.persistent = root / "etc/systemd/system/bluetooth.service.d" / NAME
        self.runtime = root / "run/systemd/system/bluetooth.service.d" / NAME
        self.legacy = self.runtime.with_name(LEGACY_NAME)

    def status(self):
        for label, path in (("Persistent", self.persistent), ("Temporary", self.runtime),
                            ("Earlier temporary test", self.legacy)):
            state = "present" if path.exists() or path.is_symlink() else "absent"
            print(f"{label}: {state} ({path})")
        pid = self.run("systemctl", "show", UNIT, "-p", "MainPID", "--value")
        try:
            args = (self.root / f"proc/{int(pid)}/cmdline").read_bytes().split(b"\0")
            enabled = b"--experimental" in args or b"-E" in args
            print(f"Running daemon has experimental flag: {'yes' if enabled else 'no'}")
        except (OSError, ValueError):
            print("Running daemon command: unavailable")
        print("Use linux-hid-connect.sh --why to check the actual LE API on the paired device.")

    def plan(self, action, temporary):
        old = {path: read_owned(path, path == self.legacy)
               for path in (self.persistent, self.runtime, self.legacy)}
        new = dict(old)
        if action == "enable":
            daemon = daemon_from_exec(self.run("systemctl", "show", UNIT, "-p", "ExecStart", "--value"))
            desired = content(daemon)
            if temporary:
                # A persistent installation already covers temporary use.
                if old[self.persistent] is None:
                    new[self.runtime] = desired
                new[self.legacy] = None
            else:
                new[self.persistent] = desired
                new[self.runtime] = None
                new[self.legacy] = None
        else:
            new[self.runtime] = None
            new[self.legacy] = None
            if not temporary:
                new[self.persistent] = None
        return [(path, old[path], value) for path, value in new.items() if value != old[path]]

    def apply(self, changes, restart=False):
        written = []
        try:
            for path, old, new in changes:
                write_file(path, new)
                written.append((path, old))
            if changes:
                self.run("systemctl", "daemon-reload")
        except Exception:
            for path, old in reversed(written):
                write_file(path, old)
            if written:
                self.run("systemctl", "daemon-reload")
            raise
        if restart:
            print("Restarting Bluetooth: current Bluetooth devices will disconnect.", flush=True)
            self.run("systemctl", "restart", UNIT)
            self.run("systemctl", "is-active", UNIT)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("status", "enable", "disable"))
    parser.add_argument("--temporary", action="store_true", help="use /run only; disappears at reboot")
    parser.add_argument("--restart", action="store_true", help="explicitly restart Bluetooth to activate now")
    parser.add_argument("--dry-run", action="store_true", help="show changes without writing or restarting")
    args = parser.parse_args()
    setup = Setup()
    try:
        if args.action == "status":
            if args.restart:
                parser.error("status cannot restart Bluetooth")
            setup.status()
            return 0
        changes = setup.plan(args.action, args.temporary)
        for path, _, new in changes:
            print(f"{'Write' if new is not None else 'Remove'}: {path}")
            if new:
                print(new, end="")
        if not changes:
            print("Configuration already matches; no files changed.")
        if args.dry_run:
            print(f"Dry run; Bluetooth restart requested: {args.restart}")
            return 0
        if os.geteuid() != 0 and (changes or args.restart):
            raise RuntimeError("Run this command with sudo to apply the displayed setup changes.")
        setup.apply(changes, args.restart)
        if not args.restart:
            print("Bluetooth was not restarted. Files apply at its next start/reboot.")
            print("An already running --experimental daemon keeps working during promotion.")
            print("To activate a new setting now, repeat this command with --restart.")
        return 0
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr.strip(), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

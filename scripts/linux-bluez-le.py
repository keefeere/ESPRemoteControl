#!/usr/bin/env python3
"""BlueZ operations scoped to one adapter and one bonded LE HID peer.

Requires python3-dbus. Never use Device1.Connect/ConnectProfile here: those
can select BR/EDR on a dual-mode phone. BlueZ's experimental Bearer.LE1 API
provides both an explicit transport and a transport-specific connection state.
"""

import argparse
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

DEVICE = "org.bluez.Device1"
ADAPTER = "org.bluez.Adapter1"
LE = "org.bluez.Bearer.LE1"
BREDR = "org.bluez.Bearer.BREDR1"
PROPERTIES = "org.freedesktop.DBus.Properties"
HID = "00001812-0000-1000-8000-00805f9b34fb"
AUDIO = ("110a", "110c", "110e", "111f", "1112")


def find_device(objects, adapter_path, address):
    matches = [(str(path), interfaces) for path, interfaces in objects.items()
               if DEVICE in interfaces
               and str(interfaces[DEVICE].get("Adapter")) == adapter_path
               and str(interfaces[DEVICE].get("Address", "")).upper() == address.upper()]
    if len(matches) != 1:
        raise RuntimeError(f"Expected one device {address} on {adapter_path}; found {len(matches)}")
    return matches[0]


def has_method(xml, interface, method):
    root = ET.fromstring(xml)
    return any(node.get("name") == method
               for iface in root.findall("interface") if iface.get("name") == interface
               for node in iface.findall("method"))


def hid_attached(address, adapter_address, root=Path("/sys/bus/hid/devices")):
    # BlueZ UHID supplies the peer as HID_UNIQ and the local adapter as
    # HID_PHYS. Names alone also match USB bridges and other ESP Remote phones.
    for path in root.glob("*/uevent"):
        try:
            fields = dict(line.split("=", 1) for line in path.read_text().splitlines() if "=" in line)
        except OSError:
            continue
        if (fields.get("HID_ID", "").startswith("0005:")
                and fields.get("HID_UNIQ", "").lower() == address.lower()
                and fields.get("HID_PHYS", "").lower() == adapter_address.lower()):
            return True
    return False


def hid_ready(interfaces, address, adapter_address, root=Path("/sys/bus/hid/devices")):
    # UHID can survive a dropped connection: also require the LE bearer.
    # BlueZ 5.87 clears Device1.ServicesResolved when either bearer disconnects,
    # including Classic while LE HID stays attached. Report it separately.
    return bool(interfaces.get(LE, {}).get("Connected")
                and hid_attached(address, adapter_address, root))


class BlueZ:
    def __init__(self, adapter, dbus_module):
        self.dbus = dbus_module
        self.bus = dbus_module.SystemBus()
        self.adapter_path = f"/org/bluez/{adapter}"
        manager = self.interface("/", "org.freedesktop.DBus.ObjectManager")
        self.objects = manager.GetManagedObjects(timeout=5)
        self.adapter = self.objects.get(self.adapter_path, {}).get(ADAPTER)
        if self.adapter is None:
            raise RuntimeError(f"Adapter {adapter} is not available")

    def interface(self, path, interface):
        return self.dbus.Interface(self.bus.get_object("org.bluez", path), interface)

    def target(self, address):
        return find_device(self.objects, self.adapter_path, address)

    def require_le(self, path, interfaces):
        props = interfaces[DEVICE]
        if not self.adapter.get("Powered"):
            raise RuntimeError("Bluetooth adapter is powered off")
        if not props.get("Paired") or props.get("Blocked"):
            raise RuntimeError("Target must be paired and not blocked")
        # UUIDs are a discovery cache, not pairing identity or a prerequisite
        # for LE.Connect. iOS can remove this app's service while it is stopped;
        # after reboot the paired phone may therefore have no cached HID UUID.
        # The caller explicitly selected this address. Verify HID after connect.
        xml = self.interface(path, "org.freedesktop.DBus.Introspectable").Introspect(timeout=5)
        if not has_method(xml, LE, "Connect"):
            raise RuntimeError(
                "BlueZ does not expose Bearer.LE1.Connect. Enable its experimental D-Bus API "
                "(see docs/linux-direct-hid.md); this helper will not fall back to Classic."
            )

    def connect(self, path, interfaces):
        self.require_le(path, interfaces)
        if interfaces.get(LE, {}).get("Connected"):
            print("LE is already connected; waiting for HID")
            return
        print(f"Connecting LE only: {path} via {LE}.Connect", flush=True)
        try:
            self.interface(path, LE).Connect(timeout=25)
        except self.dbus.DBusException as error:
            if error.get_dbus_name() not in ("org.bluez.Error.AlreadyConnected", "org.bluez.Error.InProgress"):
                raise
            print(f"LE request: {error.get_dbus_name()}; waiting for HID", flush=True)

    def set_preferred_bearer(self, path, interfaces, value):
        self.require_le(path, interfaces)
        if "PreferredBearer" not in interfaces[DEVICE]:
            raise RuntimeError("This BlueZ device does not expose PreferredBearer")
        previous = str(interfaces[DEVICE]["PreferredBearer"])
        print(f"PreferredBearer: {previous} -> {value} (saved by BlueZ for this device)")
        if previous != value:
            self.interface(path, PROPERTIES).Set(DEVICE, "PreferredBearer", value, timeout=5)

    def disconnect_device(self, path, interfaces):
        self.require_le(path, interfaces)
        print(f"Disconnecting both transports and pending requests for {path}; bond retained", flush=True)
        try:
            self.interface(path, DEVICE).Disconnect(timeout=15)
        except self.dbus.DBusException as error:
            if error.get_dbus_name() != "org.bluez.Error.NotConnected":
                raise

    def drop_audio(self, path, interfaces):
        requested = []
        for short in AUDIO:
            uuid = f"0000{short}-0000-1000-8000-00805f9b34fb"
            if uuid not in interfaces[DEVICE].get("UUIDs", []):
                continue
            try:
                self.interface(path, DEVICE).DisconnectProfile(uuid, timeout=5)
                requested.append(short)
            except self.dbus.DBusException as error:
                if error.get_dbus_name() not in ("org.bluez.Error.NotConnected",
                                                "org.bluez.Error.InvalidArguments",
                                                "org.bluez.Error.NotSupported"):
                    raise
        return requested


def print_info(path, interfaces):
    props = interfaces[DEVICE]
    print(f"Device {props['Address']}")
    print(f"  Path: {path}")
    for key in ("Name", "Alias", "AddressType", "PreferredBearer", "Paired", "Bonded", "Trusted", "Blocked", "Connected", "ServicesResolved"):
        if key in props:
            value = props[key]
            if key in ("Paired", "Bonded", "Trusted", "Blocked", "Connected", "ServicesResolved"):
                value = "yes" if value else "no"
            print(f"  {key}: {value}")
    for label, iface in (("LEConnected", LE), ("BREDRConnected", BREDR)):
        connected = interfaces.get(iface, {}).get("Connected")
        value = "unknown" if connected is None else ("yes" if connected else "no")
        print(f"  {label}: {value}")
    for uuid in props.get("UUIDs", []):
        print(f"  UUID: {uuid}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adapter", default="hci0")
    parser.add_argument("command", choices=("adapter-info", "paired", "info", "check", "connect", "disconnect", "disconnect-device", "preferred-bearer", "trust", "drop-audio", "hid-ready"))
    parser.add_argument("address", nargs="?")
    parser.add_argument("bearer", nargs="?", choices=("le", "bredr", "last-used", "last-seen"))
    args = parser.parse_args()
    if (args.command == "preferred-bearer") != (args.bearer is not None):
        parser.error("preferred-bearer requires a value; other commands do not accept one")
    if not re.fullmatch(r"hci[0-9]+", args.adapter):
        parser.error("adapter must be hciN")
    if args.command not in ("adapter-info", "paired") and (
            not args.address or not re.fullmatch(r"(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}", args.address)):
        parser.error("a device MAC address is required")
    try:
        import dbus
    except ImportError:
        print("error: python3-dbus is required by the LE helper", file=sys.stderr)
        return 2
    try:
        bluez = BlueZ(args.adapter, dbus)
        if args.command == "adapter-info":
            print(f"Controller {bluez.adapter['Address']}")
            print(f"  Powered: {'yes' if bluez.adapter.get('Powered') else 'no'}")
            return 0
        if args.command == "paired":
            for interfaces in bluez.objects.values():
                props = interfaces.get(DEVICE, {})
                if props.get("Adapter") == bluez.adapter_path and props.get("Paired"):
                    print(props["Address"])
            return 0
        path, interfaces = bluez.target(args.address)
        if args.command == "info":
            print_info(path, interfaces)
        elif args.command == "check":
            bluez.require_le(path, interfaces)
            print(f"LE-only API available: {path}")
        elif args.command == "connect":
            bluez.connect(path, interfaces)
        elif args.command == "preferred-bearer":
            bluez.set_preferred_bearer(path, interfaces, args.bearer)
        elif args.command == "disconnect-device":
            bluez.disconnect_device(path, interfaces)
        elif args.command == "disconnect":
            bluez.require_le(path, interfaces)
            print(f"Disconnecting LE only: {path}", flush=True)
            bluez.interface(path, LE).Disconnect(timeout=10)
        elif args.command == "trust":
            bluez.interface(path, PROPERTIES).Set(DEVICE, "Trusted", dbus.Boolean(True), timeout=5)
        elif args.command == "drop-audio":
            bluez.drop_audio(path, interfaces)
        elif args.command == "hid-ready":
            return 0 if hid_ready(interfaces, args.address, str(bluez.adapter["Address"])) else 1
        return 0
    except (RuntimeError, dbus.DBusException, ET.ParseError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())

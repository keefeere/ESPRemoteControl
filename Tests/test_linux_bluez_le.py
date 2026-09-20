"""Regression checks for transport selection and identity resolution; no radio needed."""

import importlib.util
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

SPEC = importlib.util.spec_from_file_location(
    "linux_bluez_le", Path(__file__).resolve().parents[1] / "scripts/inpudeck-bluez-le.py")
le = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(le)

ADAPTER_PATH = "/org/bluez/hci0"
LOCAL = "44:F7:9F:AC:CD:9C"
MAC = "10:A2:D3:01:47:A1"
# The object keeps the pre-bonding RPA, while Address becomes the identity.
PATH = ADAPTER_PATH + "/dev_60_76_12_C9_CD_46"


class DBusError(Exception):
    def get_dbus_name(self):
        return self.args[0]


class FakeBus:
    def __init__(self, enabled=True, connected=False, error=None):
        self.calls = []
        self.error = error
        self.discovery_error = None
        self.xml = ('<node><interface name="org.bluez.Bearer.LE1">'
                    + ('<method name="Connect"/>' if enabled else '')
                    + '</interface></node>')
        self.objects = {
            ADAPTER_PATH: {le.ADAPTER: {"Address": LOCAL, "Powered": True}},
            PATH: {le.DEVICE: {"Adapter": ADAPTER_PATH, "Address": MAC,
                              "Paired": True, "Blocked": False, "UUIDs": [le.HID]},
                   le.LE: {"Connected": connected}, le.BREDR: {"Connected": True}}
        }

    def interface(self, path, name):
        bus = self

        class Proxy:
            def GetManagedObjects(self, **kwargs):
                return bus.objects

            def Introspect(self, **kwargs):
                return bus.xml

            def Connect(self, **kwargs):
                bus.calls.append((path, name, "Connect"))
                if name != le.LE:
                    raise AssertionError("A generic or Classic connection was attempted")
                if bus.error:
                    raise DBusError(bus.error)

            def Set(self, interface, prop, value, **kwargs):
                bus.calls.append((path, name, "Set", interface, prop, value))
                bus.objects[path][interface][prop] = value

            def Disconnect(self, **kwargs):
                bus.calls.append((path, name, "Disconnect"))

            def DisconnectProfile(self, uuid, **kwargs):
                bus.calls.append((path, name, "DisconnectProfile", uuid))

            def SetDiscoveryFilter(self, values, **kwargs):
                bus.calls.append((path, name, "SetDiscoveryFilter", values))

            def StartDiscovery(self, **kwargs):
                bus.calls.append((path, name, "StartDiscovery"))
                if bus.discovery_error:
                    raise DBusError(bus.discovery_error)

            def StopDiscovery(self, **kwargs):
                bus.calls.append((path, name, "StopDiscovery"))

        return Proxy()

    def client(self):
        dbus = SimpleNamespace(SystemBus=lambda: self, Interface=self.interface,
                               DBusException=DBusError, Boolean=bool,
                               Dictionary=lambda value, **kw: dict(value),
                               Array=lambda value, **kw: list(value))
        return le.BlueZ("hci0", dbus)

    def get_object(self, service, path):
        assert service == "org.bluez"
        return path


class TransportTests(unittest.TestCase):
    def test_discovery_is_bounded_le_only_and_released_without_connecting(self):
        bus = FakeBus()
        bus.objects[PATH][le.DEVICE]["UUIDs"] = []
        client = bus.client()
        elapsed = [0]
        def sleep(seconds):
            elapsed[0] += seconds
            bus.objects[PATH][le.DEVICE]["UUIDs"] = [le.HID]
        client.discover(MAC, seconds=12, sleep=sleep, clock=lambda: elapsed[0])
        self.assertEqual(elapsed[0], 12)
        self.assertEqual(bus.calls, [
            (ADAPTER_PATH, le.ADAPTER, "SetDiscoveryFilter", {
                "Transport": "le", "DuplicateData": False}),
            (ADAPTER_PATH, le.ADAPTER, "StartDiscovery"),
            (ADAPTER_PATH, le.ADAPTER, "StopDiscovery"),
            (ADAPTER_PATH, le.ADAPTER, "SetDiscoveryFilter", {})])
        self.assertIn(le.HID, client.target(MAC)[1][le.DEVICE]["UUIDs"])

    def test_discovery_does_not_touch_an_existing_le_link(self):
        bus = FakeBus(connected=True)
        bus.client().discover(MAC)
        self.assertEqual(bus.calls, [])

    def test_failed_discovery_start_removes_filter_without_stopping_another_session(self):
        bus = FakeBus()
        bus.discovery_error = "org.bluez.Error.NotReady"
        with self.assertRaises(DBusError):
            bus.client().discover(MAC)
        self.assertEqual([call[2] for call in bus.calls],
                         ["SetDiscoveryFilter", "StartDiscovery", "SetDiscoveryFilter"])
        self.assertEqual(bus.calls[-1][-1], {})

    def test_unpaired_target_cannot_start_discovery(self):
        bus = FakeBus()
        bus.objects[PATH][le.DEVICE]["Paired"] = False
        with self.assertRaisesRegex(RuntimeError, "paired"):
            bus.client().discover(MAC)
        self.assertEqual(bus.calls, [])

    def test_native_reconnect_ends_discovery_early_without_resetting_link(self):
        bus = FakeBus()
        elapsed = [0]
        def sleep(seconds):
            elapsed[0] += seconds
            bus.objects[PATH][le.LE]["Connected"] = True
        bus.client().discover(MAC, sleep=sleep, clock=lambda: elapsed[0])
        self.assertEqual(elapsed[0], 1)
        self.assertEqual([call[2] for call in bus.calls],
                         ["SetDiscoveryFilter", "StartDiscovery", "StopDiscovery", "SetDiscoveryFilter"])

    def test_discovery_cleans_up_when_target_disappears(self):
        bus = FakeBus()
        elapsed = [0]
        def sleep(seconds):
            elapsed[0] += seconds
            del bus.objects[PATH]
        with self.assertRaisesRegex(RuntimeError, "found 0"):
            bus.client().discover(MAC, sleep=sleep, clock=lambda: elapsed[0])
        self.assertEqual(bus.calls[-2:], [
            (ADAPTER_PATH, le.ADAPTER, "StopDiscovery"),
            (ADAPTER_PATH, le.ADAPTER, "SetDiscoveryFilter", {})])

    def test_discovery_cleanup_also_runs_on_interruption(self):
        bus = FakeBus()
        def interrupted(seconds):
            raise KeyboardInterrupt()
        with self.assertRaises(KeyboardInterrupt):
            bus.client().discover(MAC, sleep=interrupted, clock=lambda: 0)
        self.assertEqual(bus.calls[-2:], [
            (ADAPTER_PATH, le.ADAPTER, "StopDiscovery"),
            (ADAPTER_PATH, le.ADAPTER, "SetDiscoveryFilter", {})])

    def test_bond_identity_resolves_to_existing_rpa_path(self):
        bus = FakeBus()
        # Same phone paired on another adapter must not change the target.
        bus.objects["/org/bluez/hci1/dev_other"] = {
            le.DEVICE: {"Adapter": "/org/bluez/hci1", "Address": MAC}}
        client = bus.client()
        path, interfaces = client.target(MAC.lower())
        client.connect(path, interfaces)
        self.assertEqual(bus.calls, [(PATH, le.LE, "Connect")])

    def test_classic_link_does_not_count_as_le_connected(self):
        bus = FakeBus(connected=False)
        client = bus.client()
        client.connect(*client.target(MAC))
        self.assertEqual(len(bus.calls), 1)

    def test_existing_le_link_is_preserved(self):
        bus = FakeBus(connected=True)
        client = bus.client()
        client.connect(*client.target(MAC))
        self.assertEqual(bus.calls, [])

    def test_missing_experimental_method_fails_without_connecting(self):
        bus = FakeBus(enabled=False)
        client = bus.client()
        with self.assertRaisesRegex(RuntimeError, "does not expose"):
            client.connect(*client.target(MAC))
        self.assertEqual(bus.calls, [])

    def test_le_timeout_has_no_classic_fallback_or_disconnect(self):
        bus = FakeBus(error="org.freedesktop.DBus.Error.NoReply")
        client = bus.client()
        with self.assertRaises(DBusError):
            client.connect(*client.target(MAC))
        self.assertEqual(bus.calls, [(PATH, le.LE, "Connect")])

    def test_pending_request_does_not_reset_link(self):
        bus = FakeBus(error="org.bluez.Error.InProgress")
        client = bus.client()
        client.connect(*client.target(MAC))
        self.assertEqual(bus.calls, [(PATH, le.LE, "Connect")])

    def test_failed_pending_att_does_not_trigger_destructive_recovery(self):
        bus = FakeBus(error="org.bluez.Error.Failed")
        client = bus.client()
        with self.assertRaises(DBusError):
            client.connect(*client.target(MAC))
        self.assertEqual(bus.calls, [(PATH, le.LE, "Connect")])

    def test_preference_changes_only_selected_phone_and_repeat_is_noop(self):
        bus = FakeBus()
        bus.objects[PATH][le.DEVICE]["PreferredBearer"] = "last-used"
        client = bus.client()
        client.set_preferred_bearer(*client.target(MAC), "le")
        client.set_preferred_bearer(*client.target(MAC), "le")
        self.assertEqual(bus.calls, [(PATH, le.PROPERTIES, "Set", le.DEVICE,
                                     "PreferredBearer", "le")])

    def test_missing_preference_support_changes_nothing(self):
        bus = FakeBus()
        client = bus.client()
        with self.assertRaisesRegex(RuntimeError, "does not expose PreferredBearer"):
            client.set_preferred_bearer(*client.target(MAC), "le")
        self.assertEqual(bus.calls, [])

    def test_explicit_device_reset_is_scoped_to_phone_not_adapter_or_bond(self):
        bus = FakeBus()
        client = bus.client()
        client.disconnect_device(*client.target(MAC))
        self.assertEqual(bus.calls, [(PATH, le.DEVICE, "Disconnect")])

    def test_uhid_requires_le_but_not_classic_service_resolution(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "device").mkdir()
            (root / "device/uevent").write_text(
                f"HID_ID=0005:00000000:00000000\nHID_UNIQ={MAC}\nHID_PHYS={LOCAL}\n")
            interfaces = FakeBus().objects[PATH]
            for connected, resolved, expected in (
                    (False, False, False), (False, True, False),
                    (True, False, True), (True, True, True)):
                interfaces[le.LE]["Connected"] = connected
                interfaces[le.DEVICE]["ServicesResolved"] = resolved
                self.assertEqual(le.hid_ready(interfaces, MAC, LOCAL, root), expected)

    def test_absent_or_ambiguous_identity_is_not_guessed(self):
        bus = FakeBus()
        with self.assertRaises(RuntimeError):
            le.find_device(bus.objects, ADAPTER_PATH, "00:00:00:00:00:00")
        bus.objects[ADAPTER_PATH + "/dev_duplicate"] = bus.objects[PATH]
        with self.assertRaises(RuntimeError):
            le.find_device(bus.objects, ADAPTER_PATH, MAC)

    def test_explicit_paired_target_can_rediscover_missing_cached_hid(self):
        bus = FakeBus()
        bus.objects[PATH][le.DEVICE]["UUIDs"] = []
        client = bus.client()
        client.connect(*client.target(MAC))
        self.assertEqual(bus.calls, [(PATH, le.LE, "Connect")])
        self.assertFalse(le.hid_ready(bus.objects[PATH], MAC, LOCAL))

    def test_unpaired_blocked_or_powered_off_targets_do_not_connect(self):
        for key, value in (("Paired", False), ("Blocked", True)):
            with self.subTest(key=key):
                bus = FakeBus()
                bus.objects[PATH][le.DEVICE][key] = value
                client = bus.client()
                with self.assertRaises(RuntimeError):
                    client.connect(*client.target(MAC))
                self.assertEqual(bus.calls, [])
        bus = FakeBus()
        bus.objects[ADAPTER_PATH][le.ADAPTER]["Powered"] = False
        client = bus.client()
        with self.assertRaises(RuntimeError):
            client.connect(*client.target(MAC))
        self.assertEqual(bus.calls, [])

    def test_manual_audio_drop_preserves_hid_network_and_other_devices(self):
        bus = FakeBus(connected=True)
        bus.objects[PATH][le.DEVICE]['UUIDs'] += [
            '0000110a-0000-1000-8000-00805f9b34fb',
            '00001116-0000-1000-8000-00805f9b34fb']  # NAP must be preserved
        client = bus.client()
        client.drop_audio(*client.target(MAC))
        self.assertEqual(bus.calls, [(PATH, le.DEVICE, 'DisconnectProfile',
                                     '0000110a-0000-1000-8000-00805f9b34fb')])
        self.assertTrue(bus.objects[PATH][le.LE]['Connected'])

    def test_kernel_readiness_requires_target_and_adapter_on_bluetooth(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            device = root / "device"
            device.mkdir()
            uevent = device / "uevent"
            for bus, peer, adapter, expected in (
                    ("0003", MAC, LOCAL, False),  # USB bridge with same name
                    ("0005", "AA:BB:CC:DD:EE:FF", LOCAL, False),
                    ("0005", MAC, "AA:BB:CC:DD:EE:FF", False),
                    ("0005", MAC.lower(), LOCAL.lower(), True)):
                uevent.write_text(f"HID_ID={bus}:00000000:00000000\n"
                                  f"HID_NAME=InpuDeck\nHID_UNIQ={peer}\nHID_PHYS={adapter}\n")
                self.assertEqual(le.hid_attached(MAC, LOCAL, root), expected)
            uevent.unlink()
            self.assertFalse(le.hid_attached(MAC, LOCAL, root))


if __name__ == "__main__":
    unittest.main()

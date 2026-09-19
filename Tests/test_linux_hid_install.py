"""Run the installer against an isolated prefix, with systemctl calls recorded."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/inpudeck-hid.sh"


@unittest.skipIf(os.geteuid() == 0, "user installer intentionally refuses root")
class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.prefix = self.root / "prefix with spaces"
        self.config = self.root / "config"
        self.log = self.root / "systemctl.log"
        mockbin = self.root / "bin"
        mockbin.mkdir()
        mock = mockbin / "systemctl"
        mock.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$ESP_TEST_SYSTEMCTL_LOG"\n')
        mock.chmod(0o755)
        self.env = dict(os.environ, XDG_CONFIG_HOME=str(self.config),
                        ESP_TEST_SYSTEMCTL_LOG=str(self.log),
                        PATH=str(mockbin) + os.pathsep + os.environ["PATH"])

    def run_helper(self, *args, script=SCRIPT, ok=True):
        result = subprocess.run(["bash", str(script), "--prefix", str(self.prefix), *args],
                                env=self.env, text=True, capture_output=True)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def test_repeated_install_and_self_update_do_not_change_host_settings(self):
        self.run_helper("--install")
        files = sorted(path for path in self.prefix.rglob("*") if path.is_file())
        self.assertEqual(len(files), 3)
        times = {path: path.stat().st_mtime_ns for path in files}
        self.run_helper("--install")
        installed = self.prefix / "libexec/inpudeck/inpudeck-hid.sh"
        self.run_helper("--install", script=installed)
        self.assertEqual(times, {path: path.stat().st_mtime_ns for path in files})
        self.assertFalse(self.config.exists())
        self.assertFalse(self.log.exists(), "on-demand install must not call systemctl")
        launcher = self.prefix / "bin/inpudeck-hid"
        result = subprocess.run([str(launcher), "--help"], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_launcher_remembers_prefix_for_uninstall(self):
        self.run_helper("--install")
        launcher = self.prefix / "bin/inpudeck-hid"
        result = subprocess.run([str(launcher), "--uninstall"], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(path.is_file() for path in self.prefix.rglob("*")))
        self.run_helper("--uninstall")
        self.assertFalse(self.log.exists())

    def test_unrelated_launcher_is_preserved(self):
        launcher = self.prefix / "bin/inpudeck-hid"
        launcher.parent.mkdir(parents=True)
        launcher.write_text("personal command\n")
        self.run_helper("--install", ok=False)
        self.run_helper("--uninstall", ok=False)
        self.assertEqual(launcher.read_text(), "personal command\n")

    def test_unrelated_service_is_preserved(self):
        unit = self.config / "systemd/user/inpudeck-hid.service"
        unit.parent.mkdir(parents=True)
        unit.write_text("# personal service\n")
        self.run_helper("--uninstall-service", ok=False)
        self.assertEqual(unit.read_text(), "# personal service\n")
        self.assertFalse(self.log.exists())

    def test_install_removes_owned_esp_remote_install(self):
        launcher = self.prefix / "bin/esp-remote-hid"
        installed = self.prefix / "libexec/esp-remote-control/linux-hid-connect.sh"
        backend = self.prefix / "libexec/esp-remote-control/linux-bluez-le.py"
        unit = self.config / "systemd/user/esp-remote-hid.service"
        for path in (launcher, installed, backend, unit):
            path.parent.mkdir(parents=True, exist_ok=True)
        launcher.write_text("#!/bin/sh\n# Managed by ESP Remote\n")
        installed.write_text("legacy\n")
        backend.write_text("legacy\n")
        unit.write_text("# Managed by ESP Remote\n[Service]\n")

        self.run_helper("--install")

        self.assertFalse(launcher.exists())
        self.assertFalse(unit.exists())
        self.assertFalse(installed.exists())
        self.assertTrue((self.prefix / "bin/inpudeck-hid").exists())
        self.assertIn("disable --now esp-remote-hid.service", self.log.read_text())

    def test_install_refuses_unowned_esp_remote_launcher(self):
        launcher = self.prefix / "bin/esp-remote-hid"
        launcher.parent.mkdir(parents=True)
        launcher.write_text("personal command\n")
        self.run_helper("--install", ok=False)
        self.assertEqual(launcher.read_text(), "personal command\n")

    def stub_paired_phone_without_cached_hid(self):
        self.env['ESP_TEST_LE_READY'] = str(self.root / 'le-ready')
        mock = self.root / 'bin/python3'
        mock.write_text('''#!/bin/sh
if [ "$1" = "-c" ]; then exit 0; fi
case "$4" in
  adapter-info) printf 'Controller 44:F7:9F:AC:CD:9C\\n  Powered: yes\\n' ;;
  info) printf 'Device 10:A2:D3:01:47:A1\\n  Name: iPhone\\n  Paired: yes\\n  LEConnected: no\\n  BREDRConnected: no\\n  ServicesResolved: no\\n' ;;
  check) printf 'LE-only API available\\n' ;;
  hid-ready) test -e "$ESP_TEST_LE_READY" ;;
  connect) touch "$ESP_TEST_LE_READY" ;;
  *) exit 2 ;;
esac
''')
        mock.chmod(0o755)

    def test_explicit_status_reports_missing_hid_without_connecting(self):
        self.stub_paired_phone_without_cached_hid()
        result = self.run_helper('--device', '10:A2:D3:01:47:A1', '--status')
        self.assertIn('HID=not-ready', result.stdout)
        self.assertFalse((self.root / 'le-ready').exists())

    def test_explicit_connect_can_rediscover_uncached_hid(self):
        self.stub_paired_phone_without_cached_hid()
        result = self.run_helper('--device', '10:A2:D3:01:47:A1')
        self.assertIn('HID=attached', result.stdout)
        self.assertTrue((self.root / 'le-ready').exists())

    def test_service_install_accepts_explicit_paired_peer_without_cached_hid(self):
        self.stub_paired_phone_without_cached_hid()
        self.run_helper('--device', '10:A2:D3:01:47:A1', '--install-service')
        unit = self.config / 'systemd/user/inpudeck-hid.service'
        self.assertIn('--device 10:A2:D3:01:47:A1 --watch', unit.read_text())
        self.assertIn('enable --now inpudeck-hid.service', self.log.read_text())


if __name__ == "__main__":
    unittest.main()

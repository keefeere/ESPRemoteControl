"""Exercise setup/rollback in a temporary filesystem, never system Bluetooth."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location(
    "linux_le_setup", Path(__file__).resolve().parents[1] / "scripts/linux-le-setup.py")
setup = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(setup)
DAEMON = setup.DAEMONS[0]


class SetupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.calls = []
        self.exec_start = f"{{ path={DAEMON} ; argv[]={DAEMON} ; }}"
        self.fail_reload = False

        def run(*args):
            self.calls.append(args)
            if "ExecStart" in args:
                return self.exec_start
            if args == ("systemctl", "daemon-reload") and self.fail_reload:
                self.fail_reload = False
                raise subprocess.CalledProcessError(1, args)
            return "active"

        self.manager = setup.Setup(Path(self.temp.name), run)

    def enable(self, **kwargs):
        self.manager.apply(self.manager.plan("enable", False), **kwargs)

    def test_enable_twice_writes_once_and_never_restarts(self):
        self.enable()
        before = self.manager.persistent.stat().st_mtime_ns
        self.enable()
        self.assertEqual(before, self.manager.persistent.stat().st_mtime_ns)
        self.assertEqual(self.calls.count(("systemctl", "daemon-reload")), 1)
        self.assertNotIn(("systemctl", "restart", setup.UNIT), self.calls)

    def test_promotes_legacy_runtime_without_restart(self):
        setup.write_file(self.manager.legacy, setup.content(DAEMON).removeprefix(setup.MARKER))
        self.exec_start = f"{{ argv[]={DAEMON} --experimental ; }}"
        self.enable()
        self.assertTrue(self.manager.persistent.exists())
        self.assertFalse(self.manager.legacy.exists())
        self.assertNotIn(("systemctl", "restart", setup.UNIT), self.calls)

    def test_disable_twice_keeps_unrelated_settings(self):
        self.enable()
        unrelated = self.manager.persistent.with_name("99-local.conf")
        unrelated.write_text("[Service]\nNice=1\n")
        for _ in range(2):
            self.manager.apply(self.manager.plan("disable", False))
        self.assertFalse(self.manager.persistent.exists())
        self.assertEqual(unrelated.read_text(), "[Service]\nNice=1\n")

    def test_dry_plan_does_not_write_or_restart(self):
        changes = self.manager.plan("enable", False)
        self.assertEqual(len(changes), 1)
        self.assertFalse(self.manager.persistent.exists())
        self.assertNotIn(("systemctl", "daemon-reload"), self.calls)

    def test_modified_owned_file_is_not_overwritten_or_removed(self):
        setup.write_file(self.manager.persistent, "# custom\n")
        for action in ("enable", "disable"):
            with self.assertRaisesRegex(RuntimeError, "local changes"):
                self.manager.plan(action, False)
        self.assertEqual(self.manager.persistent.read_text(), "# custom\n")

    def test_symlink_is_not_followed(self):
        self.manager.persistent.parent.mkdir(parents=True)
        self.manager.persistent.symlink_to(Path(self.temp.name) / "absent")
        with self.assertRaisesRegex(RuntimeError, "symlink"):
            self.manager.plan("enable", False)

    def test_custom_daemon_arguments_are_preserved_by_refusal(self):
        self.exec_start = f"{{ argv[]={DAEMON} --noplugin=audio ; }}"
        with self.assertRaisesRegex(RuntimeError, "Customized"):
            self.manager.plan("enable", False)
        self.assertFalse(self.manager.persistent.exists())

    def test_reload_failure_restores_runtime_override(self):
        original = setup.content(DAEMON).removeprefix(setup.MARKER)
        setup.write_file(self.manager.legacy, original)
        self.fail_reload = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.enable()
        self.assertEqual(self.manager.legacy.read_text(), original)
        self.assertFalse(self.manager.persistent.exists())

    def test_temporary_disable_does_not_remove_persistent_setup(self):
        self.enable()
        self.manager.apply(self.manager.plan("disable", True))
        self.assertTrue(self.manager.persistent.exists())
        self.assertEqual(self.manager.plan("enable", True), [])

    def test_restart_only_when_explicitly_requested(self):
        self.enable(restart=True)
        self.assertIn(("systemctl", "restart", setup.UNIT), self.calls)


if __name__ == "__main__":
    unittest.main()

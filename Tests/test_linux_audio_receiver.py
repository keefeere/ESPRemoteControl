"""Exercise the audio toggle offline; no real service or Bluetooth operations."""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import Mock

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/inpudeck-audio-receiver.py"
spec = importlib.util.spec_from_file_location("audio_receiver", SCRIPT)
audio = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audio)


class ReceiverTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.base = ["a2dp_sink", "a2dp_source", "hfp_ag"]
        self.command = Mock(return_value="")
        self.receiver = audio.Receiver(self.root / "config", self.root / "state",
                                       roles=self.roles, command=self.command)

    def roles(self):
        if not self.receiver.path.exists():
            return self.base[:]
        # Independent approximation of the generated override for offline tests.
        content = self.receiver.path.read_text()
        return content.split("override.bluez5.roles = [", 1)[1].split("]", 1)[0].split()

    def test_off_retains_headphones_and_mic_on_restores_underlying_config(self):
        self.assertTrue(self.receiver.set_enabled(False))
        self.assertEqual(self.roles(), ["a2dp_source", "hfp_ag"])
        self.assertFalse(self.receiver.enabled())
        # On must restore the current underlying configuration, not a stale copy.
        self.base.append("hsp_ag")
        self.assertTrue(self.receiver.set_enabled(True))
        self.assertEqual(self.roles(), self.base)
        self.assertFalse(self.receiver.path.exists())
        self.assertEqual(self.command.call_count, 4)

    def test_repeated_actions_do_not_restart_or_rewrite(self):
        self.assertFalse(self.receiver.set_enabled(True))
        self.command.assert_not_called()
        self.receiver.set_enabled(False)
        before = self.receiver.path.stat().st_mtime_ns
        self.command.reset_mock()
        self.assertFalse(self.receiver.set_enabled(False))
        self.assertEqual(self.receiver.path.stat().st_mtime_ns, before)
        self.command.assert_not_called()

    def test_all_classic_receiving_roles_are_removed(self):
        self.base += ["hfp_hf", "hsp_hs", "hsp_ag"]
        self.receiver.set_enabled(False)
        self.assertEqual(self.roles(), ["a2dp_source", "hfp_ag", "hsp_ag"])

    def test_unknown_roles_are_left_untouched(self):
        self.base.append("bap_sink")
        with self.assertRaises(RuntimeError):
            self.receiver.set_enabled(False)
        self.assertFalse(self.receiver.path.exists())
        self.command.assert_not_called()

    def test_failed_activation_restores_prior_file_and_restarts_prior_config(self):
        self.command.side_effect = [subprocess.CalledProcessError(1, "systemctl"), ""]
        with self.assertRaises(subprocess.CalledProcessError):
            self.receiver.set_enabled(False)
        self.assertFalse(self.receiver.path.exists())
        self.assertEqual(self.command.call_count, 2)

    def test_failed_enable_restores_disabled_state(self):
        self.receiver.set_enabled(False)
        before = self.receiver.path.read_text()
        self.command.side_effect = [subprocess.CalledProcessError(1, "systemctl"), ""]
        with self.assertRaises(subprocess.CalledProcessError):
            self.receiver.set_enabled(True)
        self.assertEqual(self.receiver.path.read_text(), before)

    def test_conflicting_override_rolls_back_without_audio_restart(self):
        self.receiver.roles = lambda: self.base[:]
        with self.assertRaisesRegex(RuntimeError, "effective WirePlumber roles"):
            self.receiver.set_enabled(False)
        self.assertFalse(self.receiver.path.exists())
        self.command.assert_not_called()

    def test_cannot_enable_over_someone_elses_disabled_config(self):
        self.base = ["a2dp_source", "hfp_ag"]
        with self.assertRaisesRegex(RuntimeError, "another configuration"):
            self.receiver.set_enabled(True)
        self.command.assert_not_called()

    def test_foreign_file_and_symlink_are_preserved(self):
        self.receiver.path.parent.mkdir(parents=True)
        self.receiver.path.write_text("# personal settings\n")
        with self.assertRaises(RuntimeError):
            self.receiver.set_enabled(False)
        self.assertEqual(self.receiver.path.read_text(), "# personal settings\n")
        self.receiver.path.unlink()
        target = self.root / "target"
        self.receiver.path.symlink_to(target)
        with self.assertRaises(RuntimeError):
            self.receiver.set_enabled(False)
        self.assertTrue(self.receiver.path.is_symlink())
        self.assertFalse(target.exists())
        self.command.assert_not_called()

    def test_gui_cancel_does_nothing(self):
        dialog = Mock(return_value=subprocess.CompletedProcess([], 1, "", ""))
        audio.gui(self.receiver, dialog=dialog)
        self.assertFalse(self.receiver.path.exists())
        self.command.assert_not_called()
        self.assertEqual(dialog.call_count, 1)

    def test_gui_applies_selected_choice_and_shows_result(self):
        dialog = Mock(return_value=subprocess.CompletedProcess([], 0, "off\n", ""))
        audio.gui(self.receiver, dialog=dialog)
        self.assertFalse(self.receiver.enabled())
        self.assertIn("--passivepopup", dialog.call_args.args[0])

    def test_install_is_idempotent_and_uninstall_restores_audio(self):
        prefix, data, config = self.root / "prefix with spaces", self.root / "data", self.root / "config"
        audio.install(prefix, data, config)
        files = [p for p in self.root.rglob("*") if p.is_file()]
        self.assertEqual(len(files), 3)
        before = {p: p.stat().st_mtime_ns for p in files}
        audio.install(prefix, data, config)
        self.assertEqual(before, {p: p.stat().st_mtime_ns for p in files})
        desktop = data / "applications/inpudeck-audio-receiver.desktop"
        if shutil.which("desktop-file-validate"):
            result = subprocess.run(["desktop-file-validate", str(desktop)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.receiver.set_enabled(False)
        audio.uninstall(prefix, data, config, self.receiver)
        self.assertTrue(self.receiver.enabled())
        self.assertTrue(all(not p.exists() for p in files))

    def test_install_preserves_unrelated_file_before_writing_anything(self):
        prefix, data, config = self.root / "prefix", self.root / "data", self.root / "config"
        launcher = prefix / "bin/inpudeck-audio-receiver"
        launcher.parent.mkdir(parents=True)
        launcher.write_text("personal command")
        with self.assertRaises(RuntimeError):
            audio.install(prefix, data, config)
        self.assertEqual(launcher.read_text(), "personal command")
        self.assertFalse(data.exists())
        self.assertFalse((prefix / "libexec").exists())

    def test_install_migrates_owned_esp_remote_files_and_configuration(self):
        prefix, data, config = self.root / "prefix", self.root / "data", self.root / "config"
        legacy_paths = (
            prefix / "libexec/esp-remote-control/linux-audio-receiver.py",
            prefix / "bin/esp-remote-audio-receiver",
            data / "applications/esp-remote-audio-receiver.desktop",
        )
        for path in legacy_paths:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(audio.LEGACY_MARKER + "legacy\n")
        legacy_config = config / "wireplumber/wireplumber.conf.d" / audio.LEGACY_NAME
        legacy_config.parent.mkdir(parents=True)
        legacy_config.write_text(audio.fragment(self.base).replace(audio.MARKER, audio.LEGACY_MARKER, 1))

        audio.install(prefix, data, config)

        self.assertTrue(self.receiver.path.exists())
        self.assertTrue(self.receiver.path.read_text().startswith(audio.MARKER))
        self.assertFalse(legacy_config.exists())
        self.assertTrue(all(not path.exists() for path in legacy_paths))

    def test_install_refuses_unowned_legacy_file(self):
        prefix, data, config = self.root / "prefix", self.root / "data", self.root / "config"
        legacy = prefix / "bin/esp-remote-audio-receiver"
        legacy.parent.mkdir(parents=True)
        legacy.write_text("personal command\n")
        with self.assertRaisesRegex(RuntimeError, "unrelated"):
            audio.install(prefix, data, config)
        self.assertEqual(legacy.read_text(), "personal command\n")


@unittest.skipUnless(Path("/usr/share/wireplumber/wireplumber.conf").exists(), "WirePlumber not installed")
class ParserIntegrationTests(unittest.TestCase):
    def test_actual_parser_reloads_override_without_reinitializing_glib(self):
        # A subprocess isolates GI initialization and configuration search paths.
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory)
            (config / "wireplumber.conf").write_text(
                "monitor.bluez.properties = { bluez5.roles = [ a2dp_sink a2dp_source hfp_ag ] }\n")
            fragment = config / "wireplumber.conf.d" / audio.NAME
            fragment.parent.mkdir()
            code = (
                "import importlib.util, json\nfrom pathlib import Path\n"
                f"spec=importlib.util.spec_from_file_location('audio', {str(SCRIPT)!r})\n"
                "audio=importlib.util.module_from_spec(spec); spec.loader.exec_module(audio)\n"
                "before=audio.configured_roles()\n"
                f"p=Path({str(fragment)!r}); p.write_text(audio.fragment(before))\n"
                "off=audio.configured_roles(); p.unlink(); on=audio.configured_roles()\n"
                "print(json.dumps([before,off,on]))\n")
            import os
            result = subprocess.run(["/usr/bin/python3", "-B", "-c", code],
                                    env=dict(os.environ, WIREPLUMBER_CONFIG_DIR=directory),
                                    capture_output=True, text=True)
            if "No module named 'gi'" in result.stderr or "Namespace Wp not available" in result.stderr:
                self.skipTest("WirePlumber introspection not installed")
            self.assertEqual(result.returncode, 0, result.stderr)
            before, off, on = json.loads(result.stdout)
            self.assertEqual(before, ["a2dp_sink", "a2dp_source", "hfp_ag"])
            self.assertEqual(off, ["a2dp_source", "hfp_ag"])
            self.assertEqual(on, before)


if __name__ == "__main__":
    unittest.main()

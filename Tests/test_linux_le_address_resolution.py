"""The boot workaround must touch only bonded dual-mode peers with an IRK."""

import importlib.util
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/inpudeck-le-address-resolution.py"
spec = importlib.util.spec_from_file_location("le_address_resolution", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class Result:
    def __init__(self, stdout="", returncode=0):
        self.stdout = stdout
        self.stderr = ""
        self.returncode = returncode


class AddressResolutionTest(unittest.TestCase):
    def test_only_bonded_dual_mode_irk_peer_and_preserve_other_flags(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            controller = root / "44:F7:9F:AC:CD:9C"
            dual = controller / "10:A2:D3:01:47:A1"
            le_only = controller / "FA:38:A6:61:23:7F"
            unknown_type = controller / "10:A2:D3:01:47:A2"
            dual.mkdir(parents=True)
            le_only.mkdir(parents=True)
            unknown_type.mkdir(parents=True)
            common = "[IdentityResolvingKey]\nKey=x\n[LinkKey]\nKey=x\n[LongTermKey]\nKey=x\n"
            (dual / "info").write_text(
                "[General]\nAddressType=public\nSupportedTechnologies=BR/EDR;LE;\n" + common)
            (le_only / "info").write_text(
                "[General]\nAddressType=static\nSupportedTechnologies=LE;\n" + common)
            (unknown_type / "info").write_text(
                "[General]\nSupportedTechnologies=BR/EDR;LE;\n" + common)
            calls = []

            def fake_run(*args):
                calls.append(args)
                if args[-1] == "info" and args[:2] == ("btmgmt", "-i"):
                    return Result("addr 44:F7:9F:AC:CD:9C version 13")
                if "get-flags" in args:
                    return Result("Current Flags: 0x00000003")
                return Result()

            module.apply("hci0", root, fake_run)
            sets = [call for call in calls if "set-flags" in call]
            self.assertEqual(sets, [("btmgmt", "-i", "hci0", "set-flags", "-t", "1",
                                     "-f", "7", "10:A2:D3:01:47:A1")])


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
# Managed by InpuDeck: Bluetooth audio receiver toggle
"""KDE GUI/CLI toggle for classic Bluetooth audio reception in this user session.

Uses WirePlumber 0.5's configuration parser. Keeps headphone output and headset
gateway roles; never edits pairing, restarts bluetoothd or installs a watcher.
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

MARKER = "# Managed by InpuDeck: Bluetooth audio receiver toggle\n"
NAME = "90-inpudeck-audio-receiver.conf"
LEGACY_MARKER = "# Managed by ESP Remote: Bluetooth audio receiver toggle\n"
LEGACY_NAME = "90-esp-remote-audio-receiver.conf"
RECEIVING = {"a2dp_sink", "hfp_hf", "hsp_hs"}
CLASSIC = RECEIVING | {"a2dp_source", "hfp_ag", "hsp_ag"}
TITLE = "Приймання Bluetooth-аудіо"
_wp_initialized = False


def run(*args):
    return subprocess.run(args, check=True, text=True, capture_output=True).stdout.strip()


def configured_roles():
    # Use WirePlumber's parser so override.* and its search paths match the daemon.
    import gi
    gi.require_version("Wp", "0.5")
    from gi.repository import Wp
    global _wp_initialized
    if not _wp_initialized:
        Wp.init(Wp.InitFlags.ALL)
        _wp_initialized = True
    conf = Wp.Conf.new("wireplumber.conf", None)
    conf.open()
    props = Wp.Properties.new_empty()
    conf.section_update_props("monitor.bluez.properties", props)
    value = props.get("bluez5.roles")
    if not value:
        raise RuntimeError("Explicit bluez5.roles configuration is required; defaults were not guessed.")
    return re.findall(r"[a-z0-9_]+", value)


def disabled_roles(roles):
    if not isinstance(roles, list) or not roles or any(not isinstance(role, str) for role in roles):
        raise ValueError("Bluetooth roles must be a nonempty list of names")
    if set(roles) - CLASSIC:
        raise RuntimeError("This toggle supports classic Bluetooth roles; inspect this host's additional roles first.")
    if "a2dp_source" not in roles:
        raise RuntimeError("Headphone output role is missing; inspect the audio configuration first.")
    return [role for role in roles if role not in RECEIVING]


def fragment(roles):
    retained = disabled_roles(roles)
    return (MARKER + "# Previous roles: " + json.dumps(roles) + "\n"
            + "monitor.bluez.properties = {\n"
            + "  override.bluez5.roles = [ " + " ".join(retained) + " ]\n}\n")


def read_managed(path):
    if path.is_symlink():
        raise RuntimeError(f"Refusing to change a symlink: {path}")
    if not path.exists():
        return None
    text = path.read_text()
    try:
        roles = json.loads(text.splitlines()[1].removeprefix("# Previous roles: "))
        if text == fragment(roles):
            return text
    except (ValueError, IndexError, TypeError):
        pass
    raise RuntimeError(f"Configuration has local changes or another owner: {path}")


def write_atomic(path, text, mode=0o644):
    if text is None:
        path.unlink(missing_ok=True)
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as file:
            temporary = Path(file.name)
            file.write(text)
            os.fchmod(file.fileno(), mode)
        temporary.replace(path)
    finally:
        if temporary:
            temporary.unlink(missing_ok=True)


class Receiver:
    def __init__(self, config, state, roles=configured_roles, command=run):
        self.path = config / "wireplumber/wireplumber.conf.d" / NAME
        self.state = state
        self.roles = roles
        self.command = command

    def enabled(self):
        return bool(set(self.roles()) & RECEIVING)

    def apply(self, enabled):
        old = read_managed(self.path)
        current = self.roles()
        retained = disabled_roles(current)
        if enabled:
            if old is None:
                if "a2dp_sink" not in current:
                    raise RuntimeError("Reception is disabled by another configuration; it was not overwritten.")
                return False
            new = None
        else:
            if old is not None:
                if set(current) & RECEIVING:
                    raise RuntimeError("Another configuration overrides this toggle; it was not overwritten.")
                return False
            if retained == current:
                return False
            new = fragment(current)
        activation_started = False
        try:
            write_atomic(self.path, new)
            effective = self.roles()
            if enabled:
                valid = "a2dp_sink" in effective and "a2dp_source" in effective
            else:
                valid = effective == retained
            if not valid:
                raise RuntimeError("The effective WirePlumber roles do not match the requested setting.")
            activation_started = True
            self.command("systemctl", "--user", "restart", "wireplumber.service")
            self.command("systemctl", "--user", "is-active", "--quiet", "wireplumber.service")
        except Exception as error:
            write_atomic(self.path, old)
            # Restore the previous running configuration if activation failed.
            if activation_started:
                try:
                    self.command("systemctl", "--user", "restart", "wireplumber.service")
                except Exception as rollback_error:
                    raise RuntimeError(f"{error}\nConfiguration restored, but restarting the previous audio configuration also failed: {rollback_error}") from error
            raise
        return True

    def set_enabled(self, enabled):
        self.state.mkdir(parents=True, exist_ok=True)
        with (self.state / "audio-receiver.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            return self.apply(enabled)


def desktop_text(script):
    # Keep Exec quoting simple and refuse paths with desktop field expansion.
    if any(char in str(script) for char in '\n\r"`$\\%='):
        raise RuntimeError("Unsupported characters in the desktop launcher path")
    return ("[Desktop Entry]\n" + MARKER + "Type=Application\n"
            "Name=Bluetooth Audio Reception\nName[uk]=Приймання Bluetooth-аудіо\n"
            "Comment=Allow or prevent phone audio playback on this computer\n"
            "Comment[uk]=Увімкнути або вимкнути звук із телефона на комп’ютері\n"
            f'Exec=/usr/bin/python3 "{script}" gui\n'
            "Icon=audio-speakers\nTerminal=false\nCategories=Settings;HardwareSettings;\n"
            "Keywords=Bluetooth;phone;receiver;аудіо;телефон;приймання;\n")


def owned_install_file(path, marker=MARKER):
    if path.is_symlink() or (path.exists() and marker not in path.read_text()):
        raise RuntimeError(f"Refusing to replace an unrelated file: {path}")


def migrate_legacy(prefix, data, config):
    legacy_paths = (
        prefix / "libexec/esp-remote-control/linux-audio-receiver.py",
        prefix / "bin/esp-remote-audio-receiver",
        data / "applications/esp-remote-audio-receiver.desktop",
    )
    for path in legacy_paths:
        owned_install_file(path, LEGACY_MARKER)

    legacy_config = config / "wireplumber/wireplumber.conf.d" / LEGACY_NAME
    current_config = config / "wireplumber/wireplumber.conf.d" / NAME
    if legacy_config.is_symlink():
        raise RuntimeError(f"Refusing to change a symlink: {legacy_config}")
    if legacy_config.exists():
        text = legacy_config.read_text()
        try:
            roles = json.loads(text.splitlines()[1].removeprefix("# Previous roles: "))
            expected = fragment(roles).replace(MARKER, LEGACY_MARKER, 1)
        except (ValueError, IndexError, TypeError):
            expected = None
        if text != expected:
            raise RuntimeError(f"Configuration has local changes or another owner: {legacy_config}")
        if current_config.exists() or current_config.is_symlink():
            raise RuntimeError(f"Both legacy and InpuDeck configurations exist; inspect them first: {legacy_config}, {current_config}")
        write_atomic(current_config, MARKER + text.removeprefix(LEGACY_MARKER))
        legacy_config.unlink()

    for path in legacy_paths:
        path.unlink(missing_ok=True)
    legacy_libexec = prefix / "libexec/esp-remote-control"
    try:
        legacy_libexec.rmdir()
    except (FileNotFoundError, OSError):
        pass


def install(prefix, data, config):
    migrate_legacy(prefix, data, config)
    script = prefix / "libexec/inpudeck/inpudeck-audio-receiver.py"
    launcher = prefix / "bin/inpudeck-audio-receiver"
    desktop = data / "applications/inpudeck-audio-receiver.desktop"
    body = Path(__file__).read_text()
    # The executable is a copy of the self-contained script, not a shell wrapper.
    files = ((script, body, 0o755), (launcher, body, 0o755),
             (desktop, desktop_text(script), 0o644))
    for path, _, _ in files:
        owned_install_file(path)
    for path, text, mode in files:
        if not path.exists() or path.read_text() != text:
            write_atomic(path, text, mode)
    print(f"Installed menu entry: {desktop}")


def uninstall(prefix, data, config, receiver):
    migrate_legacy(prefix, data, config)
    paths = (prefix / "libexec/inpudeck/inpudeck-audio-receiver.py",
             prefix / "bin/inpudeck-audio-receiver",
             data / "applications/inpudeck-audio-receiver.desktop")
    for path in paths:
        owned_install_file(path)
    if receiver.path.exists() or receiver.path.is_symlink():
        receiver.set_enabled(True)
    for path in paths:
        path.unlink(missing_ok=True)
    print("Removed toggle and restored underlying audio reception settings.")


def gui(receiver, dialog=subprocess.run):
    enabled = receiver.enabled()
    message = (f"Зараз приймання {'увімкнено' if enabled else 'вимкнено'}.\n\n"
               "Це дозволяє телефонам відтворювати звук на цьому комп’ютері.\n"
               "Навушники та мікрофон гарнітури залишаються доступними.\n\n"
               "Зміна коротко перерве звук на комп’ютері.")
    result = dialog(["kdialog", "--title", TITLE, "--default", "on" if enabled else "off",
                     "--menu", message, "off", "Вимкнути приймання від телефонів",
                     "on", "Увімкнути приймання від телефонів"], capture_output=True, text=True)
    if result.returncode == 1:  # Cancel or close: leave everything untouched.
        return
    if result.returncode != 0 or result.stdout.strip() not in ("on", "off"):
        raise RuntimeError(result.stderr or "Не вдалося відкрити перемикач.")
    selected = result.stdout.strip() == "on"
    changed = receiver.set_enabled(selected)
    text = f"Приймання Bluetooth-аудіо {'увімкнено' if selected else 'вимкнено'}."
    if not changed:
        text += " Налаштування вже було застосоване."
    dialog(["kdialog", "--title", TITLE, "--passivepopup", text, "5"], check=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("gui", "status", "on", "off", "install", "uninstall"), nargs="?", default="gui")
    args = parser.parse_args()
    config = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
    data = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local/share")
    state = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state") / "inpudeck"
    prefix = Path.home() / ".local"
    receiver = Receiver(config, state)
    try:
        if os.geteuid() == 0:
            raise RuntimeError("Run as the desktop user, without sudo.")
        if args.action == "install":
            if not shutil.which("kdialog"):
                raise RuntimeError("kdialog is required for the menu entry")
            disabled_roles(configured_roles())
            install(prefix, data, config)
        elif args.action == "uninstall":
            uninstall(prefix, data, config, receiver)
        elif args.action == "status":
            print("Audio reception: " + ("on" if receiver.enabled() else "off"))
            print("Configured roles: " + " ".join(receiver.roles()))
        elif args.action == "gui":
            gui(receiver)
        else:
            print("Changing audio reception; WirePlumber may briefly interrupt audio.", flush=True)
            changed = receiver.set_enabled(args.action == "on")
            print("Applied." if changed else "Already configured; no restart.")
        return 0
    except Exception as error:
        message = str(error)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            message += "\n" + error.stderr.strip()
        if args.action == "gui":
            subprocess.run(["kdialog", "--title", TITLE, "--error", message], check=False)
        print("error: " + message, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

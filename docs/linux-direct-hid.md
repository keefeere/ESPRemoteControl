# Direct Bluetooth HID on Linux

Written for the direct Bluetooth mode of the iOS app (**Прямий Bluetooth**), not
the ESP32 USB adapter. It covers the two behaviours reported from a BlueZ
desktop: the connection can only be started from the computer, and starting it
there also moves iPhone audio to the computer.

## Which side starts the connection

The iPhone publishes HID over GATT as a **BLE peripheral**. The computer is the
**central**: it scans, connects, and subscribes to the input reports. A BlueZ
desktop does not advertise over Bluetooth LE, so the phone cannot see it and
**Знайти комп'ютер** in the app will not list it. This is not a defect in the
app or in BlueZ; it is the shape of the profile.

What this means in practice:

- The computer always initiates the first connection and every reconnect.
- The phone's job is to stay advertising and connectable. The app now repairs a
  stalled advertisement by itself (see [Automatic recovery](#automatic-recovery)).
- **Знайти комп'ютер** stays useful for macOS, which does advertise over LE.

## Pairing

1. In the app, open the Bluetooth panel and select **Прямий Bluetooth**.
2. Tap **Дозволити нове сполучення**. The pairing window stays open for two
   minutes.
3. On the computer:

   ```bash
   bluetoothctl
   [bluetooth]# scan on
   # wait for "ESP Remote" or the iPhone name to appear
   [bluetooth]# pair AA:BB:CC:DD:EE:FF
   [bluetooth]# trust AA:BB:CC:DD:EE:FF
   [bluetooth]# scan off
   ```

   `trust` matters: it lets BlueZ accept later reconnects without a desktop
   prompt, which is what makes unattended reconnect work.

4. Do **not** press `connect` yet — see the next section.

The HID characteristics require encryption, so pairing creates a bond with the
physical iPhone rather than with a keyboard accessory.

## Why a generic "Connect" also takes your audio

BlueZ's `Connect()` method connects **every eligible profile** of a bonded
device. That is what the desktop Bluetooth applet's "Connect" button calls. A
dual-mode pairing can derive a BR/EDR key from the LE key
([cross-transport key derivation]), so one pairing action authorises both
transports, and the iPhone's A2DP and hands-free profiles become eligible. The
app publishes only the HID, battery, and device-information services; it never
requests audio.

The fix is to connect one profile instead of all of them. BlueZ exposes
`ConnectProfile()` for exactly this ([BlueZ Device API]):

```bash
bluetoothctl connect AA:BB:CC:DD:EE:FF 00001812-0000-1000-8000-00805f9b34fb
```

The UUID argument needs BlueZ 5.65 or newer. On older builds call the method
directly:

```bash
busctl call org.bluez /org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF \
  org.bluez.Device1 ConnectProfile s 00001812-0000-1000-8000-00805f9b34fb
```

## The helper script

[`scripts/linux-hid-connect.sh`](../scripts/linux-hid-connect.sh) wraps the
above, picks the right mechanism for the installed BlueZ, and waits until the
kernel has actually attached a HID device rather than reporting success on the
bare link.

```bash
# one-off: connect only the keyboard/mouse profile and trust the phone
./scripts/linux-hid-connect.sh --trust

# keep it connected, and push iPhone audio back to the phone if something
# else (a desktop applet, a previous generic Connect) pulled it over
./scripts/linux-hid-connect.sh --watch --drop-audio

# what is up right now
./scripts/linux-hid-connect.sh --status
```

With no `--device`, the script uses the single paired device that offers the HID
service; pass `--device AA:BB:CC:DD:EE:FF` or `--name iPhone` when several
match. `--watch` polls every five seconds by default and reconnects the profile
whenever it drops, which covers a computer waking from sleep.

To run it in the background for a desktop session:

```bash
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/esp-remote-hid.service <<'UNIT'
[Unit]
Description=Keep the ESP Remote HID profile connected
After=bluetooth.target

[Service]
ExecStart=%h/ESPRemoteControl/scripts/linux-hid-connect.sh --watch --drop-audio
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
UNIT
systemctl --user enable --now esp-remote-hid.service
```

Adjust `ExecStart` to wherever the repository is checked out.

## Keeping audio on the phone permanently

`--drop-audio` disconnects the audio profiles after the fact. To stop the
desktop from routing to them at all, tell the audio stack to ignore this device.
With PipeWire/WirePlumber:

```lua
-- ~/.config/wireplumber/wireplumber.conf.d/51-esp-remote.conf
monitor.bluez.rules = [
  {
    matches = [ { device.name = "~bluez_card.AA_BB_CC_DD_EE_FF" } ]
    actions = { update-props = { device.disabled = true } }
  }
]
```

Restart WirePlumber (`systemctl --user restart wireplumber`) afterwards. This
leaves HID untouched — it only removes the phone as an audio device.

## Automatic recovery

Version 2.1.3 of the app replaces the manual "force-quit and reopen" repair with
an escalating ladder that runs whenever a computer is selected but no keyboard
and mouse session exists:

| After | Step | What it fixes |
| --- | --- | --- |
| 10 s | reissue the advertisement | a failed or stopped `startAdvertising`, which left the phone invisible with nothing retrying it |
| 30 s | republish the HID services | a host holding a stale cached copy of the GATT database |
| 70 s | rebuild both CoreBluetooth managers | the state that previously only a relaunch cleared |

Any evidence of progress — a report-map read, a report subscription — rewinds
the ladder. Once it is exhausted the app keeps advertising and says
**Немає відповіді**, which means the next move belongs to the computer.

The app also no longer refreshes its services when the host has just re-read the
report map on the current publication: that read proves the host re-discovered
the database, and the refresh would have torn down a session that had only just
started working. That teardown is particularly damaging on BlueZ, which keeps a
cached GATT database for bonded devices.

## Collecting a log when it still fails

From the app: Bluetooth panel → **Поділитися журналом**. It records connection
stages, shortened peer identifiers, and error domains — never typed text.

From the computer, capture both sides of the same attempt:

```bash
# terminal 1
sudo btmon -w /tmp/esp-remote.btsnoop
# terminal 2
journalctl -fu bluetooth
# terminal 3
./scripts/linux-hid-connect.sh --status
./scripts/linux-hid-connect.sh
```

Useful things to look for:

- `bluetoothd: ... Connection refused` or `Operation already in progress` while
  the app says it is advertising: the phone and the host disagree about who owns
  the link. Restart the profile with the helper script.
- No advertising reports from the iPhone address at all: the phone is not
  advertising. Open the app, and check the journal in the Bluetooth panel for
  `Advertising failed`.
- Subscriptions in the app's log followed immediately by unsubscriptions:
  something on the host dropped the link; compare with KDE Connect or a desktop
  Bluetooth applet running, since both can also hold a link to the phone.
- `bluetoothctl info` reporting `Connected: yes` while
  `linux-hid-connect.sh --status` reports `keyboard down`: the ACL link is up but
  the HoG profile is not attached — the case `ConnectProfile` is for.

## Known limits

- Direct Bluetooth mode has no pre-OS input. A BIOS or bootloader will not talk
  to a BLE HID peripheral; use the ESP32 USB adapter for that.
- Reconnect timing after the computer resumes from suspend belongs to BlueZ's
  auto-connect policy, not to the app. `trust` plus the `--watch` helper is the
  reliable combination.
- The app pins input to one selected computer at a time. Switching hosts
  releases held keys first and discards queued text.

[cross-transport key derivation]: https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/Core_v6.3/out/en/host/security-manager-specification.html
[BlueZ Device API]: https://bluez.readthedocs.io/en/latest/device-api/

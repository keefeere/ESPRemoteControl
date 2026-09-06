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

### "But the computer is discoverable"

Turning on visibility in a Linux Bluetooth panel does not contradict the above,
because the two sides are talking about different radios:

- **Discoverable on BlueZ** primarily enables the **BR/EDR (Classic) inquiry
  scan** — the old "answer when someone asks who is here" mode. BlueZ starts
  advertising over LE only once an advertising instance is registered through
  `LEAdvertisingManager1`, which `bluetoothctl advertise on` does.
  `discoverable on` by itself does not.
- **The app scans through CoreBluetooth**, whose public API sees Bluetooth LE
  advertisements only. It cannot see a Classic device under any setting.

So a discoverable BlueZ machine that is not advertising over LE is invisible to
the app by construction. Three ways to confirm which case you are in:

1. Compare two lists on the phone. If the computer appears in **Settings →
   Bluetooth** on the iPhone but not in **Знайти комп'ютер** in the app, it is
   visible over Classic only — iOS system settings show both radios, the app
   sees only LE.
2. On the computer, `bluetoothctl show`: check `Discoverable` and the
   **Advertising Features** block, which reports the active advertising
   instances.
3. `sudo btmgmt info`: look for `advertising` in the `current settings:` line.
   If it is absent, the adapter is silent over LE.

This applies to any BlueZ host, handheld gaming images such as Bazzite
included; it was first reported there on an ASUS ROG Xbox Ally X.

If you want to experiment with the phone-initiated direction anyway,
`bluetoothctl advertise on` registers an advertising instance (add
`menu advertise` → `name on`, or the computer shows up in the app as
"Без назви · <id>", since the default advertisement carries no local name).
**This is untested.** Even if the computer then appears in the app's list and
the phone opens the link, HOGP still requires the *host* to act as the GATT
client and subscribe to the input reports; whether BlueZ does that over a link
the phone initiated has not been verified here. Connecting from the computer
with the HID profile only remains the supported path.

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

# keep the HID profile connected
./scripts/linux-hid-connect.sh --watch

# only to recover audio a desktop applet already captured; see the audio
# section below, since by then the phone has lost audio focus
./scripts/linux-hid-connect.sh --drop-audio

# what is up right now
./scripts/linux-hid-connect.sh --status
```

With no `--device`, the script picks the paired device to use. A computer that
already has Bluetooth keyboards and mice paired has several devices offering
HID, so it narrows to the one that also carries phone profiles — audio,
phonebook, messages — which a keyboard or a mouse does not. When that is still
ambiguous it lists the candidates, marking which look like a phone, and expects
`--device AA:BB:CC:DD:EE:FF` or `--name iPhone`. `--watch` polls every five seconds by default and reconnects the profile
whenever it drops, which covers a computer waking from sleep.

`ConnectProfile` alone is not always enough. BlueZ answers it with "already
connected" while holding a link whose HoG attachment is gone, which is the state
left behind when the phone moves its HID session to another computer and back.
When the profile does not attach within ten seconds, the script drops the whole
link and reconnects, because only that makes BlueZ redo the reconnection and
reattach the profile.

If the phone reports HID ready while the computer disagrees, `--debug` prints
the paired devices with what each one offers, the target's `bluetoothctl info`,
and every HID device the kernel exposes with its `HID_NAME`, `HID_PHYS` and
`HID_UNIQ`. It reports even when the target is ambiguous, since refusing to say
anything is the opposite of what debugging needs:

```bash
./scripts/linux-hid-connect.sh --debug
```

The script decides the profile is attached by finding the peer address anywhere
in a HID device's `uevent`, or failing that by matching `HID_NAME` against the
device's BlueZ name or the app's advertised name. Both are needed: which key
carries the address varies between kernel and BlueZ versions, and iOS advertises
with a rotating private address, so the address BlueZ stored at bonding and the
one the kernel recorded need not be the same string. If `--debug` lists the
phone under a shape that matches neither, that output is what to report.

To run it in the background for a desktop session:

```bash
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/esp-remote-hid.service <<'UNIT'
[Unit]
Description=Keep the ESP Remote HID profile connected
After=bluetooth.target

[Service]
ExecStart=%h/ESPRemoteControl/scripts/linux-hid-connect.sh --watch
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
UNIT
systemctl --user enable --now esp-remote-hid.service
```

Adjust `ExecStart` to wherever the repository is checked out.

## Keeping audio on the phone

Prevent the capture; do not undo it. `--drop-audio` disconnects the audio
profiles after they have already connected, and by then the phone has lost audio
focus — playback stops or pauses, and pushing it back does not undo that. Use it
only to recover from a capture that already happened.

Two things prevent it. Never press the desktop applet's **Connect** for the
phone: that is the generic `Connect()` which brings up every profile. And tell
the audio stack to ignore the device entirely, so it cannot be routed to even if
something connects the profile. With PipeWire/WirePlumber:

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

## Who dials whom

A Bluetooth mouse is ready the moment you switch it on, and the reason is a
division of labour, not speed. The mouse advertises the whole time it has
nothing to talk to. The computer keeps a connect request pending for it and
scans in the background. Neither side "searches" when you switch it on: the
first advertisement the computer hears completes a request it made minutes or
days ago. The device's whole job is to be findable; the computer's whole job is
to keep asking.

The app now does exactly the device's half and nothing more:

- it advertises the entire time direct mode is on — not only when a computer is
  selected, and not only when it is idle, so any paired computer can pick it up
  at any moment;
- a failed `startAdvertising` retries itself with a backoff, because nothing
  else can recover from it: no computer can produce an event about a phone it
  cannot see;
- the attribute table never changes while the app runs, so the copy your
  computer cached at pairing time stays valid and reconnecting is a re-encrypt
  and a re-subscribe rather than a rediscovery.

The computer's half is the half this project cannot reach from the phone, and
it is the half that usually breaks. `--why` checks all of it:

```bash
sudo ./scripts/linux-hid-connect.sh --why
```

It reports, in the order these tend to fail:

| Check | Why it stops the reconnect |
| --- | --- |
| adapter powered | nothing scans, so nothing is ever heard |
| paired / not blocked | BlueZ will not connect a device it has no bond for |
| **trusted** | otherwise BlueZ asks a human before accepting the link, and on a locked or headless session nobody answers |
| offers the HID service | the phone is not in direct mode, or the bond predates it |
| **IdentityResolvingKey in the bond** | iOS advertises with a rotating private address; without the IRK this computer cannot tell that any of those addresses is your phone, so its pending request never matches a phone that is right there advertising |
| LE long-term key in the bond | a classic-only bond cannot carry a BLE reconnect |
| link up but HID not attached | the ACL came back without the HoG profile — run the script with no options |

The two things the computer cannot answer are printed with the commands that
settle them: whether the phone is advertising at all (`bluetoothctl --timeout 12
scan le | grep -i 'ESP Remote'`), and whether BlueZ still has a pending connect.

That last one is worth internalising, because it is not a bug and it catches
everyone: **BlueZ stops trying after an explicit disconnect and does not resume
until the next `Connect()`**. `bluetoothctl disconnect`, the applet's Disconnect
button, and this script's own drop-and-retry all leave it idle by design. A
trusted, bonded device is re-armed at boot and when the adapter is powered back
on — but never after a manual disconnect. Run the script, or
`bluetoothctl connect <MAC>`, to put the request back.

## Automatic recovery

Version 2.1.3 of the app replaces the manual "force-quit and reopen" repair with
an escalating ladder that runs whenever a computer is selected but no keyboard
and mouse session exists. Since 2.1.7 it has two rungs, because nothing useful
sits between them:

| After | Step | What it fixes |
| --- | --- | --- |
| 5 s | reissue the advertisement | a failed or stopped `startAdvertising`, which left the phone invisible |
| 35 s | rebuild both CoreBluetooth managers | the state that previously only a relaunch cleared |

Any evidence of progress — a report-map read, a report subscription, the radio
coming back — rewinds the ladder. Once it is exhausted the app keeps advertising
and says the computer is not answering, which means the next move belongs to the
computer: run `--why` on it.

The middle rung used to republish the GATT database, and four other paths did
the same: closing a pairing window, a peer disconnecting, an unsubscribe, and
returning to the foreground. Each of those invalidated the cached copy on
**every** paired computer at once, so the reconnect that followed was a full
rediscovery instead of the second it should take. The foreground one was the
worst: glancing at another app for three seconds cost every computer its cache,
and the delay that followed looked like the computer being slow.

Now the table is built once per CoreBluetooth manager and nothing else touches
it. Switching computers changes which central gets notified and nothing else; a
computer still subscribed is adopted directly, which is immediate. Only the last
rung rebuilds, which is exactly why it is last.

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
- The app declares the `bluetooth-peripheral` background mode, so the phone stays
  advertising and connectable with the app in the background or the screen
  locked. iOS drops the advertised local name there, which is why the computer
  should reconnect by address — one more reason to pair and `trust` once rather
  than searching for "ESP Remote" each time. The recovery ladder above uses
  ordinary timers, so it runs while the app is in the foreground; returning to
  the app also triggers a full recovery pass.
- The app pins input to one selected computer at a time. Switching hosts
  releases held keys first and discards queued text.

[cross-transport key derivation]: https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/Core_v6.3/out/en/host/security-manager-specification.html
[BlueZ Device API]: https://bluez.readthedocs.io/en/latest/device-api/

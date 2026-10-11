# my-cables

A map of my USB-C cables: the link each one negotiates and the speed it really moves data.

USB-C cables all look the same, and the printed rating on the box tells you little. This repo
records what each of my cables actually does when it sits between my Mac and a real device.

## The map

<!-- cables:start -->
| Cable | How to spot it | Rated | E-marker says | Best link | AYN Thor push / pull (MB/s) | Samsung PSSD T7 Shield write / read (MB/s) | Verdict |
|---|---|---|---|---|---|---|---|
| **Insta360 X6 cable**<br>Insta360 | – | – | – | 10 Gb/s | 479 / 433 | – | Full 10 Gb/s data. |
| **LTT USB-C cable**<br>LTT Store | – | 40 Gb/s · 240 W | USB4 Gen 3 · 240 W · about 1 m | 10 Gb/s | 479 / 436 | 853 / 828 | Full 10 Gb/s data. |
| **AYN Thor stock cable**<br>AYN | – | – | – | 480 Mb/s | 39 / 44 | – | USB 2.0 only. Charging and slow data. |
<!-- cables:end -->

MB/s means 1,000,000 bytes per second. Each cell shows the best run for that cable and device.
The full history of every run is in [`data/cables.json`](data/cables.json).

## How the numbers are measured

- **Host:** a MacBook Pro (`Mac15,9`, Apple M3 Max). Its ports do Thunderbolt 4 and USB4 at
  40 Gb/s, but Apple silicon runs plain USB devices at 10 Gb/s at most.
- **Best link** is the speed the Mac negotiated with the device, read from the macOS I/O registry
  (`IOUSBHostDevice` → `UsbLinkSpeed`). This is the number that exposes a USB 2.0-only cable.
- **Samsung T7 Shield (disk):** a 4 GiB sequential write, then a read of the same file, with the
  page cache off (`F_NOCACHE`) and a full flush (`F_FULLFSYNC`) before the write timer stops.
  Slow links use 1 GiB. The T7 Shield itself tops out near 1,000 MB/s.
- **AYN Thor (adb):** `adb push` of 1 GiB of random data, then `adb pull` of the same file.
  adb itself caps near 450 to 500 MB/s, so this test shows "fast or slow", not the cable's ceiling.
- **E-marker says** is what the cable's own chip reports over USB Power Delivery (Discover Identity
  on SOP'): speed class, current, voltage, and an approximate length from the cable latency. macOS
  shows it under each `Port-USB-C` node in the I/O registry. Every 5 A cable and every cable faster
  than USB 2.0 should have an e-marker. Plain 3 A USB 2.0 cables usually have none, so they show "–".

### What these tests cannot see

Both test devices stop at 10 Gb/s. A 20 Gb/s or 40 Gb/s cable looks the same as a 10 Gb/s
cable here. To prove a 40 Gb/s rating you need a Thunderbolt or USB4 device on the other end.
The tests also do not measure charging power.

## Cable Lab, the app that collects the data

Cable Lab is a native SwiftUI app for macOS 14 or later. It has no dependencies beyond Xcode's
Swift toolchain. Build and open it with:

```sh
./cable-lab
```

The script builds `build/Cable Lab.app`, signs it with your Developer ID (or Apple Development)
identity, and remembers this repo folder so results land here. Then:

1. Plug a cable between the Mac and a USB disk or an adb device. The sidebar shows the link it got
   and what the cable's e-marker says.
2. A new e-marked cable is added by itself, with its rated speed, power and length filled in. A
   banner lets you rename it, or pick **This Is…** when it is a cable you saved before. A cable
   without an e-marker cannot describe itself, so add it with **+**.
3. Click **Run Test**. The result goes to `data/cables.json`, and the table above is rebuilt. A
   test also stores the e-marker of the tested cable when the cable has none stored yet.

The e-marker identifies a cable model, not one cable. Two cables of the same model look the same.

### Disks that need root

A Time Machine disk's top folder belongs to root, so you cannot create a file there. Cable Lab asks
for your Mac password in its own sheet and uses `sudo -S` for three fixed Apple tools only:
`/usr/bin/touch` and `/usr/sbin/chown -h` create an empty test file that you own, and `/bin/rm`
removes it at the end. It does this only when the top folder is owned by root and not writable by you. The
benchmark itself always runs as you, inside the app. Cable Lab never runs its own binary as root,
because that binary sits in a folder your user can write, and a swapped copy would then run as root.

With **Remember in my Keychain** on, Cable Lab saves the password in your login Keychain after
sudo accepts it, and root tests stop asking. Only Cable Lab can read it back. **Forget Saved
Password** on the Cable Map, or `./cablectl forget-password`, deletes it.

macOS privacy protection can still block a root write when the app lacks Full Disk Access. The app
then shows a button that opens **System Settings > Privacy & Security > Full Disk Access**. Add
Cable Lab there once. A stable code signature keeps that grant valid across rebuilds.

Cable Lab does not test a Time Machine disk while a backup runs, and it always deletes its test file.

### Driving it from a terminal or an agent

The running app listens on a Unix socket that only your user can open
(`~/Library/Application Support/my-cables/control.sock`). `./cablectl` talks to it and prints JSON:

```sh
./cablectl state                                  # devices, cables and the current job
./cablectl add --name "Anker 100 W" --rated-power "100 W" --looks "grey braid"
./cablectl test anker-100-w --wait                # start a test and wait for the result
./cablectl ports                                  # each USB-C port and its cable's e-marker
./cablectl link ltt-usb-c-cable --port 3          # store the e-marker on port 3 on a saved cable
./cablectl show map                               # bring the window up on the cable map
./cablectl help                                   # every command
```

Passwords never go through the socket. A root test uses the Keychain password when one is saved,
and asks in the app window otherwise. A socket client can only start the fixed disk test on a
detected volume. It cannot run its own commands as root.

### Tests

```sh
swift test
```

## License

MIT

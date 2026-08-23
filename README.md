<p align="center">
  <img src="docs/icon.png" alt="Nimbus DMX Helper icon" width="128">
</p>

<h1 align="center">Nimbus DMX Helper</h1>

<p align="center">
  A toy DMX controller for macOS — a native Swift/SwiftUI app plus a CLI, driving lights through an
  <b>Enttec DMX USB Pro</b>.<br>Built to poke at an <b>amaran Halo 300x</b> on channel 1.
</p>

<p align="center">
  <img src="docs/screenshot.png" alt="Nimbus DMX Helper: Halo fixture panel, raw channel sliders with Out/In tabs, and DMX output debug pane" width="900">
</p>

```
./build.sh run              # build + launch the SwiftUI app
./build.sh run --connect --high-speed   # …and connect immediately in high-speed mode
./build.sh run --connect --demo --screenshot docs/screenshot.png   # render the window to a PNG and quit
./build.sh app              # release build → "dist/Nimbus DMX Helper.app" and open it
./build.sh dmg              # …packed as a drag-to-Applications disk image
./build.sh install          # …installed to /Applications
./build.sh status           # running? installed? how is it signed?
./build.sh cli info         # query the widget (serial, firmware, break/MAB/refresh)
./build.sh cli halo 50 3200 # Halo @ addr 1: 50% intensity, 3200K, hold 2s
./build.sh cli set 1=255 2=64 --hold 5
./build.sh cli black
./build.sh cli bench --channels 24 --fps 750 --seconds 10   # pacing / backpressure test
./build.sh cli monitor      # watch the widget's DMX IN port (add --demo to see it with no hardware)
./build.sh cli loopback     # patch OUT→IN and check whether anything comes back
```

## Hardware

| What | Detail |
|---|---|
| Interface | Enttec DMX USB Pro, FTDI FT232 (VID `0x0403` PID `0x6001`), USB serial `EN538648` |
| Device node | `/dev/cu.usbserial-EN538648` (macOS built-in `AppleUSBFTDI` driver — no extra driver needed) |
| Widget | firmware 1.44, break 96 µs, MAB 10.7 µs, refresh 40 Hz |
| Light | amaran Halo 300x (bi-color COB, 2700–6500 K), DMX via amaran USB-C → 5-pin DMX adapter, start address 1 |

## How it works

* `Sources/DMXCore/SerialPort.swift` — bare POSIX serial (open/termios/write). The Pro
  ignores baud rate (the FTDI talks to the widget's MCU at a fixed rate); we open at 3 Mbaud
  anyway — see the gotcha below, it is not cosmetic.
* `Sources/DMXCore/EnttecDMXUSBPro.swift` — the widget's message framing:
  `7E <label> <lenLSB> <lenMSB> <data…> E7`. Label 6 = "send DMX packet";
  data = start code `00` + 512 channel bytes (518 bytes on the wire per frame).
  Labels 3/10 read widget parameters / serial number.
* `Sources/DMXCore/EnttecReceive.swift` — the other direction. Label 8 asks the widget to report
  what it hears on **DMX IN**; it then pushes label 5 (whole frames) or label 9 (40-slot deltas)
  until we send a frame again. `MessageStream` reassembles those messages from arbitrary read
  chunks and resyncs past junk.
* `Sources/DMXCore/AmaranHalo.swift` — Halo 300x channel maps (see below) → DMX bytes.
* `Sources/NimbusDMXHelper/` — SwiftUI app. `DMXController` holds the 512-channel universe and
  streams it to the widget on a background timer. Two modes:
  * **Normal** — full 512-channel frames at 40 fps (= the widget's own DMX refresh rate;
    a full frame is ~22.7 ms on the wire, so ~44 Hz is the physical ceiling). The widget
    repeats the last frame on its own, so this is plenty for sliders and cues.
  * **High speed** — sets the widget's refresh to 0 ("as fast as possible"), sends only through
    the highest in-use channel (min 24; a channel that drops to 0 keeps the frame long for
    2 s so the fixture actually receives the zero), and paces at the DMX line time of that
    short frame × 1.1. For the Halo's 3 channels that's a 24-channel frame every ~1.3 ms
    → ~750 fps, ~2 ms input-to-light instead of ~50 ms. Widget parameters are restored on
    disconnect/quit.
* `Sources/dmxcli/` — scripting/smoke-test CLI.
* `Sources/DMXCore/AppIcon.swift` — the app icon, drawn in CoreGraphics (three fader capsules under a
  2700 K → 6500 K gradient). It is the live dock icon for `./build.sh run` (a bare SwiftPM executable
  has no bundle to carry one) and is exported to `AppIcon.icns` by `./build.sh app`.
  Re-render the README copy with `./build.sh icon`.

The app window has three panes:

1. **amaran Halo 300x** — intensity / CCT / ±green / strobe / CCT+ sliders, DMX profile and
   start-address pickers. Shows the exact bytes it writes.
2. **Out / In** — *Out* is raw sliders for all 512 channels, blackout / full. *In* is the DMX
   input monitor: flip **Listen** and the pane fills with what the widget hears on its IN port —
   a heat-mapped grid of live slot values, frame rate, slot count, start code and error counters.
   Turning it on stops transmitting (see below).
3. **DMX Output Debug** — port, widget info, measured fps, byte counter, the last Enttec
   message as a hex dump (short or full 518 bytes, annotated), the currently non-zero
   channels, and a timestamped change log of every frame that differed from the previous one.

## amaran Halo 300x DMX profiles

From *amaran DMX Profile Specification V1.1 (March 2026)* — `docs/amaran-dmx-profile-spec-v1.1.pdf`.
The x-series is bi-color, so only the CCT profiles apply. Pick the profile on the light:
**Menu → DMX Mode → DMX Profile** (and set the address there too).

**Profile 1 · CCT Universal · 3 ch** (default in the app)

| Ch | Function | Values |
|---|---|---|
| 1 | Intensity | 0–255 → 0–100 % |
| 2 | CCT | 0–255 → 2700–6500 K |
| 3 | Strobe | 0–13 off · 14–128 random 1→25+ Hz · 129–255 constant 1→25+ Hz |

**Profile 2 · CCT · 5 ch**

| Ch | Function | Values |
|---|---|---|
| 1 | Intensity | 0–255 → 0–100 % |
| 2 | CCT | 0–255 → 2300–10000 K (CCT+ off) — the Halo clamps to what it can do |
| 3 | ±Green | 0–10 no effect (don't use) · 11–20 full −G · 21–119 −99…−1 % · 120–145 neutral · 146–244 +1…+99 % · 245–255 full +G |
| 4 | Strobe | as above |
| 5 | CCT+ | 0–127 off · 128–255 on |

DMX-loss behaviour is set on the light (hold / blackout / fade / hold 2 min then fade).

## Reading DMX in

The Pro has a DMX **in** port as well as an out, and the widget will report what it sees there —
but only when asked, and only instead of transmitting:

* Label 8 (`receiveDMXOnChange`) switches the widget to listening. It then streams label 5
  messages, one per DMX frame it receives (status byte, start code, then the slots), or label 9
  change-of-state blocks if you ask for deltas.
* **Receiving is a mode, not a second channel.** The widget stops driving DMX OUT while it
  listens and only goes back when it gets the next frame from us. So the app's Listen switch
  stops the send timer, and a single fixture on OUT holds its last look meanwhile. There is no
  way to watch a universe and drive one at the same time with one Pro.
* Nothing arrives at all when the IN port is idle — no signal means silence, not zeros. Feed it
  from a console, an Art-Net/sACN node, or another widget's OUT.
* Once listening, the widget is chattering; a reply you asked for is no longer the first thing in
  the buffer. Parse with `EnttecPro.message(_:in:)`, not by assuming byte 0 starts your message.

```
dmxcli monitor                 # live grid of the incoming universe
dmxcli monitor --raw           # one line per message, for protocol work
dmxcli monitor --demo          # synthetic frames through the same parser — no hardware needed
dmxcli monitor --on-change     # ask for label 9 deltas instead of whole frames
dmxcli loopback                # send a known pattern, then listen for it (needs OUT patched to IN)
dmxcli selftest                # framing/parsing checks against synthetic messages
```

`loopback` settles what this rig can actually do, and the answer is: **a single Pro cannot hear
itself.** With a 5-pin cable patched from OUT straight back into IN, nothing comes back — not in
send-always mode, not in on-change mode, and not across 42 `loopback --alternate` cycles that
drive the line right up to the moment of switching. Zero bytes, indistinguishable from an
unpatched port. That matches the API's mode exclusivity, and is what you'd expect if the widget
muxes one UART between its transmitter and receiver.

So the input monitor here is real code on a real port, but it has never seen a real frame: that
needs a *second* DMX source — another interface, a console, or an Art-Net/sACN node — feeding
this widget's IN. `dmxcli monitor --demo` and `dmxcli selftest` exercise everything up to the wire
in the meantime.

## Timing & gotchas (measured, see `dmxcli bench|drain|latency`)

* **Widget intake is fast**: ~100–120 KB/s over USB (≈ 200+ full 512-ch frames/s), so the
  host is never the bottleneck at 40 fps. Frames sent faster than the DMX line can carry are
  simply overwritten inside the widget.
* **DMX line time** = break 96 µs + MAB 10.7 µs + (1 + channels) × 44 µs. 512 ch → 22.7 ms
  (44 Hz), 128 ch → 5.8 ms (173 Hz), 24 ch → 1.2 ms (828 Hz). High-speed mode paces at this
  × 1.1; verified over 10 s with zero backlog (`TIOCOUTQ` stays 0, `write()` never blocks).
* **The baud rate matters even though the Pro ignores it.** The DMX USB Pro's data path
  runs at a fixed speed regardless of the configured baud, but macOS's serial driver
  computes its close()/drain wait as *bytes written ÷ baud*. At 115200 baud a session that
  wrote 60 KB makes `close()` — and therefore process exit — stall ~6 s, and any other
  process trying to open the port blocks behind it ("Connect hangs after relaunch"). We
  open at 3 Mbaud (`IOSSIOSPEED`), which turns that into a few ms. Symptom of getting this
  wrong: `ps` shows the old process in state `E` for seconds after quitting.
* The app closes the port synchronously on quit (⌘Q, window close, SIGINT/SIGTERM) and
  restores the widget's refresh rate if high-speed mode changed it. If a Connect ever does
  hang, wait a few seconds or unplug/replug the widget.

## Updates

The app keeps itself up to date, through
[nimbus-updater](https://github.com/njoubert/nimbus-updater) (MIT, ours, shared with
[Nimbus Leviton Bar](https://github.com/njoubert/nimbus-leviton-bar) and
[Nimbus Net Bar](https://github.com/njoubert/nimbus-net-bar); an ordinary SwiftPM dependency
pinned in `Package.resolved`).

Because this app is opened and quit rather than left running, **it checks a few seconds after
every launch** — and once a day after that, if you leave the window open. When it finds a
newer release it downloads it in the background and offers **Install Update … and Relaunch**,
both in the **Nimbus DMX Helper** menu and as a button beside the version in the connection
bar. A download is installed only if macOS confirms it is signed with the same Developer ID as
the copy you are running, and nothing installs without your click. **Check for Updates…** in
the app menu asks immediately; **Check for Updates Automatically** turns the whole thing off,
and with it off the app never contacts GitHub. `dmxcli check-update` prints what the updater
sees.

Only a copy installed in `/Applications` can replace itself — a `./build.sh run` build says so
rather than pretending.

## Requirements

macOS 15+, Swift 5.10+ toolchain (Command Line Tools are enough — no Xcode project needed).
One dependency, ours: [nimbus-updater](https://github.com/njoubert/nimbus-updater).

## Installing a release

`./build.sh dmg` builds the disk image people actually install from: the app, an Applications
folder to drag it onto, and a background explaining what it needs.

Without a Developer ID the build is ad-hoc signed and not notarized, so a copy that arrives
with a quarantine flag (browser download, AirDrop) is refused at first open and has to be
allowed in System Settings › Privacy & Security ("Open Anyway"). With one, put it in a
git-ignored `.signing` file next to `build.sh` and `app`/`dmg`/`install` sign with it
(hardened runtime, timestamped), notarize the app and the disk image, and staple both:

```
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
NOTARY_PROFILE=<profile>   # from: xcrun notarytool store-credentials <profile> --apple-id … --team-id … --password …
                           # notary credentials are per Apple ID + team, not per app — one profile serves every project
```

## License

Nimbus DMX Helper is free software under the [GNU General Public License, version 3 or
later](LICENSE). Use it, change it, ship it, sell it — but anything built from it has to be
released under the same terms, with source.

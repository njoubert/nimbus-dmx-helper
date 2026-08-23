# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A macOS app for driving DMX lights through an **Enttec DMX USB Pro**: a SwiftUI app
(**Nimbus DMX Helper**, target/executable `NimbusDMXHelper`), a scripting CLI (`dmxcli`),
and a shared library (`DMXCore`). Pure SwiftPM, no Xcode project, Command Line Tools are
enough (macOS 15+, Swift 5.10+, Swift 5 language mode). Exactly one dependency —
`NimbusUpdater` (https://github.com/njoubert/nimbus-updater, MIT, ours).

Hardware on this machine (not derivable from code): the widget enumerates as
`/dev/cu.usbserial-EN538648` (FTDI 0403:6001, Apple's built-in FTDI driver, FW 1.44); the light is an
**amaran Halo 300x** (bi-color, 2700–6500 K) at DMX address 1 via amaran's USB-C→5-pin adapter.
The Halo's DMX channel maps are in `docs/amaran-dmx-profile-spec-v1.1.pdf` and summarized in README.md.

## Commands

```
./build.sh                # swift build (debug) → .build/debug/{DMXControl,dmxcli}
./build.sh run [flags]    # build + launch the app. Flags: --connect (auto-connect),
                          #   --high-speed, --demo (preset Halo 60%/4500K), --monitor (listen on DMX IN),
                          #   --screenshot PATH (render window to PNG, quit)
./build.sh cli <args>     # build + run dmxcli
./build.sh app            # release build → "dist/Nimbus DMX Helper.app" (icon baked in) and open it
./build.sh dmg            # …packed as dist/NimbusDMXHelper-<VERSION>.dmg (drag-to-Applications)
./build.sh install        # same bundle, installed to /Applications (quits a running copy first)
./build.sh uninstall      # quit and remove /Applications/Nimbus DMX Helper.app
./build.sh status         # running? installed? how is it signed?
./build.sh icon           # re-render docs/icon.png
./build.sh social         # re-render docs/social-preview.png (GitHub's link-preview card)
./build.sh clean          # rm -rf .build dist
swift build --product dmxcli        # rebuild just the CLI
dmxcli version                      # what build is this ("dev build" outside an .app)
```

Naming, all set at the top of `build.sh`: `NAME=NimbusDMXHelper` is the executable/target and
process name (what `pgrep`/`pkill` match), `APP_NAME="Nimbus DMX Helper"` is what the user sees
(the `.app`, the disk image volume), `BUNDLE_ID=com.njoubert.nimbusdmxhelper`. Keep those
distinct — paths with spaces need quoting everywhere, and `pkill -x "Nimbus DMX Helper"` would
never match.

**House rules:** `prek run --all-files` must pass before claiming done (shellcheck runs at its
default severity, so `A && B || true` is flagged — write an `if`). Every new Swift file starts
with `// Copyright (C) 2026 Niels Joubert` and `// SPDX-License-Identifier: GPL-3.0-or-later`;
the project is GPL-3.0-or-later, so don't vendor code under an incompatible licence.

There is no test target. Checks live in the CLI — `dmxcli selftest` covers the receive parsers
with no hardware; everything else is a hardware smoke test:

```
dmxcli list | info                          # ports / widget serial, firmware, break/MAB/refresh
dmxcli halo 50 3200 [--profile 2] [--addr N] # Halo: intensity %, CCT K, hold 2 s
dmxcli set 1=255 2=64 --hold 5 | black       # raw channels
dmxcli params --rate 0|40                    # widget refresh (0 = as fast as possible) — persists in the widget!
dmxcli bench --channels 24 --fps 750 --seconds 10   # paced stream; TIOCOUTQ + write() blocking = backpressure
dmxcli drain / latency                        # burst-then-close timing / burst-then-get-params round trip
dmxcli monitor [--raw|--demo|--on-change]     # watch DMX IN (--demo = synthetic frames, no hardware)
dmxcli loopback                               # OUT→IN cable: send a known pattern, listen for it
dmxcli selftest                               # receive framing/parsing checks, no hardware
```

Only one process can hold the port (`TIOCEXCL`): stop the app before running `dmxcli`, and vice
versa. Wrap anything that talks to the widget in a timeout from scripts —
`perl -e 'alarm 20; exec @ARGV' -- .build/debug/dmxcli …` — a wedged port op otherwise hangs the shell.
After moving/renaming the repo directory, `rm -rf .build` (SwiftPM's module cache bakes in absolute paths).
Regenerate the README screenshot with `./build.sh run --connect --demo --screenshot docs/screenshot.png`
then `sips -Z 1400 docs/screenshot.png`.

## Architecture

**`Sources/DMXCore`** (library, everything `public`)
- `SerialPort` — raw POSIX serial (open/termios/write/read, `TIOCEXCL`, `TIOCOUTQ`). Opens at
  **3 Mbaud via `IOSSIOSPEED`** (ioctl number hand-defined; the macro doesn't import). See gotchas.
- `EnttecPro` — pure functions for the widget protocol: framing `7E label lenLSB lenMSB data… E7`,
  label 6 = send DMX (start code + channels, `dmxPacket(universe:channels:)`, min 24 channels),
  labels 3/10 = get params/serial, label 4 = set params. Also the **timing model**
  `dmxLineTime(channels:)` (break + MAB + (1+n)×44 µs) that pacing is built on.
- `AppIcon` — the icon drawn in CoreGraphics (1024-pt reference canvas, Apple's 824/1024 body +
  185.4 radius grid). One source for two consumers: the app sets it as the live dock icon at launch
  (a bare SwiftPM executable has no bundle to carry one), and `dmxcli icon --iconset` feeds
  `iconutil` in `build.sh app`. Change the drawing, then `./build.sh icon` to refresh the README copy.
- `EnttecReceive` — the input side: label 8 (ask to receive), label 5 (whole frames), label 9
  (40-slot deltas), plus `MessageStream`, an incremental framer that reassembles messages from
  arbitrary read chunks and resyncs past junk. Receiving is a **mode**: the widget stops driving
  DMX OUT until we send the next frame, and while listening it chatters, so replies must be
  found with `EnttecPro.message(_:in:)` rather than assuming byte 0.
- `AmaranHalo` — `HaloProfile` (Profile 1 = 3ch CCT Universal, Profile 2 = 5ch CCT) and `HaloState`
  (intensity %, CCT K, ±green, strobe, CCT+) → `encode(profile:)` bytes.

**`Sources/NimbusDMXHelper`** (SwiftUI app)
- `DMXController` (`@MainActor ObservableObject`, singleton `.shared`) is the heart. It owns the
  512-byte universe (`channels`, published, main-actor) and a lock-guarded copy (`frame`) that a
  `DispatchSourceTimer` on `ioQueue` snapshots and writes to the widget every tick. Convention:
  main-actor state is `@Published`; state shared with `ioQueue` is `nonisolated(unsafe)` and touched
  only under `lock`; ioQueue-only state is `nonisolated(unsafe)` with a comment saying so. UI updates
  from the timer are batched to ~5 Hz via `DispatchQueue.main.async`.
  - Two streaming modes. **Normal**: full 512-channel frames at `frameRate` (default 40 = the widget's
    own refresh rate). **High speed** (`highSpeed`): sends label 4 to set widget refresh 0, shrinks
    frames to the highest in-use channel (min 24, with a 2 s high-water-mark hold so a channel that
    drops to 0 is still transmitted), and re-arms the timer at `dmxLineTime × 1.1` per tick.
    Widget params are restored on disconnect/quit (`originalParams`).
  - `shutdownSync()` is called from `AppDelegate.applicationShouldTerminate` (also on
    SIGINT/SIGTERM/SIGHUP): stop timer → restore params → flush + close, synchronously on `ioQueue`,
    so the port is free before the process exits.
  - `monitoring` switches to input: stops the send timer, writes label 8, and reads via a
    `DispatchSourceRead` on `ioQueue` (cancelled *before* the port closes — it holds the fd),
    with a separate 10 Hz timer pushing `input` to the UI so signal loss shows up even when
    nothing arrives. Toggling it off restarts streaming; the first frame sent is what puts the
    widget back into output mode.
- Views: `HaloPanelView` holds its own `HaloState` and pushes encoded bytes into the universe at its
  start address on every change (one-way; the raw grid doesn't feed back). `ChannelGridView` edits
  channels directly. `DebugView` shows the last wire packet (hex), mode/frame/pacing, and a change log.
- `NimbusDMXHelperApp`/`AppDelegate`: because this runs as a bare SwiftPM executable (no bundle), the
  delegate sets `NSApp.setActivationPolicy(.regular)` and activates; it also parses the launch flags.

**`Sources/dmxcli/main.swift`** — flat command switch over the same DMXCore APIs; every command
opens the port itself. Add new experiments here first; they're cheap and don't need the GUI.

## Auto-update (NimbusUpdater)

The app checks this repo's releases and can replace itself. **`../nimbus-updater/CLAUDE.md`
holds the updater's traps — read it before touching anything about updates.**

- **How it is wired in: an ordinary SwiftPM package dependency, by URL.** `Package.swift` has
  `.package(url: "https://github.com/njoubert/nimbus-updater.git", from: "1.2.0")`; `DMXCore`
  and `dmxcli` take the product. **Not a git submodule, and not a path dependency** — the
  sibling checkout is only where the source is edited. `Package.resolved` (committed) pins the
  version, so a new upstream tag arrives only via `swift package update` plus a commit.
- **This app is opened and quit, so the launch check is the one that matters.** `Updates.swift`
  (in DMXCore, so `dmxcli check-update` shares it) sets `checkOnLaunch: true` and a 5 s
  `launchDelay`; the daily `checkInterval` only comes into play if the window is left open.
  The menu bar apps rely on the same default.
- **The surface is SwiftUI, not a menu**: `UpdateModel` (an `ObservableObject` wrapper around
  `Updater`) drives a `CommandGroup(after: .appInfo)` in `NimbusDMXHelperApp` and a button
  beside the version in `ContentView`'s connection bar. The menu bar apps' `addUpdateItems` is
  the AppKit equivalent — same states, same wording, so fix wording in all three.
- `UpdateModel` is inert for a bare SwiftPM binary (no bundle → no version) and for
  `--screenshot` runs, so `./build.sh run` never checks and screenshots never show an update.
- **A release is invisible to the updater unless it carries `NimbusDMXHelper-<version>.zip`,**
  built by `build.sh dmg` from the *stapled* app. `./build.sh release NOTES.md` does the whole
  dance and cannot forget it.
- Testing without publishing: `defaults write com.njoubert.nimbusdmxhelper updateFeedURL
  file:///tmp/latest.json` (a JSON in the API's shape whose asset URL is a local `file://`
  zip), then `defaults delete` it. **An empty update cache is not proof of a refusal** — force
  a check from the menu.

## Release and distribution

The deliverable is the disk image *and the zip beside it*; `./build.sh release NOTES.md` is the
way in. A release is:

1. **Version.** `VERSION=` near the top of `build.sh` is the marketing version
   (`CFBundleShortVersionString`, the DMG's file name). `CFBundleVersion` is
   `git rev-list --count HEAD`, so it increments by itself — commit before building. It
   cannot be a git hash: macOS requires one to three period-separated integers and *orders*
   versions by it (LaunchServices uses that ordering to decide which copy is newer). The app
   shows both in the connection bar and `dmxcli version` prints them (`AppVersion` in DMXCore).
2. **Docs.** `./build.sh icon` refreshes `docs/icon.png`; regenerate the screenshot with
   `./build.sh run --connect --demo --screenshot docs/screenshot.png` then `sips -Z 1400`.
   Either of those changes the link-preview card too, so `./build.sh social` and re-upload it
   (see the trap below).
3. **Build.** `./build.sh dmg` → signs, notarizes the app *and* the image, staples both.
   Notarization waits on Apple (minutes, occasionally longer); on failure read the reason with
   `xcrun notarytool log <submission id> --keychain-profile "$NOTARY_PROFILE"`. Then `open` the
   DMG and look at it: 640-wide window, no blank strip on the right, nothing selected.
4. **Install what you just built** by mounting the DMG and `ditto`-ing the app out of it to
   `/Applications`, *not* `./build.sh install` — install re-signs the bundle, which invalidates
   the staple and costs another full notarization round, and the DMG copy is the exact artifact
   users get. Quit the running copy first (it holds the serial port).
5. **Tag and publish:**
   ```
   git tag -a v<VERSION> -m "Nimbus DMX Helper <VERSION>"
   git push origin main --tags
   gh release create v<VERSION> "dist/NimbusDMXHelper-<VERSION>.dmg" \
     --title "Nimbus DMX Helper <VERSION>" --notes-file <notes> --latest
   ```
   Don't commit `dist/`.

**Signing** — the private key lives in this machine's login keychain and as a `.p12` export
kept off it; those are the only two copies and Apple will not re-issue it. Configured in a
git-ignored `.signing` file (`SIGN_IDENTITY`, `NOTARY_PROFILE`
— the notary credentials are per Apple ID + team, not per app, so one profile serves every
project; don't name it after this one);
unset, everything falls back to ad-hoc and the DMG background grows an "unsigned build" footer
(`dmxcli dmg-background --signed` drops it). Keep that unsigned path working — it is what any
machine without the certificate uses. The Developer ID private key lives only in the login
keychain and is not re-downloadable; the membership is annual, and if it lapses,
already-notarized releases keep working forever while new builds fall back to ad-hoc.
This app needs **no entitlements**: `/dev/cu.*` is reachable under the hardened runtime
(it would need `com.apple.security.device.serial` only inside the App Sandbox, which would
also be required for the Mac App Store — where GPL-3.0 cannot go anyway).

**DMG layout** is Finder's `.DS_Store`, written by the AppleScript in `build.sh`; geometry is
shared with `DMGBackground.swift` (640×440, icon centres 170/210 and 470/210) so change both.
Two traps: window `bounds` include the 28 pt title bar, and Finder adds the *hidden* sidebar's
remembered width back on reopen unless `sidebar width` is set to 0 and the bounds re-applied
after the close/open cycle — that is what leaves a blank strip down the right-hand side.
`set selection to {}` is not valid inside `tell disk`. The first run prompts for permission to
control Finder.

## Inspecting the running app

`--screenshot PATH` renders the window offscreen and quits — the cheap check. To drive the real
UI instead, use the accessibility API (needs Accessibility permission for whatever runs it):

```
osascript -e 'tell application "System Events" to tell process "NimbusDMXHelper"
  get entire contents of window 1        -- then match on role: AXButton, AXCheckBox, …
end tell'
```

Read a value with `value of`, press something with `click`. Watch for smart punctuation in
button labels — matching `"Don't"` against a curly `Don’t` silently fails.

## Hard-won gotchas (all measured — see README "Timing & gotchas")

- **Keep the 3 Mbaud setting.** The Pro's data path ignores baud, but macOS's serial driver computes
  its close()/drain wait as bytes-written ÷ baud. At 115200 a session that wrote 60 KB makes `close()`
  — and thus process exit — stall ~6 s, and any other `open()` blocks behind it (`ps` shows the old
  process in state `E`). That was the "Connect hangs after relaunch" bug.
- **Never send faster than the DMX line can carry the frame** (512 ch ≈ 22.7 ms → 44 Hz; 24 ch ≈
  1.2 ms). Widget intake is ~110 KB/s so the host isn't the limit; excess frames just get overwritten
  in the widget, and the driver silently buffers 100+ KB before `write()` blocks — "write didn't
  block" is not evidence you're keeping up. Use `dmxcli bench` (10 s+) to check pacing changes.
- Label 4 (set params) is **persistent** in the widget across power cycles — always restore.
  Label 10 (get serial) switches the widget's port to input and stops DMX output until the next
  label 6; label 3 (get params) does not.
- **Input and output are exclusive on the Pro.** Label 8 puts it in receive mode and it stays
  there until the next label 6, so you cannot monitor a universe and drive one at once. An idle
  IN port produces *silence*, not zero frames — "nothing received" does not mean "receive is
  broken".
- **A single widget cannot loopback to itself** (measured, FW 1.44, OUT patched to IN with a
  5-pin cable): zero bytes came back in send-always mode, in on-change mode, and across 42
  `loopback --alternate` cycles that drove the line right up to each listen window. So the
  receive path here can only ever be exercised by a *second* DMX source. Still untested for
  want of one: real label 5 reception, and the label 9 delta packing (packed vs positional).
- The Halo applies a fixed-duration crossfade to intensity/CCT changes in firmware (strobe channel is
  instant). Fades you see are not from this code; there's no fixture setting for it.

## Traps already found (don't re-learn these)

- **A README hero image is not the link preview.** What chat apps, Slack and Twitter show for
  a GitHub URL is `og:image`, and that is either a picture uploaded under the repo's
  Settings › General › Social preview or, failing that, a grey card of the repo name and the
  contributor count. GitHub never reads the README for it. **There is no API for the upload** —
  not REST, not GraphQL, not `gh` — so `./build.sh social` only draws the file; putting it on
  the repo is a manual drag onto that settings page, once per repo, and again whenever the
  icon or the screenshot changes. Apple's LinkPresentation sometimes scrapes a README image
  when the `og:image` fetch fails, which makes a repo *look* like it has a preview it hasn't
  got — check `curl -sL <repo> | grep og:image` instead: an `opengraph.githubassets.com` URL
  means the generated card, `repository-images.githubusercontent.com` means a real one.
- **Shadow offset and blur are in base space.** `CGContext.setShadow` ignores the CTM, so a
  blur sized for the 1024-pt reference canvas is that many *device pixels* at every render
  size — at the 128-pt icon the body shadow ran off the bottom edge and was clipped to a hard
  line (visible in the DMG window and Finder). Every `setShadow` in `AppIcon` multiplies by
  the render scale (size / 1024). After touching the icon, check the edge alpha is 0 at
  256 px as well as 1024 px by reading back the bitmap's outermost rows and columns.

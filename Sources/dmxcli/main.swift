// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import DMXCore
import NimbusUpdater

// dmxcli — tiny scripting/smoke-test tool for the Enttec DMX USB Pro.
//
//   dmxcli list                                  list serial ports
//   dmxcli info   [--port PATH]                  query widget serial/firmware/params
//   dmxcli set    [--port PATH] [--hold SEC] CH=VAL [CH=VAL ...]
//                                                 send a frame (e.g. 1=255 2=128), hold for SEC seconds (default 2)
//   dmxcli halo   [--port PATH] [--hold SEC] [--addr N] [--profile 1|2] INTENSITY% CCT_K [strobe off|random|constant]
//                                                 e.g. dmxcli halo 50 3200
//   dmxcli black  [--port PATH]                  send all zeros
//   dmxcli monitor [--port PATH] [--seconds S] [--on-change] [--raw] [--demo]
//                                                 watch the widget's DMX IN port: live level grid
//                                                 (--raw = one line per message). Receiving is a mode:
//                                                 the widget stops transmitting until the next output frame.
//   dmxcli selftest                              check the receive parsers against synthetic frames (no hardware)
//   dmxcli loopback [--port PATH] [--seconds S] [--channels N]
//                                                 patch OUT→IN with a 5-pin cable: send a known pattern,
//                                                 then listen for it (also settles whether the Pro can do both)
//   dmxcli icon   [--iconset DIR] [--png PATH --size N]
//                                                 render the app icon (no hardware needed)
//   dmxcli bench  [--port PATH] [--channels N] [--seconds S] [--fps F]
//                                                 send N-channel frames for S seconds; --fps 0 (default) floods with
//                                                 blocking writes (measures intake), --fps F paces at F frames/s and
//                                                 reports whether write() ever blocked (= we're outrunning the widget)
//   dmxcli params [--port PATH] [--rate R] [--break B] [--mab M]
//                                                 set widget parameters (rate 0 = as fast as possible)
//   dmxcli drain  [--port PATH] [--channels N] [--burst B]
//                                                 burst B frames then time close() (exposes the driver's baud-based drain wait)
//   dmxcli latency [--port PATH] [--channels N] [--burst B]
//                                                 burst B frames then time a get-params reply = real widget queue latency

func die(_ msg: String) -> Never { FileHandle.standardError.write((msg + "\n").data(using: .utf8)!); exit(1) }

var args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else {
    print("usage: dmxcli list|info|set|halo|black|monitor|icon|dmg-background|version|check-update|preflight [--port PATH] [--hold SEC] ...")
    exit(2)
}
args.removeFirst()

func takeOption(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...(i + 1)); return v
}

let portPath = takeOption("--port") ?? SerialPort.availablePorts().first(where: { $0.contains("usbserial") }) ?? ""
let hold = Double(takeOption("--hold") ?? "2") ?? 2

func hex(_ b: [UInt8], max: Int = 24) -> String {
    let shown = b.prefix(max).map { String(format: "%02X", $0) }.joined(separator: " ")
    return b.count > max ? shown + " … (\(b.count) bytes)" : shown
}

func openPort() -> SerialPort {
    guard !portPath.isEmpty else { die("no serial port found; pass --port /dev/cu.usbserial-XXXX") }
    let p = SerialPort(path: portPath)
    do { try p.open() } catch { die(error.localizedDescription) }
    return p
}

func stream(_ universe: [UInt8], seconds: Double, fps: Double = 30) {
    let p = openPort()
    let pkt = EnttecPro.dmxPacket(universe: universe)
    let nonzero = universe.enumerated().filter { $0.element != 0 }.map { "ch\($0.offset + 1)=\($0.element)" }
    print("port:    \(portPath)")
    print("frame:   \(nonzero.isEmpty ? "(all zero)" : nonzero.joined(separator: " "))")
    print("packet:  \(hex(pkt))")
    print("holding \(seconds)s at \(Int(fps)) fps (widget keeps repeating the last frame afterwards)…")
    let frames = Int(seconds * fps)
    for _ in 0..<max(1, frames) {
        do { try p.write(pkt) } catch { die(error.localizedDescription) }
        usleep(useconds_t(1_000_000 / fps))
    }
    p.close()
}

switch cmd {
case "list":
    for p in SerialPort.availablePorts() { print(p) }

case "info":
    let p = openPort()
    try? p.write(EnttecPro.getSerialRequest())
    let s = p.read(max: 64, timeout: 0.5)
    try? p.write(EnttecPro.getParametersRequest())
    let q = p.read(max: 64, timeout: 0.5)
    print("port:     \(portPath)")
    if let d = EnttecPro.message(.getWidgetSerial, in: s), let sn = EnttecPro.parseSerial(d) { print("serial:   \(sn)") } else { print("serial:   (no reply) raw=\(hex(s))") }
    if let d = EnttecPro.message(.getWidgetParameters, in: q), let prm = EnttecPro.parseParameters(d) {
        print("firmware: \(prm.firmwareVersion >> 8).\(prm.firmwareVersion & 0xFF)")
        print(String(format: "break:    %d (%.1f µs)", prm.breakTime, Double(prm.breakTime) * 10.67))
        print(String(format: "MAB:      %d (%.1f µs)", prm.mabTime, Double(prm.mabTime) * 10.67))
        print("refresh:  \(prm.refreshRate) Hz")
    } else { print("params:   (no reply) raw=\(hex(q))") }
    p.close()

case "set":
    var universe = [UInt8](repeating: 0, count: 512)
    for a in args {
        let parts = a.split(separator: "=")
        guard parts.count == 2, let ch = Int(parts[0]), (1...512).contains(ch), let v = Int(parts[1]), (0...255).contains(v)
        else { die("bad assignment '\(a)', expected CH=VAL with CH 1–512, VAL 0–255") }
        universe[ch - 1] = UInt8(v)
    }
    stream(universe, seconds: hold)

case "halo":
    let addr = Int(takeOption("--addr") ?? "1") ?? 1
    let profile: HaloProfile = (takeOption("--profile") ?? "1") == "2" ? .cct5ch : .cctUniversal3ch
    guard args.count >= 2, let intensity = Double(args[0]), let cct = Double(args[1]) else { die("usage: dmxcli halo INTENSITY% CCT_K [off|random|constant]") }
    var st = HaloState()
    st.intensity = intensity; st.cct = cct
    if args.count >= 3, let m = StrobeMode(rawValue: args[2].capitalized) { st.strobe = m; st.strobeRate = 0.5 }
    var universe = [UInt8](repeating: 0, count: 512)
    let bytes = st.encode(profile: profile)
    for (i, b) in bytes.enumerated() where addr + i <= 512 { universe[addr - 1 + i] = b }
    print("halo:    \(profile.rawValue) @ address \(addr) → \(bytes)")
    stream(universe, seconds: hold)

case "black":
    stream([UInt8](repeating: 0, count: 512), seconds: 1)

case "monitor":
    var opts = MonitorOptions()
    if let s = takeOption("--seconds") { opts.seconds = Double(s) }
    if let m = takeOption("--slots"), let n = Int(m) { opts.maxSlot = min(512, max(8, n)) }
    if let i = args.firstIndex(of: "--on-change") { opts.mode = .onChange; args.remove(at: i) }
    if let i = args.firstIndex(of: "--raw") { opts.raw = true; args.remove(at: i) }
    if let i = args.firstIndex(of: "--demo") { opts.demo = true; args.remove(at: i) }
    runMonitor(port: opts.demo ? nil : openPort(),
               portPath: opts.demo ? "(demo — synthetic frames, no hardware)" : portPath,
               options: opts)

case "selftest":
    receiveSelfTest()

case "loopback":
    let secs = Double(takeOption("--seconds") ?? "4") ?? 4
    let nch = Int(takeOption("--channels") ?? "24") ?? 24
    if let i = args.firstIndex(of: "--alternate") {
        args.remove(at: i)
        runLoopbackAlternating(port: openPort(), portPath: portPath, seconds: secs, channels: nch)
    } else {
        runLoopback(port: openPort(), portPath: portPath, seconds: secs, channels: nch)
    }

case "version":
    print(AppVersion.full)

case "preflight":
    // What must stay true for auto-update to keep working, checked against a built bundle.
    // `build.sh release` runs this before it pushes anything. The version comes from the bundle
    // being checked — this is about *that* build, not what is installed or running.
    guard let preflightPath = args.first else {
        FileHandle.standardError.write(Data("usage: dmxcli preflight \"dist/Nimbus DMX Helper.app\"\n".utf8))
        exit(2)
    }
    let preflightPlist = URL(fileURLWithPath: preflightPath).appendingPathComponent("Contents/Info.plist")
    let preflightInfo = (try? Data(contentsOf: preflightPlist)).flatMap {
        try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
    } ?? nil
    guard let preflightShort = preflightInfo?["CFBundleShortVersionString"] as? String,
          let preflightVersion = SemanticVersion(preflightShort) else {
        FileHandle.standardError.write(Data("\(preflightPath) has no readable CFBundleShortVersionString\n".utf8))
        exit(1)
    }
    let preflightSemaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var preflightReport: Preflight.Report?
    Task {
        preflightReport = await Preflight.run(app: URL(fileURLWithPath: preflightPath),
                                              config: Updates.config(currentVersion: preflightVersion),
                                              releaseVersion: preflightVersion)
        preflightSemaphore.signal()
    }
    preflightSemaphore.wait()
    for check in preflightReport!.checks {
        print("\(check.ok ? "ok  " : "FAIL") \(check.name): \(check.detail)")
    }
    if !(preflightReport!.passed) {
        FileHandle.standardError.write(Data("\nthis build would break auto-update for people who already have the app\n".utf8))
        exit(1)
    }
    print("\npreflight passed")

case "check-update":
    // What the app's updater sees: the feed, the parse, the comparison. Installing needs the
    // real bundle in /Applications, so it is not offered here.
    guard let current = Updates.runningVersion ?? Updates.installedVersion else {
        FileHandle.standardError.write(Data("no version to compare against: \(Updates.appName) is not installed\n".utf8))
        exit(1)
    }
    let updateConfig = Updates.config(currentVersion: current)
    print("current: \(current)  (\(Updates.runningVersion != nil ? "this bundle" : "the installed copy"))")
    let updateSemaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var updateOutcome: Result<Release?, Error>?
    Task {
        do { updateOutcome = .success(try await Release.fetchLatest(updateConfig)) }
        catch { updateOutcome = .failure(error) }
        updateSemaphore.signal()
    }
    updateSemaphore.wait()
    do {
        guard let release = try updateOutcome!.get() else {
            print("latest:  none the updater can read"); exit(0)
        }
        print("latest:  \(release.version)  [\(release.tag)]")
        if let asset = release.asset {
            print("asset:   \(asset.name)  (\(asset.size) bytes)")
        } else {
            print("asset:   none named \(updateConfig.assetPrefix)\(release.version.text).zip — invisible to the updater")
        }
        print(release.version > current
            ? (release.asset != nil ? "→ an update is available" : "→ newer, but nothing installable is published")
            : "→ up to date")
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }

case "dmg-background":
    // Render the disk image's background (1× and 2× PNGs) into a directory; build.sh packs
    // them into one TIFF. --signed drops the "unsigned build" footer.
    guard let dir = takeOption("--dir") else { die("dmg-background needs --dir DIR") }
    try DMGBackground.write(to: dir, signed: args.contains("--signed"))
    print("wrote \(dir)")

case "icon":
    // Render the app icon: --iconset DIR writes an .iconset (feed to iconutil), --png PATH one image.
    if let dir = takeOption("--iconset") {
        try AppIcon.writeIconset(to: dir)
        print("wrote \(dir)")
    }
    if let path = takeOption("--png") {
        let px = Int(takeOption("--size") ?? "1024") ?? 1024
        guard let d = AppIcon.pngData(px: px) else { die("render failed") }
        try d.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) (\(px)×\(px))")
    }

case "params":
    let rate = UInt8(takeOption("--rate") ?? "40") ?? 40
    let brk = UInt8(takeOption("--break") ?? "9") ?? 9
    let mab = UInt8(takeOption("--mab") ?? "1") ?? 1
    let p = openPort()
    let msg = EnttecPro.setParametersRequest(breakTime: brk, mabTime: mab, refreshRate: rate)
    print("sending: \(hex(msg))")
    do { try p.write(msg) } catch { die(error.localizedDescription) }
    usleep(100_000)
    try? p.write(EnttecPro.getParametersRequest())
    let q = p.read(max: 64, timeout: 0.5)
    if let d = EnttecPro.message(.getWidgetParameters, in: q), let prm = EnttecPro.parseParameters(d) {
        print("widget now: break \(prm.breakTime), MAB \(prm.mabTime), refresh \(prm.refreshRate) Hz")
    } else { print("no reply: \(hex(q))") }
    p.close()

case "drain":
    // Send a burst of N frames as fast as possible, then time close(): the kernel won't
    // return from close() until the widget has swallowed everything, so
    // rate ≈ N / (send + close). Run with two N values to separate fixed overhead from slope.
    let nch = Int(takeOption("--channels") ?? "24") ?? 24
    let n = Int(takeOption("--burst") ?? "100") ?? 100
    let p = openPort()
    var universe = [UInt8](repeating: 0, count: 512); universe[0] = 1
    let pkt = EnttecPro.dmxPacket(universe: universe, channels: nch)
    let t0 = Date()
    for _ in 0..<n { do { try p.write(pkt) } catch { die(error.localizedDescription) } }
    let tSend = Date().timeIntervalSince(t0)
    let c0 = Date(); p.close(); let tClose = Date().timeIntervalSince(c0)
    print(String(format: "%3d ch × %4d frames (%6d B): send %.3fs, close %.3fs → total %.3fs → %.1f frames/s, %.1f KB/s",
                 nch, n, n * pkt.count, tSend, tClose, tSend + tClose, Double(n) / (tSend + tClose), Double(n * pkt.count) / (tSend + tClose) / 1000))

case "latency":
    // Burst N frames, then queue a Get Widget Parameters request behind them and time the
    // reply: that's how long the widget took to chew through the burst — real end-to-end
    // queue latency, independent of close() behaviour.
    let nch = Int(takeOption("--channels") ?? "512") ?? 512
    let n = Int(takeOption("--burst") ?? "40") ?? 40
    let p = openPort()
    var universe = [UInt8](repeating: 0, count: 512); universe[0] = 1
    let pkt = EnttecPro.dmxPacket(universe: universe, channels: nch)
    // baseline first
    let b0 = Date(); try? p.write(EnttecPro.getParametersRequest()); let bResp = p.read(max: 9, timeout: 3)
    let base = Date().timeIntervalSince(b0)
    print(String(format: "baseline get-params round trip: %.1f ms (%d bytes)", base * 1000, bResp.count))
    let t0 = Date()
    for _ in 0..<n { do { try p.write(pkt) } catch { die(error.localizedDescription) } }
    try? p.write(EnttecPro.getParametersRequest())
    let resp = p.read(max: 9, timeout: 30)
    let t = Date().timeIntervalSince(t0)
    let bytes = n * pkt.count
    print(String(format: "%d × %d-ch frames (%d B) then get-params: reply after %.3f s (%d bytes) → widget intake ≈ %.1f KB/s ≈ %.1f frames/s",
                 n, nch, bytes, t, resp.count, Double(bytes) / t / 1000, Double(n) / t))
    let c0 = Date(); p.close(); print(String(format: "close(): %.0f ms", Date().timeIntervalSince(c0) * 1000))

case "bench":
    let nch = Int(takeOption("--channels") ?? "24") ?? 24
    let secs = Double(takeOption("--seconds") ?? "3") ?? 3
    let fps = Double(takeOption("--fps") ?? "0") ?? 0
    let p = openPort()
    var universe = [UInt8](repeating: 0, count: 512)
    universe[0] = 1 // keep the light dim but "on" so it's obvious we're still streaming
    let pkt = EnttecPro.dmxPacket(universe: universe, channels: nch)
    print("port:     \(portPath)")
    print("packet:   \(pkt.count) bytes (\(nch) channels), model: DMX line \(String(format: "%.2f", EnttecPro.dmxLineTime(channels: nch) * 1000)) ms/frame → \(String(format: "%.0f", 1 / EnttecPro.dmxLineTime(channels: nch))) Hz max")
    if fps > 0 { print("pacing at \(fps) fps for \(secs)s…") } else { print("flooding for \(secs)s with blocking writes…") }
    let t0 = Date()
    var frames = 0
    var maxWrite: TimeInterval = 0
    var slowWrites = 0
    var maxQ = 0, lastReportedQ = 0
    var next = t0
    while Date().timeIntervalSince(t0) < secs {
        if fps > 0 {
            next = next.addingTimeInterval(1 / fps)
            let wait = next.timeIntervalSinceNow
            if wait > 0 { usleep(useconds_t(wait * 1_000_000)) }
        }
        let w0 = Date()
        do { try p.write(pkt) } catch { die(error.localizedDescription) }
        let dt = Date().timeIntervalSince(w0)
        maxWrite = max(maxWrite, dt)
        if dt > 0.002 { slowWrites += 1 }
        frames += 1
        if frames % 200 == 0 {
            let q = p.outputQueueDepth; maxQ = max(maxQ, q)
            if q > lastReportedQ + 512 || (q == 0 && lastReportedQ > 0) {
                print(String(format: "  t=%.1fs outq=%d bytes", Date().timeIntervalSince(t0), q)); lastReportedQ = q
            }
        }
    }
    let el = Date().timeIntervalSince(t0)
    let qEnd = p.outputQueueDepth
    print("outq: max \(maxQ) bytes, at end \(qEnd) bytes  (>0 = we are outrunning the widget)")
    let bytes = frames * pkt.count
    print(String(format: "sent %d frames in %.2fs → %.0f frames/s, %.1f KB/s (%.0f kbaud @10 bits/byte)",
                 frames, el, Double(frames) / el, Double(bytes) / el / 1000, Double(bytes) * 10 / el / 1000))
    print(String(format: "write(): max %.1f ms, %d writes >2ms (blocking = USB/widget backpressure)", maxWrite * 1000, slowWrites))
    let c0 = Date(); p.close()
    print(String(format: "close(): %.0f ms", Date().timeIntervalSince(c0) * 1000))

default:
    die("unknown command \(cmd)")
}

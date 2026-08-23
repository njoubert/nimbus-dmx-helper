// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit
import DMXCore

@main
struct NimbusDMXHelperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var dmx = DMXController.shared
    @ObservedObject private var updates = UpdateModel.shared

    var body: some Scene {
        WindowGroup("Nimbus DMX Helper") {
            ContentView()
                .environmentObject(dmx)
        }
        .defaultSize(width: 1320, height: 720)
        // Updates live in the app menu, where macOS users look for them, just under About.
        .commands {
            CommandGroup(after: .appInfo) {
                Divider()
                if let release = updates.ready, updates.canInstall {
                    Button("Install Update \(release.version) and Relaunch") { updates.install() }
                } else if let release = updates.available {
                    Button("Update \(release.version) Available…") { updates.openReleasePage() }
                }
                Button("Check for Updates…") { updates.checkNow() }
                    .disabled(!updates.isAvailable || updates.checking)
                if updates.canInstall {
                    Toggle("Check for Updates Automatically", isOn: Binding(
                        get: { updates.automaticChecks },
                        set: { updates.automaticChecks = $0 }))
                }
            }
        }
    }
}

/// When run as a bare SwiftPM executable (no .app bundle) we have to promote
/// ourselves to a regular foreground app so the window and menu bar show up.
/// Also owns clean shutdown: the serial port must be closed *before* the process
/// exits, otherwise the kernel drains it lazily and the next launch blocks on open().
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // Running as a bare SwiftPM executable there is no bundle to carry an icon, so set it live.
        if let icon = AppIcon.nsImage() { NSApp.applicationIconImage = icon }
        NSApp.activate(ignoringOtherApps: true)
        // Launch flags: `--high-speed` starts in high-speed mode, `--connect` connects immediately,
        // `--monitor` starts listening on DMX IN instead of transmitting,
        // `--screenshot PATH` renders the window to a PNG after 3 s and quits (used for the README).
        let args = CommandLine.arguments
        if args.contains("--high-speed") { DMXController.shared.highSpeed = true }
        if args.contains("--connect") { DMXController.shared.connect() }
        if args.contains("--monitor") { DMXController.shared.monitoring = true }
        // Check GitHub for a newer release: once now (a session can be shorter than a day),
        // then daily if this window stays open. Does nothing for a bare binary or a
        // --screenshot run, and never installs anything without a click.
        UpdateModel.shared.start()
        if let i = args.firstIndex(of: "--screenshot"), i + 1 < args.count {
            let path = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.screenshot(to: path)
                NSApp.terminate(nil)
            }
        }
    }

    /// Render the main window (frame + content) to a PNG. Uses the layer tree so AppKit
    /// control labels and the window background come out right; no screen-recording
    /// permission needed.
    private func screenshot(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible }),
              let frameView = window.contentView?.superview else {
            FileHandle.standardError.write("screenshot: no window\n".data(using: .utf8)!); return
        }
        let scale = window.backingScaleFactor
        let size = frameView.bounds.size
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        // Layer render is bottom-up in AppKit coordinates for non-flipped layers; the frame view's
        // layer is flipped, so flip the context to match.
        if frameView.isFlipped { ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1) }
        frameView.layer?.render(in: ctx)
        guard let cg = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            FileHandle.standardError.write("screenshot: wrote \(path) (\(w)×\(h))\n".data(using: .utf8)!)
        } catch {
            FileHandle.standardError.write("screenshot: \(error)\n".data(using: .utf8)!)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        DMXController.shared.shutdownSync()
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

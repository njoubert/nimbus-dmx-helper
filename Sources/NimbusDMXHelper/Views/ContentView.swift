// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import DMXCore

struct ContentView: View {
    @EnvironmentObject var dmx: DMXController
    @ObservedObject private var updates = UpdateModel.shared

    var body: some View {
        VStack(spacing: 0) {
            connectionBar
            Divider()
            HSplitView {
                ScrollView { HaloPanelView() }
                    .frame(minWidth: 380, idealWidth: 420)
                UniversePane()
                    .frame(minWidth: 360)
                ScrollView { DebugView() }
                    .frame(minWidth: 420, idealWidth: 480)
            }
        }
        .frame(minWidth: 1180, minHeight: 620)
    }

    private var connectionBar: some View {
        HStack(spacing: 10) {
            Picker("Port", selection: $dmx.selectedPort) {
                ForEach(dmx.availablePorts, id: \.self) { Text($0.replacingOccurrences(of: "/dev/", with: "")).tag($0) }
                if dmx.availablePorts.isEmpty { Text("No serial ports").tag("") }
            }
            .frame(maxWidth: 260)
            .disabled(dmx.isConnected)

            Button { dmx.refreshPorts() } label: { Image(systemName: "arrow.clockwise") }
                .disabled(dmx.isConnected)
                .help("Rescan /dev/cu.*")

            if dmx.isConnected {
                Button("Disconnect") { dmx.disconnect() }
            } else if dmx.isConnecting {
                Button("Connecting…") {}.disabled(true)
                ProgressView().controlSize(.small)
            } else {
                Button("Connect") { dmx.connect() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(dmx.selectedPort.isEmpty)
            }

            Divider().frame(height: 18)

            Picker("Rate", selection: $dmx.frameRate) {
                Text("20 fps").tag(20.0)
                Text("30 fps").tag(30.0)
                Text("40 fps").tag(40.0)
            }
            .fixedSize()
            .disabled(dmx.highSpeed)
            .help("Normal mode frame rate. 40 fps = the widget's own DMX refresh rate; a full 512-channel frame takes ~23 ms on the wire, so ~44 Hz is the physical limit.")

            Toggle("High speed", isOn: $dmx.highSpeed)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Set the widget to 'as fast as possible', send only the channels in use (min 24), and pace at the DMX line rate of that short frame (~750 fps for a 24-channel frame).")

            Circle()
                .fill(dmx.isConnected ? Color.green : Color.red)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 0) {
                Text(dmx.statusMessage).font(.caption)
                if !dmx.widgetInfo.isEmpty {
                    Text(dmx.widgetInfo).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if dmx.isConnected {
                Text(String(format: "%.0f fps · %d ch/frame · %d frames", dmx.debug.measuredFPS, dmx.debug.frameChannels, dmx.framesSent))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            // An update, once it is downloaded and checked, right where the version already is.
            if let release = updates.ready, updates.canInstall {
                Button("Update \(release.version) ready — install") { updates.install() }
                    .controlSize(.small)
                    .help("Downloaded and checked against this app's Developer ID. Installing takes a couple of seconds and reopens the app.")
            }
            Text(AppVersion.versionString)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .help("Version and build number — quote these in a bug report. \"dev build\" means it is running outside an .app bundle.")
        }
        .padding(10)
    }
}

/// The universe, both directions: the channels we send, and what the widget hears on DMX IN.
private struct UniversePane: View {
    @EnvironmentObject var dmx: DMXController
    @State private var direction = 0

    var body: some View {
        VStack(spacing: 6) {
            Picker("", selection: $direction) {
                Text("Out").tag(0)
                Text("In").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 10)

            if direction == 0 { ChannelGridView() } else { MonitorView() }
        }
        .onAppear { if dmx.monitoring { direction = 1 } }
        .onChange(of: dmx.monitoring) { _, on in if on { direction = 1 } }
        .onChange(of: direction) {
            // Leaving the input tab shouldn't quietly leave the widget deaf-and-mute.
            if direction == 0 && dmx.monitoring { dmx.monitoring = false }
        }
    }
}

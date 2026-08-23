// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DMXCore
import NimbusUpdater
import SwiftUI

/// SwiftUI's view of `NimbusUpdater`: an ObservableObject the app menu and the connection bar
/// can bind to. The updater itself is the same one the two menu bar apps use; only the surface
/// differs, because this app has a window rather than a dropdown.
///
/// It is nil — every control disabled — when there is nothing to update: a bare SwiftPM binary
/// (`./build.sh run`, no bundle, so no version) or a `--screenshot` run.
@MainActor
final class UpdateModel: ObservableObject {
    static let shared = UpdateModel()

    @Published private(set) var state: Updater.State = .idle
    /// A manual check is in flight; the menu item stays disabled until it finishes.
    @Published private(set) var checking = false

    private let updater: Updater?

    private init() {
        guard !CommandLine.arguments.contains("--screenshot"),
              let version = Updates.runningVersion else {
            updater = nil
            return
        }
        let u = Updater(config: Updates.config(currentVersion: version))
        updater = u
        u.onChange = { [weak self] in
            guard let self, let updater = self.updater else { return }
            self.state = updater.state
        }
    }

    /// False for a bare binary or a screenshot run: there is no bundle to replace.
    var isAvailable: Bool { updater != nil }
    var canInstall: Bool { updater?.canInstall ?? false }

    var automaticChecks: Bool {
        get { updater?.automaticChecks ?? false }
        set {
            objectWillChange.send()
            updater?.automaticChecks = newValue
        }
    }

    /// Downloaded and signature-checked; `install()` will work.
    var ready: Release? { if case .ready(let release) = state { return release } else { return nil } }
    /// Newer, but not installable from here (no zip asset, or this copy is not in /Applications).
    var available: Release? { if case .available(let release) = state { return release } else { return nil } }

    /// One check on launch, then daily while the app stays open. See `Updates.config`.
    func start() { updater?.start() }

    func install() { updater?.installAndRelaunch() }

    func openReleasePage() { updater?.openReleasePage() }

    /// The menu's "Check for Updates…": always goes to the network, always says what happened.
    /// The alert is the package's, shared with the other Nimbus apps.
    func checkNow() {
        guard let updater, !checking else { return }
        checking = true
        Task { @MainActor in
            let outcome = await updater.checkNow()
            checking = false
            updater.presentCheckResult(outcome)
        }
    }
}

// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import NimbusUpdater

/// This app's side of `NimbusUpdater`: the facts that identify it, in one place, so the app
/// and `dmxcli check-update` ask about the same thing. Same shape as nimbus-leviton-bar's and
/// nimbus-net-bar's.
///
/// Unlike those two, this app is opened and quit rather than left in the menu bar, so the
/// launch check is the one that matters — `checkOnLaunch` (the default) makes it
/// unconditional, and the daily interval only comes into play during a long session.
public enum Updates {
    public static let repo = "njoubert/nimbus-dmx-helper"
    public static let bundleID = "com.njoubert.nimbusdmxhelper"
    /// The Developer ID team the release is signed with; a download signed by anyone else is
    /// refused. Shared with the other Nimbus apps (one Apple ID, one team).
    public static let teamID = "93A96TD57U"
    public static let appName = "Nimbus DMX Helper"
    public static let executableName = "NimbusDMXHelper"

    public static func config(currentVersion: SemanticVersion) -> UpdaterConfig {
        UpdaterConfig(repo: repo, bundleID: bundleID, teamID: teamID, appName: appName,
                      executableName: executableName, currentVersion: currentVersion,
                      // A session can easily be shorter than a day, so the launch check does
                      // the work; the interval only matters if the app is left open.
                      checkInterval: 24 * 3600, checkOnLaunch: true, launchDelay: 5,
                      // A session can be short, so the launch check may be the only one that
                      // ever runs here — worth saying out loud rather than leaving it in a
                      // menu the user may never open. Once per version.
                      announcesReadyUpdates: true)
    }

    /// The running bundle's version — nil for a bare SwiftPM binary (no Info.plist).
    public static var runningVersion: SemanticVersion? { SemanticVersion.ofBundle() }

    /// What `/Applications/<appName>.app` says it is, for the CLI run outside a bundle.
    public static var installedVersion: SemanticVersion? {
        let plist = URL(fileURLWithPath: "/Applications/\(appName).app/Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let short = info["CFBundleShortVersionString"] as? String else { return nil }
        return SemanticVersion(short)
    }
}

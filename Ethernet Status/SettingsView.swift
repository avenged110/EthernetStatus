// MARK: – SettingsView.swift
// Copyright © 2025 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The General settings tab, built from the shared SettingsKit primitives
// (SettingsPage / LaunchAtLoginToggle / SettingsDescribedToggle / SettingsLoggingSection).
// The window chrome, the login-item manager and the log-file monitor now live in
// SettingsKit.swift; the "About" tab is gone — About is the system About panel.

import SwiftUI

// MARK: – General Tab
// Combines general preferences and debug logging controls into a single view.

@MainActor
struct GeneralTabView: View, Loggable {
    nonisolated static let logTag = "[GeneralTabView]"

    // Kept as @AppStorage here (rather than folded entirely into SettingsDescribedToggle)
    // so 'showInterfaces' can gate the third toggle's enabled state and so the existing
    // per-toggle log lines are preserved via the .onChange handlers below.
    @AppStorage(Preferences.showAddressKey)
        private var showAddress: Bool = false
    @AppStorage(Preferences.showInterfacesKey)
        private var showInterfaces: Bool = false
    @AppStorage(Preferences.showPhantomInterfacesKey)
        private var showPhantomInterfaces: Bool = false

    var body: some View {
        SettingsPage {
            LaunchAtLoginToggle()

            Divider()

            SettingsDescribedToggle(
                "Show IP Address",
                description: "When available, display the current IPv4 address for the primary, active interface in the menu's Status section.",
                isOn: $showAddress)
                .onChange(of: showAddress) { _, newValue in
                    Self.log("Show Address \(newValue ? "enabled" : "disabled")")
                }

            SettingsDescribedToggle(
                "Show Interfaces Menu",
                description: "Display a submenu enumerating the currently-attached Ethernet interfaces and any associated hardware information.",
                isOn: $showInterfaces)
                .onChange(of: showInterfaces) { _, newValue in
                    Self.log("Show Interfaces \(newValue ? "enabled" : "disabled")")
                }

            SettingsDescribedToggle(
                "Show Internal Interfaces",
                description: "Include internal hardware interfaces in the enumerated list, even those which may not correspond to an actual Ethernet link.",
                isOn: $showPhantomInterfaces,
                isEnabled: showInterfaces)
                // A child of "Show Interfaces Menu": it only has meaning when that is on.
                .settingsChildRowInset()
                .onChange(of: showPhantomInterfaces) { _, newValue in
                    Self.log("Show Phantom Interfaces \(newValue ? "enabled" : "disabled")")
                }

            Divider()

            SettingsLoggingSection(loggingEnabledKey: Preferences.loggingEnabledKey) { newValue in
                // Deduplicated write + the "loggingEnabled set to …" log line. The
                // forced-log-on-disable and shutdownLogging() handling is done inside
                // SettingsLoggingSection.
                Preferences.loggingEnabled = newValue
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Preferences.swift
// Copyright © 2025 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Centralized preferences wrapper used across Ethernet Status.app, providing
// a single place to read/write UserDefaults-backed settings.

import Foundation

struct Preferences: Loggable {
    nonisolated static let logTag = "[PREFS]"
    // UserDefaults.standard is internally thread-safe for standard read/write operations
    // per Apple's documentation. Preferences accessors are called from several contexts
    // (the main actor, EthernetMonitor's monitorQueue via InterfaceReader, and
    // LoggerCore's actor executor). The SDK declares UserDefaults 'Sendable', so a plain
    // 'let' is checked by the compiler and needs no 'nonisolated(unsafe)' opt-out.
    private static var defaults: UserDefaults { .standard }

    // Keys used for UserDefaults. Also exposed publicly so @AppStorage bindings
    // in SettingsView can reference them without duplicating string literals.
    private enum Keys {
        static let loggingEnabled        = "preferences.loggingEnabled"
        static let showAddress           = "preferences.showAddress"
        static let showInterfaces        = "preferences.showInterfaces"
        static let showPhantomInterfaces = "preferences.showPhantomInterfaces"
    }

    static var loggingEnabledKey:        String { Keys.loggingEnabled }
    static var showAddressKey:           String { Keys.showAddress }
    static var showInterfacesKey:        String { Keys.showInterfaces }
    static var showPhantomInterfacesKey: String { Keys.showPhantomInterfaces }

    // Register sane defaults once. Guarantees defined behavior throughout the
    // application without callers needing to handle nil reads from UserDefaults.
    private static let _registeredDefaults: Void = {
        defaults.register(defaults: [
            Keys.loggingEnabled:        false,
            Keys.showAddress:           false,
            Keys.showInterfaces:        false,
            Keys.showPhantomInterfaces: false,
        ])
    }()

    // Ensure registration has run. Called explicitly by AppDelegate at launch
    // so defaults are always in place before any read occurs.
    static func ensureDefaultsRegistered() { _ = _registeredDefaults }

    // MARK: - Preferences

    // Read/write: owned by SettingsLoggingSection's binding, and also written here via
    // its change handler (GeneralTabView). The guard against redundant writes prevents a
    // spurious log entry when the binding and this setter both fire for the same toggle.
    static var loggingEnabled: Bool {
        get { defaults.bool(forKey: Keys.loggingEnabled) }
        set {
            guard defaults.bool(forKey: Keys.loggingEnabled) != newValue else { return }
            defaults.set(newValue, forKey: Keys.loggingEnabled)
            log("loggingEnabled set to \(newValue)")
        }
    }

    // Read-only: all three are written exclusively by @AppStorage bindings in
    // GeneralTabView. EthernetStatusMenu reads them each time the menu is built,
    // so no setter side-effects are needed.
    static var showAddress:           Bool { defaults.bool(forKey: Keys.showAddress) }
    static var showInterfaces:        Bool { defaults.bool(forKey: Keys.showInterfaces) }
    static var showPhantomInterfaces: Bool { defaults.bool(forKey: Keys.showPhantomInterfaces) }
}

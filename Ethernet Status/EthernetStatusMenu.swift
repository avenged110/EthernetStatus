// MARK: – EthernetStatusMenu.swift
// Copyright © 2025 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Ethernet Status.app's menu-bar applet: the status item, its menu, and the Settings
// window.
//
// This is the project-specific half of what StatusMenuController.swift used to be. The
// chrome — status item, menu construction, attributed titles, symbol caching, observation
// loop, synchronous teardown — now lives in the shared MenuControlKit.swift, and the
// Settings window in the shared SettingsKit.swift. What remains here is only what is
// actually Ethernet Status's: the reactive menu-bar glyph, the live Status section, the
// conditional Interfaces submenu, and the Settings…/Network Settings…/About/Quit tail.
//
// The app runs as `.accessory` for its whole lifetime — set once in AppDelegate and never
// changed — so the controller does not manage the activation policy.

import Cocoa

@MainActor
final class EthernetStatusMenu: Loggable {
    nonisolated static let logTag = "[SMC]"

    // MARK: - Dependencies
    private let appState: AppState
    private let settings: SettingsWindowController

    // The one long-lived Status section view. `.custom` caches it by id across rebuilds,
    // so it is created once and updated in place — exactly as the old controller kept it.
    private weak var statusSectionView: StatusSectionView?

    // The URL is a compile-time literal that always parses.
    private static let networkSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Network-Settings.extension")!

    // MARK: - Initialization

    init(appState: AppState, settingsWindowController: SettingsWindowController) {
        self.appState = appState
        self.settings = settingsWindowController
    }

    // MARK: - Menu Controller

    private lazy var menu = MenuController(.init(
        appName: "Ethernet Status",
        icon: { [weak self] in
            let connected = self?.appState.isConnected ?? false
            return .symbol(.menuBar("ethernet", weight: .semibold, isPrivate: true),
                           fallbackSymbol: .menuBar(connected ? "network" : "network.slash"),
                           alpha: connected ? 1.0 : 0.25,
                           accessibilityDescription: connected ? "Connected" : "Disconnected")
        },
        elements: { [weak self] in
            guard let self else { return [] }
            var elements: [MenuElement] = [
                .custom(id: "status",
                        make: { [weak self] in
                            let view = StatusSectionView(
                                connected: self?.appState.isConnected ?? false,
                                interface: self?.appState.activeInterface,
                                address: self?.appState.ipv4Address,
                                showAddress: Preferences.showAddress)
                            self?.statusSectionView = view
                            return view
                        },
                        update: { [weak self] view in
                            guard let self, let section = view as? StatusSectionView else { return }
                            self.statusSectionView = section
                            section.update(connected: self.appState.isConnected,
                                           interface: self.appState.activeInterface,
                                           address: self.appState.ipv4Address,
                                           showAddress: Preferences.showAddress)
                        }),
                .separator,
            ]

            if Preferences.showInterfaces {
                elements.append(.submenu(id: "interfaces", title: "Interfaces") { [weak self] in
                    self?.buildInterfaceElements() ?? []
                })
                elements.append(.separator)
            }

            elements.append(.action(id: "settings", title: "Settings…", key: ",") { [weak self] in
                self?.settings.open()
                self?.log("Opening Settings.")
            })
            elements.append(.action(id: "network", title: "Network Settings…", key: "/") {
                NSWorkspace.shared.open(Self.networkSettingsURL)
            })
            elements.append(.separator)
            elements.append(.about(title: "About Ethernet Status…") { [weak self] in
                self?.showAboutPanel()
            })
            elements.append(.separator)
            elements.append(.quit(title: "Quit Ethernet Status"))
            return elements
        },
        observing: { [weak self] in
            guard let self else { return }
            _ = self.appState.isConnected
            _ = self.appState.activeInterface
            _ = self.appState.ipv4Address
            // Mirror the old applyAppState(): keep a menu that is held open during a
            // network event current, not just the menu-bar icon.
            self.statusSectionView?.update(connected: self.appState.isConnected,
                                           interface: self.appState.activeInterface,
                                           address: self.appState.ipv4Address,
                                           showAddress: Preferences.showAddress)
        },
        willOpen: { [weak self] in
            guard let self, Preferences.showAddress else { return }
            // Re-resolve the IPv4 address from live system state: AppState's copy only
            // changes on a connectivity/primary-interface event, so on a long-lived link
            // it can be stale — exactly the case where the user just enabled
            // 'Show IP Address' or a DHCP lease reassigned the address without a link drop.
            let live = InterfaceReader.ipv4Address(forInterface: self.appState.activeInterface)
            if live != self.appState.ipv4Address { self.appState.ipv4Address = live }
        },
        prewarmSymbols: [
            .menuBar("ethernet", weight: .semibold, isPrivate: true),
            .menuBar("network"),
            .menuBar("network.slash"),
            SymbolSpec(name: "network", pointSize: 16.0, weight: .regular, scale: .medium),
            SymbolSpec(name: "network.slash", pointSize: 16.2, weight: .regular, scale: .medium),
            SymbolSpec(name: "network.connected.to.line.below",
                       pointSize: 14.0, weight: .regular, scale: .medium, isPrivate: true),
            SymbolSpec(name: "numbers.rectangle.fill",
                       pointSize: 14.0, weight: .regular, scale: .medium),
        ]))

    // MARK: - Lifecycle

    func install() { menu.install() }

    /// Shows the standard macOS About panel, which renders the app icon, name, version and
    /// the GPL-3.0 text from Credits.html in the bundle's Resources. The app stays
    /// `.accessory`; NSApp.activate() is what brings the panel to the front.
    func showAboutPanel() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
        log("Opening the standard About panel.")
    }

    func markTerminating() { menu.markTerminating() }

    func prepareForTerminationSynchronously() {
        settings.close()
        menu.prepareForTerminationSynchronously()
        log("EthernetStatusMenu torn down.")
    }
}

// MARK: - Interfaces Submenu Builder

private extension EthernetStatusMenu {

    func buildInterfaceElements() -> [MenuElement] {
        // appState.activeInterface is the single authoritative source for which interface
        // is active — maintained by the same EthernetMonitor driving the menu-bar icon,
        // so there is no TOCTOU race against a second independent SCDynamicStore query.
        let activeBsd = appState.activeInterface

        var interfaces = InterfaceReader.allEthernetInterfaces()

        if let activeBsd,
           let activeIndex = interfaces.firstIndex(where: { $0.bsdName == activeBsd }) {
            let activeIface = interfaces.remove(at: activeIndex)
            interfaces.insert(activeIface, at: 0)
        }

        guard !interfaces.isEmpty else {
            return [.info("No Interfaces Present")]
        }

        var elements: [MenuElement] = []
        for (index, iface) in interfaces.enumerated() {
            let bsd = iface.bsdName
            let title = iface.friendlyName ?? bsd
            elements.append(headerRow(id: "iface.\(bsd).header", title: title))

            if bsd == activeBsd {
                elements.append(detailRow(id: "iface.\(bsd).primary", text: "Primary: Active"))
            }
            elements.append(detailRow(id: "iface.\(bsd).bsd", text: "BSD Name: \(bsd)"))
            if let mac = iface.macAddress {
                elements.append(detailRow(id: "iface.\(bsd).mac", text: "MAC: \(mac)"))
            }
            if let ipv4 = iface.ipv4Address {
                elements.append(detailRow(id: "iface.\(bsd).ipv4", text: "IPv4: \(ipv4)"))
            }
            if let vendor = iface.vendor {
                elements.append(detailRow(id: "iface.\(bsd).vendor", text: "Vendor: \(vendor)"))
            }
            if let model = iface.model {
                elements.append(detailRow(id: "iface.\(bsd).model", text: "Model: \(model)"))
            }

            if index < interfaces.count - 1 { elements.append(.separator) }
        }
        return elements
    }

    // MARK: Row factories
    //
    // Each row is an `NSView` whose first subview is the `NSTextField`, fed through
    // `.custom` so it is created once per id and its text refreshed on every open via
    // `update` — the bounded-cache alternative to minting a value-bearing id per row.

    private static let detailIndent: CGFloat = 24.0

    func headerRow(id: String, title: String) -> MenuElement {
        .custom(id: id,
                make: { Self.makeHeaderView(title: title) },
                update: { view in Self.setText(title, in: view) })
    }

    func detailRow(id: String, text: String) -> MenuElement {
        .custom(id: id,
                make: { Self.makeDetailView(text: text) },
                update: { view in Self.setText(text, in: view) })
    }

    static func setText(_ text: String, in view: NSView) {
        (view.subviews.first as? NSTextField)?.stringValue = text
        view.setAccessibilityLabel(text)
    }

    static func makeHeaderView(title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = NSColor.labelColor
        label.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        if let cell = label.cell as? NSTextFieldCell {
            cell.lineBreakMode = .byTruncatingTail
        }

        let container = NSView()
        container.addSubview(label)
        container.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -3),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 20)
        ])

        let maxWidthConstraint = container.widthAnchor.constraint(lessThanOrEqualToConstant: 500)
        maxWidthConstraint.priority = .defaultHigh
        maxWidthConstraint.isActive = true

        container.setAccessibilityRole(.staticText)
        container.setAccessibilityLabel(title)
        return container
    }

    static func makeDetailView(text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = NSColor.tertiaryLabelColor
        label.font = NSFont.systemFont(ofSize: 12)

        let container = NSView()
        container.addSubview(label)
        container.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: detailIndent),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 18),
            container.widthAnchor.constraint(lessThanOrEqualToConstant: 500)
        ])
        container.setAccessibilityRole(.staticText)
        container.setAccessibilityLabel(text)
        return container
    }
}

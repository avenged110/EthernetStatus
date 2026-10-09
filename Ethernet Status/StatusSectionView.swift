// MARK: - StatusSectionView.swift
// Copyright © 2025 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Lightweight programmatic view used inside the menu item.
// Keeps its own subviews and exposes 'update(...)' to refresh content.

import Cocoa

final class StatusSectionView: NSView {
    private let circle: NSView
    private let imageView: NSImageView
    private let statusLabel: NSTextField

    // Address row UI
    private let addressRow: NSStackView
    private let circle2: NSView
    private let imageView2: NSImageView
    private let addressLabel: NSTextField

    // Single canonical radius used everywhere (half of the visible diameter)
    private let _iconCircleRadius: CGFloat = 13.0 // Corresponds to a 26pt diameter

    // Cached value for 'Address' glyph retrieval
    private let iconSizeMenu: CGFloat = 14.0

    // Shared helper: Build the attributed string for the address row.
    // Format when both present: "<IP> (<iface>)"
    // When no address is available, return the fallback string in tertiaryLabelColor.
    private static func makeAddressAttributed(interface: String?, address: String?) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 14)
        // Attributes reused
        let addrAttributes: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.labelColor, .font: font]
        let ifaceAttributes: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.tertiaryLabelColor, .font: font]

        if let addr = address, !addr.isEmpty {
            if let iface = interface, !iface.isEmpty {
                let combined = NSMutableAttributedString()
                combined.append(NSAttributedString(string: addr, attributes: addrAttributes))
                combined.append(NSAttributedString(string: " (", attributes: ifaceAttributes))
                combined.append(NSAttributedString(string: iface, attributes: ifaceAttributes))
                combined.append(NSAttributedString(string: ")", attributes: ifaceAttributes))
                return combined
            } else { return NSAttributedString(string: addr, attributes: addrAttributes) }
        } else {
            return NSAttributedString(string: "No Ethernet-based IP Address", attributes: [.foregroundColor: NSColor.tertiaryLabelColor, .font: font]) } }

    init(connected: Bool, interface: String?, address: String?, showAddress: Bool) {
        // Use the canonical radius to compute sizes here (keeps init() and update() consistent)
        let iconCircleSize = _iconCircleRadius * 2.0

        // --- First row icon (connection) ---
        circle = NSView()
        circle.translatesAutoresizingMaskIntoConstraints = false
        circle.wantsLayer = true
        // Deterministic layer configuration
        circle.layer?.cornerRadius = _iconCircleRadius
        circle.layer?.masksToBounds = true

        // Glyph, circle color and label text are state-dependent and set by update() below.
        imageView = NSImageView(image: NSImage())
        imageView.contentTintColor = .white
        imageView.translatesAutoresizingMaskIntoConstraints = false
        circle.addSubview(imageView)

        NSLayoutConstraint.activate([
            circle.widthAnchor.constraint(equalToConstant: iconCircleSize),
            circle.heightAnchor.constraint(equalToConstant: iconCircleSize),
            imageView.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: circle.centerYAnchor)])

        // --- Status label ---
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 14)
        statusLabel.textColor = .labelColor

        // --- Address row icon (circle2) ---
        circle2 = NSView()
        circle2.translatesAutoresizingMaskIntoConstraints = false
        circle2.wantsLayer = true
        // Deterministic configuration so the circle is always visible
        circle2.layer?.cornerRadius = _iconCircleRadius
        circle2.layer?.masksToBounds = true

        // imageView2 - private glyph (or fallback)
        let addrGlyph = SymbolCache.shared.image(named: "network.connected.to.line.below",
            pointSize: iconSizeMenu, weight: .regular, scale: .medium, isPrivate: true)
        ?? SymbolCache.shared.image(named: "numbers.rectangle.fill",
            pointSize: iconSizeMenu, weight: .regular, scale: .medium)
        imageView2 = NSImageView(image: addrGlyph ?? NSImage())
        imageView2.contentTintColor = .white
        imageView2.translatesAutoresizingMaskIntoConstraints = false
        circle2.addSubview(imageView2)

        NSLayoutConstraint.activate([
            circle2.widthAnchor.constraint(equalToConstant: iconCircleSize),
            circle2.heightAnchor.constraint(equalToConstant: iconCircleSize),
            imageView2.centerXAnchor.constraint(equalTo: circle2.centerXAnchor),
            imageView2.centerYAnchor.constraint(equalTo: circle2.centerYAnchor) ])

        // --- Address label (attributed) ---
        addressLabel = NSTextField(labelWithString: "")
        addressLabel.translatesAutoresizingMaskIntoConstraints = false

        // --- Compose address row stack ---
        addressRow = NSStackView(views: [circle2, addressLabel])
        addressRow.orientation = .horizontal
        addressRow.spacing = 8
        addressRow.alignment = .centerY
        addressRow.translatesAutoresizingMaskIntoConstraints = false
        addressRow.setContentHuggingPriority(.required, for: .vertical)
        addressRow.setContentCompressionResistancePriority(.required, for: .vertical)

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // --- Outer layout ---
        let titleLabel = NSTextField(labelWithString: "Ethernet")
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor

        // Title row simply shows "Ethernet" - interface is shown in the address-row now
        let titleRow = NSStackView(views: [titleLabel, NSView()])
        titleRow.orientation = .horizontal
        titleRow.alignment = .firstBaseline
        titleRow.distribution = .fill

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let sectionLabel = NSTextField(labelWithString: "Status")
        sectionLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        sectionLabel.textColor = .secondaryLabelColor

        let statusRow = NSStackView(views: [circle, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.spacing = 8
        statusRow.alignment = .centerY
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        statusRow.setContentHuggingPriority(.required, for: .vertical)
        statusRow.setContentCompressionResistancePriority(.required, for: .vertical)

        let outerStack = NSStackView()
        outerStack.orientation = .vertical
        outerStack.alignment = .leading
        outerStack.translatesAutoresizingMaskIntoConstraints = false
        outerStack.addView(titleRow, in: .top)
        outerStack.setCustomSpacing(12, after: titleRow)
        outerStack.addView(divider, in: .top)
        outerStack.setCustomSpacing(8, after: divider)
        outerStack.addView(sectionLabel, in: .top)
        outerStack.setCustomSpacing(6, after: sectionLabel)
        outerStack.addView(statusRow, in: .top)
        outerStack.setCustomSpacing(6, after: statusRow)
        outerStack.addView(addressRow, in: .top)

        addSubview(outerStack)

        NSLayoutConstraint.activate([
            outerStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            outerStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            outerStack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            outerStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 300) ])

        update(connected: connected, interface: interface, address: address, showAddress: showAddress) }

    required init?(coder: NSCoder) { nil }

    func update(connected: Bool, interface: String?, address: String?, showAddress: Bool) {
        // Update connection status circle + glyph + text
        circle.layer?.backgroundColor = (connected ? NSColor.systemBlue : NSColor.quaternaryTertiaryBlend).cgColor
        let symbolName = connected ? "network" : "network.slash"
        let pointSize: CGFloat = (symbolName == "network") ? 16.0 : 16.2
        imageView.image = SymbolCache.shared.image(named: symbolName,
            pointSize: pointSize, weight: .regular, scale: .medium)
        statusLabel.stringValue = connected ? "Connected" : "Disconnected"

        // Address row visibility. NSStackView detaches hidden views by default, so the
        // section collapses to the status row alone when 'Show IP Address' is off.
        addressRow.isHidden = !showAddress

        // If there is an address, highlight circle; otherwise 'gray' it
        let hasAddress = !(address ?? "").isEmpty
        circle2.layer?.backgroundColor = (hasAddress ? NSColor.systemBlue : NSColor.quaternaryTertiaryBlend).cgColor

        // Update the attributed address label "<IP> (iface)" or fallback text
        addressLabel.attributedStringValue = Self.makeAddressAttributed(interface: interface, address: address) }
}

// MARK: - Custom color blending
// Replicate Apple's background color for non-active 'circles'.
// The blended color is cached inside a @MainActor helper type so all access to
// both the cache and NSApp.effectiveAppearance is guaranteed to occur on the
// main thread, eliminating every concurrency warning at the call sites.
// NSColor.quaternaryTertiaryBlend is a convenience shim that delegates to the
// helper; callers that are already on the main actor (all current callers are)
// are unaffected.

@MainActor
private enum AppearanceBlendCache {
    static var cachedBlend: NSColor?
    static var cachedAppearanceName: NSAppearance.Name?

    static var quaternaryTertiaryBlend: NSColor {
        let currentName = NSApp.effectiveAppearance.name
        if let cached = cachedBlend, cachedAppearanceName == currentName {
            return cached
        }

        // Dynamic label colors resolve against NSAppearance.current, which outside a
        // drawing pass need not match NSApp.effectiveAppearance — resolving them there
        // could cache one appearance's blend under the other's name. Resolve explicitly.
        var resolved: (t: NSColor, q: NSColor)?
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            if let t = NSColor.tertiaryLabelColor.usingColorSpace(.deviceRGB),
               let q = NSColor.quaternaryLabelColor.usingColorSpace(.deviceRGB) {
                resolved = (t, q)
            }
        }
        guard let (t, q) = resolved else { return NSColor.tertiaryLabelColor }

        let ratio: CGFloat = 0.5
        let red   = t.redComponent   * ratio + q.redComponent   * (1 - ratio)
        let green = t.greenComponent * ratio + q.greenComponent * (1 - ratio)
        let blue  = t.blueComponent  * ratio + q.blueComponent  * (1 - ratio)
        let alpha = t.alphaComponent * ratio + q.alphaComponent * (1 - ratio)

        let blended = NSColor(red: red, green: green, blue: blue, alpha: alpha)
        cachedBlend = blended
        cachedAppearanceName = currentName
        return blended
    }
}

extension NSColor {
    /// Returns a cached 50/50 blend of tertiaryLabelColor and quaternaryLabelColor,
    /// recomputed only when the system appearance changes. Must be called on the main actor.
    @MainActor
    static var quaternaryTertiaryBlend: NSColor {
        AppearanceBlendCache.quaternaryTertiaryBlend
    }
}

// MARK: – InterfaceReader.swift
// Copyright © 2025 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Static utilities for Ethernet interface discovery, address resolution,
// and hardware detail enumeration.

import Foundation
import SystemConfiguration
import IOKit
import IOKit.network

// MARK: - Data Types

struct EthernetInterfaceInfo {
    let bsdName: String
    let friendlyName: String?
    let macAddress: String?
    let ipv4Address: String?
    let vendor: String?
    let model: String?
}

// MARK: - InterfaceReader

struct InterfaceReader: Loggable {
    nonisolated static let logTag = "[InterfaceReader]"

    // MARK: - IPv4 address

    /// Returns the IPv4 address assigned to the given interface, or nil.
    static func ipv4Address(forInterface iface: String?) -> String? {
        guard let iface else { return nil }
        guard let store = SCDynamicStoreCreate(nil, "InterfaceReaderIPv4" as CFString, nil, nil) else {
            log("ERROR: Failed to create SCDynamicStore for ipv4Address.")
            return nil
        }
        let result = ipv4Address(forInterface: iface, store: store)
        log("ipv4Address(for: \(iface)) -> \(result ?? "nil")")
        return result
    }

    // MARK: - Enumerate all Ethernet interfaces

    /// Returns info structs for all Ethernet interfaces currently known to the system.
    /// When "Show Internal Interfaces" is disabled, only interfaces with an active
    /// link (i.e. physically connected and participating in the network stack) are
    /// returned. Inactive interfaces — including Thunderbolt bridge stubs and any
    /// other hardware that is present but not linked — are treated as internal and
    /// hidden. Enabling the preference lifts this restriction and returns all
    /// Ethernet-type interfaces regardless of link state.
    static func allEthernetInterfaces() -> [EthernetInterfaceInfo] {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [] }
        guard let store = SCDynamicStoreCreate(nil, "InterfaceReaderAll" as CFString, nil, nil) else {
            log("ERROR: Failed to create SCDynamicStore for allEthernetInterfaces.")
            return []
        }

        return all.compactMap { iface -> EthernetInterfaceInfo? in
            guard
                let bsdName = SCNetworkInterfaceGetBSDName(iface) as String?,
                let type = SCNetworkInterfaceGetInterfaceType(iface) as String?,
                type == kSCNetworkInterfaceTypeEthernet as String
            else { return nil }

            // Determine link state via SCDynamicStore.
            let linkKey = "State:/Network/Interface/\(bsdName)/Link" as CFString
            var isActive = false
            if let info = SCDynamicStoreCopyValue(store, linkKey) as? [String: Any],
               let active = info["Active"] as? Bool {
                isActive = active
            }

            // When "Show Internal Interfaces" is off, hide every interface that does
            // not have an active link. This correctly suppresses Thunderbolt bridge
            // stubs, USB-Ethernet adapters that are plugged in but not linked, and
            // any other hardware that is present but not actually connected —
            // regardless of whether those interfaces carry a MAC address.
            if !Preferences.showPhantomInterfaces && !isActive {
                log("Skipping inactive interface \(bsdName) (showPhantomInterfaces = false).")
                return nil
            }

            let (mac, vendor, model) = hardwareInfo(for: bsdName)
            let friendly = SCNetworkInterfaceGetLocalizedDisplayName(iface) as String?

            return EthernetInterfaceInfo(
                bsdName: bsdName, friendlyName: friendly,
                macAddress: mac, ipv4Address: ipv4Address(forInterface: bsdName, store: store),
                vendor: vendor, model: model)
        }
    }

    // MARK: - IPv4 address lookup

    /// Returns the primary IPv4 address configd has published for the interface.
    /// Reading 'State:/Network/Interface/<bsd>/IPv4' avoids walking the getifaddrs
    /// C linked list, so no raw pointers are involved. The first entry of
    /// 'Addresses' is the interface's primary address — the one System Settings shows.
    private static func ipv4Address(forInterface bsdName: String, store: SCDynamicStore) -> String? {
        let key = "State:/Network/Interface/\(bsdName)/IPv4" as CFString
        guard let info = SCDynamicStoreCopyValue(store, key) as? [String: Any],
              let addresses = info[kSCPropNetIPv4Addresses as String] as? [String] else { return nil }
        return addresses.first
    }

    // MARK: - Hardware info (IOKit)

    private static func hardwareInfo(for bsdName: String) -> (mac: String?, vendor: String?, model: String?) {
        // Same dictionary IOBSDNameMatching builds, without handing it a C string.
        let matchingDict = [kIOBSDNameKey: bsdName] as CFDictionary
        // Apple can kiss my ass; I'll use the word "master" if I damn well please.
        let service = IOServiceGetMatchingService(kIOMasterPortDefault, matchingDict)
        guard service != 0 else { return (nil, nil, nil) }
        defer { IOObjectRelease(service) }

        // IORegistryEntrySearchCFProperty returns a managed CF reference, unlike
        // IORegistryEntryCreateCFProperty's 'Unmanaged', and can walk to the parent
        // itself, so no inout 'io_object_t' or explicit release is needed.
        func property(_ key: String, searchParents: Bool = false) -> CFTypeRef? {
            let options = searchParents
                ? IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents) : 0
            // 'unsafe' only because the plane name is passed as a C string.
            return unsafe IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString,
                                                          kCFAllocatorDefault, options)
        }

        // MAC address lives on the parent (controller) registry entry.
        var mac: String?
        if let data = property("IOMACAddress", searchParents: true) as? Data {
            // Pure-Swift hex formatting; String(format:) goes through C varargs.
            mac = data.map { byte in
                let hex = String(byte, radix: 16)
                return byte < 0x10 ? "0" + hex : hex
            }.joined(separator: ":")
        }

        let vendor = property("IOVendor") as? String
        let model = property("IOModel") as? String

        return (mac, vendor, model)
    }

    // MARK: - Retry logic for delayed IP address availability

    /// Repeatedly attempts to fetch an IPv4 address for the given interface.
    /// Returns the resolved address as soon as one is found, or nil if all
    /// attempts are exhausted.
    ///
    /// Designed as an async function rather than a callback-accepting one.
    /// This eliminates the closure-capture problem entirely: no @Sendable or
    /// @MainActor annotation is needed on any closure, because there is no
    /// closure. The caller awaits the result in its own actor context and
    /// writes to isolated state directly after the await returns.
    static func retryIPv4Address(
        forInterface iface: String,
        maxAttempts: Int = 18,
        interval: TimeInterval = 5.0
    ) async -> String? {
        var attemptsRemaining = maxAttempts
        while attemptsRemaining > 0 {
            // A canceled sleep must end the poll. With 'try?' alone, cancellation
            // makes every remaining sleep return instantly and the loop spins through
            // all remaining attempts back-to-back instead of stopping.
            do {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            } catch {
                log("retryIPv4Address: Canceled while waiting for \(iface).")
                return nil
            }
            if let addr = ipv4Address(forInterface: iface) {
                log("retryIPv4Address: Resolved \(addr) for \(iface).")
                return addr
            }
            attemptsRemaining -= 1
            log("retryIPv4Address: \(attemptsRemaining) attempt(s) remaining for \(iface).")
        }
        return nil
    }
}

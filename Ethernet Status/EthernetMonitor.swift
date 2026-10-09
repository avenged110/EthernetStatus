// MARK: - EthernetMonitor.swift
// Copyright © 2025 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Monitor the status of Ethernet interfaces using SCDynamicStore
// and NWPathMonitor for reconciliation / resilience.

import Foundation
import SystemConfiguration
import Network

// 'EthernetMonitor' is safe to pass across concurrency boundaries because all
// mutable state is either accessed exclusively on 'monitorQueue' (a serial
// DispatchQueue) or is set once at init time and never mutated again. The
// explicit '@unchecked Sendable' conformance documents this invariant for the
// compiler without requiring every property to be an actor-isolated type.
final class EthernetMonitor: @unchecked Sendable, Loggable {
    static let logTag = "[EthernetMonitor]"

    // Callback invoked on any status change: (isConnected, primaryInterfaceNameOrNil).
    // Declared '@MainActor' so the closure type itself carries main-actor isolation.
    // This lets @MainActor callers (e.g. AppDelegate) pass closures that freely
    // reference @MainActor-isolated state without any @Sendable constraint.
    // Delivery is via 'Task { @MainActor in }' in evaluateStatus(), which honors
    // the isolation contract without requiring DispatchQueue.main.async.
    private let callback: @MainActor (Bool, String?) -> Void

    // Serial queue for all dynamic store work, debounce scheduling, and
    // synchronized access to 'currentStatus', 'ethernetInterfaces', 'nwMonitor',
    // and 'debounceWorkItem'. This includes the SCDynamicStore change callback,
    // which is explicitly re-dispatched onto this queue before touching any
    // of those properties (see handleStoreChange).
    private let monitorQueue = DispatchQueue(label: "com.ethernetStatus.monitor")

    // Identity token for 'monitorQueue'. 'stopMonitoring()' uses 'monitorQueue.sync',
    // and is also called from 'deinit'. Every block scheduled on monitorQueue takes a
    // temporary strong reference to self for its duration ('guard let self', or the
    // implicit retain in 'self?.foo()'), so if the owner drops its last reference while
    // such a block is running, the final release — and therefore deinit — happens ON
    // monitorQueue. 'sync' onto the queue you are already running on deadlocks the
    // process outright. Checking this key lets stopMonitoring run its body inline in
    // exactly that case. See 'runOnMonitorQueueSync'.
    private static let queueIdentityKey = DispatchSpecificKey<ObjectIdentifier>()
    private let queueIdentity: ObjectIdentifier

    // Runs 'body' with the same mutual exclusion 'monitorQueue.sync' provides, but
    // executes it inline when the caller is already on monitorQueue instead of
    // deadlocking. Serialization still holds: being on the queue already IS exclusion.
    private func runOnMonitorQueueSync(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: Self.queueIdentityKey) == queueIdentity {
            body()
        } else {
            monitorQueue.sync(execute: body)
        }
    }

    // SCDynamicStore + runloop source
    private var store: SCDynamicStore?
    private var runLoopSource: CFRunLoopSource?

    // NW fallback monitor. Access only on 'monitorQueue'.
    private var nwMonitor: NWPathMonitor?
    private let nwQueue = DispatchQueue(label: "com.ethernetStatus.NWPath")

    // Cached set of Ethernet BSD names (e.g. en0, en7).
    // Access only on 'monitorQueue'.
    private var ethernetInterfaces: Set<String> = []

    // Current reported connectivity state.
    // Access only on 'monitorQueue'.
    private var currentStatus: Bool = false

    // Last reported primary interface. Tracked alongside 'currentStatus' so that a
    // hand-off between two simultaneously-linked Ethernet interfaces (e.g. the
    // lowest-numbered one drops while a second stays up) still produces a callback:
    // connectivity is unchanged, but the interface the rest of the app is showing —
    // and resolving an IP address for — is not.
    // Access only on 'monitorQueue'.
    private var currentInterface: String? = nil

    // Debounce work item. Access only on 'monitorQueue'.
    private var debounceWorkItem: DispatchWorkItem?

    // Retry/backoff for initial SCDynamicStore creation
    private var setupRetryCount = 0
    private let maxSetupRetries = 5
    private let retryDelayBase: TimeInterval = 2.0

    // Debounce interval
    private let debounceInterval: TimeInterval = 0.15

    // Throttle for hardware re-enumeration triggered by an unrecognized interface.
    // The notification pattern matches every 'en*' Link key, which includes Wi-Fi and
    // other non-Ethernet interfaces; those never enter 'ethernetInterfaces', so they
    // would otherwise look "unknown" on every single link event and re-run the
    // relatively expensive SCNetworkInterfaceCopyAll() each time.
    // Access only on 'monitorQueue'.
    private var lastInterfaceRebuild: TimeInterval = 0
    private let interfaceRebuildThrottle: TimeInterval = 5.0

    // MARK: - Initialization
    init(callback: @escaping @MainActor (Bool, String?) -> Void) {
        self.callback = callback
        self.queueIdentity = ObjectIdentifier(monitorQueue)
        monitorQueue.setSpecific(key: Self.queueIdentityKey, value: queueIdentity)
        setupDynamicStore()
        setupNWPathMonitor()
    }

    deinit { stopMonitoring() }

    // MARK: - SCDynamicStore setup
    private func setupDynamicStore() {
        monitorQueue.async { [weak self] in
            guard let self else { return }

            if self.store != nil { self.teardownDynamicStore() }

            // The callback context carries a retained 'StoreCallbackBox' holding only a
            // weak reference to self. SCDynamicStore owns the box through the retain/
            // release callbacks, so the pointer it hands back can never dangle — even if
            // a callback is already running on the main thread while deinit tears the
            // store down on another — and a callback that outlives self finds 'nil'.
            // 'unsafe': the context still crosses the C boundary as a raw pointer.
            let box = StoreCallbackBox(monitor: self)
            var context = unsafe SCDynamicStoreContext(
                version: 0,
                info: Unmanaged.passUnretained(box).toOpaque(),
                retain: { info in
                    unsafe UnsafeRawPointer(Unmanaged<StoreCallbackBox>.fromOpaque(info).retain().toOpaque())
                },
                release: { info in unsafe Unmanaged<StoreCallbackBox>.fromOpaque(info).release() },
                copyDescription: nil)

            self.store = withExtendedLifetime(box) {
                unsafe SCDynamicStoreCreate(nil, "EthernetMonitor" as CFString,
                    { (_, changedKeys, contextPtr) in
                        guard let ctx = unsafe contextPtr,
                              let monitor = unsafe Unmanaged<StoreCallbackBox>.fromOpaque(ctx)
                                  .takeUnretainedValue().monitor else { return }
                        // The SCDynamicStore callback fires on CFRunLoopGetMain() (main thread).
                        // All mutable state ('debounceWorkItem', 'currentStatus', etc.) must only
                        // be accessed on 'monitorQueue', so we re-dispatch immediately.
                        let keys = changedKeys as? [String] ?? []
                        monitor.monitorQueue.async {
                            monitor.handleStoreChange(keys)
                        }
                    }, &context)
            }

            guard let store = self.store else {
                self.setupRetryCount += 1
                if self.setupRetryCount <= self.maxSetupRetries {
                    let delay = self.retryDelayBase * pow(2.0, Double(self.setupRetryCount - 1))
                    Self.log("SCDynamicStore creation failed — retry \(self.setupRetryCount) in \(delay)s")
                    // Use Task.detached so no actor context is inherited from the caller
                    // (we are on monitorQueue, not on any actor). setupDynamicStore() dispatches
                    // back onto monitorQueue internally, so no actor isolation is required here.
                    Task.detached { [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        self?.setupDynamicStore()
                    }
                } else {
                    Self.log("SCDynamicStore creation failed — exceeded retries; aborting monitor setup")
                    Task { @MainActor [weak self] in self?.callback(false, nil) }
                }
                return
            }

            self.setupRetryCount = 0

            self.buildInterfaceList()

            let patterns = ["^State:/Network/Interface/en[0-9]+/Link$"]
            SCDynamicStoreSetNotificationKeys(store, nil, patterns as CFArray)

            if let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0) {
                self.runLoopSource = source
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            }

            self.evaluateStatus()

            Self.log("Initialized; Watching Link keys for Ethernet interfaces.")
        }
    }

    private func teardownDynamicStore() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            CFRunLoopSourceInvalidate(source)
            runLoopSource = nil
        }
        if let st = store {
            SCDynamicStoreSetNotificationKeys(st, nil, nil)
            store = nil
        }
    }

    // MARK: - Interface discovery
    private func buildInterfaceList() {
        ethernetInterfaces.removeAll()
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else {
            Self.log("ERROR: Failed to list SCNetworkInterface entries.")
            return
        }

        for iface in all {
            if let bsd = SCNetworkInterfaceGetBSDName(iface) as String?,
               let type = SCNetworkInterfaceGetInterfaceType(iface) as String?,
               type == kSCNetworkInterfaceTypeEthernet as String {
                ethernetInterfaces.insert(bsd)
            }
        }

        let list = Self.orderedInterfaceNames(ethernetInterfaces).joined(separator: ", ")
        Self.log("Detected Ethernet interfaces: \(list)")
    }

    // MARK: - Stop and cleanup
    func stopMonitoring() {
        // Capture the NWPathMonitor reference inside the sync block so that the nil
        // assignment (which protects against a concurrent setupNWPathMonitor write) is
        // serialized on 'monitorQueue'. We then call cancel() *after* the block exits
        // to avoid holding the queue lock while NWPathMonitor performs its own internal
        // cleanup, which could otherwise cause a deadlock.
        var monitorToCancel: NWPathMonitor?

        // NOTE: no '[weak self]' capture here. 'stopMonitoring()' is called from
        // 'deinit', and forming a weak reference to an object that is already
        // deallocating yields nil — which would make the guard bail out and skip
        // teardown entirely, leaving the run-loop source registered and firing
        // into a monitor that no longer exists. The closure below is non-escaping, so
        // referencing 'self' directly neither escapes nor prolongs the object's lifetime.
        //
        // 'runOnMonitorQueueSync' rather than a bare 'monitorQueue.sync': deinit can
        // legitimately run on monitorQueue (see 'queueIdentityKey'), and sync-ing onto
        // the current queue is an unconditional deadlock.
        runOnMonitorQueueSync {
            self.debounceWorkItem?.cancel()
            self.debounceWorkItem = nil
            self.teardownDynamicStore()
            monitorToCancel = self.nwMonitor
            self.nwMonitor = nil
        }

        // cancel() is called after the block exits so the queue is not held while
        // NWPathMonitor performs its own internal cleanup. Reading nwMonitor to nil
        // inside the block also makes a second stopMonitoring() a no-op, which matters
        // now that AppDelegate tears down explicitly and deinit tears down again.
        monitorToCancel?.cancel()
    }

    // MARK: - Status evaluation
    // Core evaluation routine. Must only be called on 'monitorQueue'.
    private func evaluateStatus() {
        // Guard against being called after teardown (e.g. an in-flight NWPathMonitor
        // event dispatched to monitorQueue just before nwMonitor.cancel() is called in
        // stopMonitoring). SCDynamicStoreCopyValue crashes if passed a nil store.
        guard let store else {
            Self.log("evaluateStatus called with nil store — skipping (monitor torn down).")
            return
        }

        let previous = currentStatus
        let previousInterface = currentInterface
        var activeInterface: String? = nil

        for name in Self.orderedInterfaceNames(ethernetInterfaces) {
            let key = "State:/Network/Interface/\(name)/Link" as CFString
            if let info = SCDynamicStoreCopyValue(store, key) as? [String: Any],
               let active = info["Active"] as? Bool, active {
                activeInterface = name
                break
            }
        }

        currentStatus = (activeInterface != nil)
        currentInterface = activeInterface

        if currentStatus != previous || activeInterface != previousInterface {
            Self.log("Status changed: connected=\(currentStatus), interface=\(activeInterface ?? "none")")
            let connected = currentStatus
            // Capture 'activeInterface' by value so the closure holds an immutable
            // copy rather than a reference to the local variable, eliminating the
            // "reference to captured var in concurrently-executing code" warning.
            let capturedInterface = activeInterface
            // Deliver on the main actor. Task { @MainActor in } honors the @MainActor
            // isolation declared on 'callback' and avoids any @Sendable constraint on
            // the closure type seen by callers.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.callback(connected, capturedInterface)
            }
        } else {
            Self.log("Evaluation: No change (connected=\(currentStatus), interface=\(activeInterface ?? "none"))")
        }
    }

    // MARK: - SCDynamicStore change handler (debounced)
    // Always called on 'monitorQueue' (re-dispatched from the SCDynamicStore callback).
    private func handleStoreChange(_ changedKeys: [String]) {
        // A notification for an interface we have never seen means hardware appeared
        // since the last enumeration (e.g. a USB/Thunderbolt Ethernet adapter plugged
        // in mid-session). Without refreshing the cached list here, evaluateStatus()
        // would keep iterating a stale set and never observe the new adapter's link
        // state — the interface would stay invisible until the next wake or relaunch.
        let unknown = changedKeys.compactMap(Self.interfaceName(fromLinkKey:))
            .contains { !ethernetInterfaces.contains($0) }
        if unknown {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastInterfaceRebuild >= interfaceRebuildThrottle {
                lastInterfaceRebuild = now
                Self.log("Store change referenced an unknown interface — rebuilding interface list.")
                buildInterfaceList()
            }
        }

        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.evaluateStatus()
        }
        debounceWorkItem = workItem
        monitorQueue.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    // Orders BSD interface names the way a human reads them: en2 before en10.
    // 'Set<String>.sorted()' is lexicographic, which puts "en10" ahead of "en2" and made
    // the "prefer the lowest-numbered active interface" rule in evaluateStatus() pick
    // the wrong one on any machine with ten or more en* devices (a docking station with
    // several adapters attached reaches that easily). Names are compared by trailing
    // numeric suffix first, then by prefix, falling back to plain lexicographic order
    // for anything that does not parse.
    private static func orderedInterfaceNames(_ names: Set<String>) -> [String] {
        func split(_ name: String) -> (prefix: Substring, number: Int?) {
            let digits = name.reversed().prefix { $0.isASCII && $0.isNumber }.count
            guard digits > 0 else { return (name[...], nil) }
            let boundary = name.index(name.endIndex, offsetBy: -digits)
            return (name[name.startIndex..<boundary], Int(name[boundary...]))
        }
        return names.sorted { lhs, rhs in
            let l = split(lhs), r = split(rhs)
            guard let ln = l.number, let rn = r.number, l.prefix == r.prefix else {
                return lhs < rhs
            }
            return ln < rn
        }
    }

    // Extracts the BSD name from a "State:/Network/Interface/<bsd>/Link" key.
    private static func interfaceName(fromLinkKey key: String) -> String? {
        let parts = key.split(separator: "/")
        // ["State:", "Network", "Interface", "<bsd>", "Link"]
        guard parts.count >= 5, parts[2] == "Interface", parts[4] == "Link" else { return nil }
        return String(parts[3])
    }

    // MARK: - NWPathMonitor fallback
    private func setupNWPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }

            let nwEthernetActive = path.availableInterfaces.contains { $0.type == .wiredEthernet }

            self.monitorQueue.async { [weak self] in
                guard let self else { return }
                guard nwEthernetActive != self.currentStatus else {
                    Self.log("NWPathMonitor: No discrepancy (ethernetActive=\(nwEthernetActive))")
                    return
                }

                // A discrepancy is a signal that our cached view of the hardware may be
                // wrong — e.g. an adapter appeared and NWPathMonitor sees its wired path
                // while the cached Ethernet set predates it — so re-enumerate before
                // re-evaluating.
                //
                // The rebuild is throttled on the same clock the store-change path uses.
                // A discrepancy is NOT necessarily transient: a cable linked at the
                // switch but with no usable path (no DHCP lease, no carrier config)
                // leaves SCDynamicStore reporting Active=true while the interface never
                // enters 'path.availableInterfaces', so the two disagree persistently.
                // Every subsequent path update then re-ran the full
                // SCNetworkInterfaceCopyAll() enumeration and emitted another log line.
                // Re-evaluating on each update is cheap and still correct; only the
                // enumeration needs rate limiting.
                let now = ProcessInfo.processInfo.systemUptime
                if now - self.lastInterfaceRebuild >= self.interfaceRebuildThrottle {
                    self.lastInterfaceRebuild = now
                    Self.log("NWPathMonitor discrepancy: NW reports ethernetActive=\(nwEthernetActive), currentStatus=\(self.currentStatus). Rebuilding and re-evaluating.")
                    self.buildInterfaceList()
                } else {
                    Self.log("NWPathMonitor discrepancy: NW reports ethernetActive=\(nwEthernetActive), currentStatus=\(self.currentStatus). Re-evaluating (rebuild throttled).")
                }
                self.evaluateStatus()
            }
        }
        // Assign before start(): the update handler fires on 'nwQueue', potentially
        // before start() returns, and publishing the reference first keeps the
        // "nwMonitor is only ever observed fully-formed" invariant intact.
        nwMonitor = monitor
        monitor.start(queue: nwQueue)
    }

    // MARK: - Public helper
    // Rebuilds the interface list (to pick up any hardware changes since last
    // check) then re-evaluates connectivity. Called explicitly on wake from sleep.
    func refreshStatus() {
        monitorQueue.async { [weak self] in
            self?.buildInterfaceList()
            self?.evaluateStatus()
        }
    }
}

// Owned by SCDynamicStore via its context retain/release callbacks. Holding the
// monitor weakly means the store never keeps it alive and a late callback after
// deinit resolves to 'nil' instead of a freed object.
private final class StoreCallbackBox {
    weak var monitor: EthernetMonitor?
    init(monitor: EthernetMonitor) { self.monitor = monitor }
}

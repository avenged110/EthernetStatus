// MARK: – AppDelegate.swift
// Copyright © 2025 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Contains: the app entry point (@main on AppDelegate), AppState, and AppDelegate.
// The Settings window is now the shared SettingsWindowController (SettingsKit.swift).

import Cocoa
import SwiftUI

// MARK: – AppState
// Single source of truth for live network status. Written by AppDelegate's
// EthernetMonitor callback; observed reactively by StatusMenuController.
// '@Observable' (macOS 14+) gives automatic, fine-grained change tracking.
// '@MainActor' guarantees all mutations occur on the main thread.

@MainActor @Observable
final class AppState {
    var isConnected: Bool = false
    var activeInterface: String? = nil
    var ipv4Address: String? = nil
}

// MARK: – AppDelegate

// Plain AppKit entry point, as in Toggler. A SwiftUI `App` needs at least one Scene, and
// an empty WindowGroup is not free: closing its window at launch only works once, because
// SwiftUI re-creates the 0×0 window on every reopen event (launching the app again while
// it is running, e.g. from Xcode, Finder or the Dock), and Mission Control then lists
// that invisible window under "Ethernet Status". With no Scene there is nothing to re-create.
@main
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, Loggable {
    nonisolated static let logTag = "[AD]"

    // MARK: - Entry point

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    let appState = AppState()

    private var statusMenuController: EthernetStatusMenu!

    // The shared Settings window (SettingsKit.swift). One tab, so the tab bar is
    // hidden and the content is hosted directly. `.centered` placement and no focus sink
    // preserve today's open-time behavior. Built in applicationDidFinishLaunching rather
    // than in a stored-property initializer (the latter trips a SILGen crash in the
    // current toolchain on the @ViewBuilder tab closure).
    private(set) var settingsWindowController: SettingsWindowController!

    private static func makeSettingsWindowController() -> SettingsWindowController {
        SettingsWindowController(.init(
            title: "Ethernet Status Settings",
            sizing: .fitToContent(width: 500),
            tabs: [
                .swiftUI(id: "general", title: "General", symbol: "gearshape") { GeneralTabView() },
            ],
            tabBar: .hidden,
            placement: .centered,
            usesFocusSink: true,
            installsTemporaryMainMenu: false))
    }

    private var ethernetMonitor: EthernetMonitor?

    // Task-based debounce for wake events. Stored as Task<Void, Never>? so it can
    // be canceled and replaced on rapid successive wake notifications without
    // touching DispatchWorkItem, which requires non-isolated @Sendable closures
    // and would produce Swift 6 actor-isolation errors for @MainActor-isolated
    // property accesses inside the block.
    private var wakeDebounceTask: Task<Void, Never>?

    // In-flight IPv4 retry poll. Kept so a new connection event can cancel a poll
    // still running for a previous one; otherwise rapid link flapping accumulates
    // overlapping 90-second polling tasks that all race to write AppState.
    private var addressRetryTask: Task<Void, Never>?

    // Set once applicationShouldTerminate has begun the deferred shutdown, so a second
    // quit request while the logger's final flush is in flight is a no-op rather than a
    // concurrent second teardown.
    private var isTerminating = false
    private var hasRepliedToTerminate = false

    private let appVersionBuild: String = {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }()

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Defaults must be registered before the first preference read.
        // prepareLogDirectory() reads 'loggingEnabled', so it has to come second;
        // previously it ran first and happened to agree only because an unregistered
        // Bool read also yields false.
        Preferences.ensureDefaultsRegistered()
        // Bootstrap the shared logger before the first log line. Ethernet Status's own
        // 5 MiB cap and millisecond timestamps are passed explicitly so on-disk output is
        // byte-identical to the previous local Logger. prepareLogDirectory() reads the
        // enabled predicate, so it must follow both this and the defaults registration.
        Logger.bootstrap(.init(fileName: "EthernetStatus.log",
                               destination: .containerLibraryLogs,
                               isEnabled: { Preferences.loggingEnabled },
                               maxFileSizeBytes: 5 * 1024 * 1024,
                               timestampFormat: "yyyy-MM-dd'T'HH:mm:ss.SSS"))
        Logger.prepareLogDirectory()
        log("Ethernet Status \(appVersionBuild) launched.")

        settingsWindowController = Self.makeSettingsWindowController()
        statusMenuController = EthernetStatusMenu(
            appState: appState,
            settingsWindowController: settingsWindowController)
        statusMenuController.install()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(handleWake(_:)),
            name: NSWorkspace.didWakeNotification, object: nil)

        setupEthernetMonitor()
    }

    // Shutdown is deferred with '.terminateLater' so the logger's final flush can be
    // awaited. The previous arrangement lost every line it wrote: shutdownLogging()
    // canceled the flush loop and dispatched a detached write, and the six log calls
    // that followed it (this method's own "Cleanup complete" line plus all of
    // applicationWillTerminate) landed in a buffer that nothing would ever flush again.
    // Termination logs — the most valuable ones when diagnosing a quit-time hang — were
    // therefore never on disk. Awaiting 'shutdownLoggingAwaiting()', whose terminal
    // flush writes inline rather than through a detached task, makes them durable.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Guard against AppKit calling this twice (e.g. a second Quit while the first
        // is still in flight); the teardown below is not written to run concurrently.
        guard !isTerminating else { return .terminateLater }
        isTerminating = true

        log("applicationShouldTerminate: Beginning controlled shutdown.")

        performTeardown()
        log("Ethernet Status \(appVersionBuild) terminating.")

        // Two racers, whichever finishes first replies. '.terminateLater' hands AppKit
        // the decision to quit, so if the final flush ever stalled (a wedged network
        // volume behind the container, a filesystem hang) the app would sit there
        // refusing to quit with no UI to explain itself. Losing the last few log lines
        // is a far better outcome than an unquittable menu-bar app, so the wait is
        // capped and termination proceeds either way.
        //
        // Both tasks are @MainActor-isolated, so 'replyToTerminateOnce()' serializes
        // them without any additional synchronization.
        Task { @MainActor [weak self] in
            await Logger.shutdownLoggingAwaiting()
            self?.replyToTerminateOnce()
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.replyToTerminateOnce()
        }
        return .terminateLater
    }

    // NSApp.reply(toApplicationShouldTerminate:) must be called exactly once.
    private func replyToTerminateOnce() {
        guard !hasRepliedToTerminate else { return }
        hasRepliedToTerminate = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    // Safety net for the termination paths that bypass applicationShouldTerminate.
    // performTeardown() is idempotent, so running it twice costs nothing.
    func applicationWillTerminate(_ notification: Notification) {
        performTeardown()
    }

    // All teardown, in one idempotent place.
    private func performTeardown() {
        wakeDebounceTask?.cancel()
        wakeDebounceTask = nil
        addressRetryTask?.cancel()
        addressRetryTask = nil

        NSWorkspace.shared.notificationCenter.removeObserver(self)

        statusMenuController?.markTerminating()
        statusMenuController?.prepareForTerminationSynchronously()
        statusMenuController = nil

        // Tear the monitor down explicitly rather than relying on deinit: the run-loop
        // source holds an unretained pointer to it, so teardown must be deterministic
        // and must happen before the last reference is dropped.
        ethernetMonitor?.stopMonitoring()
        ethernetMonitor = nil
    }

    // MARK: - Wake Handler

    @objc private func handleWake(_ notification: Notification) {
        // Cancel any pending wake debounce before scheduling a fresh one.
        // Task.cancel() is safe to call from any isolation context.
        wakeDebounceTask?.cancel()

        // Use a structured-concurrency Task that inherits @MainActor isolation from
        // this method's context. This guarantees accesses to @MainActor-isolated
        // properties (ethernetMonitor) are correctly isolated, eliminating the
        // Swift 6 actor-crossing error that DispatchWorkItem's @Sendable closure
        // would have produced.
        wakeDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            self.ethernetMonitor?.refreshStatus()
        }
    }

    // MARK: - Ethernet Monitor

    private func setupEthernetMonitor() {
        // The EthernetMonitor callback is typed '@MainActor', so this @MainActor-
        // isolated context (AppDelegate) can pass a [weak self] closure that directly
        // accesses @MainActor-isolated state (AppState properties) with no @Sendable
        // constraint. retryIPv4Address is now an async function; its result is awaited
        // inside a Task that inherits the @MainActor context from the callback.
        ethernetMonitor = EthernetMonitor { [weak self] connected, interface in
            guard let self else { return }

            self.appState.isConnected = connected
            self.appState.activeInterface = interface

            // Any previous poll belongs to a superseded connection event.
            self.addressRetryTask?.cancel()
            self.addressRetryTask = nil

            // Resolve the address unconditionally rather than only when the
            // 'Show IP Address' preference is on. The preference governs whether the
            // address row is *displayed*, not whether the value is known; tying the
            // resolution to it meant that enabling the preference mid-session left
            // AppState holding a nil address until the next connectivity change,
            // which the menu then reported as "No Ethernet-based IP Address".
            let addr = InterfaceReader.ipv4Address(forInterface: interface)
            self.appState.ipv4Address = addr

            if connected && addr == nil, let iface = interface {
                // retryIPv4Address is an async function that returns the resolved
                // address (or nil). A non-detached Task inherits this closure's
                // @MainActor context, so the await and the subsequent AppState write
                // both execute on the main actor with no closure-capture involved.
                self.addressRetryTask = Task { [weak self] in
                    let addrRetry = await InterfaceReader.retryIPv4Address(forInterface: iface)
                    guard !Task.isCancelled, let self else { return }
                    // Guard against assigning a stale address: only update if the
                    // interface that triggered the retry is still the active one and
                    // we are still connected. Without this check, an address resolved
                    // from a previous connection cycle could overwrite the current state
                    // if the cable was pulled and re-plugged during the retry window.
                    guard self.appState.isConnected,
                          self.appState.activeInterface == iface else { return }
                    self.appState.ipv4Address = addrRetry
                }
            }
        }

        // No initial refreshStatus() is needed: EthernetMonitor's setup enumerates the
        // interfaces and evaluates status itself once the dynamic store is created.
    }
}

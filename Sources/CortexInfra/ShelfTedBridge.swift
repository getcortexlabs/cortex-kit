import AppKit
import Combine
import Foundation

/// Optional, local presence bridge between the two native apps. It never opens
/// the peer, contacts Ted's daemon, or sends user data. No idle polling.
@MainActor
public final class ShelfTedBridge: NSObject, ObservableObject {
    @Published public private(set) var state: ShelfTedConnectionState = .stopped
    public let app: ShelfTedApp

    private var handshake: ShelfTedHandshake
    private var started = false
    private var timeout: Task<Void, Never>?
    private var timeoutNonce: UUID?
    private let center = DistributedNotificationCenter.default()
    private let workspace = NSWorkspace.shared
    private let notificationName: Notification.Name
    private let discovery: () -> (installed: Bool, pid: Int32?)

    public convenience init(app: ShelfTedApp) {
        self.init(app: app, notificationName: Notification.Name("app.cortex.shelf-ted.presence")) {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.peer.rawValue)
                .first(where: { !$0.isTerminated })
            let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.peer.rawValue)
                .map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            return (installed || running != nil, running?.processIdentifier)
        }
    }

    // Isolated discovery/name let a two-process smoke test exercise the real
    // transport without registering either app's identity in Launch Services.
    init(app: ShelfTedApp, notificationName: Notification.Name,
         discovery: @escaping () -> (installed: Bool, pid: Int32?)) {
        self.app = app
        self.notificationName = notificationName
        self.discovery = discovery
        handshake = ShelfTedHandshake(app: app, pid: ProcessInfo.processInfo.processIdentifier)
        super.init()
    }

    public func start() {
        guard !started else { return }
        started = true
        center.addObserver(self, selector: #selector(receive(_:)), name: notificationName,
                           object: app.rawValue, suspensionBehavior: .deliverImmediately)
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspace.notificationCenter.addObserver(self, selector: #selector(appChanged(_:)),
                                                     name: name, object: nil)
        }
        workspace.notificationCenter.addObserver(self, selector: #selector(woke),
                                                 name: NSWorkspace.didWakeNotification, object: nil)
        Foundation.NotificationCenter.default.addObserver(self, selector: #selector(activated),
                                                          name: NSApplication.didBecomeActiveNotification, object: nil)
        refresh()
    }

    public func stop() {
        guard started else { return }
        started = false
        post(handshake.stop())
        center.removeObserver(self)
        workspace.notificationCenter.removeObserver(self)
        Foundation.NotificationCenter.default.removeObserver(self)
        synchronize()
    }

    /// Refresh installation/running state on demand. Healthy connections don't
    /// send another handshake on ordinary activation events.
    public func refresh() { discover(force: false) }

    private func discover(force: Bool) {
        guard started else { return }
        let peer = discovery()
        let outgoing = handshake.discover(installed: peer.installed, runningPID: peer.pid, force: force)
        synchronize()
        outgoing.forEach(post)
    }

    @objc private func appChanged(_ notification: Notification) {
        guard let changed = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              changed.bundleIdentifier == app.peer.rawValue else { return }
        refresh()
    }

    @objc private func woke() { discover(force: true) }
    @objc private func activated() { refresh() }

    @objc private func receive(_ notification: Notification) {
        guard started,
              let json = notification.userInfo?["message"] as? String,
              json.utf8.count <= 1_024,
              let data = json.data(using: .utf8),
              let message = try? JSONDecoder().decode(ShelfTedMessage.self, from: data) else { return }
        let outgoing = handshake.receive(message, runningPID: discovery().pid)
        synchronize()
        outgoing.forEach(post)
    }

    private func post(_ message: ShelfTedMessage) {
        guard let data = try? JSONEncoder().encode(message),
              let json = String(data: data, encoding: .utf8) else { return }
        center.postNotificationName(notificationName, object: app.peer.rawValue,
                                    userInfo: ["message": json], deliverImmediately: true)
    }

    private func synchronize() {
        if state != handshake.state { state = handshake.state }
        guard timeoutNonce != handshake.pending else { return }
        timeout?.cancel()
        timeout = nil
        timeoutNonce = handshake.pending
        guard let nonce = handshake.pending else { return }
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self, self.started else { return }
            self.handshake.timedOut(nonce)
            self.synchronize()
        }
    }
}

import Foundation

public enum ShelfTedApp: String, Codable, Sendable {
    case shelf = "shelf.cortex.app"
    case ted = "ted.cortex.app"

    public var peer: ShelfTedApp { self == .shelf ? .ted : .shelf }
}

public enum ShelfTedConnectionState: Equatable, Sendable {
    case stopped
    case notInstalled
    /// Installed, but the other app is closed.
    case available
    case connecting
    case connected
    /// Running without a bridge response (for example, an older app).
    case unavailable
    case incompatible
}

/// Presence metadata only. Distributed notifications do NOT authenticate a sender;
/// never add user content, commands, or permissions to this protocol.
struct ShelfTedMessage: Codable, Equatable, Sendable {
    enum Kind: String, Codable { case hello, reply, goodbye }
    static let protocolVersion = 1

    let version: Int
    let sender: ShelfTedApp
    let pid: Int32
    let kind: Kind
    let nonce: UUID
}

/// Independent of AppKit so lifecycle races can be exercised without launching
/// apps or registering anything with Launch Services.
struct ShelfTedHandshake {
    let app: ShelfTedApp
    let pid: Int32
    private(set) var state: ShelfTedConnectionState = .stopped
    private(set) var peerPID: Int32?
    private(set) var pending: UUID?

    mutating func discover(installed: Bool, runningPID: Int32?, force: Bool = false) -> [ShelfTedMessage] {
        guard installed || runningPID != nil else {
            reset(to: .notInstalled)
            return []
        }
        guard let runningPID else {
            reset(to: .available)
            return []
        }
        guard force || peerPID != runningPID || state == .stopped else { return [] }
        peerPID = runningPID
        state = .connecting
        let nonce = UUID()
        pending = nonce
        return [message(.hello, nonce: nonce)]
    }

    mutating func receive(_ incoming: ShelfTedMessage, runningPID: Int32?) -> [ShelfTedMessage] {
        guard state != .stopped, incoming.sender == app.peer,
              incoming.pid > 0, incoming.pid == runningPID else { return [] }
        // Replies must belong to this attempt, including version negotiation.
        if incoming.kind == .reply {
            guard incoming.pid == peerPID, incoming.nonce == pending else { return [] }
            pending = nil
            state = incoming.version == ShelfTedMessage.protocolVersion ? .connected : .incompatible
            return []
        }
        if incoming.kind == .goodbye {
            guard incoming.pid == peerPID else { return [] }
            // Don't reconnect to a bridge that has intentionally stopped until
            // it announces itself again or the app process changes.
            pending = nil
            state = .unavailable
            return []
        }
        var outgoing = [message(.reply, nonce: incoming.nonce)]
        guard incoming.version == ShelfTedMessage.protocolVersion else {
            peerPID = incoming.pid
            pending = nil
            state = .incompatible
            return outgoing
        }
        // A hello also discovers a late-starting/restarted bridge. Each side
        // requires its own correlated reply before reporting connected.
        if peerPID != incoming.pid || (pending == nil && state != .connected) {
            outgoing += discover(installed: true, runningPID: incoming.pid, force: true)
        }
        return outgoing
    }

    mutating func timedOut(_ nonce: UUID) {
        guard pending == nonce else { return }
        pending = nil
        state = .unavailable
    }

    mutating func stop() -> ShelfTedMessage {
        reset(to: .stopped)
        return message(.goodbye, nonce: UUID())
    }

    private mutating func reset(to state: ShelfTedConnectionState) {
        self.state = state
        peerPID = nil
        pending = nil
    }

    private func message(_ kind: ShelfTedMessage.Kind, nonce: UUID) -> ShelfTedMessage {
        ShelfTedMessage(version: ShelfTedMessage.protocolVersion, sender: app,
                        pid: pid, kind: kind, nonce: nonce)
    }
}

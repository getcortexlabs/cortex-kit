import AppKit
import Combine
import Foundation

/// Compiled with the two bridge sources by scripts/test-shelf-ted-bridge.py.
/// Fixture PIDs and a unique notification name isolate it from installed apps.
@main
@MainActor
struct Probe {
    static func main() throws {
        let app: ShelfTedApp = CommandLine.arguments[1] == "shelf" ? .shelf : .ted
        let directory = URL(fileURLWithPath: CommandLine.arguments[2])
        let pidFile = directory.appendingPathComponent(app.rawValue)
        let peerFile = directory.appendingPathComponent(app.peer.rawValue)
        try String(ProcessInfo.processInfo.processIdentifier).write(to: pidFile, atomically: true, encoding: .utf8)
        let channel = directory.deletingLastPathComponent().lastPathComponent + "." + directory.lastPathComponent
        let bridge = ShelfTedBridge(app: app, notificationName: Notification.Name(channel)) {
            let pid = (try? String(contentsOf: peerFile, encoding: .utf8)).flatMap(Int32.init)
            return (true, pid)
        }
        var connections = 0
        var disconnected = false
        let observation = bridge.$state.sink { state in
            print("\(app): \(state)")
            if state == .unavailable { disconnected = true }
            guard state == .connected else { return }
            connections += 1
            if connections == 1 && app == .ted {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    bridge.stop()
                    bridge.stop() // teardown is idempotent
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        bridge.start()
                        bridge.start() // startup is idempotent
                    }
                }
            }
            if connections == 2 {
                // Allow both sides to finish their handshake before stopping.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    guard app == .ted || disconnected else { exit(2) }
                    bridge.stop()
                    exit(0)
                }
            }
        }
        bridge.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            print("FAIL: \(app) only completed \(connections) connections")
            bridge.stop()
            exit(1)
        }
        withExtendedLifetime((bridge, observation)) { RunLoop.main.run() }
    }
}

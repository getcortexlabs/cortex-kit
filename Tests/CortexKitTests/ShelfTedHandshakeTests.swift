import Foundation
import Testing
@testable import CortexInfra

@Suite("Shelf–Ted presence")
struct ShelfTedHandshakeTests {
    private func packet(_ kind: ShelfTedMessage.Kind = .reply, nonce: UUID,
                        pid: Int32 = 20, version: Int = 1, sender: ShelfTedApp = .ted) -> ShelfTedMessage {
        ShelfTedMessage(version: version, sender: sender, pid: pid, kind: kind, nonce: nonce)
    }

    @Test func absentAndClosedAppsNeedNoMessages() {
        var shelf = ShelfTedHandshake(app: .shelf, pid: 10)
        #expect(shelf.discover(installed: false, runningPID: nil).isEmpty)
        #expect(shelf.state == .notInstalled)
        #expect(shelf.discover(installed: true, runningPID: nil).isEmpty)
        #expect(shelf.state == .available)
        #expect(shelf.pending == nil)
    }

    @Test(arguments: [ShelfTedApp.shelf, .ted])
    func eitherAppCanStartFirst(first: ShelfTedApp) throws {
        var early = ShelfTedHandshake(app: first, pid: 10)
        var late = ShelfTedHandshake(app: first.peer, pid: 20)
        _ = early.discover(installed: true, runningPID: nil)
        let hello = try #require(late.discover(installed: true, runningPID: 10).first)
        let answers = early.receive(hello, runningPID: 20)
        #expect(early.state == .connecting)
        #expect(answers.count == 2)
        for answer in answers {
            for response in late.receive(answer, runningPID: 10) {
                _ = early.receive(response, runningPID: 20)
            }
        }
        #expect(early.state == .connected)
        #expect(late.state == .connected)
        #expect(early.pending == nil && late.pending == nil)
        #expect(early.discover(installed: true, runningPID: 20).isEmpty)
        #expect(late.discover(installed: true, runningPID: 10).isEmpty)
    }

    @Test func simultaneousStartupConvergesWithoutMessageLoop() throws {
        var shelf = ShelfTedHandshake(app: .shelf, pid: 10)
        var ted = ShelfTedHandshake(app: .ted, pid: 20)
        let fromShelf = try #require(shelf.discover(installed: true, runningPID: 20).first)
        let fromTed = try #require(ted.discover(installed: true, runningPID: 10).first)
        let shelfReply = try #require(shelf.receive(fromTed, runningPID: 20).first)
        let tedReply = try #require(ted.receive(fromShelf, runningPID: 10).first)
        #expect(shelf.receive(tedReply, runningPID: 20).isEmpty)
        #expect(ted.receive(shelfReply, runningPID: 10).isEmpty)
        #expect(shelf.state == .connected && ted.state == .connected)
    }

    @Test func unsolicitedStaleAndWrongPeerRepliesCannotConnect() throws {
        var shelf = ShelfTedHandshake(app: .shelf, pid: 10)
        let hello = try #require(shelf.discover(installed: true, runningPID: 20).first)
        for reply in [packet(nonce: UUID()), packet(nonce: hello.nonce, pid: 21),
                      packet(nonce: hello.nonce, sender: .shelf)] {
            #expect(shelf.receive(reply, runningPID: 20).isEmpty)
            #expect(shelf.state == .connecting)
        }
        _ = shelf.receive(packet(nonce: hello.nonce), runningPID: nil)
        #expect(shelf.state == .connecting)
        _ = shelf.discover(installed: true, runningPID: 20, force: true)
        _ = shelf.receive(packet(nonce: hello.nonce), runningPID: 20)
        shelf.timedOut(hello.nonce)
        #expect(shelf.state == .connecting)
    }

    @Test func oldAppTimesOutWithoutRetryPollingAndLateBridgeRecovers() throws {
        var shelf = ShelfTedHandshake(app: .shelf, pid: 10)
        let hello = try #require(shelf.discover(installed: true, runningPID: 20).first)
        shelf.timedOut(hello.nonce)
        #expect(shelf.state == .unavailable)
        #expect(shelf.discover(installed: true, runningPID: 20).isEmpty)
        _ = shelf.receive(packet(nonce: hello.nonce), runningPID: 20)
        #expect(shelf.state == .unavailable)
        let recovery = shelf.receive(packet(.hello, nonce: UUID()), runningPID: 20)
        let probe = try #require(recovery.first(where: { $0.kind == .hello }))
        _ = shelf.receive(packet(nonce: probe.nonce), runningPID: 20)
        #expect(shelf.state == .connected)
    }

    @Test func incompatibleVersionsNeverConnect() throws {
        var shelf = ShelfTedHandshake(app: .shelf, pid: 10)
        let hello = try #require(shelf.discover(installed: true, runningPID: 20).first)
        _ = shelf.receive(packet(nonce: hello.nonce, version: 2), runningPID: 20)
        #expect(shelf.state == .incompatible)
        #expect(shelf.pending == nil)
        let response = shelf.receive(packet(.hello, nonce: UUID(), version: 2), runningPID: 20)
        #expect(response.count == 1 && response.first?.kind == .reply)
        #expect(shelf.state == .incompatible)
    }

    @Test func exitAndRestartInvalidatePreviousConnection() throws {
        var shelf = ShelfTedHandshake(app: .shelf, pid: 10)
        let old = try #require(shelf.discover(installed: true, runningPID: 20).first)
        _ = shelf.receive(packet(nonce: old.nonce), runningPID: 20)
        #expect(shelf.state == .connected)
        _ = shelf.discover(installed: true, runningPID: nil)
        #expect(shelf.state == .available)
        let new = try #require(shelf.discover(installed: true, runningPID: 21).first)
        _ = shelf.receive(packet(nonce: old.nonce), runningPID: 21)
        #expect(shelf.state == .connecting)
        _ = shelf.receive(packet(nonce: new.nonce, pid: 21), runningPID: 21)
        #expect(shelf.state == .connected)
        _ = shelf.discover(installed: false, runningPID: nil)
        #expect(shelf.state == .notInstalled)
    }

    @Test func stoppedBridgeIgnoresMessagesAndCanStartAgain() throws {
        var shelf = ShelfTedHandshake(app: .shelf, pid: 10)
        let old = try #require(shelf.discover(installed: true, runningPID: 20).first)
        #expect(shelf.stop().kind == .goodbye)
        #expect(shelf.state == .stopped && shelf.pending == nil)
        #expect(shelf.receive(packet(.hello, nonce: UUID()), runningPID: 20).isEmpty)
        _ = shelf.receive(packet(nonce: old.nonce), runningPID: 20)
        #expect(shelf.state == .stopped)
        #expect(shelf.discover(installed: true, runningPID: 20).count == 1)
        #expect(shelf.state == .connecting)
    }

    @Test func goodbyeClearsPendingHandshake() throws {
        var shelf = ShelfTedHandshake(app: .shelf, pid: 10)
        let hello = try #require(shelf.discover(installed: true, runningPID: 20).first)
        _ = shelf.receive(packet(.goodbye, nonce: UUID()), runningPID: 20)
        #expect(shelf.state == .unavailable && shelf.pending == nil)
        _ = shelf.receive(packet(nonce: hello.nonce), runningPID: 20)
        #expect(shelf.state == .unavailable)
        #expect(shelf.discover(installed: true, runningPID: 20).isEmpty)
    }
}

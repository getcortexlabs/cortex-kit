import Testing
import Foundation
@testable import CortexInfra

@Suite("ShelfTedAnnouncement")
struct ShelfTedAnnouncementTests {
    private func make(title: String = "Ted", body: String? = nil,
                      action: ShelfTedAnnouncement.Action? = nil) -> ShelfTedAnnouncement {
        ShelfTedAnnouncement(sender: .ted, title: title, body: body, urgency: .important, action: action)
    }

    /// Uma pílula é uma linha só: `\n` viraria texto cortado ou espaço fantasma.
    @Test func stripsNewlinesAndControlCharacters() {
        #expect(ShelfTedAnnouncement.clean("a\nb\tc", limit: 40) == "a b c")
        #expect(ShelfTedAnnouncement.clean("x\u{0007}y", limit: 40) == "xy")
    }

    @Test func collapsesWhitespace() {
        #expect(ShelfTedAnnouncement.clean("   muito     espaço   ", limit: 40) == "muito espaço")
    }

    /// O teto é o que impede um remetente de esticar a pílula pela tela toda.
    @Test func truncatesAtTheLimitAndMarksIt() {
        let long = String(repeating: "a", count: 200)
        let out = ShelfTedAnnouncement.clean(long, limit: 10)
        #expect(out.count == 10)
        #expect(out.hasSuffix("…"))
    }

    @Test func dropsAnnouncementWithoutATitle() {
        #expect(make(title: "   ").sanitized() == nil)
        #expect(make(title: "\n\n").sanitized() == nil)
    }

    @Test func keepsAGoodAnnouncementIntact() throws {
        let clean = try #require(make(title: "Reunião em 5 min", body: "Com a squad").sanitized())
        #expect(clean.title == "Reunião em 5 min")
        #expect(clean.body == "Com a squad")
    }

    /// Um anúncio nunca pode abrir `file://` — mesmo vindo de um par verificado,
    /// um bug do outro lado não pode virar execução local.
    @Test func rejectsActionsWithDisallowedSchemes() throws {
        let bad = ShelfTedAnnouncement.Action(label: "Abrir", url: URL(string: "file:///etc/passwd")!)
        let clean = try #require(make(action: bad).sanitized())
        #expect(clean.action == nil)
    }

    @Test func keepsActionsOnPurposeBuiltSchemes() throws {
        for scheme in ["https://example.com", "cortexshelf://open/notes", "ted://thread/9"] {
            let action = ShelfTedAnnouncement.Action(label: "Ver", url: URL(string: scheme)!)
            let clean = try #require(make(action: action).sanitized())
            #expect(clean.action != nil, "esquema \(scheme) devia passar")
        }
    }

    @Test func dropsActionWithoutALabel() throws {
        let action = ShelfTedAnnouncement.Action(label: "  ", url: URL(string: "https://x.com")!)
        #expect(try #require(make(action: action).sanitized()).action == nil)
    }
}

@Suite("ShelfTedLink")
struct ShelfTedLinkTests {
    /// Cada teste com o seu socket: o caminho real é compartilhado pelo usuário,
    /// e dois testes disputando o mesmo nó falhariam um ao outro.
    private func tempSocket() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ted-\(UUID().uuidString.prefix(8)).sock").path
    }

    /// Ida e volta de verdade: socket real, processo real (nós mesmos).
    @Test func deliversAnAnnouncementOverTheSocket() async throws {
        let path = tempSocket()
        let received = Mailbox()
        let listener = ShelfTedListener(socketPath: path) { received.put($0) }
        try listener.start()
        defer { listener.stop() }

        try ShelfTedLink.send(ShelfTedAnnouncement(
            sender: .ted, title: "Ted tem algo", body: "três e-mails importantes", urgency: .important), to: path)

        let got = try #require(await received.wait(), "o anúncio não chegou")
        #expect(got.title == "Ted tem algo")
        #expect(got.urgency == .important)
        #expect(got.sender == .ted)
    }

    /// O que chega é limpo na entrada, não na hora de desenhar.
    @Test func sanitizesOnArrival() async throws {
        let path = tempSocket()
        let received = Mailbox()
        let listener = ShelfTedListener(socketPath: path) { received.put($0) }
        try listener.start()
        defer { listener.stop() }

        try ShelfTedLink.send(ShelfTedAnnouncement(
            sender: .ted, title: "linha\numa\nsó", urgency: .normal,
            action: .init(label: "Abrir", url: URL(string: "file:///tmp")!)), to: path)

        let got = try #require(await received.wait())
        #expect(!got.title.contains("\n"))
        #expect(got.action == nil)
    }

    /// Sem ninguém escutando, falha na hora — nada fica em fila. Um aviso atrasado
    /// na notch é ruído.
    @Test func failsFastWhenNobodyIsListening() throws {
        #expect(throws: ShelfTedLink.LinkError.peerUnavailable) {
            try ShelfTedLink.send(ShelfTedAnnouncement(sender: .ted, title: "ninguém em casa"),
                                  to: tempSocket())
        }
    }

    /// Dois listeners não podem disputar o mesmo socket — o segundo tem que
    /// recusar, em vez de roubar o nó do primeiro.
    @Test func refusesToStealAnotherListenersSocket() throws {
        let path = tempSocket()
        let first = ShelfTedListener(socketPath: path) { _ in }
        try first.start()
        defer { first.stop() }
        let second = ShelfTedListener(socketPath: path) { _ in }
        #expect(throws: ShelfTedLink.LinkError.alreadyListening) { try second.start() }
    }

    /// Um socket órfão (resto de crash) não pode impedir o app de subir.
    @Test func reclaimsAStaleSocketFile() throws {
        let path = tempSocket()
        FileManager.default.createFile(atPath: path, contents: Data())
        defer { unlink(path) }
        let listener = ShelfTedListener(socketPath: path) { _ in }
        try listener.start()          // não deve lançar
        listener.stop()
    }
}

/// Caixa de correio thread-safe: o listener entrega numa fila de fundo.
private final class Mailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ShelfTedAnnouncement?

    func put(_ a: ShelfTedAnnouncement) { lock.lock(); defer { lock.unlock() }; value = a }

    /// `withLock` em vez de lock/unlock soltos: travar manualmente é indisponível
    /// em contexto async no Swift 6.
    private var current: ShelfTedAnnouncement? { lock.withLock { value } }

    func wait(timeout: TimeInterval = 3) async -> ShelfTedAnnouncement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let current { return current }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }
}

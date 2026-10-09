import Foundation
import Security
import os

/// Canal local AUTENTICADO entre os apps da família — o único caminho por onde
/// conteúdo do usuário pode trafegar.
///
/// Por que não reusar o `ShelfTedBridge`: aquele anda por notificação distribuída,
/// que **não autentica remetente**. Serve pra presença (hello/reply/goodbye, sem
/// conteúdo), e o próprio arquivo avisa pra nunca pôr conteúdo ali. Se um anúncio
/// viajasse por lá, qualquer processo do Mac poderia escrever na notch — uma
/// superfície que o usuário lê como se fosse o sistema falando. Daí este socket.
///
/// Como a confiança é estabelecida, em três camadas:
///  1. o socket vive num diretório 0700 do usuário e o próprio nó é 0600;
///  2. o par tem que ser o MESMO UID (`LOCAL_PEERCRED`);
///  3. o par tem que satisfazer um requisito de assinatura de código, obtido pelo
///     **audit token** da conexão (`LOCAL_PEERTOKEN`) — e não pelo PID, que pode
///     ser reusado entre o accept e a checagem.
public enum ShelfTedLink {
    private static let log = Logger(subsystem: "app.cortex.infra", category: "ted-link")

    /// `os_log` desta camada não aparece no `log show`/`log stream` em build
    /// avulso, o que deixou um bug de aceitação invisível por horas. Com
    /// CORTEX_LINK_DEBUG=1 cada passo sai no stderr, que sempre aparece.
    static let debug = ProcessInfo.processInfo.environment["CORTEX_LINK_DEBUG"] != nil
    static func trace(_ message: @autoclosure () -> String) {
        guard debug else { return }
        FileHandle.standardError.write(Data("[ted-link] \(message())\n".utf8))
    }

    /// Onde o socket mora. Diretório compartilhado pela família, 0700.
    public static func socketURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("Cortex", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("shelf-ted.sock", isDirectory: false)
    }

    /// Requisito de assinatura exigido do par.
    static let teamRequirement = "anchor apple generic and certificate leaf[subject.OU] = \"7CHG584VYB\""

    /// O time que assina ESTE binário, se houver. Um build de dev (`swift build`)
    /// é ad-hoc e devolve nil.
    static func ownTeamIdentifier() -> String? {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var statik: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &statik) == errSecSuccess, let statik else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(statik, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Se nós mesmos somos assinados por um time, exigimos o mesmo do par. Num
    /// build de dev (ad-hoc, sem time) exigir isso tornaria o canal impossível de
    /// usar — e também não haveria o que proteger, já que o binário local não é o
    /// distribuído. A política se auto-ajusta: **um app notarizado sempre exige**.
    static var enforcesCodeIdentity: Bool { ownTeamIdentifier() != nil }
}

// MARK: - Verificação do par

extension ShelfTedLink {
    /// Decide se aceita quem está do outro lado de `fd`. Devolve o motivo da
    /// recusa pra ficar no log — um canal silencioso é impossível de depurar.
    /// Observado a cada conexão: o audit token do par estava disponível?
    ///
    /// Sempre lido, mesmo quando não exigimos identidade, porque é o ÚNICO jeito
    /// de um teste cobrir a corrida que derrubou isto em produção — num teste os
    /// binários são ad-hoc, a verificação de assinatura nem roda, e o caminho do
    /// token ficava invisível.
    nonisolated(unsafe) private(set) static var lastPeerHadAuditToken: Bool?

    static func authorize(_ fd: Int32) -> Result<Void, PeerRejection> {
        var euid = uid_t(0), egid = gid_t(0)
        guard getpeereid(fd, &euid, &egid) == 0 else { return .failure(.noCredentials) }
        guard euid == getuid() else { return .failure(.otherUser(euid)) }

        var token = audit_token_t()
        var len = socklen_t(MemoryLayout<audit_token_t>.size)
        let gotToken = getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &len) == 0
            && len == socklen_t(MemoryLayout<audit_token_t>.size)
        lastPeerHadAuditToken = gotToken

        guard enforcesCodeIdentity else { return .success(()) }
        guard gotToken else { return .failure(.noAuditToken) }
        let data = withUnsafeBytes(of: token) { Data($0) }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: data] as CFDictionary, [], &code) == errSecSuccess,
              let code else { return .failure(.noCode) }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(teamRequirement as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return .failure(.badRequirement) }
        let status = SecCodeCheckValidity(code, [], requirement)
        guard status == errSecSuccess else { return .failure(.signatureMismatch(status)) }
        return .success(())
    }

    enum PeerRejection: Error, Equatable {
        case noCredentials
        case otherUser(uid_t)
        case noAuditToken
        case noCode
        case badRequirement
        case signatureMismatch(OSStatus)

        var reason: String {
            switch self {
            case .noCredentials: return "sem credenciais do par"
            case .otherUser(let uid): return "outro usuário (uid \(uid))"
            case .noAuditToken: return "sem audit token"
            case .noCode: return "processo não resolvido para um SecCode"
            case .badRequirement: return "requisito inválido"
            case .signatureMismatch(let s): return "assinatura não satisfaz o requisito (\(s))"
            }
        }
    }
}

// MARK: - Endereço

extension ShelfTedLink {
    static func address(for path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < capacity else { throw LinkError.pathTooLong(path.utf8.count) }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            path.withCString { source in
                strlcpy(UnsafeMutableRawPointer(raw).assumingMemoryBound(to: CChar.self), source, capacity)
            }
        }
        return addr
    }

    static func withSockaddr<T>(_ addr: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    public enum LinkError: Error, Equatable {
        case pathTooLong(Int)
        case socketFailed(Int32)
        case bindFailed(Int32)
        case listenFailed(Int32)
        case alreadyListening
        case peerUnavailable
        case sendFailed(Int32)
        case payloadTooLarge(Int)
    }
}

// MARK: - Lado que escuta (o Shelf)

/// Escuta anúncios do par. **Custo ocioso zero**: um `DispatchSource` no fd de
/// escuta só acorda quando alguém conecta — nada tica, nada pergunta em loop.
/// (O Shelf tem um contrato de render-on-demand; um poller aqui o quebraria.)
public final class ShelfTedListener: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.cortex.ted-link.listener")
    private let handler: @Sendable (ShelfTedAnnouncement) -> Void
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let log = Logger(subsystem: "app.cortex.infra", category: "ted-link")

    /// Quanto tempo esperamos o payload de uma conexão aceita. Um par travado não
    /// pode prender a fila; 2s é folgado pra um JSON de alguns KB no mesmo Mac.
    private static let receiveTimeout = timeval(tv_sec: 2, tv_usec: 0)

    /// `socketPath` existe como seam de teste (mesmo padrão do `baseOverride` dos
    /// stores do Shelf): sem ele, testes paralelos disputariam o socket real do
    /// usuário e falhariam um ao outro.
    private let socketPath: String?

    public init(socketPath: String? = nil,
                onAnnouncement: @escaping @Sendable (ShelfTedAnnouncement) -> Void) {
        self.socketPath = socketPath
        self.handler = onAnnouncement
    }

    deinit { stop() }

    public func start() throws {
        guard source == nil else { throw ShelfTedLink.LinkError.alreadyListening }
        let path = try socketPath ?? ShelfTedLink.socketURL().path
        try clearStaleSocket(at: path)

        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw ShelfTedLink.LinkError.socketFailed(errno) }
        var addr = try ShelfTedLink.address(for: path)
        let bound = ShelfTedLink.withSockaddr(&addr) { pointer, length in bind(listener, pointer, length) }
        guard bound == 0 else {
            let code = errno
            close(listener)
            throw ShelfTedLink.LinkError.bindFailed(code)
        }
        // Só o dono conecta. Primeira camada, antes de qualquer checagem de código.
        chmod(path, 0o600)
        guard listen(listener, 8) == 0 else {
            let code = errno
            close(listener)
            unlink(path)
            throw ShelfTedLink.LinkError.listenFailed(code)
        }

        fd = listener
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(listener); unlink(path) }
        self.source = source
        source.resume()
        log.info("ted-link escutando (exige identidade de código: \(ShelfTedLink.enforcesCodeIdentity))")
        ShelfTedLink.trace("escutando em \(path) · exige identidade: \(ShelfTedLink.enforcesCodeIdentity)")
    }

    public func stop() {
        source?.cancel()
        source = nil
        fd = -1
    }

    /// Um socket pode sobrar no disco quando o app morre sem desligar. Conectar
    /// nele distingue "alguém vivo escutando" de "resto de crash": só o resto é
    /// removido, pra nunca roubar o socket de uma instância viva.
    private func clearStaleSocket(at path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw ShelfTedLink.LinkError.socketFailed(errno) }
        defer { close(probe) }
        var addr = try ShelfTedLink.address(for: path)
        let alive = ShelfTedLink.withSockaddr(&addr) { pointer, length in connect(probe, pointer, length) } == 0
        guard !alive else { throw ShelfTedLink.LinkError.alreadyListening }
        unlink(path)
    }

    private func acceptPending() {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }   // EAGAIN: nada mais pendente
            defer { close(client) }
            ShelfTedLink.trace("conexão aceita (fd \(client))")
            if case .failure(let rejection) = ShelfTedLink.authorize(client) {
                log.error("ted-link recusou uma conexão: \(rejection.reason, privacy: .public)")
                ShelfTedLink.trace("RECUSADO: \(rejection.reason)")
                continue
            }
            ShelfTedLink.trace("autorizado")
            var timeout = Self.receiveTimeout
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            guard let payload = readPayload(client) else {
                ShelfTedLink.trace("sem payload")
                continue
            }
            ShelfTedLink.trace("payload de \(payload.count) bytes")
            deliver(payload)
        }
    }

    /// Lê até EOF, com teto. O teto é o que impede um par (mesmo legítimo, mas com
    /// bug) de empurrar megabytes para dentro da ilha.
    private func readPayload(_ client: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= ShelfTedAnnouncement.maxBytes {
            let read = recv(client, &buffer, buffer.count, 0)
            if read > 0 {
                data.append(contentsOf: buffer[0..<read])
                continue
            }
            if read == 0 { return data.isEmpty ? nil : data }   // EOF limpo
            log.error("ted-link: leitura falhou (errno \(errno))")
            return nil
        }
        log.error("ted-link: payload acima do teto, descartado")
        return nil
    }

    private func deliver(_ data: Data) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let raw = try? decoder.decode(ShelfTedAnnouncement.self, from: data) else {
            log.error("ted-link: payload não decodificou")
            ShelfTedLink.trace("DECODE falhou: \(String(data: data.prefix(200), encoding: .utf8) ?? "?")")
            return
        }
        guard raw.version == ShelfTedAnnouncement.protocolVersion else {
            log.error("ted-link: versão \(raw.version) incompatível")
            return
        }
        guard let clean = raw.sanitized() else {
            log.error("ted-link: anúncio vazio depois da limpeza")
            return
        }
        handler(clean)
    }
}

// MARK: - Lado que fala (o Ted)

extension ShelfTedLink {
    /// Entrega um anúncio ao par. Dispara e esquece: se o outro app está fechado,
    /// isso falha de imediato com `.peerUnavailable` — nada fica em fila, porque
    /// um aviso que chega meia hora atrasado na notch é ruído, não ajuda.
    public static func send(_ announcement: ShelfTedAnnouncement, to socketPath: String? = nil) throws {
        guard let clean = announcement.sanitized() else { throw LinkError.payloadTooLarge(0) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(clean)
        guard data.count <= ShelfTedAnnouncement.maxBytes else {
            throw LinkError.payloadTooLarge(data.count)
        }

        let path = try socketPath ?? socketURL().path
        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        guard client >= 0 else { throw LinkError.socketFailed(errno) }
        defer { close(client) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = try address(for: path)
        let connected = withSockaddr(&addr) { pointer, length in connect(client, pointer, length) }
        guard connected == 0 else { throw LinkError.peerUnavailable }

        try data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let wrote = Darwin.send(client, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
                guard wrote > 0 else { throw LinkError.sendFailed(errno) }
                sent += wrote
            }
        }
        // Fecha a escrita: é o EOF que diz ao listener que o payload acabou.
        shutdown(client, SHUT_WR)

        // E ESPERA o receptor fechar. Não é cortesia: o listener só pergunta ao
        // kernel quem somos DEPOIS do accept, e o audit token de um par que já
        // fechou e saiu não existe mais — um remetente legítimo era recusado com
        // "sem audit token", de forma intermitente, conforme quem ganhasse a
        // corrida. Esperar o EOF custa milissegundos e elimina a corrida.
        var sink = [UInt8](repeating: 0, count: 1)
        var wait = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        _ = recv(client, &sink, 1, 0)   // 0 no EOF, -1 no timeout: os dois servem
    }
}

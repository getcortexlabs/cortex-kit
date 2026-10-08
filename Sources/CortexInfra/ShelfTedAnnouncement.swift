import Foundation

/// O que um app da família pede ao outro para anunciar na ilha.
///
/// Envelope versionado (mesmo padrão do `SchemaStore` do Shelf): para mudar o
/// formato, suba `protocolVersion` e alargue o decodificador — nunca troque o
/// sentido de um campo existente.
///
/// Diferente do `ShelfTedMessage`, que é só presença e trafega por notificação
/// distribuída (sem remetente autenticado), ISTO carrega conteúdo do usuário e
/// por isso só pode andar pelo canal autenticado do `ShelfTedLink`.
public struct ShelfTedAnnouncement: Codable, Equatable, Sendable, Identifiable {
    public static let protocolVersion = 1

    /// Tetos rígidos. A ilha é um relance: texto longo não cabe na notch e ainda
    /// deixaria um remetente hostil esticar a pílula pela tela toda.
    public static let maxTitle = 72
    public static let maxBody = 160
    public static let maxActionLabel = 20
    /// Teto do que o listener aceita ler de uma conexão, antes de decodificar.
    public static let maxBytes = 8 * 1024

    public enum Urgency: String, Codable, Sendable {
        /// Aparece quando você olhar para a notch.
        case normal
        /// Vale interromper: a ilha reage na hora.
        case important
    }

    /// O que um toque faz. Só esquemas de propósito — um anúncio não abre
    /// `file://` nem nada que execute algo local.
    public struct Action: Codable, Equatable, Sendable {
        public static let allowedSchemes: Set<String> = ["https", "cortexshelf", "ted", "cortexted"]

        public let label: String
        public let url: URL

        public init(label: String, url: URL) {
            self.label = label
            self.url = url
        }

        var isAllowed: Bool {
            guard let scheme = url.scheme?.lowercased() else { return false }
            return Self.allowedSchemes.contains(scheme)
        }
    }

    public let id: UUID
    public let version: Int
    public let sender: ShelfTedApp
    public let title: String
    public let body: String?
    public let urgency: Urgency
    public let action: Action?
    public let sentAt: Date

    public init(id: UUID = UUID(),
                version: Int = ShelfTedAnnouncement.protocolVersion,
                sender: ShelfTedApp,
                title: String,
                body: String? = nil,
                urgency: Urgency = .normal,
                action: Action? = nil,
                sentAt: Date = Date()) {
        self.id = id
        self.version = version
        self.sender = sender
        self.title = title
        self.body = body
        self.urgency = urgency
        self.action = action
        self.sentAt = sentAt
    }

    /// Versão segura de exibir, ou `nil` se não houver nada a mostrar.
    ///
    /// Puro de propósito: é a fronteira de confiança entre "outro processo
    /// mandou" e "isto vai para a tela", e é o que os testes exercitam. Mesmo um
    /// remetente com assinatura válida pode mandar algo malformado — por bug, não
    /// por maldade — e a ilha não pode quebrar por causa disso.
    public func sanitized() -> ShelfTedAnnouncement? {
        let cleanTitle = Self.clean(title, limit: Self.maxTitle)
        guard !cleanTitle.isEmpty else { return nil }
        let cleanBody = body.map { Self.clean($0, limit: Self.maxBody) }.flatMap { $0.isEmpty ? nil : $0 }
        let cleanAction = action.flatMap { a -> Action? in
            let label = Self.clean(a.label, limit: Self.maxActionLabel)
            guard !label.isEmpty, a.isAllowed else { return nil }
            return Action(label: label, url: a.url)
        }
        return ShelfTedAnnouncement(id: id, version: version, sender: sender,
                                    title: cleanTitle, body: cleanBody,
                                    urgency: urgency, action: cleanAction, sentAt: sentAt)
    }

    /// Tira controles e quebras de linha (uma pílula é uma linha só; `\n` viraria
    /// espaço fantasma ou texto cortado), colapsa espaços e corta no limite.
    static func clean(_ raw: String, limit: Int) -> String {
        // Separador (quebra de linha, tab) vira ESPAÇO — apagá-lo grudaria as
        // palavras ("Reunião\nàs 15h" viraria "Reuniãoàs 15h"). Os demais
        // controles não separam nada e simplesmente somem.
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            if CharacterSet.newlines.contains(scalar) || scalar == "\t" {
                scalars.append(" ")
            } else if !CharacterSet.controlCharacters.contains(scalar) {
                scalars.append(scalar)
            }
        }
        let stripped = String(scalars)
        let collapsed = stripped.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > limit else { return trimmed }
        // Corta na fronteira de caractere e sinaliza que foi cortado.
        return String(trimmed.prefix(limit - 1)) + "…"
    }
}

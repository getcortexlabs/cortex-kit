# CortexKit — Public API Reference

Complete public surface of CortexKit `0.1.0`. Grouped by module. Every symbol
below is `public`; everything else is an implementation detail.

A native macOS UI + foundation kit. `import CortexKit` re-exports all four
modules; import a single module (`import CortexUI`, etc.) to keep link cost
minimal.

---

## CortexKit (umbrella)

```swift
enum CortexKit {
    static let version: String                                   // "0.1.0"

    /// One-call setup: builds a PrefsStore for `namespace`, installs the
    /// BrandConfig (logo + theme namespace), returns the store for reuse.
    @discardableResult
    static func configure(
        namespace: String,
        logo: NSImage? = nil,
        fallbackSymbol: String = "circle.hexagongrid.fill",
        defaultTheme: AccentTheme = .violet
    ) -> PrefsStore
}
```

---

## CortexInfra

No UI, no dependencies — the root of the module graph.

### ShelfTedBridge

Optional native-app presence integration for Shelf and Ted, using AppKit's
Launch Services discovery and Foundation distributed notifications.

```swift
@MainActor
let bridge = ShelfTedBridge(app: .shelf) // .ted in Ted's app delegate
bridge.start()
// Observe bridge.$state; call bridge.stop() during app termination.
```

States: `stopped`, `notInstalled`, `available` (installed but closed),
`connecting`, `connected`, `unavailable` (running without a response),
`incompatible` (different protocol version). `refresh()` rechecks discovery.
Both apps need bridge-enabled builds. An installed older app remains optional
and cannot be reported as connected without completing the handshake.

Protocol v1 uses notification `app.cortex.shelf-ted.presence`, addressed by
the receiver's bundle ID (`shelf.cortex.app` / `ted.cortex.app`). The `message`
field is bounded JSON with version, sender bundle ID, PID, kind
(`hello` / `reply` / `goodbye`), and a UUID nonce. Replies must match the
outstanding nonce and the currently running peer PID. Launch/termination,
activation, and wake events refresh presence; a single three-second deadline
handles unresponsive peers. There is no idle polling or automatic app launch.

This is presence metadata, **not authenticated IPC**. PID/bundle checks prevent
accidental cross-talk, not impersonation by another local process. Do not send
user data or execute commands over this channel. Notifications in Shelf,
daemon/AI events, and a private authenticated content transport are future work.

Validation: `swift test` covers the handshake lifecycle;
`python3 scripts/test-shelf-ted-bridge.py` exercises the real transport in two
isolated processes (requires a logged-in macOS session that permits distributed
notifications; restricted agent sandboxes can block this check).

### PrefsStore

A namespaced `UserDefaults` wrapper. Every key is `"<namespace>.<suffix>"`.

```swift
struct PrefsStore: @unchecked Sendable {
    let namespace: String
    init(namespace: String, defaults: UserDefaults = .standard)

    func key(_ suffix: String) -> String

    // Read (with optional defaults)
    func string(for suffix: String) -> String?
    func string(for suffix: String, default fallback: String) -> String
    func bool(for suffix: String, default fallback: Bool = false) -> Bool
    func int(for suffix: String, default fallback: Int = 0) -> Int
    func double(for suffix: String, default fallback: Double = 0) -> Double

    // Write
    func set(_ value: String?, for suffix: String)
    func set(_ value: Bool, for suffix: String)
    func set(_ value: Int, for suffix: String)
    func set(_ value: Double, for suffix: String)
    func remove(_ suffix: String)
}
```

### Keychain

Service-scoped generic-password storage. Setting an empty string deletes the
item. UUID overloads key the account by `uuidString`.

```swift
struct Keychain: Sendable {
    let service: String
    init(service: String)

    @discardableResult func set(_ value: String, for account: String) -> Bool
    func get(_ account: String) -> String?
    func delete(_ account: String)

    @discardableResult func set(_ value: String, for id: UUID) -> Bool
    func get(_ id: UUID) -> String?
    func delete(_ id: UUID)
}
```

### ShellRunner

PATH resolution + subprocess execution, off the main thread.

```swift
enum ShellRunner {
    struct Output: Sendable {
        let stdout: String
        let stderr: String
        let exitCode: Int32
        var ok: Bool                                  // exitCode == 0
    }
    enum ShellError: LocalizedError { case launchFailed(String) }

    static var commonBinDirs: [String]                // ~/.local/bin, brew, nvm…
    static func resolve(_ binary: String) async -> String?   // login shell + scan
    static func augmentedEnvironment() -> [String: String]   // PATH-augmented env

    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil
    ) async throws -> Output
}
```

---

## CortexAI

Drives the user's local AI CLI. No API keys, no token cost.

### AICLI

```swift
enum AICLI: String, Codable, CaseIterable, Sendable, Identifiable {
    case claude, codex
    var id: String                                    // rawValue
    var binary: String                                // "claude" / "codex"
    var displayName: String                           // "Claude Code" / "OpenAI Codex"
    var installHint: String                           // npm i -g …
    func arguments(for prompt: String) -> [String]    // ["-p", …] / ["exec","-q",…]
}

enum AIError: LocalizedError {
    case noProvider, notFound(AICLI), emptyInput, failed(String)
}
```

### AIProvider

```swift
struct AIProvider: Sendable {
    static let backendPrefKey: String                 // "aiProvider"
    static let autoValue: String                      // "auto"

    init(prefs: PrefsStore? = nil)                    // prefs → honour pinned backend

    func detect() async -> [AICLI: String]            // all installed CLIs → path
    func detectBackend() async -> AICLI?              // first available (claude first)
    func resolveBackend() async -> AICLI?             // pinned-if-installed, else auto

    func run(prompt: String, cli: AICLI) async throws -> String   // trimmed stdout
    func run(prompt: String) async throws -> String              // resolve + run
}
```

### AIText

Pure helpers for taming CLI output (fully unit-tested).

```swift
enum AIText {
    static func stripFences(_ s: String) -> String           // remove ``` … ```
    static func firstMeaningfulLine(_ raw: String) -> String // first non-blank/non-fence
    static func truncated(_ text: String, to limit: Int) -> String
}
```

---

## CortexUI

The shared visual identity. Depends on `CortexInfra` (for `PrefsStore`).

### AccentTheme

```swift
enum AccentTheme: String, CaseIterable, Identifiable, Sendable {
    case violet, ocean, sunset, forest, mono
    var id: String
    var label: String                                 // "Violet", …, "Graphite"
    var palette: [Color]                              // 5 colors
    var accent: Color
}
```

### BrandConfig + Brand

`BrandConfig` is the injection seam. `Brand` is the surface the UI reads from;
it falls back to a default config (Violet, no logo) until `configure` is called.

```swift
struct BrandConfig: @unchecked Sendable {
    let prefs: PrefsStore
    let themeKey: String                              // default "accentTheme"
    let logo: NSImage?
    let fallbackSymbol: String
    let defaultTheme: AccentTheme
    init(prefs: PrefsStore, themeKey: String = "accentTheme",
         logo: NSImage? = nil, fallbackSymbol: String = "circle.hexagongrid.fill",
         defaultTheme: AccentTheme = .violet)
}

enum Brand {
    static func configure(_ config: BrandConfig)
    static var theme: AccentTheme
    static func setTheme(_ theme: AccentTheme)
    static var palette: [Color]
    static var accent: Color
    static var gradient: LinearGradient
    static var logo: NSImage?
    static var fallbackSymbol: String
}
```

### Views, modifiers & styles

```swift
struct AuroraBackground: View {                       // 60→10fps idle throttle
    init(intensity: Double = 1.0)
}
struct NoiseOverlay: View { init() }

struct LogoMark: View { init(size: CGFloat = 40) }

struct ShimmerText: View {
    init(_ text: String, size: CGFloat = 38,
         weight: Font.Weight = .bold, design: Font.Design = .rounded)
}

struct StatusDot: View { init(color: Color, size: CGFloat = 8) }

struct GlassCard<Content: View>: View {               // Liquid Glass + parallax
    init(padding: CGFloat = 20, interactive: Bool = true,
         alignment: Alignment = .center, fillsWidth: Bool = true,
         @ViewBuilder _ content: () -> Content)
}

struct LiquidGlassBackground: ViewModifier { init(cornerRadius: CGFloat = 18) }
struct CascadeModifier: ViewModifier { init(delay: Double, distance: CGFloat = 18) }

struct PressableStyle: ButtonStyle { init() }
struct GradientButtonStyle: ButtonStyle { init() }

// View extensions
extension View {
    func liquidGlass(cornerRadius: CGFloat = 18) -> some View
    func cascade(delay: Double, distance: CGFloat = 18) -> some View
}

// ButtonStyle conveniences
extension ButtonStyle where Self == GradientButtonStyle { static var gradient }
extension ButtonStyle where Self == PressableStyle      { static var pressable }

// Animation tokens
extension Animation {
    enum cortex {
        static let standard: Animation                // spring 0.4 / 0.78
        static let bouncy:   Animation                // spring 0.55 / 0.7
        static let snappy:   Animation                // spring 0.25 / 0.85
    }
}
```

---

## CortexHelpers

Reusable SwiftUI pieces. Depends on `CortexUI` (for `Brand`).

### ToastCenter

```swift
@MainActor
final class ToastCenter: ObservableObject {
    enum Kind: Sendable { case success, error, info }
    struct Toast: Identifiable, Equatable, Sendable {
        let id: UUID; let message: String; let kind: Kind
    }
    @Published var current: Toast?
    init()
    func show(_ message: String, kind: Kind = .info)
    func success(_ m: String); func error(_ m: String); func info(_ m: String)
}

extension View { func toasts(_ center: ToastCenter) -> some View }
```

### MarkdownText

```swift
struct MarkdownText: View {
    init(_ text: String)
    enum Kind: Equatable, Sendable {
        case heading(level: Int, text: String), paragraph(String)
        case list(items: [String], ordered: Bool), code(String)
    }
    struct Block: Identifiable, Equatable, Sendable { let id: Int; let kind: Kind }
    static func parse(_ text: String) -> [Block]
}
```

### JSONHighlighter

```swift
enum JSONHighlighter {
    static func highlight(_ json: String) -> AttributedString   // brand-colored
    static func isJSON(_ text: String) -> Bool
    static func prettyPrint(_ text: String) -> String           // sorted keys
}
```

### SearchHighlight

```swift
enum SearchHighlight {
    static func attributed(_ value: String, query: String) -> AttributedString
    static func elapsed(_ seconds: TimeInterval) -> String      // "<1ms", "1.2s"
}
```

### Skeleton

```swift
struct SkeletonRow: View  { init(width: CGFloat = 160, height: CGFloat = 10) }
struct SkeletonList: View {
    init(rows: Int = 6, widths: [CGFloat] = [140, 110, 160, 90, 130, 100])
}
```

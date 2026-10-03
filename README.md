<div align="center">

# CortexKit

**A native macOS UI + foundation kit, built entirely in Swift.**

An animated "Aurora + Liquid Glass" design system, a zero-API-key AI layer that
drives the user's local `claude`/`codex` CLI, and the plumbing every macOS app
re-implements — preferences, Keychain, subprocess running.

`SwiftUI` · `macOS 14+` · `Swift 6.2` · zero third-party dependencies

</div>

---

## Why

Most native Mac apps re-implement the same things: a themeable look, secret
storage, a preferences wrapper, "shell out to a tool on the user's PATH." And
"call an LLM" usually means shipping an API key and burning tokens.

CortexKit packages all of that:

- A cohesive **design system** — animated Aurora background, Liquid Glass cards
  with cursor parallax, a 5-theme accent palette, shimmer titles, status dots,
  staggered entrances — that you adopt with a single `configure` call.
- An **AI layer with no API keys** — it runs whatever AI CLI the user already
  has authenticated (`claude` / `codex`), so there's no token cost and nothing
  to manage.
- **Plumbing done once and tested** — namespaced preferences, service-scoped
  Keychain, and robust `PATH` resolution for launching CLIs from a sandboxed,
  Finder-launched `.app`.

It's a versioned Swift package: drop it in, and the next app — yours or anyone
else's — starts from a polished baseline.

## What's inside

CortexKit is **four modules** behind one umbrella, so a consumer takes only what
it needs (a CLI tool can pull `CortexAI` with no SwiftUI link cost):

| Module | Contents |
|---|---|
| **CortexUI** | `Brand` + `BrandConfig` (the injection seam), `AccentTheme` (Violet/Ocean/Sunset/Forest/Graphite), `AuroraBackground`, Liquid Glass (`liquidGlass`, `GlassCard`), `ShimmerText`, `StatusDot`, `LogoMark`, `cascade`, `GradientButtonStyle`/`PressableStyle`, `Animation.cortex` springs |
| **CortexAI** | `AICLI` (claude/codex), `AIProvider` (detect / resolve / run via the user's CLI), `AIText` (strip fences, first-line, truncate) |
| **CortexInfra** | `PrefsStore` (namespaced `UserDefaults`), `Keychain` (service-scoped), `ShellRunner` (PATH resolution + subprocess) — **no UI** |
| **CortexHelpers** | `ToastCenter` + `.toasts()`, `MarkdownText`, `JSONHighlighter`, `SearchHighlight`, `SkeletonRow`/`SkeletonList` |

`import CortexKit` re-exports all four.

## Install

In your app's `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/rafaelaugustos/cortex-kit", from: "0.1.0"),
],
targets: [
    .executableTarget(
        name: "MyApp",
        dependencies: [
            .product(name: "CortexKit", package: "cortex-kit"),
            // …or pick granular products:
            // .product(name: "CortexUI", package: "cortex-kit"),
        ]
    )
]
```

Requires **macOS 14+** and the **Swift 6.2** toolchain.

Liquid Glass is macOS 26 only, so `.liquidGlass()` falls back to
`.ultraThinMaterial` below 26 — the nearest thing the system has, and a real
vibrancy-backed translucency rather than a flat fill. Nothing else in the kit
needs 26.

## Quick start

Configure once at launch — this installs your app's namespace (for preferences
and the accent theme) and logo into the shared identity:

```swift
import SwiftUI
import CortexKit

@main
struct MyApp: App {
    init() {
        // Returns a PrefsStore you can reuse for your own settings + AIProvider.
        _ = CortexKit.configure(
            namespace: "mynewapp",
            logo: NSImage(named: "AppIcon"),
            fallbackSymbol: "sparkles"
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

Then build UI with the kit's vocabulary:

```swift
struct ContentView: View {
    @StateObject private var toasts = ToastCenter()

    var body: some View {
        ZStack {
            AuroraBackground()                       // the animated brand backdrop
            VStack(spacing: 20) {
                ShimmerText("My New App")
                GlassCard {                          // Liquid Glass + cursor parallax
                    HStack {
                        StatusDot(color: .green)
                        Text("Ready")
                    }
                }
                Button("Do the thing") { toasts.success("Done") }
                    .buttonStyle(.gradient)
            }
            .cascade(delay: 0.05)                    // staggered entrance
        }
        .toasts(toasts)
    }
}
```

### Drive the local AI

No API keys — it shells out to whatever the user already has on `PATH`:

```swift
let prefs = CortexKit.configure(namespace: "mynewapp")   // also returns the store
let ai = AIProvider(prefs: prefs)

if let cli = await ai.resolveBackend() {        // honours a user-pinned backend
    let answer = try await ai.run(prompt: "Summarize this diff…", cli: cli)
    let clean = AIText.firstMeaningfulLine(answer)
}
// Or in one call (auto-detects, throws .noProvider if none installed):
let reply = try await ai.run(prompt: "…")
```

### Store a secret

```swift
let keychain = Keychain(service: "mynewapp.tokens")
keychain.set(token, for: accountID)              // also accepts a UUID
let token = keychain.get(accountID)
```

## Design notes

- **`Brand` is configured, not hard-coded.** Nothing about the theme or logo is
  baked into the package: each app provides its preference namespace + logo via
  `Brand.configure` (or the `CortexKit.configure` shortcut). `BrandConfig` is the
  injection seam — so the package never reads another app's `UserDefaults` keys
  or bundles an icon. Until configured, `Brand` falls back to a sensible default
  (Violet, SF Symbol logo) so previews and tests just work.
- **Robust AI CLI resolution.** `AIProvider` resolves the binary through an
  interactive login shell **and** a scan of common install dirs (Homebrew, nvm,
  `~/.local/bin`, …), so it finds `claude`/`codex` even when the app launched
  from Finder with a bare environment — and honours a user-pinned backend before
  falling back to auto-detection.
- **Performance is built in.** `AuroraBackground` throttles from 60→10fps when
  the app loses focus (same look, far less idle CPU/GPU). `NoiseOverlay` uses a
  seeded PRNG so the speckle is computed deterministically, not re-randomised per
  frame. `JSONHighlighter` is a single hand-rolled pass that tolerates partial
  JSON. `ShellRunner` drains stderr concurrently so a full pipe can't deadlock.
- **Granular link cost.** Need only the AI layer? `import CortexAI` and you don't
  link SwiftUI. `CortexInfra` has no dependencies at all.

## Module graph

```
CortexKit  (umbrella, @_exported)
 ├─ CortexUI ───────┐
 │   └─ CortexInfra │
 ├─ CortexAI        │
 │   └─ CortexInfra │
 ├─ CortexInfra ◄───┘   (no dependencies)
 └─ CortexHelpers
     └─ CortexUI
```

## Develop

```sh
swift build
swift test
```

16 unit tests cover the pure logic (`AIText`, `AICLI` argv, `PrefsStore`
namespacing/round-trips). The UI and process layers are exercised by the
consuming apps.

See [API.md](API.md) for the full public surface.

## License

TBD.

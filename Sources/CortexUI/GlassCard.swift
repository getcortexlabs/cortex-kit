import SwiftUI

// MARK: - Liquid Glass

/// Applies the macOS 26 Liquid Glass material in a continuous rounded rect.
/// On macOS 14–15 it degrades to ultra-thin material — same silhouette,
/// no refraction (progressive enhancement).
public struct LiquidGlassBackground: ViewModifier {
    public var cornerRadius: CGFloat
    public init(cornerRadius: CGFloat = 18) { self.cornerRadius = cornerRadius }
    public func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            content.background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        }
    }
}

public extension View {
    /// Wraps the view in a Liquid Glass surface.
    func liquidGlass(cornerRadius: CGFloat = 18) -> some View {
        modifier(LiquidGlassBackground(cornerRadius: cornerRadius))
    }
}

// MARK: - Glass card with parallax + glow

/// A Liquid Glass card that tilts toward the cursor and shows an accent halo on
/// hover — the kit's signature container. Set `interactive: false` for a
/// static card (e.g. inside a scroll view where tilt would be distracting).
public struct GlassCard<Content: View>: View {
    private let content: Content
    public var padding: CGFloat
    public var interactive: Bool
    public var alignment: Alignment
    public var fillsWidth: Bool

    public init(
        padding: CGFloat = 20,
        interactive: Bool = true,
        alignment: Alignment = .center,
        fillsWidth: Bool = true,
        @ViewBuilder _ content: () -> Content
    ) {
        self.padding = padding
        self.interactive = interactive
        self.alignment = alignment
        self.fillsWidth = fillsWidth
        self.content = content()
    }

    @State private var hover = false
    @State private var localMouse: CGPoint = .zero
    @State private var size: CGSize = .zero

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: alignment)
            .liquidGlass(cornerRadius: 18)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        RadialGradient(
                            colors: [Brand.accent.opacity(hover ? 0.20 : 0), .clear],
                            center: UnitPoint(
                                x: size.width > 0 ? localMouse.x / size.width : 0.5,
                                y: size.height > 0 ? localMouse.y / size.height : 0.5
                            ),
                            startRadius: 1, endRadius: 240
                        )
                    )
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            )
            .background(
                GeometryReader { geo in
                    Color.clear.onAppear { size = geo.size }
                        .onChange(of: geo.size) { _, new in size = new }
                }
            )
            .scaleEffect(hover && interactive ? 1.012 : 1.0)
            .rotation3DEffect(
                .degrees(interactive && size.height > 0
                         ? Double((localMouse.y - size.height / 2) / size.height) * -3 : 0),
                axis: (x: 1, y: 0, z: 0)
            )
            .rotation3DEffect(
                .degrees(interactive && size.width > 0
                         ? Double((localMouse.x - size.width / 2) / size.width) * 3 : 0),
                axis: (x: 0, y: 1, z: 0)
            )
            .shadow(color: hover ? Brand.accent.opacity(0.30) : .black.opacity(0.18),
                    radius: hover ? 24 : 14, y: hover ? 14 : 8)
            .animation(.cortex.standard, value: hover)
            .onContinuousHover { phase in
                guard interactive else { return }
                switch phase {
                case .active(let p): hover = true; localMouse = p
                case .ended: hover = false
                }
            }
    }
}

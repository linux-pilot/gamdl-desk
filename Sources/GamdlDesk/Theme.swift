import AppKit
import SwiftUI

/// Material You–style color roles built from the "Electric Coast" palette:
/// coral #F65B62, petrol #006C76 and citron #D9E66B, with ink #1F2329 and cream #FFFBEA for text.
/// Light mode leads with petrol and dark mode with citron, so the accent always contrasts with the
/// background; each swaps into the other's container role. Every role adapts by itself.
enum Palette {
    static let primary = dynamic(light: 0x006C76, dark: 0xD9E66B)
    static let onPrimary = dynamic(light: 0xFFFBEA, dark: 0x1F2329)
    static let primaryContainer = dynamic(light: 0xD9E66B, dark: 0x006C76)
    static let onPrimaryContainer = dynamic(light: 0x1F2329, dark: 0xFFFBEA)

    /// Coral, darkened a step in light mode so small text stays readable.
    static let error = dynamic(light: 0xD8434B, dark: 0xF65B62)

    static let background = dynamic(light: 0xFAFAF4, dark: 0x16191D)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x1F2329)
    static let surfaceHigh = dynamic(light: 0xF0F2E4, dark: 0x2A2F36)
    static let outline = dynamic(light: 0xD9DCCB, dark: 0x3A4048)

    /// The accent's glow behind the filled button and the app icon.
    static let glow = primary

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            rgb(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        })
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

enum Radius {
    static let card: CGFloat = 20
    static let field: CGFloat = 14
    static let tile: CGFloat = 12
}

/// Spring-based motion, in the spirit of Material's emphasized and standard easing.
enum Motion {
    static let emphasized = Animation.spring(response: 0.45, dampingFraction: 0.82)
    static let standard = Animation.spring(response: 0.32, dampingFraction: 0.88)
    static let quick = Animation.easeOut(duration: 0.15)
}

extension View {
    /// `animation(_:value:)` that turns itself off when Reduce Motion is on.
    func motion<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }

    /// A filled Material card on the window background.
    func card(padding: CGFloat = 14) -> some View {
        self.padding(padding)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Palette.outline.opacity(0.6)))
    }
}

private struct MotionModifier<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

// MARK: - Buttons

/// Material 3 common buttons: filled, tonal and text, as pills with a hover/press state layer.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case filled, tonal, text }
    var kind: Kind = .filled

    func makeBody(configuration: Configuration) -> some View {
        PillButtonBody(configuration: configuration, kind: kind)
    }
}

private struct PillButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: PillButtonStyle.Kind
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @State private var hovering = false

    private var large: Bool { controlSize == .large }

    var body: some View {
        configuration.label
            .font(.system(size: large ? 14 : 12, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, kind == .text ? (large ? 12 : 8) : (large ? 20 : 12))
            .frame(minHeight: large ? 38 : 26)
            .background(container, in: Capsule())
            .overlay(Capsule().fill(foreground.opacity(stateLayer)))
            .contentShape(Capsule())
            .shadow(color: kind == .filled && isEnabled ? Palette.glow.opacity(hovering ? 0.45 : 0.28) : .clear,
                    radius: hovering ? 12 : 8, y: 3)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovering = $0 }
            .motion(Motion.quick, value: hovering)
            .motion(Motion.standard, value: configuration.isPressed)
    }

    private var foreground: Color {
        switch kind {
        case .filled: Palette.onPrimary
        case .tonal: Palette.onPrimaryContainer
        case .text: Palette.primary
        }
    }

    private var container: Color {
        switch kind {
        case .filled: Palette.primary
        case .tonal: Palette.primaryContainer
        case .text: .clear
        }
    }

    private var stateLayer: Double {
        guard isEnabled else { return 0 }
        return configuration.isPressed ? 0.14 : hovering ? 0.08 : 0
    }
}

/// Material 3 icon buttons: a round state layer on hover, filled with the primary color when `selected`,
/// and a bounce of the symbol as the pointer arrives.
struct IconButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, selected: selected)
    }
}

private struct IconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var arrivals = 0

    var body: some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: 13, weight: .semibold))
            .symbolEffect(.bounce, value: arrivals)
            .foregroundStyle(selected ? Palette.onPrimary : Palette.primary)
            .frame(width: 28, height: 28)
            .background(selected ? Palette.primary : hovering ? Palette.primaryContainer : .clear, in: Circle())
            .overlay(Circle().fill((selected ? Palette.onPrimary : Palette.primary).opacity(stateLayer)))
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { inside in
                hovering = inside
                if inside && !reduceMotion && isEnabled { arrivals += 1 }
            }
            .motion(Motion.quick, value: hovering)
            .motion(Motion.standard, value: configuration.isPressed)
            .motion(Motion.emphasized, value: selected)
    }

    private var stateLayer: Double {
        guard isEnabled else { return 0 }
        return configuration.isPressed ? 0.16 : selected && hovering ? 0.1 : 0
    }
}

// MARK: - Components

/// A Material segmented control: the selected pill slides between options.
struct PillPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    withAnimation(reduceMotion ? nil : Motion.emphasized) { selection = option }
                } label: {
                    Text(title(option))
                        .font(.callout.weight(selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Palette.onPrimaryContainer : .secondary)
                        .padding(.horizontal, 14)
                        .frame(height: 26)
                        .background {
                            if selected {
                                Capsule().fill(Palette.primaryContainer)
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Palette.surfaceHigh, in: Capsule())
    }
}

/// A small Material assist chip.
struct Chip: View {
    let text: String
    var systemImage: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(tint.opacity(0.14), in: Capsule())
        .fixedSize()
    }
}

/// An icon in a soft tinted circle, like a Material list item's leading avatar.
struct IconBadge: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.16), in: Circle())
    }
}

/// Material's indeterminate linear progress indicator.
struct IndeterminateBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            if reduceMotion {
                Capsule().fill(Palette.primary.opacity(0.7))
            } else {
                TimelineView(.animation) { context in
                    let period = 1.5
                    let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                    let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
                    let width = geo.size.width * 0.32
                    Capsule().fill(Palette.primary)
                        .frame(width: width)
                        .offset(x: -width + (geo.size.width + width) * eased)
                }
            }
        }
        .frame(height: 3)
        .background(Palette.primary.opacity(0.18))
        .clipped()
        .accessibilityHidden(true)
    }
}

/// The app icon on a soft lime glow that breathes while `active`.
struct GlowingAppIcon: View {
    var size: CGFloat = 72
    var active = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if active && !reduceMotion {
                PhaseAnimator([0.85, 1.15]) { scale in
                    glow.scaleEffect(scale).opacity(scale > 1 ? 1 : 0.6)
                } animation: { _ in .easeInOut(duration: 1.1) }
            } else {
                glow.opacity(0.7)
            }
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        }
        .frame(width: size * 1.3, height: size * 1.3)
        .accessibilityHidden(true)
    }

    private var glow: some View {
        Circle()
            .fill(RadialGradient(colors: [Palette.glow.opacity(0.35), .clear],
                                 center: .center, startRadius: 0, endRadius: size * 1.1))
            .frame(width: size * 2.2, height: size * 2.2)
    }
}

extension View {
    /// The brand tint and Material-like rounded type for a window's content (sheets inherit it).
    func appTheme() -> some View {
        tint(Palette.primary)
            .fontDesign(.rounded)
            .toolbarBackground(Palette.background, for: .windowToolbar)
    }
}

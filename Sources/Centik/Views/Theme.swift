import AppKit
import SwiftUI

enum ThemeKind: String, CaseIterable, Identifiable {
    case night, glass, aurora, neon, minimal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .night: return "Gece"
        case .glass: return "Cam"
        case .aurora: return "Aurora"
        case .neon: return "Neon"
        case .minimal: return "Sade"
        }
    }

    var subtitle: String {
        switch self {
        case .night: return "Saf siyah, çentikle bütünleşir"
        case .glass: return "Arkadaki masaüstünü buzlu camla gösterir"
        case .aurora: return "Vurgu renginde yavaşça akan ışık"
        case .neon: return "Kenarında dönen parlak çizgi"
        case .minimal: return "Gölgesiz, sakin, dikkat dağıtmaz"
        }
    }

    static var current: ThemeKind { ThemeKind(rawValue: Pref.string(Pref.theme)) ?? .night }
}

enum AnimationStyle: String, CaseIterable, Identifiable {
    case fluid, bouncy, calm

    var id: String { rawValue }
    var title: String {
        switch self {
        case .fluid: return "Akıcı"
        case .bouncy: return "Zıplayan"
        case .calm: return "Sakin"
        }
    }
    var damping: Double {
        switch self {
        case .fluid: return 0.74
        case .bouncy: return 0.58
        case .calm: return 0.92
        }
    }
}

/// Animation curves derived from the user's effect settings.
/// Slows every animation down for the demo recorder (`--demo`), which can only take a few
/// frames a second; its frames are played back faster. Always 1 in normal use.
enum DemoClock {
    static var slowdown: Double = 1
    private static let origin = Date()

    /// The time timeline-driven effects should animate by.
    static func time(_ date: Date) -> TimeInterval {
        origin.timeIntervalSinceReferenceDate + date.timeIntervalSince(origin) / slowdown
    }
}

enum Motion {
    static var enabled: Bool { Pref.bool(Pref.animationsEnabled) }
    private static var speed: Double { max(0.4, Pref.double(Pref.animationSpeed)) / DemoClock.slowdown }
    private static var style: AnimationStyle { AnimationStyle(rawValue: Pref.string(Pref.animationStyle)) ?? .fluid }

    static var island: Animation {
        enabled ? .spring(response: 0.46 / speed, dampingFraction: style.damping) : .linear(duration: 0)
    }
    static var hover: Animation {
        enabled ? .spring(response: 0.3 / speed, dampingFraction: max(0.5, style.damping - 0.12)) : .linear(duration: 0)
    }
    static var content: Animation {
        enabled ? .spring(response: 0.36 / speed, dampingFraction: 0.82) : .linear(duration: 0)
    }
    static var quick: Animation {
        enabled ? .easeOut(duration: 0.16 / speed) : .linear(duration: 0)
    }
}

/// The colour used for highlights: taken from the playing artwork, or the user's own choice.
struct AccentColor {
    static func resolve(artwork: NSColor?) -> Color {
        if Pref.string(Pref.accentMode) == "artwork", let artwork { return Color(nsColor: artwork) }
        return Color(hex: Pref.string(Pref.accentHex)) ?? .purple
    }
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    var hex: String {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return "#A97CFF" }
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}

/// Fill behind the island's content. The strip level with the notch always stays pure black
/// so the island still reads as part of the hardware notch whatever the theme.
struct IslandBackground: View {
    var theme: ThemeKind
    var presentation: Presentation
    var accent: Color
    var notchHeight: CGFloat

    private var isOpen: Bool {
        if case .transient(let t) = presentation { return t.isPeek }
        return presentation == .expanded
    }

    var body: some View {
        ZStack {
            Color.black
            if isOpen {
                switch theme {
                case .night, .minimal:
                    EmptyView()
                case .glass:
                    VisualEffectBlur(material: .hudWindow)
                        .overlay(Color.black.opacity(0.28))
                        .mask(topFade)
                case .aurora:
                    AuroraLayer(accent: accent, animated: Motion.enabled).mask(topFade)
                case .neon:
                    LinearGradient(colors: [accent.opacity(0.0), accent.opacity(0.12)], startPoint: .top, endPoint: .bottom)
                }
            }
        }
    }

    private var topFade: some View {
        GeometryReader { geo in
            let start = min(1, notchHeight / max(geo.size.height, 1))
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .clear, location: start * 0.85),
                .init(color: .white, location: min(1, start + 0.25)),
            ], startPoint: .top, endPoint: .bottom)
        }
    }
}

/// Rotating light around the rim for the neon theme.
struct NeonRim: View {
    var shape: NotchShape
    var accent: Color
    /// The rim fades out over this many points at the top, so no line runs along the screen edge.
    var hiddenTop: CGFloat = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !Motion.enabled)) { context in
            let angle = Angle.degrees(DemoClock.time(context.date).truncatingRemainder(dividingBy: 6) * 60)
            let gradient = AngularGradient(colors: [accent, accent.opacity(0.1), .white.opacity(0.8), accent.opacity(0.1), accent],
                                           center: .center, angle: angle)
            shape.stroke(gradient, lineWidth: 1.6)
                .shadow(color: accent.opacity(0.7), radius: 6)
                .padding(8)
                .drawingGroup()
                .padding(-8)
        }
        .hidingTop(hiddenTop)
    }
}

extension Color {
    /// A neighbouring hue so the aurora has two tones from one accent.
    func blendHue() -> Color {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .systemPurple
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: (h + 0.12).truncatingRemainder(dividingBy: 1), saturation: s, brightness: b, opacity: a)
    }
}

private struct IslandAccentKey: EnvironmentKey {
    static let defaultValue: Color = .purple
}

extension EnvironmentValues {
    var islandAccent: Color {
        get { self[IslandAccentKey.self] }
        set { self[IslandAccentKey.self] = newValue }
    }
}

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

extension View {
    /// Fades the view out over the top `height` points, keeping the strip beside the notch clean.
    func hidingTop(_ height: CGFloat) -> some View {
        mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: .bottom).frame(height: height)
                Color.white
            }
        }
    }
}

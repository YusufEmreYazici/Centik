import SwiftUI

/// The island outline: concave flares where it meets the top edge, rounded bottom corners.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let t = topRadius
        let b = min(bottomRadius, rect.height / 2, (rect.width - 2 * t) / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t), control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY), control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b), control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

struct LevelBar: View {
    var value: Double
    var tint: Color = .white
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                Capsule().fill(tint).frame(width: max(height, geo.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: height)
    }
}

struct ArtworkView: View {
    var image: NSImage?
    var size: CGFloat
    var radius: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [.purple.opacity(0.7), .blue.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Two side wings around the physical notch.
struct Wings<Left: View, Right: View>: View {
    var notchWidth: CGFloat
    var height: CGFloat
    @ViewBuilder var left: Left
    @ViewBuilder var right: Right

    var body: some View {
        HStack(spacing: 0) {
            left.frame(maxWidth: .infinity)
            Color.clear.frame(width: notchWidth)
            right.frame(maxWidth: .infinity)
        }
        .frame(height: height)
    }
}

struct IconButton: View {
    var symbol: String
    var size: CGFloat = 14
    var active = false
    var bounce = 0
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: bounce)
                .foregroundStyle(active ? Color.accentColor : .white.opacity(hover ? 1 : 0.85))
                .frame(width: size + 16, height: size + 14)
                .background(Circle().fill(Color.white.opacity(hover ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hover = $0 }
        .animation(Motion.quick, value: hover)
    }
}

/// Shrinks a little while held and springs back on release.
struct PressScaleStyle: ButtonStyle {
    var scale: CGFloat = 0.84

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(Motion.hover, value: configuration.isPressed)
    }
}

/// Compact capsule button that reads well on the black island.
struct PillButtonStyle: ButtonStyle {
    var tint: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.titleAndIcon)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(tint.opacity(configuration.isPressed ? 0.3 : 0.15)))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(Motion.hover, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
    static func pill(_ tint: Color) -> PillButtonStyle { PillButtonStyle(tint: tint) }
}

extension Color {
    static let island = Color.black
    static let subtleText = Color.white.opacity(0.55)
    static let cardFill = Color.white.opacity(0.07)
}

func batterySymbol(_ level: Int, charging: Bool) -> String {
    if charging { return "battery.100percent.bolt" }
    switch level {
    case ..<13: return "battery.0percent"
    case ..<38: return "battery.25percent"
    case ..<63: return "battery.50percent"
    case ..<88: return "battery.75percent"
    default: return "battery.100percent"
    }
}

func batteryColor(_ level: Int, charging: Bool, low: Bool = false) -> Color {
    if charging { return .green }
    if low || level <= 10 { return .red }
    if level <= 20 { return .orange }
    return .white
}

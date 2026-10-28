import SwiftUI

/// Raised surface used by every panel inside the expanded island.
struct CardSurface: View {
    var tint: Color?
    var radius: CGFloat = 16

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape
            .fill(LinearGradient(colors: [.white.opacity(0.085), .white.opacity(0.035)], startPoint: .top, endPoint: .bottom))
            .overlay {
                if let tint {
                    shape.fill(LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing))
                }
            }
            .overlay(
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.03)], startPoint: .top, endPoint: .bottom),
                                   lineWidth: 0.7)
            )
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 12
    var tint: Color?
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(CardSurface(tint: tint))
    }
}

/// Small uppercase heading with an icon, used above each block.
struct SectionLabel: View {
    var title: String
    var symbol: String?

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
            Text(title.uppercased(with: Locale(identifier: "tr_TR")))
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.9)
        }
        .foregroundStyle(.white.opacity(0.45))
    }
}

struct Chip: View {
    var text: String
    var symbol: String?
    var tint: Color = .white

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 8.5, weight: .bold)) }
            Text(text).font(.system(size: 9.5, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.16)))
    }
}

/// Round transport-style button: filled for the primary action, glassy otherwise.
struct CircleControl: View {
    var symbol: String
    var size: CGFloat = 34
    var filled = false
    var tint: Color = .white
    var bounce = 0
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.4, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: bounce)
                .foregroundStyle(filled ? Color.black : tint)
                .frame(width: size, height: size)
                .background(
                    Circle().fill(filled ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color.white.opacity(hover ? 0.16 : 0.08)))
                )
                .overlay(Circle().strokeBorder(.white.opacity(filled ? 0 : 0.1), lineWidth: 0.6))
                .shadow(color: filled ? tint.opacity(0.45) : .clear, radius: hover ? 10 : 6)
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle(scale: 0.88))
        .onHover { hover = $0 }
        .animation(Motion.quick, value: hover)
    }
}

/// Pre-blurred artwork blown up into an ambient backdrop.
struct ArtworkBackdrop: View {
    var image: NSImage?
    var accent: Color

    var body: some View {
        // The image sits in an overlay so its fill size never grows the backdrop past its frame.
        Color.clear
            .overlay {
                if let image {
                    // Already blurred (MusicService.blurred); only scaled here.
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fill)
                        .opacity(0.75)
                } else {
                    LinearGradient(colors: [accent.opacity(0.35), accent.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .overlay(LinearGradient(colors: [.black.opacity(0.25), .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
            .clipped()
            // clipped() only trims drawing: the filled artwork overhangs the card and would
            // swallow clicks on the tab bar above it.
            .allowsHitTesting(false)
    }
}

struct EmptyState: View {
    var symbol: String
    var title: String
    var subtitle: String
    var tint: Color

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                Circle().fill(tint.opacity(0.16)).frame(width: 46, height: 46)
                Circle().strokeBorder(tint.opacity(0.35), lineWidth: 0.8).frame(width: 46, height: 46)
                Image(systemName: symbol).font(.system(size: 19, weight: .semibold)).foregroundStyle(tint)
            }
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(subtitle).font(.system(size: 10.5)).foregroundStyle(Color.subtleText).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

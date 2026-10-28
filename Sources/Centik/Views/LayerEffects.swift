import AppKit
import QuartzCore
import SwiftUI

// Continuous effects run as Core Animation layer animations. They play in the render server,
// so they cost the app no CPU and never make SwiftUI redraw the rest of the island.
// A SwiftUI TimelineView doing the same work re-rendered the whole island every frame.

/// Two radial lights drifting slowly along the bottom of the island.
struct AuroraLayer: NSViewRepresentable {
    var accent: Color
    var animated: Bool

    func makeNSView(context: Context) -> AuroraView { AuroraView() }

    func updateNSView(_ view: AuroraView, context: Context) {
        view.update(accent: NSColor(accent), animated: animated)
    }
}

final class AuroraView: NSView {
    private let first = CAGradientLayer()
    private let second = CAGradientLayer()
    private var accent: NSColor?
    private var animated = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        for g in [first, second] {
            g.type = .radial
            g.startPoint = CGPoint(x: 0.5, y: 0.5)
            g.endPoint = CGPoint(x: 1, y: 1)
            layer?.addSublayer(g)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(accent: NSColor, animated: Bool) {
        if accent != self.accent {
            self.accent = accent
            let hue = Self.shifted(accent)
            first.colors = [accent.withAlphaComponent(0.5).cgColor, accent.withAlphaComponent(0.16).cgColor, NSColor.clear.cgColor]
            second.colors = [hue.withAlphaComponent(0.32).cgColor, hue.withAlphaComponent(0.1).cgColor, NSColor.clear.cgColor]
        }
        if animated != self.animated {
            self.animated = animated
            animated ? startDrift() : stopDrift()
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds
        first.bounds = CGRect(x: 0, y: 0, width: 560, height: 560)
        second.bounds = CGRect(x: 0, y: 0, width: 480, height: 480)
        first.position = CGPoint(x: b.width * 0.3, y: -b.height * 0.1)
        second.position = CGPoint(x: b.width * 0.75, y: b.height * 0.05)
        CATransaction.commit()
        if animated { startDrift() }
    }

    private func startDrift() {
        drift(first, dx: bounds.width * 0.2, duration: 9)
        drift(second, dx: -bounds.width * 0.15, duration: 11.5)
    }

    private func stopDrift() {
        first.removeAllAnimations()
        second.removeAllAnimations()
    }

    private func drift(_ layer: CAGradientLayer, dx: CGFloat, duration: CFTimeInterval) {
        let a = CABasicAnimation(keyPath: "position.x")
        a.byValue = dx
        a.duration = duration
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(a, forKey: "drift")
    }

    private static func shifted(_ color: NSColor) -> NSColor {
        let c = color.usingColorSpace(.sRGB) ?? .systemPurple
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: (h + 0.12).truncatingRemainder(dividingBy: 1), saturation: s, brightness: b, alpha: a)
    }
}

/// Four bars bouncing at different rates while music plays.
struct EqualizerLayer: NSViewRepresentable {
    var playing: Bool
    var color: Color

    func makeNSView(context: Context) -> EqualizerBarsView { EqualizerBarsView() }

    func updateNSView(_ view: EqualizerBarsView, context: Context) {
        view.update(playing: playing && Motion.enabled, color: NSColor(color))
    }
}

final class EqualizerBarsView: NSView {
    private var bars: [CALayer] = []
    private var playing: Bool?
    private static let durations: [CFTimeInterval] = [0.42, 0.33, 0.51, 0.38]
    private static let barWidth: CGFloat = 2.6
    private static let gap: CGFloat = 2

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.barWidth * 4 + Self.gap * 3, height: 14)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for _ in 0..<4 {
            let bar = CALayer()
            bar.cornerRadius = Self.barWidth / 2
            bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(playing: Bool, color: NSColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bars.forEach { $0.backgroundColor = color.cgColor }
        CATransaction.commit()
        guard playing != self.playing else { return }
        self.playing = playing
        playing ? start() : stop()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let total = Self.barWidth * 4 + Self.gap * 3
        let x0 = (bounds.width - total) / 2
        for (i, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: Self.barWidth, height: 14)
            bar.position = CGPoint(x: x0 + CGFloat(i) * (Self.barWidth + Self.gap) + Self.barWidth / 2, y: bounds.midY)
        }
        CATransaction.commit()
        if playing == true { start() } else { stop() }
    }

    private func start() {
        for (i, bar) in bars.enumerated() {
            bar.transform = CATransform3DIdentity
            let a = CABasicAnimation(keyPath: "transform.scale.y")
            a.fromValue = 0.3
            a.toValue = 1
            a.duration = Self.durations[i]
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timeOffset = Double(i) * 0.17
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bar.add(a, forKey: "bounce")
        }
    }

    private func stop() {
        for bar in bars {
            bar.removeAllAnimations()
            bar.transform = CATransform3DMakeScale(1, 0.22, 1)
        }
    }
}

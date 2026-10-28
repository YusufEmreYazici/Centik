import SwiftUI

extension Metric {
    var tint: Color {
        switch self {
        case .cpu: return Color(red: 0.35, green: 0.78, blue: 1)
        case .memory: return Color(red: 0.75, green: 0.5, blue: 1)
        case .gpu: return Color(red: 0.35, green: 0.9, blue: 0.55)
        case .network: return Color(red: 1, green: 0.62, blue: 0.25)
        }
    }

    /// 0…1 level for gauges, or nil when the metric is a rate rather than a share.
    func fraction(_ m: SystemMonitor) -> Double? {
        switch self {
        case .cpu: return m.cpu
        case .memory: return m.memoryFraction
        case .gpu: return m.gpu
        case .network: return nil
        }
    }

    func shortValue(_ m: SystemMonitor) -> String {
        if self == .network { return SystemMonitor.shortRate(m.downBytesPerSec) }
        guard let f = fraction(m) else { return "–" }
        return AppLanguage.percent(Int((f * 100).rounded()))
    }
}

/// Colour that warms up as a share gets high.
func loadColor(_ base: Color, _ value: Double) -> Color {
    value > 0.9 ? .red : value > 0.75 ? .orange : base
}

// MARK: - Side wings

struct SystemCompact: View {
    var notchWidth: CGFloat
    var height: CGFloat
    @ObservedObject private var monitor = SystemMonitor.shared
    @AppStorage(Pref.wingLeft) private var left = "cpu"
    @AppStorage(Pref.wingRight) private var right = "memory"

    var body: some View {
        Wings(notchWidth: notchWidth, height: height) {
            WingGauge(metric: Metric(rawValue: left) ?? .cpu, monitor: monitor)
        } right: {
            WingGauge(metric: Metric(rawValue: right) ?? .memory, monitor: monitor)
        }
        .onAppear { monitor.demand("wings", true) }
        .onDisappear { monitor.demand("wings", false) }
    }
}

/// Ring and number for one metric, sized to fit beside the notch.
/// Live figures update once a second without animation: an animated change re-renders the
/// whole island at display refresh rate for a good part of every second.
struct WingGauge: View {
    var metric: Metric
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        let fraction = metric.fraction(monitor)
        let color = loadColor(metric.tint, fraction ?? 0)
        HStack(spacing: 4) {
            ZStack {
                Circle().stroke(color.opacity(0.22), lineWidth: 2.4)
                if let fraction {
                    Circle().trim(from: 0, to: max(0.02, fraction))
                        .stroke(color, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                } else {
                    Image(systemName: "arrow.down").font(.system(size: 6.5, weight: .black)).foregroundStyle(color)
                }
            }
            .frame(width: 13, height: 13)
            Text(metric.shortValue(monitor))
                .font(.system(size: 10.5, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize()
        }
        .help(metric.title)
    }
}

// MARK: - Sparkline

/// Filled line chart of recent values. `scale` fixes the top of the chart; when nil the chart
/// scales to its own peak (used for network rates).
struct Sparkline: View {
    var values: [Double]
    var tint: Color
    var scale: Double? = 1
    var filled = true

    var body: some View {
        GeometryReader { geo in
            let peak = max(scale ?? (values.max() ?? 1), 0.0001)
            let count = SystemMonitor.historyLength
            let step = geo.size.width / CGFloat(count - 1)
            let offset = CGFloat(count - values.count) * step
            let points = values.enumerated().map { i, v in
                CGPoint(x: offset + CGFloat(i) * step, y: geo.size.height * (1 - CGFloat(min(1, v / peak))))
            }
            ZStack {
                if points.count > 1, filled {
                    Path { p in
                        p.move(to: CGPoint(x: points[0].x, y: geo.size.height))
                        points.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: points.last!.x, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                }
                if points.count > 1 {
                    Path { p in
                        p.move(to: points[0])
                        points.dropFirst().forEach { p.addLine(to: $0) }
                    }
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                    Circle().fill(tint).frame(width: 4, height: 4)
                        .shadow(color: tint, radius: 3)
                        .position(points.last!)
                }
            }
        }
    }
}

// MARK: - System tab

/// The cards view: one card per metric plus a strip of system facts.
struct SystemOverview: View {
    @ObservedObject private var monitor = SystemMonitor.shared

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                MetricCard(metric: .cpu, value: percent(monitor.cpu),
                           detail: String(localized: "\(monitor.coreCount) çekirdek · sistem %\(Int(monitor.cpuSystem * 100))")) {
                    CoreBars(cores: monitor.cores, tint: Metric.cpu.tint)
                }
                MetricCard(metric: .memory, value: SystemMonitor.gigabytes(monitor.memoryUsed),
                           detail: String(localized: "\(SystemMonitor.gigabytes(monitor.memoryTotal)) içinden · sıkışt. \(SystemMonitor.gigabytes(monitor.memoryCompressed))")) {
                    PressureBar(pressure: monitor.memoryPressure, fraction: monitor.memoryFraction)
                }
                MetricCard(metric: .gpu, value: monitor.gpu.map(percent) ?? "–",
                           detail: monitor.gpu == nil ? String(localized: "Sürücü kullanım bildirmiyor") : String(localized: "Grafik işlemci kullanımı")) {
                    EmptyView()
                }
                MetricCard(metric: .network, value: SystemMonitor.rate(monitor.downBytesPerSec),
                           detail: "↑ \(SystemMonitor.rate(monitor.upBytesPerSec))", chartScale: nil) {
                    EmptyView()
                }
            }
            HStack(spacing: 6) {
                if monitor.diskTotal > 0 {
                    Chip(text: String(localized: "\(ByteCountFormatter.string(fromByteCount: monitor.diskFree, countStyle: .file)) boş"),
                         symbol: "internaldrive.fill", tint: monitor.diskFree < 20_000_000_000 ? .orange : .white)
                }
                ThermalChip()
                Chip(text: uptime, symbol: "clock.fill", tint: .white).help("Açık kalma süresi")
                Spacer(minLength: 0)
                ForEach(monitor.topProcesses.prefix(1), id: \.name) { p in
                    Chip(text: String(localized: "\(p.name) %\(Int(p.cpu))"), symbol: "flame.fill", tint: loadColor(.white, p.cpu / 100))
                }
            }
        }
    }

    private func percent(_ v: Double) -> String { AppLanguage.percent(Int((v * 100).rounded())) }

    private var uptime: String {
        let uptime = ProcessInfo.processInfo.systemUptime
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.allowedUnits = uptime >= 86_400 ? [.day, .hour] : [.hour, .minute]
        var calendar = Calendar.current
        calendar.locale = AppLanguage.locale
        f.calendar = calendar
        return f.string(from: uptime) ?? ""
    }
}

struct MetricCard<Extra: View>: View {
    var metric: Metric
    var value: String
    var detail: String
    var chartScale: Double? = 1
    @ViewBuilder var extra: Extra
    @ObservedObject private var monitor = SystemMonitor.shared

    var body: some View {
        let fraction = metric.fraction(monitor) ?? 0
        let tint = metric == .network ? metric.tint : loadColor(metric.tint, fraction)
        Card(padding: 10, tint: tint) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    SectionLabel(title: metric.title, symbol: metric.symbol)
                    Spacer(minLength: 0)
                }
                Text(value)
                    .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                        .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(detail)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.subtleText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Sparkline(values: monitor.history[metric] ?? [], tint: tint, scale: chartScale)
                    .frame(maxHeight: .infinity)
                extra
            }
        }
    }
}

/// One thin bar per core, tallest when the core is busiest.
struct CoreBars: View {
    var cores: [Double]
    var tint: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(cores.enumerated()), id: \.offset) { _, load in
                VStack {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(loadColor(tint, load))
                        .frame(height: max(2, 12 * load))
                }
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.07)))
            }
        }
        .frame(height: 12)
    }
}

struct PressureBar: View {
    var pressure: Int
    var fraction: Double

    var body: some View {
        let (label, color): (String, Color) = pressure >= 4 ? (String(localized: "Kritik"), .red) : pressure >= 2 ? (String(localized: "Baskı var"), .orange) : ("Normal", .green)
        HStack(spacing: 6) {
            LevelBar(value: fraction, tint: color, height: 4)
            Text(label).font(.system(size: 8.5, weight: .bold)).foregroundStyle(color).fixedSize()
        }
        .frame(height: 12)
    }
}

struct ThermalChip: View {
    @State private var state = ProcessInfo.processInfo.thermalState

    var body: some View {
        let (text, color): (String, Color) = switch state {
        case .nominal: ("Normal", .green)
        case .fair: (String(localized: "Ilık"), .yellow)
        case .serious: (String(localized: "Sıcak"), .orange)
        case .critical: (String(localized: "Çok sıcak"), .red)
        @unknown default: (String(localized: "Bilinmiyor"), .gray)
        }
        Chip(text: text, symbol: "thermometer.medium", tint: color)
            .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
                state = ProcessInfo.processInfo.thermalState
            }
    }
}

import SwiftUI

/// System tab: a switcher between the overview cards, the app list and large charts.
struct SystemTab: View {
    @AppStorage(Pref.systemView) private var view = "overview"
    @AppStorage(Pref.liveActivity) private var liveActivity = "music"
    @Namespace private var switcher

    private var inWings: Bool { liveActivity == "musicThenSystem" || liveActivity == "system" }
    private let views: [(id: String, title: String, symbol: String)] = [
        ("overview", "Genel", "square.grid.2x2.fill"),
        ("apps", "Uygulamalar", "list.bullet.rectangle.fill"),
        ("charts", "Grafikler", "chart.xyaxis.line"),
    ]

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 6) {
                HStack(spacing: 2) {
                    ForEach(views, id: \.id) { v in
                        Button { withAnimation(Motion.content) { view = v.id } } label: {
                            Label(v.title, systemImage: v.symbol)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(view == v.id ? .white : .white.opacity(0.5))
                                .padding(.horizontal, 9)
                                .frame(height: 22)
                                .background {
                                    if view == v.id {
                                        Capsule().fill(Metric.cpu.tint.opacity(0.32))
                                            .matchedGeometryEffect(id: "view", in: switcher)
                                    }
                                }
                                .contentShape(Capsule())
                        }
                        .buttonStyle(PressScaleStyle(scale: 0.94))
                    }
                }
                .padding(2)
                .background(Capsule().fill(.white.opacity(0.06)))
                Spacer()
                Button {
                    liveActivity = inWings ? "music" : "musicThenSystem"
                } label: {
                    Label(inWings ? "Kanatlarda" : "Kanatlara ekle", systemImage: inWings ? "checkmark.circle.fill" : "plus.circle")
                }
                .buttonStyle(.pill(inWings ? .green : Metric.cpu.tint))
                .help("Müzik çalmıyorken çentiğin iki yanında canlı ölçümleri göster")
            }
            Group {
                switch view {
                case "apps": ProcessListView()
                case "charts": SystemCharts()
                default: SystemOverview()
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .transition(.opacity)
        }
        .onAppear { SystemMonitor.shared.demand("tab", true) }
        .onDisappear { SystemMonitor.shared.demand("tab", false) }
    }
}

// MARK: - Apps

struct ProcessListView: View {
    @ObservedObject private var monitor = ProcessMonitor.shared
    @AppStorage(Pref.processScope) private var scope = "apps"
    @AppStorage(Pref.processSort) private var sort = "cpu"

    private var rows: [ProcessGroup] {
        let source = scope == "apps" ? monitor.apps : monitor.processes
        return Array(source.sorted { sort == "cpu" ? ($0.cpu, $0.memory) > ($1.cpu, $1.memory) : $0.memory > $1.memory }.prefix(50))
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Menu {
                    Picker("", selection: $scope) {
                        Text("Uygulamalar (yardımcılarıyla)").tag("apps")
                        Text("Tüm işlemlerim").tag("all")
                    }
                    .pickerStyle(.inline)
                } label: {
                    HStack(spacing: 3) {
                        Text(scope == "apps" ? "UYGULAMA" : "İŞLEM").tracking(0.8)
                        Text("\((scope == "apps" ? monitor.apps : monitor.processes).count)").foregroundStyle(.white.opacity(0.35))
                        Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                    }
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
                SortHeader(title: "CPU", key: "cpu", sort: $sort).frame(width: 96, alignment: .trailing)
                SortHeader(title: "BELLEK", key: "memory", sort: $sort).frame(width: 64, alignment: .trailing)
                Color.clear.frame(width: 58)
            }
            .padding(.horizontal, 8)
            if rows.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 3) {
                        ForEach(rows) { ProcessRow(group: $0, showsCount: scope == "apps") }
                    }
                }
            }
        }
        .onAppear { ProcessMonitor.shared.demand(true) }
        .onDisappear { ProcessMonitor.shared.demand(false) }
    }
}

struct SortHeader: View {
    var title: String
    var key: String
    @Binding var sort: String

    var body: some View {
        Button { sort = key } label: {
            HStack(spacing: 2) {
                Text(title).tracking(0.8)
                if sort == key { Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)) }
            }
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(sort == key ? .white.opacity(0.85) : .white.opacity(0.4))
        }
        .buttonStyle(.plain)
    }
}

struct ProcessRow: View {
    var group: ProcessGroup
    var showsCount: Bool
    @State private var hover = false
    @State private var confirmForce = false

    var body: some View {
        let cpuColor = loadColor(Metric.cpu.tint, min(1, group.cpu / 100))
        HStack(spacing: 8) {
            Image(nsImage: group.icon).resizable().frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(group.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Text(showsCount ? "\(group.pids.count) işlem" : "PID \(group.pids.first ?? 0)")
                    .font(.system(size: 9, weight: .medium).monospacedDigit()).foregroundStyle(Color.subtleText)
            }
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                LevelBar(value: min(1, group.cpu / 100), tint: cpuColor, height: 4).frame(width: 40)
                Text(String(format: "%%%.1f", group.cpu))
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(group.cpu >= 1 ? cpuColor : .white.opacity(0.45))
                    .frame(width: 48, alignment: .trailing)
            }
            .frame(width: 96, alignment: .trailing)
            Text(Self.memory(group.memory))
                .font(.system(size: 10.5, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(group.memory > 1_073_741_824 ? Metric.memory.tint : .white.opacity(0.75))
                .frame(width: 64, alignment: .trailing)
            // The column keeps its width when no button is showing, so rows line up with the header.
            ZStack(alignment: .trailing) {
                Color.clear
                action
            }
            .frame(width: 58)
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(CardSurface(tint: confirmForce ? .red : nil, radius: 9).opacity(hover || confirmForce ? 1 : 0.45))
        .onHover { hover = $0 }
        .contextMenu {
            if !group.isProtected {
                Button("Kapat") { ProcessMonitor.shared.quit(group, force: false) }
                Button("Zorla Kapat…") { confirmForce = true }
            }
            if let path = group.bundlePath {
                Button("Finder'da Göster") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            }
            Button("PID'yi Kopyala") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(group.pids.map(String.init).joined(separator: " "), forType: .string)
            }
        }
        .animation(Motion.quick, value: hover)
    }

    @ViewBuilder
    private var action: some View {
        if group.isProtected {
            Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.white.opacity(hover ? 0.4 : 0))
                .help("Sistem için gerekli; buradan kapatılamaz")
        } else if confirmForce {
            Button("Emin misin?") {
                ProcessMonitor.shared.quit(group, force: true)
                confirmForce = false
            }
            .buttonStyle(.pill(.red))
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { confirmForce = false }
            }
            .help("Kaydedilmemiş değişiklikler kaybolur")
        } else if hover {
            Button("Kapat") { ProcessMonitor.shared.quit(group, force: false) }
                .buttonStyle(.pill(.red))
                .help("Uygulamadan kapanmasını ister (⌘Q gibi). Zorla kapatmak için sağ tıkla.")
        }
    }

    static func memory(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        return mb >= 1024 ? String(format: "%.2f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }
}

// MARK: - Charts

struct SystemCharts: View {
    @ObservedObject private var monitor = SystemMonitor.shared

    var body: some View {
        HStack(spacing: 8) {
            Card(padding: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        SectionLabel(title: "Son 60 saniye", symbol: "chart.xyaxis.line")
                        Spacer()
                        legend(.cpu, monitor.cpu)
                        legend(.memory, monitor.memoryFraction)
                        if let gpu = monitor.gpu { legend(.gpu, gpu) }
                    }
                    ZStack {
                        GridLines()
                        Sparkline(values: monitor.history[.memory] ?? [], tint: Metric.memory.tint, filled: false)
                        Sparkline(values: monitor.history[.gpu] ?? [], tint: Metric.gpu.tint, filled: false)
                        Sparkline(values: monitor.history[.cpu] ?? [], tint: Metric.cpu.tint)
                    }
                }
            }
            Card(padding: 10, tint: Metric.network.tint) {
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel(title: "Ağ", symbol: "arrow.up.arrow.down")
                    HStack(spacing: 10) {
                        rate("arrow.down", monitor.downBytesPerSec)
                        rate("arrow.up", monitor.upBytesPerSec)
                    }
                    Sparkline(values: monitor.history[.network] ?? [], tint: Metric.network.tint, scale: nil)
                }
            }
            .frame(width: 190)
        }
    }

    private func legend(_ metric: Metric, _ value: Double) -> some View {
        HStack(spacing: 4) {
            Circle().fill(metric.tint).frame(width: 6, height: 6)
            Text("\(metric.title) %\(Int((value * 100).rounded()))")
                .font(.system(size: 9.5, weight: .semibold).monospacedDigit()).foregroundStyle(.white.opacity(0.8))
        }
    }

    private func rate(_ symbol: String, _ value: Double) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(Metric.network.tint)
            Text(SystemMonitor.rate(value)).font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
        }
    }
}

/// Faint horizontal guides at 25, 50 and 75 percent.
struct GridLines: View {
    var body: some View {
        GeometryReader { geo in
            ForEach([0.25, 0.5, 0.75], id: \.self) { f in
                Path { p in
                    let y = geo.size.height * (1 - f)
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
                .stroke(.white.opacity(0.07), style: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
            }
        }
    }
}

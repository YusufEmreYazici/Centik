import SwiftUI

/// Home card when nothing is playing: the time, battery, quick actions and the last track.
struct IdleDashboard: View {
    @ObservedObject private var battery = BatteryService.shared
    @ObservedObject private var awake = KeepAwake.shared
    @ObservedObject private var timer = TimerService.shared
    @ObservedObject private var shelf = ShelfStore.shared
    @ObservedObject private var music = MusicService.shared
    @Environment(\.islandAccent) private var accent

    var body: some View {
        Card(padding: 12, tint: accent.opacity(0.7)) {
            VStack(alignment: .leading, spacing: 10) {
                header
                actions
                lastPlayed
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            TimelineView(.everyMinute) { context in
                VStack(alignment: .leading, spacing: 0) {
                    Text(Self.greeting(context.date))
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(accent)
                    Text(context.date, format: .dateTime.hour().minute())
                        .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                }
            }
            Spacer(minLength: 0)
            WeatherBadge()
            if battery.hasBattery {
                BatteryRing(level: battery.level, charging: battery.isCharging)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            QuickAction(symbol: awake.isOn ? "cup.and.saucer.fill" : "cup.and.saucer",
                        title: awake.isOn ? "Uyanık" : "Uyanık tut",
                        subtitle: awake.isOn ? (awake.until.map { "\($0.formatted(date: .omitted, time: .shortened))'e kadar" } ?? "Açık") : "Uykuyu engelle",
                        tint: .orange, active: awake.isOn) { awake.toggle() }
                .contextMenu {
                    Button("30 dakika") { awake.start(for: 1800) }
                    Button("1 saat") { awake.start(for: 3600) }
                    Button("2 saat") { awake.start(for: 7200) }
                    Button("Süresiz") { awake.start() }
                    if awake.isOn { Divider(); Button("Kapat") { awake.stop() } }
                }
            QuickAction(symbol: "timer", title: timer.isActive ? TimerService.format(timer.remaining) : "25 dk odak",
                        subtitle: timer.isActive ? (timer.isRunning ? "Çalışıyor" : "Duraklatıldı") : "Zamanlayıcı",
                        tint: .pink, active: timer.isActive) {
                if timer.isActive { IslandModel.shared.tab = .timer } else { timer.start(minutes: 25) }
            }
            QuickAction(symbol: "person.crop.square", title: "Ayna", subtitle: "Kamera önizleme", tint: .blue, active: false) {
                withAnimation(Motion.content) { IslandModel.shared.mirrorOn = true }
            }
            QuickAction(symbol: "camera.viewfinder", title: "Ekran", subtitle: "görüntüsü", tint: .teal, active: false) {
                IslandModel.shared.collapse()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.screenshot.launcher") {
                        NSWorkspace.shared.openApplication(at: url, configuration: .init())
                    }
                }
            }
            QuickAction(symbol: "tray.full.fill", title: "Raf", subtitle: shelf.urls.isEmpty ? "Boş" : "\(shelf.urls.count) öğe",
                        tint: .yellow, active: !shelf.urls.isEmpty) {
                withAnimation(Motion.content) { IslandModel.shared.tab = .shelf }
            }
        }
    }

    @ViewBuilder
    private var lastPlayed: some View {
        HStack(spacing: 8) {
            if let last = music.lastTrack {
                Image(systemName: "music.note").font(.system(size: 10, weight: .bold)).foregroundStyle(accent)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(accent.opacity(0.18)))
                VStack(alignment: .leading, spacing: 0) {
                    Text("Son çalan · \(last.app.displayName)").font(.system(size: 8.5, weight: .bold)).tracking(0.5)
                        .foregroundStyle(Color.subtleText)
                    Text("\(last.title) — \(last.artist)").font(.system(size: 11, weight: .semibold)).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button { music.resume(last.app) } label: { Label("Devam et", systemImage: "play.fill") }
                    .buttonStyle(.pill(accent))
            } else {
                Text("Müzik çalmıyor").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.subtleText)
                Spacer(minLength: 0)
                PlayerLaunchButton(app: .spotify)
                PlayerLaunchButton(app: .music)
            }
        }
        .frame(height: 26)
    }

    static func greeting(_ date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: return "Günaydın"
        case 12..<17: return "İyi günler"
        case 17..<22: return "İyi akşamlar"
        default: return "İyi geceler"
        }
    }
}

struct QuickAction: View {
    var symbol: String
    var title: String
    var subtitle: String
    var tint: Color
    var active: Bool
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(active ? .black : tint)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(active ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(tint.opacity(0.16))))
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.system(size: 9, weight: .medium)).foregroundStyle(Color.subtleText).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(CardSurface(tint: active || hover ? tint : nil, radius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle(scale: 0.94))
        .onHover { hover = $0 }
        .animation(Motion.quick, value: hover)
        .animation(Motion.quick, value: active)
    }
}

struct BatteryRing: View {
    var level: Int
    var charging: Bool

    var body: some View {
        let color = batteryColor(level, charging: charging)
        ZStack {
            Circle().stroke(color.opacity(0.2), lineWidth: 4)
            Circle().trim(from: 0, to: CGFloat(level) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: -1) {
                Image(systemName: charging ? "bolt.fill" : "battery.75percent").font(.system(size: 8, weight: .bold))
                Text("%\(level)").font(.system(size: 10, weight: .bold, design: .rounded).monospacedDigit())
            }
            .foregroundStyle(color)
        }
        .frame(width: 44, height: 44)
    }
}

struct WeatherBadge: View {
    @ObservedObject private var weather = WeatherService.shared
    @AppStorage(Pref.weatherCity) private var city = ""

    var body: some View {
        if city.isEmpty {
            Button { SettingsWindow.shared.show(page: .tools) } label: {
                Label("Hava durumu ekle", systemImage: "cloud.sun.fill")
            }
            .buttonStyle(.pill(.cyan))
        } else if let temp = weather.temperature {
            let condition = weather.condition
            HStack(spacing: 8) {
                Image(systemName: condition.symbol)
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 22))
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(Int(temp.rounded()))°").font(.system(size: 20, weight: .bold, design: .rounded))
                        Text(condition.text).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                    }
                    Text(detail).font(.system(size: 9, weight: .medium)).foregroundStyle(Color.subtleText).lineLimit(1)
                }
            }
            .help("\(city) · \(weather.updated.map { "güncellendi \($0.formatted(date: .omitted, time: .shortened))" } ?? "")")
        } else {
            Image(systemName: weather.failed ? "wifi.exclamationmark" : "cloud")
                .foregroundStyle(Color.subtleText)
                .help(weather.failed ? "Hava durumu alınamadı" : "Yükleniyor")
        }
    }

    private var detail: String {
        var parts = [city]
        if let h = weather.high, let l = weather.low { parts.append("↑\(Int(h.rounded()))° ↓\(Int(l.rounded()))°") }
        if let rain = weather.rainChance, rain >= 20 { parts.append("☂︎ %\(rain)") }
        return parts.joined(separator: " · ")
    }
}

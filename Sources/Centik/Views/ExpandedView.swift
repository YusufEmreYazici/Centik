import SwiftUI
import UniformTypeIdentifiers

struct ExpandedView: View {
    @ObservedObject private var model = IslandModel.shared
    @ObservedObject private var battery = BatteryService.shared
    @Namespace private var tabSpace
    // Read so the tab bar redraws when tabs are turned on, off or reordered in Settings.
    @AppStorage(Pref.hiddenTabs) private var hiddenTabs = ""
    @AppStorage(Pref.tabOrder) private var tabOrder = ""

    var body: some View {
        VStack(spacing: 0) {
            Wings(notchWidth: model.geometry.notchWidth, height: model.geometry.notchHeight) {
                HStack(spacing: 2) {
                    ForEach(model.visibleTabs) { tab in
                        TabButton(tab: tab, selected: model.tab == tab && !model.mirrorOn, namespace: tabSpace) {
                            withAnimation(Motion.content) {
                                model.mirrorOn = false
                                model.tab = tab
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 14)
            } right: {
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    TimelineView(.everyMinute) { context in
                        Text(context.date, format: .dateTime.hour().minute())
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    if battery.hasBattery {
                        HStack(spacing: 3) {
                            Text("%\(battery.level)").font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                            Image(systemName: batterySymbol(battery.level, charging: battery.isCharging))
                                .font(.system(size: 13))
                        }
                        .foregroundStyle(batteryColor(battery.level, charging: battery.isCharging))
                    }
                    IconButton(symbol: model.mirrorOn ? "person.crop.square.fill" : "person.crop.square", size: 12,
                               active: model.mirrorOn) {
                        withAnimation(Motion.content) { model.mirrorOn.toggle() }
                    }
                    .help("Ayna")
                    .accessibilityLabel("Ayna")
                    IconButton(symbol: "gearshape.fill", size: 11) { SettingsWindow.shared.show() }
                        .help("Ayarlar")
                        .accessibilityLabel("Ayarlar")
                }
                .padding(.trailing, 12)
            }

            Group {
                if model.mirrorOn {
                    MirrorPanel()
                } else {
                switch model.tab {
                case .home: HomeTab()
                case .system: SystemTab()
                case .shelf: ShelfTab()
                case .clipboard: ClipboardTab()
                case .timer: TimerTab()
                case .notes: NotesTab()
                case .assistant: AssistantTab()
                case .agents: AgentsTab()
                }
                }
            }
            .id(model.mirrorOn ? "mirror" : model.tab.rawValue)
            .transition(AnyTransition(.blurReplace).combined(with: .offset(y: 6)))
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .foregroundStyle(.white)
    }
}

struct TabButton: View {
    var tab: IslandTab
    var selected: Bool
    var namespace: Namespace.ID
    var action: () -> Void
    @State private var hover = false
    @Environment(\.islandAccent) private var accent

    var body: some View {
        Button(action: action) { label }
            .buttonStyle(PressScaleStyle(scale: 0.9))
            .help(tab.title)
            .accessibilityLabel(tab.title)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .onHover { hover = $0 }
    }

    private var label: some View {
        Group {
            HStack(spacing: 5) {
                if DemoClock.slowdown == 1 {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 11.5, weight: .semibold))
                        .symbolEffect(.bounce, value: selected)
                } else if let image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 11.5, weight: .semibold)) {
                    // The demo recorder renders layers itself, and symbol images drawn the usual
                    // way don't always reach it; a plain image does.
                    Image(nsImage: image).renderingMode(.template)
                }
            }
            .foregroundStyle(selected ? .white : .white.opacity(hover ? 0.8 : 0.45))
            .frame(width: 28)
            .frame(height: 24)
            .background {
                if selected {
                    // One highlight that slides between tabs.
                    Capsule().fill(accent.opacity(0.3))
                        .overlay(Capsule().strokeBorder(accent.opacity(0.55), lineWidth: 0.6))
                        .matchedGeometryEffect(id: "tab", in: namespace)
                } else if hover {
                    Capsule().fill(Color.white.opacity(0.07))
                }
            }
            .contentShape(Capsule())
        }
    }
}

// MARK: - Home

struct HomeTab: View {
    @AppStorage(Pref.calendarEnabled) private var calendarEnabled = true
    @ObservedObject private var music = MusicService.shared

    var body: some View {
        HStack(spacing: 10) {
            if music.hasTrack { MusicCard() } else { IdleDashboard() }
            if calendarEnabled {
                CalendarCard().frame(width: 216)
            }
        }
    }
}

struct MusicCard: View {
    @ObservedObject private var music = MusicService.shared
    @ObservedObject private var audio = AudioService.shared
    @ObservedObject private var brightness = BrightnessService.shared
    @Environment(\.islandAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            player
            controlsRow
        }
        .padding(13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            ArtworkBackdrop(image: music.backdrop, accent: accent)
                .animation(Motion.content, value: music.title)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .overlay(CardSurface().opacity(0.7).allowsHitTesting(false))
    }

    private var player: some View {
        let edge: Edge = music.skipDirection < 0 ? .leading : .trailing
        return HStack(alignment: .top, spacing: 14) {
            ArtworkView(image: music.artwork, size: 92, radius: 14)
                .id(music.title + music.artist)
                .transition(.push(from: edge))
                .frame(width: 92, height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.6))
                .shadow(color: accent.opacity(0.5), radius: 16, y: 4)
                .scaleEffect(music.isPlaying ? 1 : 0.93)
                .onTapGesture { music.openPlayer() }

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Chip(text: music.source?.displayName ?? "", symbol: "music.note", tint: accent)
                    if music.isPlaying {
                        EqualizerLayer(playing: true, color: accent).frame(width: 18, height: 12)
                    }
                    Spacer(minLength: 0)
                    IconButton(symbol: "shuffle", size: 11, active: music.shuffle) { music.toggleShuffle() }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(music.title).font(.system(size: 16, weight: .bold)).lineLimit(1)
                    Text(music.artist).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                }
                .id(music.title + music.artist)
                .transition(AnyTransition.push(from: edge).combined(with: AnyTransition(.blurReplace)))
                .padding(.top, 4)
                Spacer(minLength: 4)
                ProgressRow()
            }
        }
        .frame(height: 92)
        .animation(Motion.content, value: music.title)
        .animation(Motion.hover, value: music.isPlaying)
    }

    private var controlsRow: some View {
        HStack(spacing: 12) {
            if music.hasTrack {
                HStack(spacing: 8) {
                    CircleControl(symbol: "backward.fill", size: 32, bounce: music.backCount) { music.previous() }
                    CircleControl(symbol: music.isPlaying ? "pause.fill" : "play.fill", size: 40, filled: true,
                                  bounce: music.isPlaying ? 1 : 0) { music.playPause() }
                    CircleControl(symbol: "forward.fill", size: 32, bounce: music.forwardCount) { music.next() }
                }
            }
            if audio.hasVolumeControl || brightness.available {
            HStack(spacing: 12) {
                if audio.hasVolumeControl {
                    SliderRow(symbol: audio.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                              value: Binding(get: { Double(audio.muted ? 0 : audio.volume) },
                                             set: { audio.setVolume(Float($0)) }),
                              onSymbolTap: { audio.toggleMute() })
                }
                if brightness.available {
                    SliderRow(symbol: "sun.max.fill",
                              value: Binding(get: { Double(brightness.brightness) }, set: { brightness.set(Float($0)) }))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Capsule().fill(.black.opacity(0.25)))
            }
        }
    }
}

struct PlayerLaunchButton: View {
    var app: PlayerApp

    var body: some View {
        Button { MusicService.shared.launch(app) } label: {
            HStack(spacing: 5) {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.rawValue) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 15, height: 15)
                }
                Text(app.displayName)
            }
        }
        .buttonStyle(.pill)
    }
}

struct SliderRow: View {
    var symbol: String
    @Binding var value: Double
    var onSymbolTap: (() -> Void)?

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 15)
                .onTapGesture { onSymbolTap?() }
            ScrubBar(value: value, tint: .white, height: 4) { value = $0 }
        }
    }
}

/// Thin bar that can be clicked or dragged to set a 0…1 value.
struct ScrubBar: View {
    var value: Double
    var tint: Color
    var height: CGFloat
    var onChange: (Double) -> Void
    var onCommit: ((Double) -> Void)?
    @State private var dragging: Double?
    @State private var hover = false

    var body: some View {
        GeometryReader { geo in
            LevelBar(value: dragging ?? value, tint: tint, height: hover || dragging != nil ? height + 2 : height)
                .shadow(color: tint.opacity(hover ? 0.5 : 0), radius: 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let v = min(1, max(0, g.location.x / geo.size.width))
                        dragging = v
                        if onCommit == nil { onChange(v) }
                    }
                    .onEnded { g in
                        let v = min(1, max(0, g.location.x / geo.size.width))
                        dragging = nil
                        if let onCommit { onCommit(v) } else { onChange(v) }
                    })
        }
        .frame(height: 14)
        .onHover { hover = $0 }
        .animation(Motion.quick, value: hover)
    }
}

struct ProgressRow: View {
    @ObservedObject private var music = MusicService.shared
    @Environment(\.islandAccent) private var accent

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let pos = music.position
            let dur = max(music.duration, 1)
            VStack(spacing: 1) {
                ScrubBar(value: pos / dur, tint: accent, height: 4, onChange: { _ in },
                         onCommit: { music.seek(to: $0 * dur) })
                HStack {
                    Text(Self.time(pos))
                    Spacer()
                    Text("-" + Self.time(max(0, dur - pos)))
                }
                .font(.system(size: 9.5, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    static func time(_ s: Double) -> String {
        let t = Int(s)
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

struct CalendarCard: View {
    @ObservedObject private var calendar = CalendarService.shared
    @Environment(\.islandAccent) private var accent

    var body: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .center, spacing: 9) {
                    Text(Date.now, format: .dateTime.day())
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(Date.now, format: .dateTime.weekday(.wide))
                            .font(.system(size: 12, weight: .bold)).foregroundStyle(accent)
                        Text(Date.now, format: .dateTime.month(.wide).year())
                            .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color.subtleText)
                    }
                    Spacer(minLength: 0)
                }
                WeekStrip(accent: accent)
                content
                Spacer(minLength: 0)
            }
        }
        .onAppear { calendar.reload() }
    }

    @ViewBuilder
    private var content: some View {
        if !calendar.authorized {
            VStack(alignment: .leading, spacing: 6) {
                Text("Etkinliklerini görmek için takvim erişimi ver.")
                    .font(.system(size: 10.5)).foregroundStyle(Color.subtleText)
                    .fixedSize(horizontal: false, vertical: true)
                Button(calendar.denied ? "Sistem Ayarları" : "İzin Ver") {
                    calendar.denied ? calendar.openPrivacySettings() : calendar.requestAccess()
                }
                .buttonStyle(.pill(accent))
            }
        } else if calendar.events.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                Text("Bugün takvimin boş").foregroundStyle(.white.opacity(0.7))
            }
            .font(.system(size: 11, weight: .medium))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(calendar.events.prefix(2)) { event in EventRow(event: event) }
                if calendar.events.count > 2 {
                    Text("+\(calendar.events.count - 2) etkinlik daha")
                        .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Color.subtleText)
                }
            }
        }
    }
}

struct WeekStrip: View {
    var accent: Color

    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let start = cal.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { i in
                let day = cal.date(byAdding: .day, value: i, to: start) ?? today
                let isToday = cal.isDate(day, inSameDayAs: today)
                VStack(spacing: 2) {
                    Text(day, format: .dateTime.weekday(.narrow))
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.white.opacity(isToday ? 0.9 : 0.4))
                    Text(day, format: .dateTime.day())
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(isToday ? .black : .white.opacity(day < today ? 0.35 : 0.8))
                        .frame(width: 21, height: 21)
                        .background(Circle().fill(isToday ? AnyShapeStyle(accent.gradient) : AnyShapeStyle(Color.clear)))
                        .shadow(color: isToday ? accent.opacity(0.6) : .clear, radius: 5)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

struct EventRow: View {
    var event: CalEvent

    var body: some View {
        let ongoing = !event.allDay && event.start <= .now
        HStack(spacing: 7) {
            Capsule().fill(Color(nsColor: event.color)).frame(width: 3, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Text(timeText).font(.system(size: 9.5, weight: .medium).monospacedDigit()).foregroundStyle(Color.subtleText)
            }
            Spacer(minLength: 0)
            if let url = event.joinURL {
                Button { NSWorkspace.shared.open(url) } label: { Label("Katıl", systemImage: "video.fill") }
                    .buttonStyle(.pill(ongoing ? .green : Color(nsColor: event.color)))
                    .help("\(event.joinServiceName) toplantısına katıl")
            } else if ongoing {
                Chip(text: "ŞİMDİ", tint: Color(nsColor: event.color))
            }
        }
    }

    private var timeText: String {
        if event.allDay { return "Tüm gün" }
        let f = Date.FormatStyle.dateTime.hour().minute()
        return "\(event.start.formatted(f)) – \(event.end.formatted(f))"
    }
}

// MARK: - Shelf

struct ShelfTab: View {
    @ObservedObject private var shelf = ShelfStore.shared
    @ObservedObject private var model = IslandModel.shared
    @Environment(\.islandAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                SectionLabel(title: "Raf", symbol: "tray.full.fill")
                if !shelf.urls.isEmpty { Chip(text: "\(shelf.urls.count) öğe", tint: accent) }
                Spacer()
                if !shelf.urls.isEmpty {
                    Button { shelf.airDrop() } label: { Label("AirDrop", systemImage: "dot.radiowaves.left.and.right") }
                        .buttonStyle(.pill(.blue))
                    Button { shelf.clear() } label: { Label("Temizle", systemImage: "trash") }
                        .buttonStyle(.pill(.red))
                }
            }
            if shelf.urls.isEmpty {
                DropZone(targeted: model.dropTargeted, accent: accent)
            } else if shelf.urls.count <= 6 {
                items
            } else {
                ScrollView(.horizontal, showsIndicators: false) { items }
            }
        }
    }

    private var items: some View {
        HStack(spacing: 9) {
            ForEach(shelf.urls, id: \.self) { url in ShelfItem(url: url) }
            if shelf.urls.count < 6 { AddMoreTile(accent: accent) }
        }
    }
}

struct DropZone: View {
    var targeted: Bool
    var accent: Color
    @State private var phase: CGFloat = 0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(accent.opacity(targeted ? 0.16 : 0.05))
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.4, dash: [7, 6], dashPhase: phase))
                .foregroundStyle(targeted ? accent : .white.opacity(0.22))
            VStack(spacing: 10) {
                EmptyState(symbol: targeted ? "arrow.down.circle.fill" : "tray.and.arrow.down.fill",
                           title: targeted ? "Bırak, rafa ekleyeyim" : "Dosyaları buraya bırak",
                           subtitle: "Finder'dan ya da herhangi bir yerden çentiğe sürükle.",
                           tint: accent)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Chip(text: "AirDrop ile paylaş", symbol: "dot.radiowaves.left.and.right", tint: .blue)
                    Chip(text: "Geri sürükle", symbol: "hand.draw.fill", tint: .white)
                    Chip(text: "Dosyalar yerinde kalır", symbol: "lock.fill", tint: .green)
                }
            }
        }
        .scaleEffect(targeted ? 1.015 : 1)
        .animation(Motion.hover, value: targeted)
        .onChange(of: targeted) { _, on in
            if on {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { phase = -26 }
            } else {
                withAnimation(.linear(duration: 0)) { phase = 0 }
            }
        }
    }
}

struct AddMoreTile: View {
    var accent: Color

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "plus").font(.system(size: 18, weight: .semibold))
            Text("Sürükle\nbırak").font(.system(size: 9.5, weight: .medium)).multilineTextAlignment(.center)
        }
        .foregroundStyle(.white.opacity(0.35))
        .frame(width: 88, height: 122)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                .foregroundStyle(.white.opacity(0.15))
        )
    }
}

struct ShelfItem: View {
    var url: URL
    @State private var hover = false

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().frame(width: 50, height: 50)
                .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
            VStack(spacing: 1) {
                Text(url.lastPathComponent)
                    .font(.system(size: 10, weight: .semibold)).lineLimit(2).multilineTextAlignment(.center)
                Text(detail).font(.system(size: 9, weight: .medium)).foregroundStyle(Color.subtleText).lineLimit(1)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 12)
        .frame(width: 88, height: 122, alignment: .top)
        .background(CardSurface(radius: 14).opacity(hover ? 1.4 : 1))
        .overlay(alignment: .topTrailing) {
            if hover {
                Button { ShelfStore.shared.remove(url) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(.black.opacity(0.7)))
                        .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 0.6))
                }
                .buttonStyle(PressScaleStyle())
                .offset(x: 5, y: -5)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .offset(y: hover ? -2 : 0)
        .shadow(color: .black.opacity(hover ? 0.4 : 0), radius: 8, y: 4)
        .animation(Motion.hover, value: hover)
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { ShelfStore.shared.open(url) }
        .onDrag {
            IslandModel.shared.isDraggingOut = true
            return NSItemProvider(contentsOf: url) ?? NSItemProvider()
        }
        .contextMenu {
            Button("Aç") { ShelfStore.shared.open(url) }
            Button("Finder'da Göster") { ShelfStore.shared.reveal(url) }
            Button("AirDrop ile Gönder") { ShelfStore.shared.airDrop([url]) }
            Divider()
            Button("Raftan Kaldır") { ShelfStore.shared.remove(url) }
        }
        .help(url.path)
    }

    private var detail: String {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isPackageKey])
        if values?.isDirectory == true && values?.isPackage != true { return "Klasör" }
        if url.pathExtension == "app" { return "Uygulama" }
        guard let size = values?.fileSize else { return url.pathExtension.uppercased() }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

// MARK: - Timer

struct TimerTab: View {
    @ObservedObject private var timer = TimerService.shared
    private let presets: [Double] = [1, 3, 5, 10, 15, 25, 45, 60]

    var body: some View {
        HStack(spacing: 18) {
            TimerRing(progress: timer.progress, active: timer.isActive, running: timer.isRunning,
                      text: timer.isActive ? TimerService.format(timer.remaining) : "0:00")
                .frame(width: 150, height: 150)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel(title: "Hızlı başlat", symbol: "bolt.fill")
                    Spacer()
                    if timer.isActive, timer.isRunning {
                        Chip(text: "Bitiş \(Date.now.addingTimeInterval(timer.remaining).formatted(date: .omitted, time: .shortened))",
                             symbol: "flag.checkered", tint: .orange)
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 4), spacing: 7) {
                    ForEach(presets, id: \.self) { m in
                        PresetButton(minutes: Int(m)) { timer.start(minutes: m) }
                    }
                }
                HStack(spacing: 10) {
                    if timer.isActive {
                        CircleControl(symbol: timer.isRunning ? "pause.fill" : "play.fill", size: 38, filled: true, tint: .orange,
                                      bounce: timer.isRunning ? 1 : 0) {
                            timer.isRunning ? timer.pause() : timer.resume()
                        }
                        CircleControl(symbol: "plus", size: 32) { timer.add(minutes: 1) }
                        CircleControl(symbol: "xmark", size: 32, tint: .red) { timer.cancel() }
                        Text(timer.isRunning ? "Çalışıyor" : "Duraklatıldı")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.subtleText)
                    } else {
                        Image(systemName: "info.circle").foregroundStyle(Color.subtleText)
                        Text("Bir süre seç. Çalışırken geri sayım çentiğin yanında görünür.")
                            .font(.system(size: 10.5)).foregroundStyle(Color.subtleText)
                    }
                }
                .frame(height: 38)
            }
        }
    }
}

struct PresetButton: View {
    var minutes: Int
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(minutes)").font(.system(size: 15, weight: .bold, design: .rounded))
                Text("dk").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(CardSurface(tint: hover ? .orange : nil, radius: 11))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle(scale: 0.92))
        .onHover { hover = $0 }
        .animation(Motion.quick, value: hover)
    }
}

struct TimerRing: View {
    var progress: Double
    var active: Bool
    var running: Bool
    var text: String

    private let gradient = AngularGradient(colors: [.orange, .pink, .orange], center: .center)

    var body: some View {
        ZStack {
            // Minute ticks around the dial.
            ForEach(0..<60, id: \.self) { i in
                Capsule()
                    .fill(.white.opacity(i % 5 == 0 ? 0.35 : 0.12))
                    .frame(width: i % 5 == 0 ? 2 : 1, height: i % 5 == 0 ? 6 : 4)
                    .offset(y: -70)
                    .rotationEffect(.degrees(Double(i) * 6))
            }
            Circle().stroke(.white.opacity(0.07), lineWidth: 9).padding(14)
            Circle()
                .trim(from: 0, to: max(0.001, progress))
                .stroke(gradient, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: .orange.opacity(active ? 0.6 : 0), radius: 8)
                .padding(14)
                .animation(.linear(duration: 0.25), value: progress)
            VStack(spacing: 2) {
                Text(text)
                    .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText(countsDown: true))
                Text(!active ? "HAZIR" : running ? "KALAN" : "DURAKLATILDI")
                    .font(.system(size: 8.5, weight: .bold)).tracking(1)
                    .foregroundStyle(active ? .orange : .white.opacity(0.4))
            }
            .animation(Motion.quick, value: text)
        }
    }
}

// MARK: - Agents

struct AgentsTab: View {
    @ObservedObject var agents = AgentService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                SectionLabel(title: "Kodlama ajanları", symbol: "sparkles")
                Spacer()
                HookBadge(name: "Claude Code", installed: HookInstaller.claudeInstalled)
                HookBadge(name: "Codex", installed: HookInstaller.codexInstalled)
                if !agents.events.isEmpty {
                    Button { agents.clear() } label: { Image(systemName: "trash") }.buttonStyle(.pill(.red))
                }
            }
            if agents.events.isEmpty {
                HStack(spacing: 10) {
                    AgentIntegrationCard(source: "claude", name: "Claude Code", installed: HookInstaller.claudeInstalled,
                                         detail: "Onay beklediğinde ve işi bitince haber verir.")
                    AgentIntegrationCard(source: "codex", name: "Codex", installed: HookInstaller.codexInstalled,
                                         detail: "Her tur tamamlandığında haber verir.")
                }
            } else {
                if agents.events.count <= 2 {
                    list
                } else {
                    ScrollView(showsIndicators: false) { list }
                }
            }
        }
    }
}

extension AgentsTab {
    var list: some View {
        VStack(spacing: 7) {
            ForEach(agents.events) { AgentRow(event: $0) }
        }
    }
}

struct AgentAvatar: View {
    var source: String
    var size: CGFloat = 32

    var body: some View {
        let style = Self.style(source)
        ZStack {
            Circle().fill(LinearGradient(colors: [style.color, style.color.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: style.symbol).font(.system(size: size * 0.42, weight: .bold)).foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: style.color.opacity(0.45), radius: 6)
    }

    static func style(_ source: String) -> (color: Color, symbol: String) {
        switch source {
        case "claude": return (Color(red: 0.85, green: 0.47, blue: 0.34), "asterisk")
        case "codex": return (Color(red: 0.2, green: 0.72, blue: 0.55), "chevron.left.forwardslash.chevron.right")
        case "cursor": return (.blue, "cursorarrow.rays")
        case "gemini": return (Color(red: 0.33, green: 0.52, blue: 0.98), "sparkle")
        case "ollama": return (Color(white: 0.55), "cube.fill")
        case "assistant": return (Color(red: 0.6, green: 0.45, blue: 0.95), "sparkles")
        default: return (.gray, "terminal.fill")
        }
    }
}

struct AgentRow: View {
    var event: AgentEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentAvatar(source: event.source)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(event.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if event.needsAttention { Chip(text: "BEKLİYOR", symbol: "hand.raised.fill", tint: .orange) }
                    Spacer(minLength: 0)
                    Text(event.date.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 9.5, weight: .medium).monospacedDigit()).foregroundStyle(Color.subtleText)
                }
                if !event.message.isEmpty {
                    Text(event.message).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.65)).lineLimit(2)
                }
                if let project = event.project {
                    Chip(text: project, symbol: "folder.fill", tint: .white)
                }
            }
        }
        .padding(10)
        .background(CardSurface(tint: event.needsAttention ? .orange : nil, radius: 13))
    }
}

struct AgentIntegrationCard: View {
    var source: String
    var name: String
    var installed: Bool
    var detail: String

    var body: some View {
        Card(padding: 12, tint: AgentAvatar.style(source).color) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) {
                    AgentAvatar(source: source, size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name).font(.system(size: 13, weight: .bold))
                        HStack(spacing: 4) {
                            Circle().fill(installed ? Color.green : .white.opacity(0.3)).frame(width: 6, height: 6)
                            Text(installed ? "Bağlı" : "Bağlı değil").font(.system(size: 10, weight: .medium)).foregroundStyle(Color.subtleText)
                        }
                    }
                }
                Text(detail).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(installed ? "Ayarlar" : "Tek tıkla bağla") { SettingsWindow.shared.show() }
                    .buttonStyle(.pill(installed ? .white : AgentAvatar.style(source).color))
            }
        }
    }
}

struct HookBadge: View {
    var name: String
    var installed: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(installed ? Color.green : Color.white.opacity(0.3)).frame(width: 6, height: 6)
                .shadow(color: installed ? .green : .clear, radius: 3)
            Text(name).font(.system(size: 9.5, weight: .semibold))
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(Color.cardFill))
    }
}

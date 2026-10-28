import SwiftUI

struct RootView: View {
    var body: some View {
        IslandView()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
            .environment(\.colorScheme, .dark)
    }
}

struct IslandView: View {
    @ObservedObject private var model = IslandModel.shared

    var body: some View {
        IslandBody(p: model.presentation)
    }
}

struct IslandBody: View {
    var p: Presentation
    @ObservedObject private var model = IslandModel.shared
    @ObservedObject private var music = MusicService.shared
    @AppStorage(Pref.theme) private var themeName = "night"
    @AppStorage(Pref.accentMode) private var accentMode = "artwork"
    @AppStorage(Pref.accentHex) private var accentHex = "#A97CFF"

    var body: some View {
        let size = model.size(for: p)
        let r = model.radii(for: p)
        let shape = NotchShape(topRadius: r.top, bottomRadius: r.bottom)
        let theme = ThemeKind(rawValue: themeName) ?? .night
        let accent = AccentColor.resolve(artwork: music.artwork == nil ? nil : music.accent)
        let shadowed = theme != .minimal

        ZStack(alignment: .top) {
            IslandBackground(theme: theme, presentation: p, accent: accent, notchHeight: model.geometry.notchHeight)
            content(p)
                .padding(.horizontal, r.top)
                .frame(width: size.width, height: size.height, alignment: .top)
                .id(contentKey(p))
                .transition(AnyTransition.asymmetric(
                    insertion: AnyTransition.scale(scale: 0.88, anchor: .top)
                        .combined(with: AnyTransition(.blurReplace))
                        .animation(Motion.content.delay(0.06)),
                    removal: AnyTransition(.blurReplace).animation(.easeIn(duration: 0.12 * DemoClock.slowdown))))
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        // Decorations only; they must never take clicks meant for the controls underneath.
        .overlay {
            ZStack {
                shape.stroke(Color.white.opacity(p == .expanded && theme != .minimal ? 0.07 : 0), lineWidth: 1)
                if theme == .neon && p != .idle { NeonRim(shape: shape, accent: accent, hiddenTop: model.geometry.notchHeight) }
                attentionGlow(p, shape: shape)
                shape.stroke(model.dropTargeted ? accent : .clear, lineWidth: 2)
            }
            .allowsHitTesting(false)
        }
        // The shadow comes from a plain shape behind the island. Shadowing the island itself
        // would re-rasterise all of its content, blurred, on every update or animation frame.
        .background(
            shape.fill(Color.black)
                .shadow(color: .black.opacity(!shadowed ? 0 : p == .expanded ? 0.55 : p == .idle ? 0 : 0.25),
                        radius: p == .expanded ? 22 : 8, y: p == .expanded ? 10 : 3)
                .allowsHitTesting(false)
        )
        .environment(\.islandAccent, accent)
        .opacity(p == .idle && !model.geometry.hasNotch && !model.hoverPeek ? 0 : 1)
        .contentShape(shape)
        .onTapGesture {
            // Clicking a capture notice puts the file on the shelf.
            if case .transient(.capture(let event)) = p {
                ShelfStore.shared.add([event.url])
                model.expand(tab: .shelf)
            } else if p != .expanded {
                model.expand()
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $model.dropTargeted) { providers in
            model.tab = .shelf
            if !model.isExpanded { model.expand(tab: .shelf) }
            return ShelfStore.shared.add(providers: providers)
        }
        .animation(Motion.island, value: p)
    }

    /// A breathing orange rim while an agent is waiting for approval.
    @ViewBuilder
    private func attentionGlow(_ p: Presentation, shape: NotchShape) -> some View {
        if case .transient(.agent(let event)) = p, event.needsAttention {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let pulse = (sin(DemoClock.time(context.date) * 4) + 1) / 2
                shape.stroke(Color.orange.opacity(0.35 + 0.5 * pulse), lineWidth: 1.5)
                    .shadow(color: .orange.opacity(0.6 * pulse), radius: 8)
            }
            .hidingTop(model.geometry.notchHeight)
        }
    }

    private func contentKey(_ p: Presentation) -> String {
        switch p {
        case .idle: return "idle"
        case .music: return "music"
        case .timer: return "timer"
        case .system: return "system"
        case .meeting: return "meeting"
        case .expanded: return "expanded"
        case .transient(let t):
            switch t {
            case .volume: return "volume"
            case .brightness: return "brightness"
            case .battery: return "battery"
            case .unlock: return "unlock"
            case .network(let title, _, _): return "network-\(title)"
            case .agent(let e): return "agent-\(e.id)"
            case .track: return "track"
            case .timerDone: return "timerDone"
            case .meetingSoon(let e): return "meetingSoon-\(e.id)"
            case .capture(let e): return "capture-\(e.url.path)"
            }
        }
    }

    @ViewBuilder
    private func content(_ p: Presentation) -> some View {
        let g = model.geometry
        switch p {
        case .idle:
            Color.clear
        case .music:
            MusicCompact(notchWidth: g.notchWidth, height: g.notchHeight)
        case .timer:
            TimerCompact(notchWidth: g.notchWidth, height: g.notchHeight)
        case .system:
            SystemCompact(notchWidth: g.notchWidth, height: g.notchHeight)
        case .meeting:
            MeetingCompact(notchWidth: g.notchWidth, height: g.notchHeight)
        case .transient(let t):
            TransientView(transient: t, notchWidth: g.notchWidth, height: g.notchHeight)
        case .expanded:
            ExpandedView()
        }
    }
}

// MARK: - Compact activities

struct MusicCompact: View {
    var notchWidth: CGFloat
    var height: CGFloat
    @ObservedObject private var music = MusicService.shared
    @Environment(\.islandAccent) private var accent

    var body: some View {
        Wings(notchWidth: notchWidth, height: height) {
            ArtworkView(image: music.artwork, size: height - 12, radius: 6)
                .shadow(color: accent.opacity(0.6), radius: 5)
                .id(music.title)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        } right: {
            EqualizerLayer(playing: music.isPlaying, color: accent).frame(width: 18, height: 14)
        }
        .animation(Motion.content, value: music.title)
    }
}

struct TimerCompact: View {
    var notchWidth: CGFloat
    var height: CGFloat
    @ObservedObject private var timer = TimerService.shared

    var body: some View {
        Wings(notchWidth: notchWidth, height: height) {
            ZStack {
                Circle().stroke(Color.orange.opacity(0.25), lineWidth: 2.5)
                Circle().trim(from: 0, to: timer.progress).stroke(Color.orange, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: height - 16, height: height - 16)
        } right: {
            Text(TimerService.format(timer.remaining))
                .font(.system(size: 12.5, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(timer.isRunning ? .orange : .orange.opacity(0.5))
        }
    }
}

struct TransientView: View {
    var transient: Transient
    var notchWidth: CGFloat
    var height: CGFloat
    @AppStorage(Pref.hudStyle) private var hudStyle = "bar"
    @AppStorage(Pref.hudBarWidth) private var hudBarWidth = 34.0

    var body: some View {
        switch transient {
        case .volume(let v, let muted):
            hud(symbol: volumeSymbol(v, muted: muted), value: muted ? 0 : Double(v), tint: .white)
        case .brightness(let v):
            hud(symbol: v < 0.5 ? "sun.min.fill" : "sun.max.fill", value: Double(v), tint: .yellow)
        case .battery(let level, let charging, let low):
            Wings(notchWidth: notchWidth, height: height) {
                Image(systemName: charging ? "bolt.fill" : batterySymbol(level, charging: false))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(batteryColor(level, charging: charging, low: low))
                    .symbolEffect(.pulse, isActive: low)
            } right: {
                Text("%\(level)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(batteryColor(level, charging: charging, low: low))
            }
        case .unlock:
            Wings(notchWidth: notchWidth, height: height) {
                Image(systemName: "lock.open.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            } right: { EmptyView() }
        case .network(let title, let symbol, let ok):
            peek(left: Image(systemName: symbol).foregroundStyle(ok ? .green : .red),
                 title: title, subtitle: nil)
        case .agent(let event):
            peek(left: Image(systemName: event.symbol).foregroundStyle(event.needsAttention ? .orange : .green),
                 title: event.title,
                 subtitle: [event.project, event.message.isEmpty ? nil : event.message].compactMap { $0 }.joined(separator: " · "))
        case .track:
            TrackPeek(notchWidth: notchWidth, height: height)
        case .timerDone:
            peek(left: Image(systemName: "timer").foregroundStyle(.orange), title: "Süre doldu", subtitle: "Zamanlayıcı tamamlandı")
        case .capture(let event):
            CapturePeek(event: event, notchWidth: notchWidth, height: height)
        case .meetingSoon(let event):
            peek(left: Image(systemName: event.joinURL == nil ? "calendar" : "video.fill").foregroundStyle(Color(nsColor: event.color)),
                 title: "\(event.title) · \(MeetingCompact.countdown(to: event.start))",
                 subtitle: [event.start.formatted(date: .omitted, time: .shortened),
                            event.joinURL == nil ? nil : "\(event.joinServiceName) — katılmak için çentiği aç"]
                    .compactMap { $0 }.joined(separator: " · "))
        }
    }

    private func hud(symbol: String, value: Double, tint: Color) -> some View {
        Wings(notchWidth: notchWidth, height: height) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
        } right: {
            if hudStyle == "percent" {
                Text("%\(Int((value * 100).rounded()))")
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(tint)
            } else {
                LevelBar(value: value, tint: tint, height: 5).frame(width: hudBarWidth)
                    .animation(Motion.quick, value: value)
            }
        }
    }

    private func peek(left: some View, title: String, subtitle: String?) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: height)
            HStack(spacing: 10) {
                left.font(.system(size: 18, weight: .semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(Color.subtleText).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .frame(maxHeight: .infinity)
        }
    }

    private func volumeSymbol(_ v: Float, muted: Bool) -> String {
        if muted || v == 0 { return "speaker.slash.fill" }
        if v < 0.33 { return "speaker.wave.1.fill" }
        if v < 0.66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

struct TrackPeek: View {
    var notchWidth: CGFloat
    var height: CGFloat
    @ObservedObject private var music = MusicService.shared
    @Environment(\.islandAccent) private var accent

    var body: some View {
        VStack(spacing: 0) {
            Wings(notchWidth: notchWidth, height: height) {
                Image(systemName: "music.note").font(.system(size: 12, weight: .bold)).foregroundStyle(accent)
            } right: {
                EqualizerLayer(playing: music.isPlaying, color: accent).frame(width: 18, height: 14)
            }
            HStack(spacing: 10) {
                ArtworkView(image: music.artwork, size: 30, radius: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(music.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(music.artist).font(.system(size: 11)).foregroundStyle(Color.subtleText).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Meeting countdown

struct MeetingCompact: View {
    var notchWidth: CGFloat
    var height: CGFloat
    @ObservedObject private var calendar = CalendarService.shared

    var body: some View {
        if let event = calendar.upcoming {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                let minutes = event.start.timeIntervalSince(context.date) / 60
                let color: Color = minutes <= 1 ? .red : minutes <= 5 ? .orange : Color(nsColor: event.color)
                Wings(notchWidth: notchWidth, height: height) {
                    Image(systemName: event.joinURL == nil ? "calendar" : "video.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(color)
                        .symbolEffect(.pulse, isActive: minutes <= 1)
                } right: {
                    Text(Self.countdown(to: event.start, now: context.date))
                        .font(.system(size: 11.5, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
    }

    static func countdown(to start: Date, now: Date = .now) -> String {
        let minutes = Int(ceil(start.timeIntervalSince(now) / 60))
        if minutes <= 0 { return "Şimdi" }
        return "\(minutes) dk"
    }
}

// MARK: - Captures

struct CapturePeek: View {
    var event: CaptureEvent
    var notchWidth: CGFloat
    var height: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Wings(notchWidth: notchWidth, height: height) {
                Image(systemName: event.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.teal)
            } right: {
                Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            HStack(spacing: 10) {
                Group {
                    if let thumb = event.thumbnail {
                        Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "doc.fill").foregroundStyle(.white.opacity(0.6))
                    }
                }
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(0.15), lineWidth: 0.6))
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text("Rafa eklemek için tıkla, paylaşmak için sürükle")
                        .font(.system(size: 10.5)).foregroundStyle(Color.subtleText).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(maxHeight: .infinity)
            .help(event.url.lastPathComponent)
            .onDrag { NSItemProvider(contentsOf: event.url) ?? NSItemProvider() }
        }
    }
}

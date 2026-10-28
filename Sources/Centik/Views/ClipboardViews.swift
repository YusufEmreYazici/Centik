import SwiftUI

extension ClipKind {
    var tint: Color {
        switch self {
        case .text: return .white
        case .link: return .blue
        case .code: return .purple
        case .color: return .pink
        case .image: return .teal
        case .file: return .yellow
        }
    }
}

enum ClipFilter: Hashable {
    case all, pinned
    case kind(ClipKind)
}

struct ClipboardTab: View {
    @ObservedObject private var clipboard = ClipboardService.shared
    @AppStorage(Pref.clipboardEnabled) private var enabled = true
    @Environment(\.islandAccent) private var accent
    @State private var filter: ClipFilter = .all
    @State private var selectedID: UUID?

    private var filtered: [ClipItem] {
        switch filter {
        case .all: return clipboard.items
        case .pinned: return clipboard.items.filter(\.pinned)
        case .kind(let k): return clipboard.items.filter { $0.kind == k }
        }
    }

    private var selected: ClipItem? {
        filtered.first { $0.id == selectedID } ?? filtered.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if !enabled {
                EmptyState(symbol: "pause.circle.fill", title: String(localized: "Pano geçmişi kapalı"),
                           subtitle: String(localized: "Ayarlar → Aktiviteler'den açabilirsin."), tint: .gray)
            } else if clipboard.items.isEmpty {
                EmptyState(symbol: "doc.on.clipboard", title: String(localized: "Henüz bir şey kopyalanmadı"),
                           subtitle: String(localized: "Metin, bağlantı, renk, görsel ve dosyalar burada birikir."), tint: accent)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    list.frame(width: 286)
                    if let selected {
                        ClipPreview(item: selected).id(selected.id)
                            .transition(.opacity)
                    } else {
                        EmptyState(symbol: "line.3.horizontal.decrease.circle", title: String(localized: "Bu filtrede öğe yok"),
                                   subtitle: String(localized: "Başka bir tür seç."), tint: .gray)
                    }
                }
                .animation(Motion.quick, value: selected?.id)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 5) {
            FilterChip(title: String(localized: "Tümü"), count: clipboard.items.count, symbol: "square.grid.2x2.fill",
                       selected: filter == .all, tint: accent) { filter = .all }
            let pinnedCount = clipboard.items.filter(\.pinned).count
            if pinnedCount > 0 {
                FilterChip(title: nil, count: pinnedCount, symbol: "pin.fill", selected: filter == .pinned, tint: .orange) {
                    filter = .pinned
                }
            }
            ForEach(ClipKind.allCases) { kind in
                if let n = clipboard.counts[kind], n > 0 {
                    FilterChip(title: nil, count: n, symbol: kind.symbol, selected: filter == .kind(kind), tint: kind.tint) {
                        filter = .kind(kind)
                    }
                    .help(kind.title)
                }
            }
            Spacer(minLength: 4)
            Chip(text: String(localized: "Bellekte"), symbol: "lock.fill", tint: .green)
                .help("Geçmiş yalnızca bellekte tutulur; sabitlenenler hariç diske yazılmaz. Şifre yöneticisi öğeleri kaydedilmez.")
            if clipboard.items.contains(where: { !$0.pinned }) {
                Button { clipboard.clear() } label: { Image(systemName: "trash") }
                    .buttonStyle(.pill(.red))
                    .help("Sabitlenmemiş her şeyi temizle")
            }
        }
    }

    @ViewBuilder
    private var list: some View {
        // Four rows fit without scrolling; more scroll.
        if filtered.count <= 4 {
            rows
        } else {
            ScrollView(showsIndicators: false) { rows }
        }
    }

    private var rows: some View {
        LazyVStack(spacing: 4) {
            ForEach(filtered) { item in
                ClipListRow(item: item, selected: item.id == (selected?.id)) { selectedID = item.id }
            }
        }
    }
}

struct FilterChip: View {
    var title: String?
    var count: Int
    var symbol: String
    var selected: Bool
    var tint: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold))
                if let title { Text(title).font(.system(size: 10, weight: .semibold)) }
                Text("\(count)").font(.system(size: 9.5, weight: .bold).monospacedDigit())
                    .foregroundStyle(selected ? .white : tint.opacity(0.8))
            }
            .foregroundStyle(selected ? .white : tint)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(Capsule().fill(tint.opacity(selected ? 0.42 : 0.14)))
            .overlay(Capsule().strokeBorder(tint.opacity(selected ? 0.7 : 0), lineWidth: 0.7))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle(scale: 0.92))
    }
}

/// Small square that stands for an item: its thumbnail, file icon, colour swatch or kind icon.
struct ClipThumb: View {
    var item: ClipItem
    var size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(item.kind.tint.opacity(0.16))
            switch item.kind {
            case .image:
                if let thumb = item.thumbnail {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
                }
            case .file:
                if let first = item.files.first {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: first.path)).resizable().padding(size * 0.08)
                }
            case .color:
                Circle().fill(Color(nsColor: item.color ?? .gray))
                    .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 0.7))
                    .padding(size * 0.2)
            default:
                Image(systemName: item.kind.symbol).font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(item.kind.tint)
            }
        }
        .frame(width: size, height: size)
    }
}

struct ClipListRow: View {
    var item: ClipItem
    var selected: Bool
    var select: () -> Void
    @Environment(\.islandAccent) private var accent
    @State private var hover = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            ClipThumb(item: item, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(item.kind == .code ? .system(size: 10.5, design: .monospaced) : .system(size: 11, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let icon = item.source?.icon {
                        Image(nsImage: icon).resizable().frame(width: 10, height: 10)
                    }
                    Text(copied ? "Kopyalandı" : "\(item.kind.title) · \(ClipAge.text(item.date))")
                        .foregroundStyle(copied ? .green : Color.subtleText)
                }
                .font(.system(size: 9.5, weight: .medium))
            }
            Spacer(minLength: 0)
            if item.pinned {
                Image(systemName: "pin.fill").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.orange)
            }
            Button {
                ClipboardService.shared.copy(item)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(copied ? .green : .white.opacity(0.85))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.white.opacity(0.1)))
            }
            .buttonStyle(PressScaleStyle())
            .opacity(hover || copied ? 1 : 0)
            .help("Kopyala")
        }
        .padding(.horizontal, 7)
        .frame(height: 38)
        .background(CardSurface(tint: selected ? accent : nil, radius: 11).opacity(selected ? 1 : hover ? 0.9 : 0.55))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(accent.opacity(selected ? 0.55 : 0), lineWidth: 0.8))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) {
            ClipboardService.shared.copy(item)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        }
        .onTapGesture(perform: select)
        .onDrag { ClipboardService.shared.itemProvider(item) }
        .contextMenu { ClipMenu(item: item) }
        .animation(Motion.quick, value: hover)
    }
}

struct ClipMenu: View {
    var item: ClipItem

    var body: some View {
        Button("Kopyala") { ClipboardService.shared.copy(item) }
        if item.rtf != nil { Button("Düz Metin Olarak Kopyala") { ClipboardService.shared.copy(item, plain: true) } }
        Button(item.pinned ? "Sabitlemeyi Kaldır" : "Sabitle") { ClipboardService.shared.togglePin(item) }
        Button("Rafa Ekle") { ClipboardService.shared.addToShelf(item) }
        if item.kind == .image { Button("İndirilenler'e Kaydet") { ClipboardService.shared.saveImage(item) } }
        Divider()
        Button("Sil") { ClipboardService.shared.remove(item) }
    }
}

// MARK: - Preview

struct ClipPreview: View {
    var item: ClipItem
    @Environment(\.islandAccent) private var accent
    @State private var copied = false

    var body: some View {
        Card(padding: 10, tint: item.kind.tint.opacity(0.6)) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Chip(text: item.kind.title, symbol: item.kind.symbol, tint: item.kind.tint)
                    if let source = item.source {
                        HStack(spacing: 3) {
                            if let icon = source.icon { Image(nsImage: icon).resizable().frame(width: 12, height: 12) }
                            Text(source.name).lineLimit(1)
                        }
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Color.subtleText)
                    }
                    Text("· \(ClipAge.text(item.date))").font(.system(size: 9.5)).foregroundStyle(Color.subtleText)
                    Spacer(minLength: 0)
                    IconButton(symbol: item.pinned ? "pin.fill" : "pin", size: 10, active: item.pinned) {
                        ClipboardService.shared.togglePin(item)
                    }
                    .help(item.pinned ? "Sabitlemeyi kaldır" : "Sabitle; yeniden başlatınca da kalır")
                }
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                actions
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .image:
            HStack(alignment: .top, spacing: 10) {
                if let thumb = item.thumbnail {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.6))
                        .shadow(color: .black.opacity(0.4), radius: 5, y: 2)
                }
                VStack(alignment: .leading, spacing: 3) {
                    if let s = item.pixelSize { stat(String(localized: "Boyut"), "\(Int(s.width)) × \(Int(s.height))") }
                    stat(String(localized: "Veri"), ByteCountFormatter.string(fromByteCount: Int64(item.byteCount), countStyle: .file))
                }
                .fixedSize()
            }
        case .file:
            VStack(alignment: .leading, spacing: 5) {
                ForEach(item.files.prefix(3), id: \.self) { url in
                    HStack(spacing: 7) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(url.lastPathComponent).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                            Text(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(.system(size: 9)).foregroundStyle(Color.subtleText).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                if item.files.count > 3 {
                    Text("+\(item.files.count - 3) dosya daha").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Color.subtleText)
                }
            }
        case .color:
            let c = item.color ?? .gray
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: c))
                    .frame(width: 64, height: 64)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 0.8))
                    .shadow(color: Color(nsColor: c).opacity(0.6), radius: 10)
                VStack(alignment: .leading, spacing: 3) {
                    stat("HEX", ColorText.hex(c))
                    stat("RGB", ColorText.rgb(c))
                    stat("HSB", ColorText.hsb(c))
                }
            }
        case .link:
            let url = item.text.flatMap(URL.init(string:))
            VStack(alignment: .leading, spacing: 3) {
                Text(url?.host() ?? String(localized: "Bağlantı")).font(.system(size: 14, weight: .bold)).lineLimit(1)
                Text(item.text ?? "").font(.system(size: 10)).foregroundStyle(.blue.opacity(0.9))
                    .lineLimit(3).truncationMode(.middle)
            }
        case .text, .code:
            VStack(alignment: .leading, spacing: 4) {
                Text(String((item.text ?? "").prefix(600)))
                    .font(item.kind == .code ? .system(size: 10, design: .monospaced) : .system(size: 11))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(item.kind == .code ? 6 : 5)
                Spacer(minLength: 0)
                Text(TextStats.describe(item.text ?? "") + (item.rtf != nil ? String(localized: " · biçimli") : ""))
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(Color.subtleText)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button {
                ClipboardService.shared.copy(item)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                Label(copied ? "Kopyalandı" : "Kopyala", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.pill(copied ? .green : accent))
            switch item.kind {
            case .link:
                Button { ClipboardService.shared.open(item) } label: { Label("Aç", systemImage: "safari") }.buttonStyle(.pill(.blue))
            case .file:
                Button { ClipboardService.shared.open(item) } label: { Label("Göster", systemImage: "folder") }.buttonStyle(.pill)
            case .image:
                Button { ClipboardService.shared.saveImage(item) } label: { Label("Kaydet", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.pill)
            case .color:
                Button { ClipboardService.shared.copy(ClipItem(kind: .text, text: ColorText.rgb(item.color ?? .gray), source: nil)) } label: {
                    Text("RGB kopyala")
                }
                .buttonStyle(.pill)
            default:
                if item.rtf != nil {
                    Button { ClipboardService.shared.copy(item, plain: true) } label: { Text("Düz metin") }.buttonStyle(.pill)
                }
            }
            Spacer(minLength: 0)
            Button { ClipboardService.shared.addToShelf(item) } label: { Image(systemName: "tray.and.arrow.down.fill") }
                .buttonStyle(.pill).help("Rafa ekle")
            Button { ClipboardService.shared.remove(item) } label: { Image(systemName: "trash") }
                .buttonStyle(.pill(.red)).help("Sil")
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(label).font(.system(size: 8.5, weight: .bold)).tracking(0.5).foregroundStyle(Color.subtleText)
                .frame(width: 34, alignment: .leading)
            Text(value).font(.system(size: 10.5, weight: .semibold, design: .monospaced)).textSelection(.enabled)
        }
    }
}

enum ClipAge {
    static func text(_ date: Date) -> String {
        Date.now.timeIntervalSince(date) < 60 ? String(localized: "az önce") : date.formatted(.relative(presentation: .numeric))
    }
}

enum TextStats {
    static func describe(_ text: String) -> String {
        let words = text.split { $0.isWhitespace || $0.isNewline }.count
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        return String(localized: "\(text.count) karakter · \(words) kelime · \(lines) satır")
    }
}

enum ColorText {
    private static func srgb(_ c: NSColor) -> NSColor { c.usingColorSpace(.sRGB) ?? c }

    static func hex(_ c: NSColor) -> String {
        let s = srgb(c)
        return String(format: "#%02X%02X%02X", Int(s.redComponent * 255), Int(s.greenComponent * 255), Int(s.blueComponent * 255))
    }

    static func rgb(_ c: NSColor) -> String {
        let s = srgb(c)
        return "rgb(\(Int(s.redComponent * 255)), \(Int(s.greenComponent * 255)), \(Int(s.blueComponent * 255)))"
    }

    static func hsb(_ c: NSColor) -> String {
        let s = srgb(c)
        return "\(Int(s.hueComponent * 360))°, %\(Int(s.saturationComponent * 100)), %\(Int(s.brightnessComponent * 100))"
    }
}

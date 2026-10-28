import AppKit
import CoreImage
import OSLog

enum AppleScript {
    private static let queue = DispatchQueue(label: "centik.applescript", qos: .userInitiated)
    static let log = Logger(subsystem: "com.emre.centik", category: "music")

    static func run(_ source: String, completion: ((NSAppleEventDescriptor?) -> Void)? = nil) {
        queue.async {
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error {
                let number = error[NSAppleScript.errorNumber] as? Int ?? 0
                let message = error[NSAppleScript.errorMessage] as? String ?? ""
                log.error("AppleScript error \(number, privacy: .public): \(message, privacy: .private)")
            }
            DispatchQueue.main.async { completion?(error == nil ? result : nil) }
        }
    }
}

enum PlayerApp: String, CaseIterable {
    case spotify = "com.spotify.client"
    case music = "com.apple.Music"

    var scriptName: String { self == .spotify ? "Spotify" : "Music" }
    var displayName: String { self == .spotify ? "Spotify" : "Apple Music" }
    var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: rawValue).isEmpty }
}

/// Now-playing state for Spotify and Apple Music.
/// Both apps broadcast a distributed notification on every state change; details are read
/// through AppleScript, guarded by `is running` so a query never launches the player.
final class MusicService: ObservableObject {
    static let shared = MusicService()

    @Published private(set) var source: PlayerApp?
    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var album = ""
    @Published private(set) var artwork: NSImage?
    /// The artwork pre-blurred once per track for the music card's backdrop.
    @Published private(set) var backdrop: NSImage?
    @Published private(set) var accent = NSColor.white
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: Double = 0
    @Published private(set) var shuffle = false
    /// +1 after "next", -1 after "previous"; artwork slides in from that side.
    @Published private(set) var skipDirection = 1
    @Published private(set) var forwardCount = 0
    @Published private(set) var backCount = 0

    /// Fires when a different track starts (not on the first track seen after launch).
    var onTrackChange: (() -> Void)?

    private var anchorPosition: Double = 0
    private var anchorDate = Date()
    private var trackKey = ""
    private var lastSkip = Date.distantPast
    private var syncTimer: Timer?

    var hasTrack: Bool { source != nil && !title.isEmpty }

    var position: Double {
        guard isPlaying else { return anchorPosition }
        return min(duration, anchorPosition + Date().timeIntervalSince(anchorDate))
    }

    func start() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) { [weak self] _ in
            self?.refresh(.spotify)
        }
        dnc.addObserver(forName: .init("com.apple.Music.playerInfo"), object: nil, queue: .main) { [weak self] _ in
            self?.refresh(.music)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if let self, app?.bundleIdentifier == self.source?.rawValue { self.clear() }
        }
        for app in PlayerApp.allCases where app.isRunning { refresh(app) }

        // Periodic resync keeps the interpolated position honest after seeks done in the player itself.
        syncTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, self.isPlaying, let source = self.source else { return }
            self.refresh(source)
        }
    }

    func refresh(_ app: PlayerApp) {
        guard Pref.bool(Pref.musicEnabled), app.isRunning else { return }
        AppleScript.run(Self.stateScript(app)) { [weak self] result in self?.apply(result, from: app) }
    }

    // MARK: Controls

    func playPause() {
        guard let source else { return }
        anchorPosition = position
        anchorDate = Date()
        isPlaying.toggle()
        send("playpause", to: source)
    }

    func next() {
        guard let source else { return }
        skipDirection = 1
        forwardCount += 1
        lastSkip = Date()
        send("next track", to: source)
    }

    func previous() {
        guard let source else { return }
        skipDirection = -1
        backCount += 1
        lastSkip = Date()
        send("previous track", to: source)
    }

    func toggleShuffle() {
        guard let source else { return }
        shuffle.toggle()
        send(source == .spotify ? "set shuffling to not shuffling" : "set shuffle enabled to not shuffle enabled", to: source)
    }

    func seek(to seconds: Double) {
        guard let source else { return }
        anchorPosition = seconds
        anchorDate = Date()
        objectWillChange.send()
        send("set player position to \(Int(seconds))", to: source)
    }

    func openPlayer() {
        let id = source?.rawValue ?? PlayerApp.music.rawValue
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    /// The last track seen in any session, for "pick up where you left off".
    var lastTrack: (title: String, artist: String, app: PlayerApp)? {
        guard let v = UserDefaults.standard.stringArray(forKey: Pref.lastTrack), v.count == 3,
              let app = PlayerApp(rawValue: v[2]), !v[0].isEmpty else { return nil }
        return (v[0], v[1], app)
    }

    /// Starts playback in `app`, launching it if needed (this is a user action).
    func resume(_ app: PlayerApp) {
        AppleScript.run("tell application \"\(app.scriptName)\" to play") { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.refresh(app) }
        }
    }

    func launch(_ app: PlayerApp) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.rawValue) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    private func send(_ command: String, to app: PlayerApp) {
        AppleScript.log.info("send \(command, privacy: .public) -> \(app.scriptName, privacy: .public)")
        guard app.isRunning else { return }
        AppleScript.run("tell application \"\(app.scriptName)\" to \(command)") { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.refresh(app) }
        }
    }

    // MARK: State

    private static func stateScript(_ app: PlayerApp) -> String {
        let name = app.scriptName
        let fields = app == .spotify
            ? "(duration of t) / 1000, player position, shuffling, id of t, artwork url of t"
            : "duration of t, player position, shuffle enabled, persistent ID of t, \"\""
        return """
        if application "\(name)" is running then
            try
                tell application "\(name)"
                    if player state is stopped then return {"stopped"}
                    set t to current track
                    return {(player state as string), name of t, artist of t, album of t, \(fields)}
                end tell
            end try
        end if
        return {"stopped"}
        """
    }

    private func apply(_ d: NSAppleEventDescriptor?, from app: PlayerApp) {
        guard let d, d.numberOfItems >= 1 else { return }
        let state = d.atIndex(1)?.stringValue ?? "stopped"
        guard state != "stopped", d.numberOfItems >= 9 else {
            if source == app { isPlaying = false; anchorPosition = 0 }
            return
        }
        let playing = state == "playing"
        AppleScript.log.debug("state \(app.scriptName, privacy: .public): \(state, privacy: .public) \(d.atIndex(2)?.stringValue ?? "", privacy: .private)")
        // A paused player never steals focus from one that is actually playing.
        if source != nil, source != app, isPlaying, !playing { return }

        let key = d.atIndex(8)?.stringValue ?? ""
        let changed = key != trackKey || source != app
        let hadTrack = !trackKey.isEmpty

        source = app
        title = d.atIndex(2)?.stringValue ?? ""
        artist = d.atIndex(3)?.stringValue ?? ""
        album = d.atIndex(4)?.stringValue ?? ""
        duration = d.atIndex(5)?.doubleValue ?? 0
        anchorPosition = d.atIndex(6)?.doubleValue ?? 0
        anchorDate = Date()
        shuffle = d.atIndex(7)?.booleanValue ?? false
        isPlaying = playing

        if changed {
            if hadTrack && Date().timeIntervalSince(lastSkip) > 2 { skipDirection = 1 }
            trackKey = key
            loadArtwork(app, url: d.atIndex(9)?.stringValue)
            UserDefaults.standard.set([title, artist, app.rawValue], forKey: Pref.lastTrack)
            if hadTrack && playing { onTrackChange?() }
        }
    }

    private func clear() {
        source = nil
        title = ""; artist = ""; album = ""
        artwork = nil
        backdrop = nil
        isPlaying = false
        duration = 0
        anchorPosition = 0
        trackKey = ""
    }

    private func loadArtwork(_ app: PlayerApp, url: String?) {
        let key = trackKey
        let finish: (NSImage?) -> Void = { [weak self] image in
            guard let self, self.trackKey == key else { return }
            self.artwork = image
            self.accent = image.flatMap(Self.accentColor) ?? .white
            self.backdrop = image.flatMap(Self.blurred)
        }
        switch app {
        case .spotify:
            guard let url, let u = URL(string: url) else { return finish(nil) }
            URLSession.shared.dataTask(with: u) { data, _, _ in
                let image = data.flatMap(NSImage.init(data:))
                DispatchQueue.main.async { finish(image) }
            }.resume()
        case .music:
            let script = """
            if application "Music" is running then
                try
                    tell application "Music" to return raw data of artwork 1 of current track
                end try
            end if
            """
            AppleScript.run(script) { result in
                finish(result.flatMap { NSImage(data: $0.data) })
            }
        }
    }

    /// Average artwork colour, lifted so it stays readable on the black island.
    /// Small, heavily blurred and saturated copy of the artwork. Blurring in the view instead
    /// would redo the blur on every frame the island redraws.
    static func blurred(_ image: NSImage) -> NSImage? {
        guard let tiff = image.tiffRepresentation, let ci = CIImage(data: tiff) else { return nil }
        let side: CGFloat = 96
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: side / ci.extent.width, y: side / ci.extent.height))
        let output = scaled.clampedToExtent()
            .applyingGaussianBlur(sigma: 9)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.5])
            .cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
        guard let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: side, height: side))
    }

    static func accentColor(_ image: NSImage) -> NSColor? {
        guard let tiff = image.tiffRepresentation, let ci = CIImage(data: tiff),
              let filter = CIFilter(name: "CIAreaAverage", parameters: [
                  kCIInputImageKey: ci, kCIInputExtentKey: CIVector(cgRect: ci.extent),
              ]),
              let output = filter.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()])
            .render(output, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        let base = NSColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: min(1, s * 1.25), brightness: max(b, 0.8), alpha: 1)
    }
}

#if DEBUG
extension MusicService {
    /// Fills in a fake track for `--snapshot` renders.
    func loadPreview(title: String, artist: String, artwork: NSImage?) {
        source = .spotify
        self.title = title
        self.artist = artist
        self.artwork = artwork
        backdrop = artwork.flatMap(Self.blurred)
        accent = artwork.flatMap(Self.accentColor) ?? .systemPink
        duration = 214
        anchorPosition = 83
        anchorDate = Date()
        isPlaying = true
    }

    /// Plays the next fake track with the same slide a real skip gets.
    func previewSkip(title: String, artist: String, artwork: NSImage?) {
        skipDirection = 1
        loadPreview(title: title, artist: artist, artwork: artwork)
        anchorPosition = 0
    }

    func previewPlaying(_ playing: Bool) { isPlaying = playing }
}
#endif

import AppKit
import AudioToolbox
import CoreAudio
import CoreWLAN
import IOKit.ps
import Network

// MARK: - Volume

/// Default output device volume and mute, observed through CoreAudio property listeners.
final class AudioService: ObservableObject {
    static let shared = AudioService()

    @Published private(set) var volume: Float = 0
    @Published private(set) var muted = false
    @Published private(set) var hasVolumeControl = false

    var onChange: ((Float, Bool) -> Void)?

    private var device = AudioDeviceID(0)
    private var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
    private var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
    private var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private lazy var listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.read(notify: true) }

    func start() {
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, .main) { [weak self] _, _ in
            self?.attach()
        }
        attach()
    }

    private func attach() {
        if device != 0 {
            AudioObjectRemovePropertyListenerBlock(device, &volumeAddress, .main, listener)
            AudioObjectRemovePropertyListenerBlock(device, &muteAddress, .main, listener)
        }
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, 0, nil, &size, &id)
        device = id
        hasVolumeControl = AudioObjectHasProperty(id, &volumeAddress)
        if hasVolumeControl { AudioObjectAddPropertyListenerBlock(id, &volumeAddress, .main, listener) }
        if AudioObjectHasProperty(id, &muteAddress) { AudioObjectAddPropertyListenerBlock(id, &muteAddress, .main, listener) }
        read(notify: false)
    }

    private func read(notify: Bool) {
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        if hasVolumeControl { AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, &value) }
        var mute = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(device, &muteAddress) { AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &mute) }
        let changed = abs(value - volume) > 0.001 || (mute != 0) != muted
        volume = value
        muted = mute != 0
        if notify && changed { onChange?(volume, muted) }
    }

    func setVolume(_ v: Float) {
        IslandModel.log.info("setVolume \(v, privacy: .public) device \(self.device, privacy: .public) hasControl \(self.hasVolumeControl, privacy: .public)")
        guard hasVolumeControl else { return }
        var value = Float32(max(0, min(1, v)))
        AudioObjectSetPropertyData(device, &volumeAddress, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        if muted && value > 0 { setMute(false) }
    }

    func toggleMute() { setMute(!muted) }

    private func setMute(_ on: Bool) {
        guard AudioObjectHasProperty(device, &muteAddress) else { return }
        var value = UInt32(on ? 1 : 0)
        AudioObjectSetPropertyData(device, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
}

// MARK: - Brightness

/// Built-in display brightness via the private DisplayServices framework, loaded at runtime.
/// There is no change notification, so it is polled; ambient auto-brightness moves in tiny steps
/// and is filtered out, while key presses move in large ones.
final class BrightnessService: ObservableObject {
    static let shared = BrightnessService()

    @Published private(set) var brightness: Float = 0
    @Published private(set) var available = false

    var onChange: ((Float) -> Void)?

    private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (UInt32, Float) -> Int32
    private var getFn: GetFn?
    private var setFn: SetFn?
    private var display = CGMainDisplayID()
    private var lastManual = Date.distantPast
    private var lastSetByUs = Date.distantPast
    private var timer: Timer?

    func start() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY) else { return }
        if let sym = dlsym(handle, "DisplayServicesGetBrightness") { getFn = unsafeBitCast(sym, to: GetFn.self) }
        if let sym = dlsym(handle, "DisplayServicesSetBrightness") { setFn = unsafeBitCast(sym, to: SetFn.self) }

        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        CGGetOnlineDisplayList(16, &ids, &count)
        if let builtin = ids.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) { display = builtin }

        guard let value = current() else { return }
        brightness = value
        available = true
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func current() -> Float? {
        var value: Float = 0
        guard let getFn, getFn(display, &value) == 0 else { return nil }
        return value
    }

    private func poll() {
        guard let value = current() else { return }
        let delta = abs(value - brightness)
        guard delta >= 0.002 else { return }
        let now = Date()
        let manual = (delta >= 0.012 || now.timeIntervalSince(lastManual) < 1) && now.timeIntervalSince(lastSetByUs) > 0.6
        brightness = value
        if manual {
            lastManual = now
            onChange?(value)
        }
    }

    func set(_ value: Float) {
        IslandModel.log.info("setBrightness \(value, privacy: .public) available \(self.setFn != nil, privacy: .public)")
        guard let setFn else { return }
        lastSetByUs = Date()
        let v = max(0, min(1, value))
        _ = setFn(display, v)
        brightness = v
    }
}

// MARK: - Battery

enum BatteryEvent {
    case pluggedIn(Int, charging: Bool)
    case unplugged(Int)
    case low(Int)
}

final class BatteryService: ObservableObject {
    static let shared = BatteryService()

    @Published private(set) var level = 100
    @Published private(set) var isCharging = false
    @Published private(set) var isPluggedIn = false
    @Published private(set) var hasBattery = false

    var onEvent: ((BatteryEvent) -> Void)?

    private var started = false
    private var lowShown = false

    func start() {
        read()
        started = true
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<BatteryService>.fromOpaque(ctx).takeUnretainedValue().read()
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    private func read() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            let newLevel = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current
            let plugged = desc[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
            let wasPlugged = isPluggedIn

            hasBattery = true
            level = newLevel
            isCharging = charging
            isPluggedIn = plugged

            guard started else { return }
            if plugged != wasPlugged {
                onEvent?(plugged ? .pluggedIn(newLevel, charging: charging) : .unplugged(newLevel))
            }
            let threshold = Int(Pref.double(Pref.lowBatteryThreshold))
            if !plugged && newLevel <= threshold && !lowShown {
                lowShown = true
                onEvent?(.low(newLevel))
            } else if plugged || newLevel > threshold {
                lowShown = false
            }
            return
        }
    }
}

// MARK: - Network

/// Internet reachability plus Wi-Fi radio power. Offline is only reported after it persists,
/// so brief path flaps during roaming don't pop the island.
final class NetworkService: NSObject, ObservableObject, CWEventDelegate {
    static let shared = NetworkService()

    @Published private(set) var isOnline = true

    var onEvent: ((String, String, Bool) -> Void)?

    private let monitor = NWPathMonitor()
    private var lastStatus: NWPath.Status?
    private var offlineReported = false
    private var offlineWork: DispatchWorkItem?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in DispatchQueue.main.async { self?.handle(path) } }
        monitor.start(queue: DispatchQueue(label: "centik.network"))
        let client = CWWiFiClient.shared()
        client.delegate = self
        try? client.startMonitoringEvent(with: .powerDidChange)
    }

    private func handle(_ path: NWPath) {
        let online = path.status == .satisfied
        defer { lastStatus = path.status; isOnline = online }
        guard let last = lastStatus, (last == .satisfied) != online else { return }

        if online {
            offlineWork?.cancel()
            guard offlineReported else { return }
            offlineReported = false
            if path.usesInterfaceType(.wifi) && path.isExpensive {
                onEvent?(String(localized: "Kişisel Erişim Noktası bağlandı"), "personalhotspot", true)
            } else if path.usesInterfaceType(.wifi) {
                onEvent?(String(localized: "İnternet geri geldi · Wi-Fi"), "wifi", true)
            } else if path.usesInterfaceType(.wiredEthernet) {
                onEvent?(String(localized: "İnternet geri geldi · Ethernet"), "cable.connector", true)
            } else {
                onEvent?(String(localized: "İnternet geri geldi"), "network", true)
            }
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.isOnline else { return }
                self.offlineReported = true
                self.onEvent?(String(localized: "İnternet bağlantısı yok"), "wifi.exclamationmark", false)
            }
            offlineWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
        }
    }

    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) {
        DispatchQueue.main.async {
            let on = CWWiFiClient.shared().interface(withName: interfaceName)?.powerOn() ?? false
            self.onEvent?(on ? String(localized: "Wi-Fi açıldı") : String(localized: "Wi-Fi kapatıldı"), on ? "wifi" : "wifi.slash", on)
        }
    }
}

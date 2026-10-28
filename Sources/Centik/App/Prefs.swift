import Foundation

/// UserDefaults keys and their defaults. Views bind with @AppStorage(Pref.x).
enum Pref {
    static let expandOnHover = "expandOnHover"
    static let haptics = "haptics"
    static let hideInFullscreen = "hideInFullscreen"
    static let display = "display"                 // "builtin" | "main"
    static let showMenuBarIcon = "showMenuBarIcon"
    static let hotKeyEnabled = "hotKeyEnabled"

    static let musicEnabled = "musicEnabled"
    static let trackPreview = "trackPreview"
    static let volumeHUD = "volumeHUD"
    static let brightnessHUD = "brightnessHUD"
    static let hudStyle = "hudStyle"               // "bar" | "percent"
    static let hudDuration = "hudDuration"
    static let batteryAlerts = "batteryAlerts"
    static let lowBatteryThreshold = "lowBatteryThreshold"
    static let networkAlerts = "networkAlerts"
    static let unlockSound = "unlockSound"
    static let unlockSoundName = "unlockSoundName"
    static let unlockIcon = "unlockIcon"
    static let clipboardEnabled = "clipboardEnabled"
    static let calendarEnabled = "calendarEnabled"
    static let agentAlerts = "agentAlerts"
    static let agentSound = "agentSound"
    static let shelfPaths = "shelfPaths"

    static let theme = "theme"                     // ThemeKind raw value
    static let accentMode = "accentMode"           // "artwork" | "custom"
    static let accentHex = "accentHex"
    static let animationsEnabled = "animationsEnabled"
    static let animationStyle = "animationStyle"   // AnimationStyle raw value
    static let animationSpeed = "animationSpeed"
    static let hoverGrow = "hoverGrow"
    static let islandExtraWidth = "islandExtraWidth"
    static let hudBarWidth = "hudBarWidth"
    static let liveActivity = "liveActivity"       // "musicThenSystem" | "music" | "system" | "off"
    static let wingLeft = "wingLeft"               // Metric raw value
    static let wingRight = "wingRight"
    static let hoverDelay = "hoverDelay"           // seconds before hover expands
    static let collapseDelay = "collapseDelay"     // seconds after leaving before collapse
    static let openTab = "openTab"                 // "last" | IslandTab raw value
    static let lastTrack = "lastTrack"             // [title, artist, app bundle id]
    static let meetingAlerts = "meetingAlerts"
    static let meetingLead = "meetingLead"         // minutes before start
    static let captureScreenshots = "captureScreenshots"
    static let captureDownloads = "captureDownloads"
    static let weatherCity = "weatherCity"
    static let weatherLatitude = "weatherLatitude"
    static let weatherLongitude = "weatherLongitude"
    static let systemView = "systemView"           // "overview" | "apps" | "charts"
    static let processScope = "processScope"       // "apps" | "all"
    static let processSort = "processSort"         // "cpu" | "memory"
    static let hiddenTabs = "hiddenTabs"           // comma-separated IslandTab raw values
    static let tabOrder = "tabOrder"               // comma-separated IslandTab raw values
    static let aiProvider = "aiProvider"           // AIProvider raw value; models in "aiModel.<provider>"


    static let allKeys: Set<String> = Set<String>([
        expandOnHover,
        haptics,
        hideInFullscreen,
        display,
        showMenuBarIcon,
        hotKeyEnabled,
        musicEnabled,
        trackPreview,
        volumeHUD,
        brightnessHUD,
        hudStyle,
        hudDuration,
        batteryAlerts,
        lowBatteryThreshold,
        networkAlerts,
        unlockSound,
        unlockSoundName,
        unlockIcon,
        clipboardEnabled,
        calendarEnabled,
        agentAlerts,
        agentSound,
        shelfPaths,
        theme,
        accentMode,
        accentHex,
        animationsEnabled,
        animationStyle,
        animationSpeed,
        hoverGrow,
        islandExtraWidth,
        hudBarWidth,
        liveActivity,
        wingLeft,
        wingRight,
        hoverDelay,
        collapseDelay,
        openTab,
        lastTrack,
        meetingAlerts,
        meetingLead,
        captureScreenshots,
        captureDownloads,
        weatherCity,
        weatherLatitude,
        weatherLongitude,
        systemView,
        processScope,
        processSort,
        hiddenTabs,
        tabOrder,
        aiProvider,
    ]).union(AIProvider.allCases.map(\.modelPref))

    static func register() {
        UserDefaults.standard.register(defaults: [
            expandOnHover: true,
            haptics: true,
            hideInFullscreen: true,
            display: "builtin",
            showMenuBarIcon: true,
            hotKeyEnabled: true,
            musicEnabled: true,
            trackPreview: true,
            volumeHUD: true,
            brightnessHUD: true,
            hudStyle: "bar",
            hudDuration: 1.6,
            batteryAlerts: true,
            lowBatteryThreshold: 20,
            networkAlerts: true,
            unlockSound: false,
            unlockSoundName: "Glass",
            unlockIcon: true,
            clipboardEnabled: true,
            calendarEnabled: true,
            agentAlerts: true,
            agentSound: true,
            theme: "night",
            accentMode: "artwork",
            accentHex: "#A97CFF",
            animationsEnabled: true,
            animationStyle: "fluid",
            animationSpeed: 1.0,
            hoverGrow: true,
            islandExtraWidth: 0.0,
            hudBarWidth: 34.0,
            liveActivity: "music",
            wingLeft: "cpu",
            wingRight: "memory",
            hoverDelay: 0.2,
            collapseDelay: 0.3,
            openTab: "last",
            meetingAlerts: true,
            meetingLead: 10.0,
            captureScreenshots: true,
            captureDownloads: true,
            systemView: "overview",
            processScope: "apps",
            processSort: "cpu",
            hiddenTabs: "",
            tabOrder: "",
            aiProvider: "auto",
        ])
    }

    static func bool(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }
    static func double(_ key: String) -> Double { UserDefaults.standard.double(forKey: key) }
    static func string(_ key: String) -> String { UserDefaults.standard.string(forKey: key) ?? "" }
}

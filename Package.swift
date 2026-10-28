// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Centik",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Centik",
            path: "Sources/Centik",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("IOKit"),
                .linkedFramework("EventKit"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("Carbon"),
                .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)

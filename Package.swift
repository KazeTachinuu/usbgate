// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    // Every unsafe construct must be spelled `unsafe`, so a security review sees
    // each IOKit and Disk Arbitration boundary instead of hunting for them.
    .strictMemorySafety(),
    .unsafeFlags(["-warnings-as-errors"], .when(configuration: .debug)),
]

let package = Package(
    name: "usbgate",
    // macOS 13 is the floor: Swift Testing needs it, macOS 12 is out of
    // support, and every Apple silicon Mac runs 13 or later.
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "USBGateKit",
            swiftSettings: strict,
            linkerSettings: [.linkedFramework("DiskArbitration"), .linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "usbgate",
            dependencies: ["USBGateKit"],
            swiftSettings: strict,
            linkerSettings: [.linkedFramework("DiskArbitration"), .linkedFramework("IOKit")]
        ),
        .testTarget(
            name: "USBGateKitTests",
            dependencies: ["USBGateKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)

// swift-tools-version:5.9
//
// VHS til Mac – Swift Package.
// Bygges til en ferdig .app med scripts/bygg-app.sh (krever Xcode KUN på byggemaskinen,
// f.eks. GitHub Actions). Sluttbrukeren trenger verken Xcode, Homebrew eller Terminal.
import PackageDescription

let package = Package(
    name: "VHSTilMac",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "VHSTilMac", targets: ["VHSTilMac"])
    ],
    targets: [
        // libusb 1.0.27 (LGPL-2.1), kompilert statisk inn i appen – ingen Homebrew.
        .target(
            name: "CLibUSB",
            path: "Sources/CLibUSB",
            exclude: ["COPYING", "AUTHORS", "README-VHS-til-Mac.md"],
            sources: [
                "core.c", "descriptor.c", "hotplug.c", "io.c", "strerror.c", "sync.c",
                "os/darwin_usb.c", "os/events_posix.c", "os/threads_posix.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .headerSearchPath("os")
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security")
            ]
        ),
        // Protokoll, rammebygging, lyd og deinterlacing for Somagic SMI2021 / ezcap 1c88:1001.
        .target(
            name: "SMICore",
            dependencies: ["CLibUSB"],
            path: "Sources/SMICore",
            publicHeadersPath: "include",
            cSettings: [.define("_DARWIN_C_SOURCE")]
        ),
        // SwiftUI-appen.
        .executableTarget(
            name: "VHSTilMac",
            dependencies: ["SMICore"],
            path: "Sources/VHSTilMac",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("AppKit")
            ]
        )
    ]
)

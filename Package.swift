// swift-tools-version:5.9
// The platform-independent core of the app: configuration, package format,
// coordinate mapping, emulator arguments, logging. Built and tested on Linux
// by CI; the iOS app compiles the same sources into its own module (app/build.sh).
import PackageDescription

let package = Package(
    name: "VirtualPhone",
    products: [
        .library(name: "VirtualPhoneCore", targets: ["VirtualPhoneCore"]),
    ],
    targets: [
        .target(name: "VirtualPhoneCore", path: "app/Sources/Core"),
        .testTarget(
            name: "VirtualPhoneCoreTests",
            dependencies: ["VirtualPhoneCore"],
            path: "tests/unit/VirtualPhoneCoreTests"
        ),
    ]
)

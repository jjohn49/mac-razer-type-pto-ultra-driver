// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ProTypeUltra",
    platforms: [.macOS("15.0")],
    products: [
        .library(name: "KeyboardCore", targets: ["KeyboardCore"]),
        .library(name: "KeyboardHID", targets: ["KeyboardHID"]),
        .executable(name: "protype", targets: ["ProTypeCLI"]),
        .executable(name: "protype-helper", targets: ["ProTypeHelper"])
    ],
    targets: [
        .target(name: "KeyboardCore"),
        .target(name: "KeyboardHID", dependencies: ["KeyboardCore"], linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(name: "ProTypeCLI", dependencies: ["KeyboardHID"]),
        .executableTarget(name: "ProTypeHelper", dependencies: ["KeyboardHID"]),
        .testTarget(name: "KeyboardCoreTests", dependencies: ["KeyboardCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "KeyboardHIDTests", dependencies: ["KeyboardHID"])
    ]
)

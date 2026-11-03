// swift-tools-version: 6.2
import Foundation
import PackageDescription

// DILATED_CHANNEL=mas builds the Mac App Store variant: MAS_CHANNEL is defined and Sparkle is not linked.
// Unset or "direct" is the Developer ID build.
let channel = ProcessInfo.processInfo.environment["DILATED_CHANNEL"] ?? "direct"
let isMAS = channel == "mas"
precondition(isMAS || channel == "direct", "DILATED_CHANNEL must be direct or mas")
let channelSettings: [SwiftSetting] = isMAS ? [.define("MAS_CHANNEL")] : []
let sparkleDependencies: [Target.Dependency] =
  isMAS ? [] : [.product(name: "Sparkle", package: "Sparkle")]

let package = Package(
  name: "Dilated",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "DilatedCore", targets: ["DilatedCore"]),
    .library(name: "DilatedUI", targets: ["DilatedUI"]),
    .library(name: "DilatedControl", targets: ["DilatedControl"]),
    .executable(name: "DilatedApp", targets: ["Dilated"]),
    .executable(name: "dilated", targets: ["DilatedCLI"]),
  ],
  dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    .package(url: "https://github.com/nalexn/ViewInspector", exact: "0.10.5"),
  ],
  targets: [
    .target(name: "DilatedCore", swiftSettings: channelSettings),
    .target(name: "DilatedControl", dependencies: ["DilatedCore"], swiftSettings: channelSettings),
    .target(
      name: "DilatedUpdates", dependencies: sparkleDependencies, swiftSettings: channelSettings),
    .target(
      name: "DilatedUI",
      dependencies: [
        "DilatedCore", "DilatedControl", "DilatedUpdates",
      ],
      resources: [.copy("Resources/MenuBar"), .copy("Resources/Fonts"), .copy("Resources/Sounds")],
      swiftSettings: channelSettings,
      linkerSettings: [
        .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
      ]),
    .executableTarget(name: "Dilated", dependencies: ["DilatedUI"]),
    .executableTarget(name: "DilatedCLI", dependencies: ["DilatedCore", "DilatedControl"]),
    .testTarget(
      name: "DilatedCoreTests", dependencies: ["DilatedCore"], swiftSettings: channelSettings),
    .testTarget(
      name: "DilatedControlTests", dependencies: ["DilatedControl"], swiftSettings: channelSettings),
    .testTarget(
      name: "DilatedUITests",
      dependencies: [
        "DilatedUI", "DilatedUpdates", "DilatedCLI",
        .product(name: "ViewInspector", package: "ViewInspector"),
      ],
      swiftSettings: channelSettings),
  ]
)

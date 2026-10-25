// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Dilated",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "DilatedCore", targets: ["DilatedCore"]),
    .library(name: "DilatedUI", targets: ["DilatedUI"]),
    .library(name: "DilatedControl", targets: ["DilatedControl"]),
    .executable(name: "DilatedApp", targets: ["Dilated"]),
    .executable(name: "dilated", targets: ["DilatedCLI"]),
    .executable(name: "dilated-helper", targets: ["DilatedHelper"]),
  ],
  dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
  ],
  targets: [
    .target(name: "DilatedCore"),
    .target(name: "DilatedControl", dependencies: ["DilatedCore"]),
    .target(
      name: "DilatedUI",
      dependencies: [
        "DilatedCore", "DilatedControl", .product(name: "Sparkle", package: "Sparkle"),
      ],
      resources: [.copy("Resources/MenuBar"), .copy("Resources/Fonts"), .copy("Resources/Sounds")],
      linkerSettings: [
        .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
      ]),
    .executableTarget(name: "Dilated", dependencies: ["DilatedUI"]),
    .executableTarget(name: "DilatedCLI", dependencies: ["DilatedCore", "DilatedControl"]),
    .executableTarget(name: "DilatedHelper", dependencies: ["DilatedCore"]),
    .testTarget(name: "DilatedCoreTests", dependencies: ["DilatedCore"]),
    .testTarget(name: "DilatedControlTests", dependencies: ["DilatedControl"]),
    .testTarget(name: "DilatedUITests", dependencies: ["DilatedUI"]),
  ]
)

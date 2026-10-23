// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Dilated",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "DilatedCore", targets: ["DilatedCore"]),
    .library(name: "DilatedControl", targets: ["DilatedControl"]),
    .executable(name: "dilated", targets: ["DilatedCLI"]),
  ],
  targets: [
    .target(name: "DilatedCore"),
    .target(name: "DilatedControl", dependencies: ["DilatedCore"]),
    .executableTarget(name: "DilatedCLI", dependencies: ["DilatedCore", "DilatedControl"]),
    .testTarget(name: "DilatedCoreTests", dependencies: ["DilatedCore"]),
    .testTarget(name: "DilatedControlTests", dependencies: ["DilatedControl"]),
  ]
)

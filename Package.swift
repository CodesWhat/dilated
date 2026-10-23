// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Dilated",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "DilatedCore", targets: ["DilatedCore"]),
  ],
  targets: [
    .target(name: "DilatedCore"),
    .testTarget(name: "DilatedCoreTests", dependencies: ["DilatedCore"]),
  ]
)

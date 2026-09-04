// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "Rant",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "RantCore", targets: ["RantCore"])
  ],
  targets: [
    .target(
      name: "RantCore",
      path: "Sources/RantCore",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "RantCoreTests",
      dependencies: ["RantCore"],
      path: "Tests/RantCoreTests",
      resources: [.copy("Fixtures")],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
  ]
)

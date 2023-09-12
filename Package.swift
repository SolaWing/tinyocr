// swift-tools-version:5.4

import PackageDescription

let package = Package(
  name: "tinyocr",
  platforms: [
    .macOS(.v10_15)
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.0.0"),
    .package(url: "https://github.com/apple/swift-log", from: "1.0.0"),
  ],
  targets: [
    .executableTarget(name: "tinyocr",
                      dependencies: [
                        .product(name: "ArgumentParser", package: "swift-argument-parser"),
                        .product(name: "Logging", package: "swift-log"),
                      ]),
  ]
)

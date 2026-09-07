// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "BlueLyrics",
  platforms: [.macOS(.v13)],
  targets: [
    .executableTarget(
      name: "BlueLyrics",
      path: "Sources/BlueLyrics",
      swiftSettings: [.unsafeFlags(["-swift-version", "5"])],
      linkerSettings: [
        .linkedFramework("Cocoa"), .linkedFramework("WebKit"), .linkedFramework("Network"),
        .linkedFramework("ScreenCaptureKit"), .linkedFramework("ShazamKit"), .linkedFramework("Speech"),
        .linkedFramework("AVFoundation"),
      ]
    ),
  ]
)

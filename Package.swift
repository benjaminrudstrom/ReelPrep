// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ReelPrep",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FCPXMLKit", targets: ["FCPXMLKit"]),
        .library(name: "FCP7XMLKit", targets: ["FCP7XMLKit"]),
        .executable(name: "reelprep", targets: ["reelprep"]),
        .executable(name: "ReelPrepApp", targets: ["ReelPrepApp"]),
    ],
    targets: [
        // Pure FCPXML model, writer and DTD validation. No AVFoundation, no UI.
        .target(name: "FCPXMLKit"),
        // The same timeline as Final Cut Pro 7 XML (xmeml), for Premiere Pro and DaVinci Resolve. Pure, no UI.
        .target(name: "FCP7XMLKit", dependencies: ["FCPXMLKit"]),
        // Cut planning: beats + clips -> slots -> FCPXML timeline. Pure logic.
        .target(name: "ReelCore", dependencies: ["FCPXMLKit"]),
        // Reading media (AVFoundation) and beat detection (Accelerate).
        .target(name: "ReelMedia", dependencies: ["ReelCore", "FCP7XMLKit"]),
        .executableTarget(name: "reelprep", dependencies: ["FCPXMLKit", "ReelCore", "ReelMedia"]),
        // SwiftUI views (the beat editor now; the whole app in Step 3).
        .target(name: "ReelUI", dependencies: ["ReelCore", "ReelMedia"]),
        .executableTarget(name: "ReelPrepApp", dependencies: ["ReelUI"]),
        .executableTarget(name: "reelprep-snapshot", dependencies: ["ReelUI"]),
        .testTarget(name: "FCPXMLKitTests", dependencies: ["FCPXMLKit"]),
        .testTarget(name: "FCP7XMLKitTests", dependencies: ["FCP7XMLKit", "FCPXMLKit"]),
        .testTarget(name: "ReelCoreTests", dependencies: ["ReelCore"]),
        .testTarget(name: "ReelMediaTests", dependencies: ["ReelMedia"]),
        .testTarget(name: "ReelUITests", dependencies: ["ReelUI", "ReelCore"]),
    ],
    swiftLanguageModes: [.v5]
)

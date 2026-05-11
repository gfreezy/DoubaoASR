// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DoubaoASR",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DoubaoASR", targets: ["DoubaoASR"])
    ],
    targets: [
        .target(
            name: "DoubaoASR",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox")
            ]
        )
    ]
)

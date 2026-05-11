// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DoubaoASR",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [
        .library(name: "DoubaoASR", targets: ["DoubaoASR"])
    ],
    dependencies: [
        .package(url: "https://github.com/gfreezy/talkercommon", exact: "20260505.0.3")
    ],
    targets: [
        .target(
            name: "DoubaoASR",
            dependencies: [
                .product(name: "TalkerCommonSync", package: "talkercommon")
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox")
            ]
        )
    ]
)

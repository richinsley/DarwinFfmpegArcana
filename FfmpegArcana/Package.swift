// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FfmpegArcana",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .tvOS(.v17)
    ],
    products: [
        .library(
            name: "FfmpegArcana",
            targets: ["FfmpegArcana"]
        ),
    ],
    targets: [
        // C wrapper around FFmpeg
        .target(
            name: "CFfmpegWrapper",
            path: "Sources/CFfmpegWrapper",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                // Paths relative to package root (FfmpegArcana/)
                .headerSearchPath("../Frameworks/ios_device/include"),
                .headerSearchPath("../Frameworks/ios_device/include/arcana"),
                .headerSearchPath("../Frameworks/macos/include"),
                .headerSearchPath("../Frameworks/macos/include/arcana"),
            ],
            linkerSettings: [
                .linkedLibrary("z"),
                .linkedLibrary("bz2"),
                .linkedLibrary("iconv"),
                .linkedLibrary("c++"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Security"),
                .linkedFramework("AVFoundation"),
            ]
        ),
        
        // Swift API layer
        .target(
            name: "FfmpegArcana",
            dependencies: ["CFfmpegWrapper"],
            path: "Sources/FfmpegArcana"
        ),
    ]
)
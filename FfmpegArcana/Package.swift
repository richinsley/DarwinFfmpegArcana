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
        // This is what other packages/apps can import
        .library(
            name: "FfmpegArcana",
            targets: ["FfmpegArcana"]
        ),
    ],
    targets: [
        // C wrapper around FFmpeg
        // The "path" and "publicHeadersPath" tell SPM where to find the code
        .target(
            name: "CFfmpegWrapper",
            path: "Sources/CFfmpegWrapper",
            publicHeadersPath: "include",
            cSettings: [
                // These paths are relative to the package root
                // Users must set FFMPEG_FRAMEWORK_PATH in their project
                // Or we provide a default location
                .headerSearchPath("include"),
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
        
        // Unit tests
        .testTarget(
            name: "FfmpegArcanaTests",
            dependencies: ["FfmpegArcana"],
            path: "Tests/FfmpegArcanaTests"
        ),
    ]
)

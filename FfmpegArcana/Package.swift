// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FfmpegArcana",
    platforms: [
        .macOS(.v14),
        .iOS(.v26),
        .tvOS(.v26)
    ],
    products: [
        .library(
            name: "FfmpegArcana",
            targets: ["FfmpegArcana"]
        ),
    ],
    targets: [
        // 1. Binary Target
        // Since Frameworks is now inside FfmpegArcana/, the path is local.
        .binaryTarget(
            name: "FFmpeg",
            path: "Frameworks/FFmpeg.xcframework"
        ),

        // 2. C Wrapper
        // We remove the manual headerSearchPaths for the frameworks.
        // The 'dependencies' array handles the include paths automatically.
        .target(
            name: "CFfmpegWrapper",
            dependencies: ["FFmpeg"],
            path: "Sources/CFfmpegWrapper",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("include/arcana")
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
        
        // 3. Swift API
        .target(
            name: "FfmpegArcana",
            dependencies: ["CFfmpegWrapper"],
            path: "Sources/FfmpegArcana"
        ),
        
        // 4. Tests
        .testTarget(
            name: "FfmpegArcanaTests",
            dependencies: ["FfmpegArcana"],
            path: "Tests/FfmpegArcanaTests"
        )
    ]
)

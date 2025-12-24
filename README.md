# FfmpegArcana

Swift Package wrapping FFmpeg for iOS, macOS, and tvOS.

## Structure

```
workspace/
├── Frameworks/
│   └── FFmpeg.xcframework/       # Your FFmpeg build
├── FfmpegArcana/                 # THIS PACKAGE
│   ├── Package.swift
│   └── Sources/
│       ├── CFfmpegWrapper/       # C wrapper
│       └── FfmpegArcana/         # Swift API
└── FfmpegArcanaTestHarness/      # CMake test harness (separate)
    ├── CMakeLists.txt
    ├── build.sh
    └── main.swift
```

## Usage in Xcode

### 1. Add Package Dependency

**Local package:**
1. File → Add Package Dependencies → Add Local
2. Select the FfmpegArcana directory

**Or in Package.swift:**
```swift
dependencies: [
    .package(path: "../FfmpegArcana"),
]
```

### 2. Configure Build Settings

In your Xcode project, add:

**Header Search Paths:**
```
$(PROJECT_DIR)/../Frameworks/FFmpeg.xcframework/macos-arm64/FFmpeg.framework/Headers/arcana
```

**Framework Search Paths:**
```
$(PROJECT_DIR)/../Frameworks/FFmpeg.xcframework/macos-arm64
```

**Other Linker Flags:**
```
-framework FFmpeg
```

### 3. Import and Use

```swift
import FfmpegArcana

// Check versions
print(FFmpeg.avcodecVersion)

// Decode video
let decoder = try VideoDecoder(url: "video.mp4")
while let frame = try decoder.decodeNextFrame() {
    // Use frame.data(plane: 0) for pixels
}
```

## Development with CMake

For fast iteration outside Xcode, use the test harness:

```bash
cd FfmpegArcanaTestHarness
./build.sh
./build/bin/fftest test
./build/bin/fftest decode /path/to/video.mp4
```

## API

### High-Level

```swift
let decoder = try VideoDecoder(
    url: "video.mp4",
    outputFormat: .bgra,    // For display
    useHardware: true       // VideoToolbox
)

try decoder.decodeAll { frame in
    print("Frame \(frame.frameNumber) at \(frame.timestamp)s")
    return true // continue
}
```

### Low-Level

```swift
let demuxer = try Demuxer(url: "video.mp4")
let decoder = try demuxer.createVideoDecoder()
let frame = try Frame()

while true {
    do {
        let packet = try demuxer.readPacket()
        defer { packet.unref() }
        
        if packet.streamIndex == demuxer.videoStreamIndex {
            try decoder.send(packet)
            try decoder.receive(into: frame)
            // process frame
        }
    } catch FFmpegError.endOfFile { break }
      catch FFmpegError.needsMoreInput { continue }
}
```

## Requirements

- macOS 14+ / iOS 17+ / tvOS 17+
- Xcode 15+
- FFmpeg.xcframework with your FFmpeg build

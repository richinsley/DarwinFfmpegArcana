## build ffmpeg-arcana framework
brew install cmake nasm meson autoconf automake libtool wget curl
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
cd ffmpeg
./build-ffmpeg.sh ../FfmpegArcana/Frameworks

## build test harness
cd FfmpegArcanaTestHarness
./build.sh

## create xcode App
Assume we want to create an app called 'FfmpegArcanaApp'
```bash
DarwinFfmpegArcana/
├── FfmpegArcana/              # The Swift package
├── FfmpegArcanaTestHarness/   # CMake CLI test (VS Code)
├── FfmpegArcanaApp/           # NEW: Xcode iOS app
│   ├── FfmpegArcanaApp.xcodeproj/
│   └── FfmpegArcanaApp/
│       ├── FfmpegArcanaAppApp.swift
│       ├── ContentView.swift
│       └── Assets.xcassets/
└── Frameworks/
    └── FFmpeg.xcframework/
```

### Add FfmpegArcana Package
File → Add Package Dependencies → Add Local
Select the FfmpegArcana folder

import Testing
@testable import FfmpegArcana

@Test func testVersions() {
    #expect(!FFmpeg.avcodecVersion.isEmpty)
    #expect(!FFmpeg.avformatVersion.isEmpty)
    #expect(!FFmpeg.avutilVersion.isEmpty)
}

@Test func testPixelFormats() {
    #expect(PixelFormat.yuv420p.description == "yuv420p")
    #expect(PixelFormat.bgra.description == "bgra")
    #expect(!PixelFormat.yuv420p.isHardware)
    #expect(PixelFormat.videoToolbox.isHardware)
}

@Test func testFrameAllocation() throws {
    let frame = try Frame()
    #expect(frame.width == 0)
    #expect(frame.height == 0)
}

@Test func testFrameWithBuffer() throws {
    let frame = try Frame(width: 1920, height: 1080, pixelFormat: .bgra)
    #expect(frame.width == 1920)
    #expect(frame.height == 1080)
    #expect(frame.pixelFormat == .bgra)
    #expect(frame.data(plane: 0) != nil)
}

@Test func testPacketAllocation() throws {
    _ = try Packet()
}

@Test func testScalerCreation() throws {
    _ = try Scaler(
        srcWidth: 1920, srcHeight: 1080, srcFormat: .yuv420p,
        dstWidth: 1280, dstHeight: 720, dstFormat: .bgra
    )
}

@Test func testDemuxerInvalidPath() {
    #expect(throws: FFmpegError.self) {
        _ = try Demuxer(url: "/nonexistent/video.mp4")
    }
}

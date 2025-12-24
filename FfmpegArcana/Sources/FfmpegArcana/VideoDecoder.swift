/**
 * VideoDecoder - High-level video decode pipeline
 */

import Foundation

public struct DecodedFrame: @unchecked Sendable {
    public let frame: Frame
    public let timestamp: Double
    public let frameNumber: Int

    public var width: Int { frame.width }
    public var height: Int { frame.height }
    public var pixelFormat: PixelFormat { frame.pixelFormat }
}

public typealias DecodeProgressCallback = (DecodedFrame) -> Bool

public final class VideoDecoder: @unchecked Sendable {
    private let demuxer: Demuxer
    private let decoder: Decoder
    private var scaler: Scaler?

    public let videoInfo: VideoInfo
    public let useHardwareAcceleration: Bool

    private var frameCount: Int = 0
    private let outputFormat: PixelFormat
    private let outputWidth: Int
    private let outputHeight: Int

    public init(url: String,
                outputFormat: PixelFormat = .bgra,
                outputSize: (width: Int, height: Int)? = nil,
                useHardware: Bool = true) throws {

        self.demuxer = try Demuxer(url: url)
        self.videoInfo = try demuxer.videoInfo()
        self.decoder = try demuxer.createVideoDecoder(useHardware: useHardware)
        self.useHardwareAcceleration = decoder.isHardwareAccelerated

        self.outputFormat = outputFormat
        self.outputWidth = outputSize?.width ?? videoInfo.width
        self.outputHeight = outputSize?.height ?? videoInfo.height
    }

    public func decodeNextFrame() throws -> DecodedFrame? {
        let frame = try Frame()

        while true {
            do {
                try decoder.receive(into: frame)
                frameCount += 1

                let outputFrame = try convertIfNeeded(frame)
                let timestamp = Double(frameCount) / videoInfo.frameRate

                return DecodedFrame(frame: outputFrame, timestamp: timestamp, frameNumber: frameCount)

            } catch FFmpegError.needsMoreInput {
                do {
                    let packet = try demuxer.readPacket()
                    defer { packet.unref() }

                    if packet.streamIndex == demuxer.videoStreamIndex {
                        try decoder.send(packet)
                    }
                } catch FFmpegError.endOfFile {
                    try decoder.send(nil)
                }
            } catch FFmpegError.endOfFile {
                return nil
            }
        }
    }

    public func decodeAll(progress callback: DecodeProgressCallback) throws {
        while let frame = try decodeNextFrame() {
            if !callback(frame) { break }
        }
    }

    public func seek(to seconds: Double) throws {
        try demuxer.seek(to: seconds)
        decoder.flush()
        frameCount = Int(seconds * videoInfo.frameRate)
    }

    public func reset() throws {
        try seek(to: 0)
        frameCount = 0
    }

    private func convertIfNeeded(_ frame: Frame) throws -> Frame {
        var sourceFrame = frame

        if frame.isHardware {
            let swFormat = frame.softwarePixelFormat ?? .nv12
            sourceFrame = try Frame(width: frame.width, height: frame.height, pixelFormat: swFormat)
            try frame.transferToSoftware(destination: sourceFrame)
        }

        let needsConversion = sourceFrame.pixelFormat != outputFormat ||
                             sourceFrame.width != outputWidth ||
                             sourceFrame.height != outputHeight

        guard needsConversion else { return sourceFrame }

        if scaler == nil {
            scaler = try Scaler(
                srcWidth: sourceFrame.width, srcHeight: sourceFrame.height, srcFormat: sourceFrame.pixelFormat,
                dstWidth: outputWidth, dstHeight: outputHeight, dstFormat: outputFormat
            )
        }

        let outputFrame = try Frame(width: outputWidth, height: outputHeight, pixelFormat: outputFormat)
        try scaler?.scale(from: sourceFrame, to: outputFrame)

        return outputFrame
    }
}

extension VideoDecoder {
    public static func extractFrame(from url: String, at time: Double = 0) throws -> DecodedFrame? {
        let decoder = try VideoDecoder(url: url)
        if time > 0 { try decoder.seek(to: time) }
        return try decoder.decodeNextFrame()
    }
}

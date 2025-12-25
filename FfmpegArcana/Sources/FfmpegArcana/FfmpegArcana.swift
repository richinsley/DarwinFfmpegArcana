/**
 * FfmpegArcana - Swift wrapper for FFmpeg
 */

import Foundation
import CFfmpegWrapper

// MARK: - Error Handling

public enum FFmpegError: Error, LocalizedError {
    case openFailed(path: String, code: Int32)
    case decoderCreationFailed
    case noVideoStream
    case noAudioStream
    case invalidContext
    case scalerCreationFailed
    case frameAllocationFailed
    case packetAllocationFailed
    case endOfFile
    case needsMoreInput
    case ffmpegError(code: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let path, let code):
            return "Failed to open '\(path)': \(FFmpeg.errorString(code))"
        case .decoderCreationFailed: return "Failed to create decoder"
        case .noVideoStream: return "No video stream found"
        case .noAudioStream: return "No audio stream found"
        case .invalidContext: return "Invalid context"
        case .scalerCreationFailed: return "Failed to create scaler"
        case .frameAllocationFailed: return "Failed to allocate frame"
        case .packetAllocationFailed: return "Failed to allocate packet"
        case .endOfFile: return "End of file"
        case .needsMoreInput: return "Needs more input"
        case .ffmpegError(let code, let message): return "FFmpeg error \(code): \(message)"
        }
    }
}

// MARK: - FFmpeg Utilities

public enum FFmpeg {
    public static func errorString(_ code: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        ff_get_error_string(code, &buffer, buffer.count)
        return String(cString: buffer)
    }

    public static var avcodecVersion: String { String(cString: ff_get_avcodec_version()) }
    public static var avformatVersion: String { String(cString: ff_get_avformat_version()) }
    public static var avutilVersion: String { String(cString: ff_get_avutil_version()) }

    public static func setLogLevel(_ level: LogLevel) {
        ff_set_log_level(level.rawValue)
    }

    public enum LogLevel: Int32 {
        case quiet = -8, panic = 0, fatal = 8, error = 16
        case warning = 24, info = 32, verbose = 40, debug = 48
    }
}

// MARK: - Pixel Format

public enum PixelFormat: Int32, CustomStringConvertible, Sendable {
    case yuv420p = 0, nv12 = 23, bgra = 26, rgba = 28
    case rgb24 = 2, p010le = 161, videoToolbox = 181, unknown = -1

    public init(avFormat: Int32) {
        self = PixelFormat(rawValue: avFormat) ?? .unknown
    }

    public var description: String { String(cString: ff_pixel_format_name(rawValue)) }
    public var isHardware: Bool { ff_pixel_format_is_hardware(rawValue) }
}

// MARK: - Video Info

public struct VideoInfo: Sendable {
    public let width: Int
    public let height: Int
    public let pixelFormat: PixelFormat
    public let frameRateNumerator: Int
    public let frameRateDenominator: Int
    public let duration: Double

    public var frameRate: Double {
        guard frameRateDenominator > 0 else { return 0 }
        return Double(frameRateNumerator) / Double(frameRateDenominator)
    }

    public var aspectRatio: Double {
        guard height > 0 else { return 0 }
        return Double(width) / Double(height)
    }
}

// MARK: - Demuxer

public final class Demuxer: @unchecked Sendable {
    private let ctx: OpaquePointer

    public init(url: String) throws {
        guard let ctx = ff_demux_create() else { throw FFmpegError.invalidContext }
        self.ctx = ctx

        let result = ff_demux_open(ctx, url)
        if result < 0 {
            ff_demux_destroy(ctx)
            throw FFmpegError.openFailed(path: url, code: result)
        }
    }

    deinit { ff_demux_destroy(ctx) }

    public var streamCount: Int { Int(ff_demux_get_stream_count(ctx)) }
    public var videoStreamIndex: Int { Int(ff_demux_get_video_stream_index(ctx)) }
    public var audioStreamIndex: Int { Int(ff_demux_get_audio_stream_index(ctx)) }
    public var duration: Double { ff_demux_get_duration(ctx) }

    public func videoInfo() throws -> VideoInfo {
        guard videoStreamIndex >= 0 else { throw FFmpegError.noVideoStream }

        var width: Int32 = 0, height: Int32 = 0, pixFmt: Int32 = 0
        var fpsNum: Int32 = 0, fpsDen: Int32 = 0

        let result = ff_demux_get_video_info(ctx, &width, &height, &pixFmt, &fpsNum, &fpsDen)
        if result < 0 {
            throw FFmpegError.ffmpegError(code: result, message: FFmpeg.errorString(result))
        }

        return VideoInfo(
            width: Int(width), height: Int(height),
            pixelFormat: PixelFormat(avFormat: pixFmt),
            frameRateNumerator: Int(fpsNum), frameRateDenominator: Int(fpsDen),
            duration: duration
        )
    }

    public func readPacket() throws -> Packet {
        let packet = try Packet()
        let result = ff_demux_read_packet(ctx, packet.ptr)

        if result == FF_ERROR_EOF { throw FFmpegError.endOfFile }
        if result < 0 { throw FFmpegError.ffmpegError(code: result, message: FFmpeg.errorString(result)) }

        return packet
    }

    public func seek(to seconds: Double) throws {
        let result = ff_demux_seek(ctx, seconds)
        if result < 0 { throw FFmpegError.ffmpegError(code: result, message: FFmpeg.errorString(result)) }
    }

    public func createDecoder(streamIndex: Int, useHardware: Bool = true) throws -> Decoder {
        try Decoder(demuxer: self, streamIndex: streamIndex, useHardware: useHardware)
    }

    public func createVideoDecoder(useHardware: Bool = true) throws -> Decoder {
        guard videoStreamIndex >= 0 else { throw FFmpegError.noVideoStream }
        return try createDecoder(streamIndex: videoStreamIndex, useHardware: useHardware)
    }

    fileprivate var internalContext: OpaquePointer { ctx }
}

// MARK: - Decoder

public final class Decoder: @unchecked Sendable {
    private let ctx: OpaquePointer
    public let streamIndex: Int

    fileprivate init(demuxer: Demuxer, streamIndex: Int, useHardware: Bool) throws {
        guard let ctx = ff_decoder_create(demuxer.internalContext, Int32(streamIndex), useHardware) else {
            throw FFmpegError.decoderCreationFailed
        }
        self.ctx = ctx
        self.streamIndex = streamIndex
    }

    deinit { ff_decoder_destroy(ctx) }

    public var isHardwareAccelerated: Bool { ff_decoder_is_hardware(ctx) }
    public var pixelFormat: PixelFormat { PixelFormat(avFormat: ff_decoder_get_pixel_format(ctx)) }

    public func send(_ packet: Packet?) throws {
        let result = ff_decoder_send_packet(ctx, packet?.ptr)
        if result < 0 && result != FF_ERROR_EAGAIN {
            throw FFmpegError.ffmpegError(code: result, message: FFmpeg.errorString(result))
        }
    }

    public func receive(into frame: Frame) throws {
        let result = ff_decoder_receive_frame(ctx, frame.ptr)

        if result == FF_ERROR_EAGAIN { throw FFmpegError.needsMoreInput }
        if result == FF_ERROR_EOF { throw FFmpegError.endOfFile }
        if result < 0 { throw FFmpegError.ffmpegError(code: result, message: FFmpeg.errorString(result)) }
    }

    public func flush() { ff_decoder_flush(ctx) }
}

// MARK: - Frame

public final class Frame: @unchecked Sendable {
    internal let ptr: UnsafeMutablePointer<AVFrame>
    private let ownsMemory: Bool
    
    /// Direct access to underlying AVFrame pointer for interop with C APIs.
    public var avFrame: UnsafeMutablePointer<AVFrame> { ptr }

    public init() throws {
        guard let ptr = ff_frame_alloc() else { throw FFmpegError.frameAllocationFailed }
        self.ptr = ptr
        self.ownsMemory = true
    }

    public init(width: Int, height: Int, pixelFormat: PixelFormat) throws {
        guard let ptr = ff_frame_alloc() else { throw FFmpegError.frameAllocationFailed }
        self.ptr = ptr
        self.ownsMemory = true

        let result = ff_frame_alloc_buffer(ptr, Int32(width), Int32(height), pixelFormat.rawValue)
        if result < 0 {
            ff_frame_free(ptr)
            throw FFmpegError.ffmpegError(code: result, message: FFmpeg.errorString(result))
        }
    }
    
    /// Initialize by taking ownership of an existing AVFrame pointer.
    /// Used internally by FIFO read operations.
    internal init(taking ptr: UnsafeMutablePointer<AVFrame>) {
        self.ptr = ptr
        self.ownsMemory = true
    }

    deinit { 
        if ownsMemory {
            ff_frame_free(ptr) 
        }
    }

    public var width: Int { Int(ptr.pointee.width) }
    public var height: Int { Int(ptr.pointee.height) }
    public var pixelFormat: PixelFormat { PixelFormat(avFormat: ptr.pointee.format) }
    public var isHardware: Bool { ff_frame_is_hardware(ptr) }

    public func data(plane: Int) -> UnsafeMutablePointer<UInt8>? {
        ff_frame_get_data(ptr, Int32(plane))
    }

    public func linesize(plane: Int) -> Int {
        Int(ff_frame_get_linesize(ptr, Int32(plane)))
    }

    public func transferToSoftware(destination: Frame) throws {
        let result = ff_transfer_hw_frame(ptr, destination.ptr)
        if result < 0 { throw FFmpegError.ffmpegError(code: result, message: FFmpeg.errorString(result)) }
    }

    public var softwarePixelFormat: PixelFormat? {
        guard isHardware else { return nil }
        return PixelFormat(avFormat: ff_get_sw_format(ptr))
    }
}

// MARK: - Packet

public final class Packet: @unchecked Sendable {
    internal let ptr: UnsafeMutablePointer<AVPacket>
    private let ownsMemory: Bool
    
    /// Direct access to underlying AVPacket pointer for interop with C APIs.
    public var avPacket: UnsafeMutablePointer<AVPacket> { ptr }

    public init() throws {
        guard let ptr = ff_packet_alloc() else { throw FFmpegError.packetAllocationFailed }
        self.ptr = ptr
        self.ownsMemory = true
    }
    
    /// Initialize by taking ownership of an existing AVPacket pointer.
    /// Used internally by FIFO read operations.
    internal init(taking ptr: UnsafeMutablePointer<AVPacket>) {
        self.ptr = ptr
        self.ownsMemory = true
    }

    deinit { 
        if ownsMemory {
            ff_packet_free(ptr) 
        }
    }

    public var streamIndex: Int { Int(ff_packet_get_stream_index(ptr)) }
    public func unref() { ff_packet_unref(ptr) }
}

// MARK: - Scaler

public final class Scaler: @unchecked Sendable {
    private let ctx: OpaquePointer

    public init(srcWidth: Int, srcHeight: Int, srcFormat: PixelFormat,
                dstWidth: Int, dstHeight: Int, dstFormat: PixelFormat) throws {
        guard let ctx = ff_scaler_create(
            Int32(srcWidth), Int32(srcHeight), srcFormat.rawValue,
            Int32(dstWidth), Int32(dstHeight), dstFormat.rawValue
        ) else { throw FFmpegError.scalerCreationFailed }
        self.ctx = ctx
    }

    deinit { ff_scaler_destroy(ctx) }

    public func scale(from source: Frame, to destination: Frame) throws {
        let result = ff_scaler_scale(ctx, source.ptr, destination.ptr)
        if result < 0 { throw FFmpegError.ffmpegError(code: result, message: FFmpeg.errorString(result)) }
    }
}
// Sources/FfmpegArcana/Pipeline/PipelineTypes.swift

import Foundation
import AVFoundation
import CoreMedia

// MARK: - Media Format

/// Describes the format of media flowing through a port
public struct MediaFormat: Equatable, CustomStringConvertible {
    
    // MARK: Video properties
    public var width: Int?
    public var height: Int?
    public var pixelFormat: OSType?                    // kCVPixelFormatType_*
    public var frameRate: CMTime?
    public var colorSpaceName: String?
    public var isHDR: Bool?
    public var fieldMode: FieldMode?
    
    // MARK: Audio properties  
    public var sampleRate: Double?
    public var channelCount: Int?
    public var audioBitsPerChannel: Int?
    public var audioIsInterleaved: Bool?
    
    // MARK: Common
    public var mediaType: CMMediaType?
    
    public enum FieldMode: String, Codable, Sendable {
        case progressive
        case interlacedTopFirst
        case interlacedBottomFirst
    }
    
    public var description: String {
        var parts: [String] = []
        if let w = width, let h = height {
            parts.append("\(w)x\(h)")
        }
        if let fr = frameRate, fr.value > 0 {
            let fps = Double(fr.timescale) / Double(fr.value)
            parts.append(String(format: "%.2ffps", fps))
        }
        if let sr = sampleRate, let ch = channelCount {
            parts.append("\(Int(sr))Hz \(ch)ch")
        }
        return parts.joined(separator: " ")
    }
    
    public static var unknown: MediaFormat { MediaFormat() }
    
    public init() {}
    
    // MARK: Factory methods
    
    public static func video(width: Int, height: Int, pixelFormat: OSType, frameRate: CMTime) -> MediaFormat {
        var fmt = MediaFormat()
        fmt.mediaType = kCMMediaType_Video
        fmt.width = width
        fmt.height = height
        fmt.pixelFormat = pixelFormat
        fmt.frameRate = frameRate
        return fmt
    }
    
    public static func audio(sampleRate: Double, channels: Int) -> MediaFormat {
        var fmt = MediaFormat()
        fmt.mediaType = kCMMediaType_Audio
        fmt.sampleRate = sampleRate
        fmt.channelCount = channels
        return fmt
    }
    
    public static func audio(from format: AVAudioFormat) -> MediaFormat {
        var fmt = MediaFormat()
        fmt.mediaType = kCMMediaType_Audio
        fmt.sampleRate = format.sampleRate
        fmt.channelCount = Int(format.channelCount)
        fmt.audioBitsPerChannel = Int(format.streamDescription.pointee.mBitsPerChannel)
        fmt.audioIsInterleaved = format.isInterleaved
        return fmt
    }
}

// MARK: - Component State

public enum ComponentState: Equatable, CustomStringConvertible {
    case idle                   // Created, not configured
    case ready                  // Configured, can start
    case running                // Active
    case paused                 // Suspended, can resume
    case error(ComponentError)  // Faulted
    
    public var description: String {
        switch self {
        case .idle: return "idle"
        case .ready: return "ready"
        case .running: return "running"
        case .paused: return "paused"
        case .error(let e): return "error: \(e.localizedDescription)"
        }
    }
    
    public var canTransitionToRunning: Bool {
        switch self {
        case .ready, .paused: return true
        default: return false
        }
    }
}

public struct ComponentError: Error, Equatable, LocalizedError {
    public let code: Int
    public let message: String
    public let underlyingErrorDescription: String?
    
    public var errorDescription: String? { message }
    
    public init(code: Int, message: String, underlying: Error? = nil) {
        self.code = code
        self.message = message
        self.underlyingErrorDescription = underlying?.localizedDescription
    }
    
    public static func == (lhs: ComponentError, rhs: ComponentError) -> Bool {
        lhs.code == rhs.code && lhs.message == rhs.message
    }
    
    // Common errors
    public static let notConfigured = ComponentError(code: 1, message: "Component not configured")
    public static let alreadyRunning = ComponentError(code: 2, message: "Component already running")
    public static let invalidState = ComponentError(code: 3, message: "Invalid state for operation")
    public static let connectionFailed = ComponentError(code: 4, message: "Failed to connect ports")
    public static let formatMismatch = ComponentError(code: 5, message: "Incompatible media formats")
}

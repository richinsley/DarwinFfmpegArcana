// Sources/FfmpegArcana/Pipeline/Ports/InputPorts.swift

import Foundation
import AVFoundation
import CoreMedia

// MARK: - Base Input Port

public class BaseInputPort: InputPort {
    public let id: String
    public let mediaType: CMMediaType
    public var acceptedFormats: [MediaFormat] = []
    public weak var component: PipelineComponent?
    
    private weak var _connection: OutputPort?
    private let lock = NSLock()
    
    public var connection: OutputPort? {
        lock.lock()
        defer { lock.unlock() }
        return _connection
    }
    
    public init(id: String, mediaType: CMMediaType) {
        self.id = id
        self.mediaType = mediaType
    }
    
    public func connect(to output: OutputPort) throws {
        lock.lock()
        defer { lock.unlock() }
        
        guard output.mediaType == mediaType else {
            throw ComponentError.formatMismatch
        }
        
        _connection = output
    }
    
    public func disconnect() {
        lock.lock()
        defer { lock.unlock() }
        _connection = nil
    }
    
    // Override in subclasses
    public func receive(_ sample: CMSampleBuffer) {}
    public func receive(_ pixelBuffer: CVPixelBuffer, time: CMTime) {}
    public func receive(_ audioBuffer: AVAudioPCMBuffer, time: AVAudioTime) {}
}

// MARK: - Video Input Port with Handler

public class VideoInputPort: BaseInputPort {
    
    public var sampleHandler: ((CMSampleBuffer) -> Void)?
    public var pixelBufferHandler: ((CVPixelBuffer, CMTime) -> Void)?
    
    public init(id: String) {
        super.init(id: id, mediaType: kCMMediaType_Video)
    }
    
    public override func receive(_ sample: CMSampleBuffer) {
        sampleHandler?(sample)
    }
    
    public override func receive(_ pixelBuffer: CVPixelBuffer, time: CMTime) {
        pixelBufferHandler?(pixelBuffer, time)
    }
}

// MARK: - Audio Input Port with Handler

public class AudioInputPort: BaseInputPort {
    
    public var sampleHandler: ((CMSampleBuffer) -> Void)?
    public var audioBufferHandler: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    
    public init(id: String) {
        super.init(id: id, mediaType: kCMMediaType_Audio)
    }
    
    public override func receive(_ sample: CMSampleBuffer) {
        sampleHandler?(sample)
    }
    
    public override func receive(_ audioBuffer: AVAudioPCMBuffer, time: AVAudioTime) {
        audioBufferHandler?(audioBuffer, time)
    }
}
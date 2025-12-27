// Sources/FfmpegArcana/Pipeline/Ports/OutputPorts.swift

import Foundation
import AVFoundation
import CoreMedia

// MARK: - Base Output Port

public class BaseOutputPort: OutputPort {
    public let id: String
    public let mediaType: CMMediaType
    public private(set) var format: MediaFormat = .unknown
    public weak var component: PipelineComponent?
    
    private var _connections: [InputPort] = []
    private let lock = NSLock()
    
    public var connections: [InputPort] {
        lock.lock()
        defer { lock.unlock() }
        return _connections
    }
    
    public init(id: String, mediaType: CMMediaType) {
        self.id = id
        self.mediaType = mediaType
    }
    
    public func connect(to input: InputPort) throws {
        lock.lock()
        defer { lock.unlock() }
        
        guard input.mediaType == mediaType else {
            throw ComponentError.formatMismatch
        }
        
        if !_connections.contains(where: { $0 === input }) {
            _connections.append(input)
            try input.connect(to: self)
        }
    }
    
    public func disconnect(from input: InputPort) {
        lock.lock()
        defer { lock.unlock() }
        
        _connections.removeAll { $0 === input }
        input.disconnect()
    }
    
    public func disconnectAll() {
        lock.lock()
        let conns = _connections
        _connections.removeAll()
        lock.unlock()
        
        conns.forEach { $0.disconnect() }
    }
    
    public func updateFormat(_ newFormat: MediaFormat) {
        format = newFormat
    }
}

// MARK: - Video Output Port

public class VideoOutputPort: BaseOutputPort {
    
    public init(id: String) {
        super.init(id: id, mediaType: kCMMediaType_Video)
    }
    
    public func send(_ sampleBuffer: CMSampleBuffer) {
        for input in connections {
            input.receive(sampleBuffer)
        }
    }
    
    public func send(_ pixelBuffer: CVPixelBuffer, time: CMTime) {
        for input in connections {
            input.receive(pixelBuffer, time: time)
        }
    }
}

// MARK: - Audio Output Port

public class AudioOutputPort: BaseOutputPort {
    
    public init(id: String) {
        super.init(id: id, mediaType: kCMMediaType_Audio)
    }
    
    public func send(_ sampleBuffer: CMSampleBuffer) {
        for input in connections {
            input.receive(sampleBuffer)
        }
    }
    
    public func send(_ audioBuffer: AVAudioPCMBuffer, time: AVAudioTime) {
        for input in connections {
            input.receive(audioBuffer, time: time)
        }
    }
}
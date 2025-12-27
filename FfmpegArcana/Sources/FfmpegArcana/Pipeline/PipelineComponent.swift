// Sources/FfmpegArcana/Pipeline/PipelineComponent.swift

import Foundation
import CoreMedia
import AVFoundation

// MARK: - Ports

/// Output port - produces media samples
public protocol OutputPort: AnyObject {
    var id: String { get }
    var mediaType: CMMediaType { get }
    var format: MediaFormat { get }
    var component: PipelineComponent? { get }
    
    /// Connected inputs (fan-out supported)
    var connections: [InputPort] { get }
    
    func connect(to input: InputPort) throws
    func disconnect(from input: InputPort)
    func disconnectAll()
}

/// Input port - consumes media samples
public protocol InputPort: AnyObject {
    var id: String { get }
    var mediaType: CMMediaType { get }
    var acceptedFormats: [MediaFormat] { get }  // Empty = accepts any
    var component: PipelineComponent? { get }
    
    /// Connected output (single source)
    var connection: OutputPort? { get }
    
    func connect(to output: OutputPort) throws
    func disconnect()
    
    /// Called by connected output to deliver samples
    func receive(_ sample: CMSampleBuffer)
    func receive(_ pixelBuffer: CVPixelBuffer, time: CMTime)
    func receive(_ audioBuffer: AVAudioPCMBuffer, time: AVAudioTime)
}

// MARK: - Base Component Protocol

public protocol PipelineComponent: AnyObject {
    /// Unique identifier for this instance
    var id: String { get }
    
    /// Human-readable name
    var displayName: String { get }
    
    /// Current state
    var state: ComponentState { get }
    
    /// Available ports
    var inputPorts: [String: InputPort] { get }
    var outputPorts: [String: OutputPort] { get }
    
    /// Exposed parameters for control surface
    var parameters: ParameterSet { get }
    
    // MARK: Lifecycle
    
    /// Configure and allocate resources. Call before start().
    func prepare() async throws
    
    /// Begin processing
    func start() async throws
    
    /// Pause processing, retain resources
    func pause() async throws
    
    /// Stop and release resources
    func stop() async throws
    
    // MARK: Parameters
    
    func setParameter(_ key: String, value: Any) throws
    func getParameter(_ key: String) -> Any?
    
    /// Callback when parameter changes (for UI binding)
    var onParameterChanged: ((String, Any) -> Void)? { get set }
    
    /// Callback when state changes
    var onStateChanged: ((ComponentState) -> Void)? { get set }
}

// MARK: - Source Component (no inputs)

public protocol SourceComponent: PipelineComponent {
    // Sources produce media, no inputs
}

// MARK: - Sink Component (no outputs)  

public protocol SinkComponent: PipelineComponent {
    // Sinks consume media, no outputs
}

// MARK: - Processor Component (has both)

public protocol ProcessorComponent: PipelineComponent {
    // Processors transform media
}

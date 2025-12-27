// Sources/FfmpegArcana/Pipeline/Components/MicrophoneSource.swift

import Foundation
import AVFoundation

public class MicrophoneSource: NSObject, SourceComponent {
    
    public let id: String
    public var displayName: String { "Microphone" }
    public private(set) var state: ComponentState = .idle
    
    public var inputPorts: [String: InputPort] { [:] }
    public lazy var outputPorts: [String: OutputPort] = {
        ["audio": audioOutput]
    }()
    
    public var parameters: ParameterSet { _parameters }
    public var onParameterChanged: ((String, Any) -> Void)?
    public var onStateChanged: ((ComponentState) -> Void)?
    
    private let audioOutput = AudioOutputPort(id: "audio")
    private let _parameters = ParameterSet()
    
    // AVFoundation
    private var captureSession: AVCaptureSession?
    private var audioDevice: AVCaptureDevice?
    private var audioInput: AVCaptureDeviceInput?
    private var audioDataOutput: AVCaptureAudioDataOutput?
    
    private let sessionQueue = DispatchQueue(label: "mic.session", qos: .userInitiated)
    private let outputQueue = DispatchQueue(label: "mic.output", qos: .userInitiated)
    
    public init(id: String = UUID().uuidString) {
        self.id = id
        super.init()
        audioOutput.component = self
        
        setupParameters()
    }
    
    private func setupParameters() {
        _parameters.add(.float("gain", display: "Gain", default: 1.0, range: 0...2))
        _parameters.add(.bool("muted", display: "Mute", default: false))
        _parameters.add(.readout("sampleRate", display: "Sample Rate", type: .float))
        _parameters.add(.readout("channels", display: "Channels", type: .int))
    }
    
    // MARK: - Lifecycle
    
    public func prepare() async throws {
        let session = AVCaptureSession()
        
        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw ComponentError(code: 300, message: "No microphone available")
        }
        
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw ComponentError(code: 301, message: "Cannot add audio input")
        }
        session.addInput(input)
        
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: outputQueue)
        guard session.canAddOutput(output) else {
            throw ComponentError(code: 302, message: "Cannot add audio output")
        }
        session.addOutput(output)
        
        captureSession = session
        audioDevice = device
        audioInput = input
        audioDataOutput = output
        
        // Update readouts
        let formatDesc = device.activeFormat.formatDescription
        if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee {
            _parameters.updateReadOnly("sampleRate", value: asbd.mSampleRate)
            _parameters.updateReadOnly("channels", value: Int(asbd.mChannelsPerFrame))
        }
        
        setState(.ready)
    }
    
    public func start() async throws {
        guard state.canTransitionToRunning else { throw ComponentError.invalidState }
        
        sessionQueue.async { [weak self] in
            self?.captureSession?.startRunning()
        }
        setState(.running)
    }
    
    public func pause() async throws {
        sessionQueue.async { [weak self] in
            self?.captureSession?.stopRunning()
        }
        setState(.paused)
    }
    
    public func stop() async throws {
        sessionQueue.async { [weak self] in
            self?.captureSession?.stopRunning()
            self?.captureSession = nil
        }
        setState(.idle)
    }
    
    public func setParameter(_ key: String, value: Any) throws {
        try _parameters.set(key, value: value)
        onParameterChanged?(key, value)
    }
    
    public func getParameter(_ key: String) -> Any? {
        _parameters.get(key)
    }
    
    private func setState(_ newState: ComponentState) {
        state = newState
        onStateChanged?(newState)
    }
}

extension MicrophoneSource: AVCaptureAudioDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard (_parameters.get("muted") as? Bool) != true else { return }
        audioOutput.send(sampleBuffer)
    }
}
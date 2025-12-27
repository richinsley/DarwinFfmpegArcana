// Sources/FfmpegArcana/Pipeline/Components/CameraSource.swift

import Foundation
import AVFoundation
import CoreMedia

public class CameraSource: NSObject, SourceComponent {
    
    // MARK: - PipelineComponent conformance
    
    public let id: String
    public var displayName: String { "Camera" }
    public private(set) var state: ComponentState = .idle
    
    public var inputPorts: [String: InputPort] { [:] }  // Sources have no inputs
    public lazy var outputPorts: [String: OutputPort] = {
        [
            "video": videoOutput,
            "audio": audioOutput
        ]
    }()
    
    public var parameters: ParameterSet { _parameters }
    public var onParameterChanged: ((String, Any) -> Void)?
    public var onStateChanged: ((ComponentState) -> Void)?
    
    // MARK: - Outputs
    
    private let videoOutput = VideoOutputPort(id: "video")
    private let audioOutput = AudioOutputPort(id: "audio")
    
    // MARK: - AVFoundation
    
    private let captureSession = AVCaptureSession()
    private var videoDevice: AVCaptureDevice?
    private var audioDevice: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var videoDataOutput: AVCaptureVideoDataOutput?
    private var audioDataOutput: AVCaptureAudioDataOutput?
    
    private let sessionQueue = DispatchQueue(label: "camera.session", qos: .userInitiated)
    private let videoOutputQueue = DispatchQueue(label: "camera.video.output", qos: .userInitiated)
    private let audioOutputQueue = DispatchQueue(label: "camera.audio.output", qos: .userInitiated)
    
    // MARK: - Parameters
    
    private let _parameters = ParameterSet()
    
    // MARK: - Configuration
    
    public struct Configuration {
        public var position: AVCaptureDevice.Position = .back
        public var preferredResolution: CGSize?
        public var preferredFrameRate: Double?
        public var enableAudio: Bool = true
        
        public init() {}
    }
    
    private var config: Configuration
    
    // MARK: - Init
    
    public init(id: String = UUID().uuidString, configuration: Configuration = Configuration()) {
        self.id = id
        self.config = configuration
        
        super.init()
        
        videoOutput.component = self
        audioOutput.component = self
        
        setupBaseParameters()
    }
    
    private func setupBaseParameters() {
        // Position - always available
        _parameters.add(.enumeration(
            "position",
            display: "Camera",
            options: [
                ParameterOption("back", display: "Back"),
                ParameterOption("front", display: "Front")
            ],
            default: config.position == .back ? "back" : "front"
        ))
        
        // Readouts
        _parameters.add(.readout("resolution", display: "Resolution", type: .string))
        _parameters.add(.readout("frameRate", display: "Frame Rate", type: .float))
        _parameters.add(.readout("activeFormat", display: "Format", type: .string))
    }
    
    private func setupDeviceParameters() {
        guard let device = videoDevice else { return }
        
        // Exposure
        if device.isExposureModeSupported(.custom) {
            _parameters.add(.enumeration(
                "exposureMode",
                display: "Exposure",
                options: [
                    ParameterOption("auto", display: "Auto"),
                    ParameterOption("locked", display: "Locked"),
                    ParameterOption("custom", display: "Manual")
                ],
                default: "auto"
            ))
            
            let format = device.activeFormat
            _parameters.add(.float(
                "iso",
                display: "ISO",
                default: Double(device.iso),
                range: Double(format.minISO)...Double(format.maxISO)
            ))
            
            let minShutter = format.minExposureDuration.seconds
            let maxShutter = format.maxExposureDuration.seconds
            _parameters.add(.float(
                "shutterSpeed",
                display: "Shutter",
                default: device.exposureDuration.seconds,
                range: minShutter...maxShutter
            ))
        }
        
        // Focus
        if device.isFocusModeSupported(.autoFocus) {
            var focusOptions: [ParameterOption] = [
                ParameterOption("auto", display: "Auto"),
                ParameterOption("locked", display: "Locked")
            ]
            if device.isLockingFocusWithCustomLensPositionSupported {
                focusOptions.append(ParameterOption("manual", display: "Manual"))
                
                _parameters.add(.float(
                    "lensPosition",
                    display: "Focus",
                    default: Double(device.lensPosition),
                    range: 0...1
                ))
            }
            
            _parameters.add(.enumeration(
                "focusMode",
                display: "Focus Mode",
                options: focusOptions,
                default: "auto"
            ))
        }
        
        // White Balance
        if device.isWhiteBalanceModeSupported(.locked) {
            var wbOptions: [ParameterOption] = [
                ParameterOption("auto", display: "Auto"),
                ParameterOption("locked", display: "Locked")
            ]
            
            if device.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
                wbOptions.append(ParameterOption("custom", display: "Custom"))
                
                // Temperature/Tint - approximate ranges
                _parameters.add(.float("colorTemp", display: "Color Temp", default: 5500, range: 2000...10000))
                _parameters.add(.float("tint", display: "Tint", default: 0, range: -150...150))
            }
            
            _parameters.add(.enumeration(
                "whiteBalanceMode",
                display: "White Balance",
                options: wbOptions,
                default: "auto"
            ))
        }
        
        // Zoom
        let maxZoom = min(device.activeFormat.videoMaxZoomFactor, 10.0)  // Cap at 10x for UI
        _parameters.add(.float("zoom", display: "Zoom", default: 1.0, range: 1.0...maxZoom))
        
        // HDR (if supported)
        if device.activeFormat.isVideoHDRSupported {
            _parameters.add(.bool("hdrEnabled", display: "HDR", default: false))
        }
        
        // Torch
        if device.hasTorch {
            _parameters.add(.bool("torchEnabled", display: "Torch", default: false))
            _parameters.add(.float("torchLevel", display: "Torch Level", default: 1.0, range: 0...1))
        }
    }
    
    // MARK: - Lifecycle
    
    public func prepare() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: ComponentError.notConfigured)
                    return
                }
                
                do {
                    try self.setupCaptureSession()
                    self.setState(.ready)
                    continuation.resume()
                } catch {
                    self.setState(.error(ComponentError(code: 100, message: "Setup failed", underlying: error)))
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    public func start() async throws {
        guard state.canTransitionToRunning else {
            throw ComponentError.invalidState
        }
        
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [weak self] in
                self?.captureSession.startRunning()
                self?.setState(.running)
                continuation.resume()
            }
        }
    }
    
    public func pause() async throws {
        guard state == .running else {
            throw ComponentError.invalidState
        }
        
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [weak self] in
                self?.captureSession.stopRunning()
                self?.setState(.paused)
                continuation.resume()
            }
        }
    }
    
    public func stop() async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [weak self] in
                self?.captureSession.stopRunning()
                self?.teardownCaptureSession()
                self?.setState(.idle)
                continuation.resume()
            }
        }
    }
    
    // MARK: - Parameters
    
    public func setParameter(_ key: String, value: Any) throws {
        try _parameters.set(key, value: value)
        applyParameterOnSessionQueue(key, value: value)
        onParameterChanged?(key, value)
    }
    
    public func getParameter(_ key: String) -> Any? {
        _parameters.get(key)
    }
    
    private func applyParameterOnSessionQueue(_ key: String, value: Any) {
        sessionQueue.async { [weak self] in
            self?.applyParameter(key, value: value)
        }
    }
    
    private func applyParameter(_ key: String, value: Any) {
        // Must be called on sessionQueue
        guard let device = videoDevice else { return }
        
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            
            switch key {
            case "position":
                if let posStr = value as? String {
                    let newPos: AVCaptureDevice.Position = posStr == "front" ? .front : .back
                    if newPos != device.position {
                        switchCamera(to: newPos)
                    }
                }
                
            case "exposureMode":
                if let modeStr = value as? String {
                    let mode: AVCaptureDevice.ExposureMode
                    switch modeStr {
                    case "locked": mode = .locked
                    case "custom": mode = .custom
                    default: mode = .continuousAutoExposure
                    }
                    if device.isExposureModeSupported(mode) {
                        device.exposureMode = mode
                    }
                }
                
            case "iso":
                if let iso = value as? Double, device.exposureMode == .custom {
                    device.setExposureModeCustom(
                        duration: device.exposureDuration,
                        iso: Float(iso)
                    )
                }
                
            case "shutterSpeed":
                if let shutter = value as? Double, device.exposureMode == .custom {
                    device.setExposureModeCustom(
                        duration: CMTime(seconds: shutter, preferredTimescale: 1000000),
                        iso: device.iso
                    )
                }
                
            case "focusMode":
                if let modeStr = value as? String {
                    let mode: AVCaptureDevice.FocusMode
                    switch modeStr {
                    case "locked": mode = .locked
                    case "manual": mode = .locked
                    default: mode = .continuousAutoFocus
                    }
                    if device.isFocusModeSupported(mode) {
                        device.focusMode = mode
                    }
                }
                
            case "lensPosition":
                if let pos = value as? Double {
                    device.setFocusModeLocked(lensPosition: Float(pos))
                }
                
            case "zoom":
                if let zoom = value as? Double {
                    device.videoZoomFactor = CGFloat(zoom)
                }
                
            case "hdrEnabled":
                if let enabled = value as? Bool {
                    if device.activeFormat.isVideoHDRSupported {
                        device.automaticallyAdjustsVideoHDREnabled = false
                        device.isVideoHDREnabled = enabled
                    }
                }
                
            case "torchEnabled":
                if let enabled = value as? Bool, device.hasTorch {
                    device.torchMode = enabled ? .on : .off
                }
                
            case "torchLevel":
                if let level = value as? Double, device.hasTorch && device.torchMode == .on {
                    try device.setTorchModeOn(level: Float(level))
                }
                
            default:
                break
            }
        } catch {
            print("Failed to apply parameter \(key): \(error)")
        }
    }
    
    // MARK: - Private Setup
    
    private func setupCaptureSession() throws {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        
        // Video device
        let position = config.position
        guard let vDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            throw ComponentError(code: 101, message: "No camera available for position: \(position)")
        }
        videoDevice = vDevice
        
        let vInput = try AVCaptureDeviceInput(device: vDevice)
        guard captureSession.canAddInput(vInput) else {
            throw ComponentError(code: 102, message: "Cannot add video input")
        }
        captureSession.addInput(vInput)
        videoInput = vInput
        
        // Configure format if requested
        if let resolution = config.preferredResolution {
            try selectFormat(width: Int(resolution.width), height: Int(resolution.height), frameRate: config.preferredFrameRate)
        } else if let frameRate = config.preferredFrameRate {
            try selectFormat(width: nil, height: nil, frameRate: frameRate)
        }
        
        // Video output
        let vOutput = AVCaptureVideoDataOutput()
        vOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        vOutput.alwaysDiscardsLateVideoFrames = true
        vOutput.setSampleBufferDelegate(self, queue: videoOutputQueue)
        
        guard captureSession.canAddOutput(vOutput) else {
            throw ComponentError(code: 103, message: "Cannot add video output")
        }
        captureSession.addOutput(vOutput)
        videoDataOutput = vOutput
        
        // Audio (optional)
        if config.enableAudio {
            if let aDevice = AVCaptureDevice.default(for: .audio) {
                audioDevice = aDevice
                let aInput = try AVCaptureDeviceInput(device: aDevice)
                if captureSession.canAddInput(aInput) {
                    captureSession.addInput(aInput)
                    audioInput = aInput
                    
                    let aOutput = AVCaptureAudioDataOutput()
                    aOutput.setSampleBufferDelegate(self, queue: audioOutputQueue)
                    if captureSession.canAddOutput(aOutput) {
                        captureSession.addOutput(aOutput)
                        audioDataOutput = aOutput
                    }
                }
            }
        }
        
        // Update output formats
        updateOutputFormat()
        
        // Setup device-specific parameters
        setupDeviceParameters()
    }
    
    private func teardownCaptureSession() {
        captureSession.beginConfiguration()
        
        if let vInput = videoInput { captureSession.removeInput(vInput) }
        if let aInput = audioInput { captureSession.removeInput(aInput) }
        if let vOutput = videoDataOutput { captureSession.removeOutput(vOutput) }
        if let aOutput = audioDataOutput { captureSession.removeOutput(aOutput) }
        
        captureSession.commitConfiguration()
        
        videoDevice = nil
        audioDevice = nil
        videoInput = nil
        audioInput = nil
        videoDataOutput = nil
        audioDataOutput = nil
    }
    
    private func selectFormat(width: Int?, height: Int?, frameRate: Double?) throws {
        guard let device = videoDevice else { return }
        
        let formats = device.formats.filter { format in
            let desc = format.formatDescription
            let dimensions = CMVideoFormatDescriptionGetDimensions(desc)
            
            // Filter by resolution if specified
            if let w = width, let h = height {
                if dimensions.width != w || dimensions.height != h { return false }
            }
            
            // Filter by frame rate if specified
            if let fr = frameRate {
                let supportsRate = format.videoSupportedFrameRateRanges.contains { range in
                    range.minFrameRate <= fr && fr <= range.maxFrameRate
                }
                if !supportsRate { return false }
            }
            
            return true
        }
        
        guard let bestFormat = formats.first else {
            throw ComponentError(code: 104, message: "No matching format found")
        }
        
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        
        device.activeFormat = bestFormat
        
        if let fr = frameRate,
           let range = bestFormat.videoSupportedFrameRateRanges.first(where: { $0.minFrameRate <= fr && fr <= $0.maxFrameRate }) {
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fr))
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fr))
        }
    }
    
    private func switchCamera(to position: AVCaptureDevice.Position) {
        // Already on sessionQueue when called from applyParameter
        config.position = position
        teardownCaptureSession()
        
        do {
            try setupCaptureSession()
            if state == .running {
                captureSession.startRunning()
            }
        } catch {
            setState(.error(ComponentError(code: 105, message: "Camera switch failed", underlying: error)))
        }
    }
    
    private func updateOutputFormat() {
        guard let device = videoDevice else { return }
        
        let desc = device.activeFormat.formatDescription
        let dimensions = CMVideoFormatDescriptionGetDimensions(desc)
        let frameRate = 1.0 / device.activeVideoMinFrameDuration.seconds
        
        let format = MediaFormat.video(
            width: Int(dimensions.width),
            height: Int(dimensions.height),
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            frameRate: device.activeVideoMinFrameDuration
        )
        
        videoOutput.updateFormat(format)
        
        // Update readouts
        _parameters.updateReadOnly("resolution", value: "\(dimensions.width)x\(dimensions.height)")
        _parameters.updateReadOnly("frameRate", value: frameRate)
        _parameters.updateReadOnly("activeFormat", value: device.activeFormat.description)
    }
    
    private func setState(_ newState: ComponentState) {
        state = newState
        onStateChanged?(newState)
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraSource: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output == videoDataOutput {
            videoOutput.send(sampleBuffer)
        } else if output == audioDataOutput {
            audioOutput.send(sampleBuffer)
        }
    }
    
    public func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Track dropped frames if needed
    }
}
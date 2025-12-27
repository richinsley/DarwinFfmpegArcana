// Sources/FfmpegArcana/Pipeline/Components/Display/DisplaySink.swift

import Foundation
import AVFoundation
import CoreMedia
import MetalKit
import CFfmpegWrapper

// MARK: - Display Sink Configuration

public struct DisplaySinkConfiguration: Sendable {
    public var enablePreview: Bool = true
    public var enableExternalDisplay: Bool = true
    public var enableAudioMonitoring: Bool = true
    public var routeAudioToHDMI: Bool = true
    public var fifoCapacity: Int = 3
    
    public var matchFrameRate: Bool = true
    public var bypassColorSpaceConversion: Bool = true
    
    public init() {}
}

// MARK: - Display Sink

public final class DisplaySink: NSObject, SinkComponent, @unchecked Sendable {
    
    // MARK: - PipelineComponent conformance
    
    public let id: String
    public var displayName: String { "Display Output" }
    public private(set) var state: ComponentState = .idle
    
    private var _inputPorts: [String: InputPort]?
    public var inputPorts: [String: InputPort] {
        if _inputPorts == nil {
            _inputPorts = [
                "video": videoInput,
                "audio": audioInput
            ]
        }
        return _inputPorts!
    }
    public var outputPorts: [String: OutputPort] { [:] }
    
    public var parameters: ParameterSet { _parameters }
    public var onParameterChanged: ((String, Any) -> Void)?
    public var onStateChanged: ((ComponentState) -> Void)?
    
    // MARK: - Inputs
    
    private let videoInput: VideoInputPort
    private let audioInput: AudioInputPort
    
    // MARK: - Command Infrastructure
    
    private let cmdPool: CmdPool
    private let videoFifo: CmdFifo
    private let audioFifo: CmdFifo
    
    private var videoConsumerThread: Thread?
    private var audioConsumerThread: Thread?
    private var shouldRun = false
    
    // MARK: - Rendering
    
    private let renderer: DisplayRenderer
    
    private var metalDevice: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var renderPipeline: MTLRenderPipelineState?
    private var textureCache: CVMetalTextureCache?
    
    // MARK: - Audio
    
    private var audioEngine: AVAudioEngine?
    private var audioPlayerNode: AVAudioPlayerNode?
    
    // MARK: - Parameters
    
    private let _parameters = ParameterSet()
    
    // MARK: - Configuration
    
    private let config: DisplaySinkConfiguration
    private var sourceFormat: MediaFormat?
    private var droppedFrameCount = 0
    
    // MARK: - Init
    
    public init(
        id: String = UUID().uuidString, 
        configuration: DisplaySinkConfiguration = DisplaySinkConfiguration(),
        renderer: DisplayRenderer? = nil
    ) {
        self.id = id
        self.config = configuration
        
        // Use provided renderer or create platform default
        self.renderer = renderer ?? Self.createPlatformRenderer()
        
        self.cmdPool = CmdPool(initialSize: 8, maxSize: 16)
        self.videoFifo = CmdFifo(capacity: configuration.fifoCapacity, mode: .blocking)
        self.audioFifo = CmdFifo(capacity: configuration.fifoCapacity, mode: .blocking)
        
        self.videoInput = VideoInputPort(id: "video")
        self.audioInput = AudioInputPort(id: "audio")
        
        super.init()
        
        videoInput.component = self
        audioInput.component = self
        
        setupParameters()
        setupInputHandlers()
        setupRendererCallbacks()
    }
    
    private static func createPlatformRenderer() -> DisplayRenderer {
        #if canImport(UIKit) && !os(macOS)
        return IOSDisplayRenderer()
        #elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
        return MacOSDisplayRenderer()
        #else
        fatalError("Unsupported platform")
        #endif
    }
    
    deinit {
        shouldRun = false
        videoFifo.flowEnabled = false
        audioFifo.flowEnabled = false
    }
    
    private func setupParameters() {
        _parameters.add(.bool("previewEnabled", display: "Preview", default: config.enablePreview))
        _parameters.add(.bool("externalEnabled", display: "External Display", default: config.enableExternalDisplay))
        _parameters.add(.bool("audioMonitoring", display: "Audio Monitor", default: config.enableAudioMonitoring))
        _parameters.add(.bool("hdmiAudio", display: "HDMI Audio", default: config.routeAudioToHDMI))
        
        _parameters.add(.readout("externalStatus", display: "External Status", type: .string))
        _parameters.add(.readout("externalResolution", display: "External Resolution", type: .string))
        _parameters.add(.readout("videoFifoCount", display: "Video Buffer", type: .int))
        _parameters.add(.readout("droppedFrames", display: "Dropped Frames", type: .int))
    }
    
    private func setupInputHandlers() {
        videoInput.sampleHandler = { [weak self] sampleBuffer in
            self?.enqueueVideoSample(sampleBuffer)
        }
        
        audioInput.sampleHandler = { [weak self] sampleBuffer in
            self?.enqueueAudioSample(sampleBuffer)
        }
    }
    
    private func setupRendererCallbacks() {
        renderer.onExternalDisplayChanged = { [weak self] connected, resolution in
            guard let self = self else { return }
            if connected {
                self._parameters.updateReadOnly("externalStatus", value: "Connected")
                self._parameters.updateReadOnly("externalResolution", value: resolution ?? "Unknown")
                self.onParameterChanged?("externalStatus", "Connected")
                self.onParameterChanged?("externalResolution", resolution ?? "Unknown")
            } else {
                self._parameters.updateReadOnly("externalStatus", value: "Disconnected")
                self._parameters.updateReadOnly("externalResolution", value: "N/A")
                self.onParameterChanged?("externalStatus", "Disconnected")
                self.onParameterChanged?("externalResolution", "N/A")
            }
        }
    }
    
    // MARK: - Public Interface
    
    @MainActor
    public func createPreviewView(frame: CGRect) -> MTKView? {
        renderer.metalDevice = metalDevice
        return renderer.createPreviewView(frame: frame)
    }
    
    @MainActor
    public func attachPreview(to view: MTKView) {
        renderer.attachPreviewView(view)
        if metalDevice == nil {
            metalDevice = view.device ?? MTLCreateSystemDefaultDevice()
        }
    }
    
    // MARK: - Lifecycle
    
    public func prepare() async throws {
        guard let device = metalDevice ?? MTLCreateSystemDefaultDevice() else {
            throw ComponentError(code: 200, message: "Metal not available")
        }
        metalDevice = device
        renderer.metalDevice = device
        commandQueue = device.makeCommandQueue()
        
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        textureCache = cache
        
        try setupRenderPipeline()
        
        if config.enableAudioMonitoring {
            try setupAudioEngine()
        }
        
        if config.enableExternalDisplay {
            await MainActor.run {
                self.renderer.startExternalDisplayObservation()
            }
        }
        
        setState(.ready)
    }
    
    public func start() async throws {
        guard state.canTransitionToRunning else {
            throw ComponentError.invalidState
        }
        
        videoFifo.flowEnabled = true
        audioFifo.flowEnabled = true
        shouldRun = true
        
        startConsumerThreads()
        
        if config.enableAudioMonitoring, let engine = audioEngine {
            try engine.start()
        }
        
        setState(.running)
    }
    
    public func pause() async throws {
        videoFifo.flowEnabled = false
        audioFifo.flowEnabled = false
        audioEngine?.pause()
        setState(.paused)
    }
    
    public func stop() async throws {
        shouldRun = false
        videoFifo.flowEnabled = false
        audioFifo.flowEnabled = false
        
        videoConsumerThread = nil
        audioConsumerThread = nil
        
        audioEngine?.stop()
        
        await MainActor.run {
            self.renderer.stopExternalDisplayObservation()
            self.renderer.teardownExternalDisplay()
        }
        
        setState(.idle)
    }
    
    // MARK: - Parameters
    
    public func setParameter(_ key: String, value: Any) throws {
        try _parameters.set(key, value: value)
        applyParameter(key, value: value)
        onParameterChanged?(key, value)
    }
    
    public func getParameter(_ key: String) -> Any? {
        return _parameters.get(key)
    }
    
    private func applyParameter(_ key: String, value: Any) {
        switch key {
        case "audioMonitoring":
            if let enabled = value as? Bool {
                if enabled {
                    try? audioEngine?.start()
                } else {
                    audioEngine?.pause()
                }
            }
            
        case "externalEnabled":
            if let enabled = value as? Bool {
                Task { @MainActor in
                    if enabled {
                        self.renderer.startExternalDisplayObservation()
                    } else {
                        self.renderer.stopExternalDisplayObservation()
                        self.renderer.teardownExternalDisplay()
                    }
                }
            }
            
        default:
            break
        }
    }
    
    // MARK: - FIFO Producers
    
    private func enqueueVideoSample(_ sampleBuffer: CMSampleBuffer) {
        guard videoFifo.flowEnabled else { return }
        
        guard videoFifo.tryWaitForWriteSpace() else {
            droppedFrameCount += 1
            _parameters.updateReadOnly("droppedFrames", value: droppedFrameCount)
            return
        }
        
        guard let cmd = cmdPool.acquire() else {
            droppedFrameCount += 1
            return
        }
        
        let retained = Unmanaged.passRetained(sampleBuffer as AnyObject)
        cmd.ptr.pointee.type = FF_CMD_FRAME
        cmd.ptr.pointee.data = retained.toOpaque()
        cmd.ptr.pointee.pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).value
        
        do {
            try videoFifo.write(cmd)
            _parameters.updateReadOnly("videoFifoCount", value: videoFifo.count)
        } catch {
            retained.release()
            cmd.release()
        }
    }
    
    private func enqueueAudioSample(_ sampleBuffer: CMSampleBuffer) {
        guard audioFifo.flowEnabled else { return }
        guard audioFifo.tryWaitForWriteSpace() else { return }
        guard let cmd = cmdPool.acquire() else { return }
        
        let retained = Unmanaged.passRetained(sampleBuffer as AnyObject)
        cmd.ptr.pointee.type = FF_CMD_FRAME
        cmd.ptr.pointee.data = retained.toOpaque()
        cmd.ptr.pointee.pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).value
        
        do {
            try audioFifo.write(cmd)
        } catch {
            retained.release()
            cmd.release()
        }
    }
    
    // MARK: - Consumer Threads
    
    private func startConsumerThreads() {
        videoConsumerThread = Thread { [weak self] in
            self?.videoConsumerLoop()
        }
        videoConsumerThread?.name = "DisplaySink.VideoConsumer"
        videoConsumerThread?.qualityOfService = .userInteractive
        videoConsumerThread?.start()
        
        audioConsumerThread = Thread { [weak self] in
            self?.audioConsumerLoop()
        }
        audioConsumerThread?.name = "DisplaySink.AudioConsumer"
        audioConsumerThread?.qualityOfService = .userInteractive
        audioConsumerThread?.start()
    }
    
    private func videoConsumerLoop() {
        while shouldRun {
            do {
                try videoFifo.waitForReadData()
                
                guard let cmd = try videoFifo.read() else { continue }
                defer { cmd.release() }
                
                guard let dataPtr = cmd.data else { continue }
                let sampleBuffer = Unmanaged<CMSampleBuffer>.fromOpaque(dataPtr).takeRetainedValue()
                
                processVideoFrame(sampleBuffer)
                
            } catch CmdFifoError.flowDisabled {
                break
            } catch {
                print("Video consumer error: \(error)")
            }
        }
    }
    
    private func audioConsumerLoop() {
        while shouldRun {
            do {
                try audioFifo.waitForReadData()
                
                guard let cmd = try audioFifo.read() else { continue }
                defer { cmd.release() }
                
                guard let dataPtr = cmd.data else { continue }
                let sampleBuffer = Unmanaged<CMSampleBuffer>.fromOpaque(dataPtr).takeRetainedValue()
                
                processAudioFrame(sampleBuffer)
                
            } catch CmdFifoError.flowDisabled {
                break
            } catch {
                print("Audio consumer error: \(error)")
            }
        }
    }
    
    // MARK: - Frame Processing
    
    private func processVideoFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        updateSourceFormat(from: pixelBuffer)
        
        // Render to preview
        if config.enablePreview, let preview = renderer.previewView {
            renderToMetalView(preview, pixelBuffer: pixelBuffer)
        }
        
        // Render to external display
        if config.enableExternalDisplay, let external = renderer.externalView {
            renderToMetalView(external, pixelBuffer: pixelBuffer)
        }
    }
    
    private func processAudioFrame(_ sampleBuffer: CMSampleBuffer) {
        guard config.enableAudioMonitoring else { return }
        // Audio playback implementation
    }
    
    private func updateSourceFormat(from pixelBuffer: CVPixelBuffer) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        
        if sourceFormat?.width != width || sourceFormat?.height != height {
            sourceFormat = MediaFormat.video(
                width: width,
                height: height,
                pixelFormat: pixelFormat,
                frameRate: CMTime(value: 1, timescale: 30)
            )
        }
    }
    
    private func renderToMetalView(_ view: MTKView, pixelBuffer: CVPixelBuffer) {
        guard let textureCache = textureCache,
              let commandQueue = commandQueue,
              let renderPipeline = renderPipeline else { return }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture
        )
        
        guard status == kCVReturnSuccess,
              let cvTex = cvTexture,
              let texture = CVMetalTextureGetTexture(cvTex) else { return }
        
        guard let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let descriptor = view.currentRenderPassDescriptor else { return }
        
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        descriptor.colorAttachments[0].storeAction = .store
        
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        
        encoder.setRenderPipelineState(renderPipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
    
    // MARK: - Audio
    
    private func setupAudioEngine() throws {
        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        
        let outputNode = engine.outputNode
        let format = outputNode.inputFormat(forBus: 0)
        
        engine.connect(playerNode, to: outputNode, format: format)
        
        self.audioEngine = engine
        self.audioPlayerNode = playerNode
        
        if config.routeAudioToHDMI {
            try configureAudioSessionForHDMI()
        }
    }
    
    private func configureAudioSessionForHDMI() throws {
        #if canImport(UIKit) && !os(macOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, options: [.allowAirPlay])
        try session.setActive(true)
        #endif
        // macOS doesn't need explicit audio session configuration
    }
    
    // MARK: - Metal Setup
    
    private func setupRenderPipeline() throws {
        guard let device = metalDevice else { return }
        
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;
        
        struct VertexOut {
            float4 position [[position]];
            float2 texCoord;
        };
        
        vertex VertexOut vertexShader(uint vertexID [[vertex_id]]) {
            float2 positions[] = {
                float2(-1, -1), float2(1, -1),
                float2(-1, 1), float2(1, 1)
            };
            float2 texCoords[] = {
                float2(0, 1), float2(1, 1),
                float2(0, 0), float2(1, 0)
            };
            
            VertexOut out;
            out.position = float4(positions[vertexID], 0, 1);
            out.texCoord = texCoords[vertexID];
            return out;
        }
        
        fragment float4 fragmentShader(VertexOut in [[stage_in]],
                                       texture2d<float> texture [[texture(0)]]) {
            constexpr sampler s(filter::linear);
            return texture.sample(s, in.texCoord);
        }
        """
        
        let library = try device.makeLibrary(source: shaderSource, options: nil)
        
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "vertexShader")
        descriptor.fragmentFunction = library.makeFunction(name: "fragmentShader")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        
        renderPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }
    
    private func setState(_ newState: ComponentState) {
        state = newState
        onStateChanged?(newState)
    }
}


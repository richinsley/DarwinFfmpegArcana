// Sources/FfmpegArcana/Pipeline/Components/DisplaySink.swift

import Foundation
import AVFoundation
import CoreMedia
import MetalKit
import UIKit
import CFfmpegWrapper

// MARK: - Display Sink Configuration

public struct DisplaySinkConfiguration: Sendable {
    public var enablePreview: Bool = true
    public var enableExternalDisplay: Bool = true
    public var enableAudioMonitoring: Bool = true
    public var routeAudioToHDMI: Bool = true
    public var fifoCapacity: Int = 3  // Small buffer for display - we want low latency
    
    /// Whether to match external display frame rate to source
    public var matchFrameRate: Bool = true
    
    /// Whether to bypass color space conversion for accurate color output
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
    
    // MARK: - Inputs (with FIFOs)
    
    private let videoInput: VideoInputPort
    private let audioInput: AudioInputPort
    
    // MARK: - Command Infrastructure
    
    private let cmdPool: CmdPool
    private let videoFifo: CmdFifo
    private let audioFifo: CmdFifo
    
    // Consumer threads
    private var videoConsumerThread: Thread?
    private var audioConsumerThread: Thread?
    private var shouldRun = false
    
    // MARK: - Metal Rendering
    
    private var metalDevice: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var renderPipeline: MTLRenderPipelineState?
    private var textureCache: CVMetalTextureCache?
    
    // Preview view (for on-device display)
    private weak var previewView: MTKView?
    
    // MARK: - External Display
    
    private var externalWindow: UIWindow?
    private var externalMetalView: MTKView?
    private var displayConfigurator: Any?
    
    // MARK: - Audio
    
    private var audioEngine: AVAudioEngine?
    private var audioPlayerNode: AVAudioPlayerNode?
    
    // MARK: - Parameters
    
    private let _parameters = ParameterSet()
    
    // MARK: - Configuration
    
    private let config: DisplaySinkConfiguration
    
    // Source format tracking
    private var sourceFormat: MediaFormat?
    
    // MARK: - Init
    
    public init(id: String = UUID().uuidString, configuration: DisplaySinkConfiguration = DisplaySinkConfiguration()) {
        self.id = id
        self.config = configuration
        
        // Create command infrastructure
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
    }
    
    deinit {
        // Ensure threads are stopped
        shouldRun = false
        videoFifo.flowEnabled = false
        audioFifo.flowEnabled = false
    }
    
    private func setupParameters() {
        _parameters.add(.bool("previewEnabled", display: "Preview", default: config.enablePreview))
        _parameters.add(.bool("externalEnabled", display: "External Display", default: config.enableExternalDisplay))
        _parameters.add(.bool("audioMonitoring", display: "Audio Monitor", default: config.enableAudioMonitoring))
        _parameters.add(.bool("hdmiAudio", display: "HDMI Audio", default: config.routeAudioToHDMI))
        
        // Readouts
        _parameters.add(.readout("externalStatus", display: "External Status", type: .string))
        _parameters.add(.readout("externalResolution", display: "External Resolution", type: .string))
        _parameters.add(.readout("videoFifoCount", display: "Video Buffer", type: .int))
        _parameters.add(.readout("droppedFrames", display: "Dropped Frames", type: .int))
    }
    
    private func setupInputHandlers() {
        // Video input handler - runs on producer's thread, pushes to FIFO
        videoInput.sampleHandler = { [weak self] sampleBuffer in
            self?.enqueueVideoSample(sampleBuffer)
        }
        
        // Audio input handler - runs on producer's thread, pushes to FIFO
        audioInput.sampleHandler = { [weak self] sampleBuffer in
            self?.enqueueAudioSample(sampleBuffer)
        }
    }
    
    // MARK: - Public Interface
    
    @MainActor
    public func createPreviewView(frame: CGRect) -> MTKView? {
        guard let device = metalDevice ?? MTLCreateSystemDefaultDevice() else { return nil }
        metalDevice = device
        
        let view = MTKView(frame: frame, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.enableSetNeedsDisplay = false
        view.isPaused = true
        view.backgroundColor = .black
        view.autoResizeDrawable = true
        
        previewView = view
        return view
    }
    
    @MainActor
    public func attachPreview(to view: MTKView) {
        previewView = view
        if metalDevice == nil {
            metalDevice = view.device ?? MTLCreateSystemDefaultDevice()
        }
    }
    
    // MARK: - Lifecycle
    
    public func prepare() async throws {
        // Setup Metal
        guard let device = metalDevice ?? MTLCreateSystemDefaultDevice() else {
            throw ComponentError(code: 200, message: "Metal not available")
        }
        metalDevice = device
        commandQueue = device.makeCommandQueue()
        
        // Texture cache
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        textureCache = cache
        
        // Render pipeline
        try setupRenderPipeline()
        
        // Audio engine
        if config.enableAudioMonitoring {
            try setupAudioEngine()
        }
        
        // External display observation (on main thread)
        if config.enableExternalDisplay {
            await MainActor.run {
                self.setupExternalDisplayObservation()
            }
        }
        
        setState(.ready)
    }
    
    public func start() async throws {
        guard state.canTransitionToRunning else {
            throw ComponentError.invalidState
        }
        
        // Enable FIFOs
        videoFifo.flowEnabled = true
        audioFifo.flowEnabled = true
        shouldRun = true
        
        // Start consumer threads
        startConsumerThreads()
        
        // Start audio
        if config.enableAudioMonitoring, let engine = audioEngine {
            try engine.start()
        }
        
        // Check for external display
        await MainActor.run {
            self.checkForExternalDisplay()
        }
        
        setState(.running)
    }
    
    public func pause() async throws {
        // Disable flow but keep threads alive
        videoFifo.flowEnabled = false
        audioFifo.flowEnabled = false
        audioEngine?.pause()
        setState(.paused)
    }
    
    public func stop() async throws {
        // Stop flow and threads
        shouldRun = false
        videoFifo.flowEnabled = false
        audioFifo.flowEnabled = false
        
        // Wait for threads to finish (they'll exit when flow is disabled)
        videoConsumerThread = nil
        audioConsumerThread = nil
        
        audioEngine?.stop()
        
        await MainActor.run {
            self.teardownExternalDisplay()
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
                        self.checkForExternalDisplay()
                    } else {
                        self.teardownExternalDisplay()
                    }
                }
            }
            
        default:
            break
        }
    }
    
    // MARK: - FIFO Producers (called from input port handlers)
    
    private var droppedFrameCount = 0
    
    private func enqueueVideoSample(_ sampleBuffer: CMSampleBuffer) {
        guard videoFifo.flowEnabled else { return }
        
        // Try to get write space without blocking (drop if full - display should never block)
        guard videoFifo.tryWaitForWriteSpace() else {
            droppedFrameCount += 1
            _parameters.updateReadOnly("droppedFrames", value: droppedFrameCount)
            return
        }
        
        // Acquire command from pool
        guard let cmd = cmdPool.acquire() else {
            droppedFrameCount += 1
            return
        }
        
        // Wrap the sample buffer
        // Note: We need to retain the sample buffer since cmd.data is unmanaged
        let retained = Unmanaged.passRetained(sampleBuffer as AnyObject)
        cmd.ptr.pointee.type = FF_CMD_FRAME
        cmd.ptr.pointee.data = retained.toOpaque()
        cmd.ptr.pointee.pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).value
        
        // Write to FIFO (transfers ownership)
        do {
            try videoFifo.write(cmd)
            _parameters.updateReadOnly("videoFifoCount", value: videoFifo.count)
        } catch {
            // Release on failure
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
        // Video consumer - renders frames
        videoConsumerThread = Thread { [weak self] in
            self?.videoConsumerLoop()
        }
        videoConsumerThread?.name = "DisplaySink.VideoConsumer"
        videoConsumerThread?.qualityOfService = .userInteractive
        videoConsumerThread?.start()
        
        // Audio consumer - plays audio
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
                // Wait for data (blocks until available or flow disabled)
                try videoFifo.waitForReadData()
                
                // Read command
                guard let cmd = try videoFifo.read() else { continue }
                defer { cmd.release() }
                
                // Extract sample buffer
                guard let dataPtr = cmd.data else { continue }
                let sampleBuffer = Unmanaged<CMSampleBuffer>.fromOpaque(dataPtr).takeRetainedValue()
                
                // Process on this thread
                processVideoFrame(sampleBuffer)
                
            } catch CmdFifoError.flowDisabled {
                // Normal shutdown
                break
            } catch {
                // Log and continue
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
    
    // MARK: - Frame Processing (runs on consumer threads)
    
    private func processVideoFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        // Update source format
        updateSourceFormat(from: pixelBuffer)
        
        // Render to preview
        if config.enablePreview, let preview = previewView {
            renderToMetalView(preview, pixelBuffer: pixelBuffer)
        }
        
        // Render to external display
        if config.enableExternalDisplay, let external = externalMetalView {
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
    
    // MARK: - External Display
    
    @MainActor
    private func setupExternalDisplayObservation() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sceneDidActivate(_:)),
            name: UIScene.didActivateNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sceneDidDisconnect(_:)),
            name: UIScene.didDisconnectNotification,
            object: nil
        )
    }
    
    @MainActor
    @objc private func sceneDidActivate(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene else { return }
        
        let mainScenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        
        guard let mainScene = mainScenes.first,
              scene.screen != mainScene.screen else { return }
        
        setupExternalDisplay(on: scene)
    }
    
    @MainActor
    @objc private func sceneDidDisconnect(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene else { return }
        
        if externalWindow?.windowScene == scene {
            teardownExternalDisplay()
        }
    }
    
    @MainActor
    private func checkForExternalDisplay() {
        let scenes = UIApplication.shared.connectedScenes
        guard let mainScene = scenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            updateExternalDisplayStatus(connected: false)
            return
        }
        
        let mainScreen = mainScene.screen
        
        for scene in scenes {
            guard let windowScene = scene as? UIWindowScene,
                  windowScene.screen != mainScreen else {
                continue
            }
            
            setupExternalDisplay(on: windowScene)
            return
        }
        
        updateExternalDisplayStatus(connected: false)
    }
    
    @MainActor
    private func setupExternalDisplay(on windowScene: UIWindowScene) {
        teardownExternalDisplay()
        
        let screen = windowScene.screen
        
        let window = UIWindow(windowScene: windowScene)
        window.frame = screen.bounds
        window.backgroundColor = .black
        
        guard let device = metalDevice else { return }
        
        let mtkView = MTKView(frame: screen.bounds, device: device)
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = false
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = true
        mtkView.backgroundColor = .black
        mtkView.autoResizeDrawable = true
        
        let viewController = UIViewController()
        viewController.view = mtkView
        viewController.view.backgroundColor = .black
        
        window.rootViewController = viewController
        window.makeKeyAndVisible()
        
        self.externalWindow = window
        self.externalMetalView = mtkView
        
        if #available(iOS 17.0, *) {
            setupDisplayConfigurator(for: mtkView.layer)
        }
        
        updateExternalDisplayStatus(connected: true, screen: screen)
    }
    
    @available(iOS 17.0, *)
    @MainActor
    private func setupDisplayConfigurator(for layer: CALayer) {
        let frameRateSupported = AVCaptureExternalDisplayConfigurator.isMatchingFrameRateSupported
        let colorSpaceSupported = AVCaptureExternalDisplayConfigurator.isBypassingColorSpaceConversionSupported
        print("External display capabilities - frameRate: \(frameRateSupported), colorSpace: \(colorSpaceSupported)")
    }
    
    @MainActor
    private func teardownExternalDisplay() {
        displayConfigurator = nil
        externalMetalView = nil
        externalWindow?.isHidden = true
        externalWindow = nil
        updateExternalDisplayStatus(connected: false)
    }
    
    private func updateExternalDisplayStatus(connected: Bool, screen: UIScreen? = nil) {
        if connected, let screen = screen {
            let resolution = "\(Int(screen.bounds.width))x\(Int(screen.bounds.height))"
            _parameters.updateReadOnly("externalStatus", value: "Connected")
            _parameters.updateReadOnly("externalResolution", value: resolution)
            onParameterChanged?("externalStatus", "Connected")
            onParameterChanged?("externalResolution", resolution)
        } else {
            _parameters.updateReadOnly("externalStatus", value: "Disconnected")
            _parameters.updateReadOnly("externalResolution", value: "N/A")
            onParameterChanged?("externalStatus", "Disconnected")
            onParameterChanged?("externalResolution", "N/A")
        }
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
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, options: [.allowAirPlay])
        try session.setActive(true)
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

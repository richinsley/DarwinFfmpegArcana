// HDMIDisplayManager.swift
// Manages external HDMI display output using AVCaptureExternalDisplayConfigurator

import Foundation
import AVFoundation
import CoreMedia
import MetalKit
import UIKit
import os.log

public final class HDMIDisplayManager: NSObject, @unchecked Sendable {
    
    // MARK: - Properties
    
    private nonisolated let logger = Logger(subsystem: "com.camerahdmi", category: "HDMIDisplay")
    
    // Metal resources
    private let metalDevice: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private var renderPipeline: MTLRenderPipelineState?
    private var textureCache: CVMetalTextureCache?
    
    // Preview (on-device)
    private weak var previewView: MTKView?
    
    // External display
    private var externalWindowScene: UIWindowScene?
    private var externalWindow: UIWindow?
    private var externalView: MTKView?
    private var targetDrawableSize: CGSize = .zero
    
    // AVCapture external display configurator
    private var displayConfigurator: AVCaptureExternalDisplayConfigurator?
    private weak var captureDevice: AVCaptureDevice?
    
    // State
    private let stateLock = NSLock()
    private var _isExternalDisplayConnected = false
    private var _externalDisplayResolution: CGSize = .zero
    private var _activeFrameRate: Double = 0
    
    var isExternalDisplayConnected: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isExternalDisplayConnected
    }
    
    var externalDisplayResolution: CGSize {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _externalDisplayResolution
    }
    
    var activeFrameRate: Double {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _activeFrameRate
    }
    
    // Callbacks
    var onExternalDisplayChanged: ((Bool, CGSize, Double) -> Void)?
    
    // Thread-safe pixel buffer
    private let bufferLock = NSLock()
    private var latestPixelBuffer: CVPixelBuffer?
    
    // MARK: - Initialization
    
    override public init() {
        metalDevice = MTLCreateSystemDefaultDevice()
        commandQueue = metalDevice?.makeCommandQueue()
        
        super.init()
        
        if let device = metalDevice {
            var cache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
            textureCache = cache
            
            do {
                try setupRenderPipeline()
            } catch {
                logger.error("Failed to create render pipeline: \(error.localizedDescription)")
            }
        }
        
        setupSceneNotifications()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Public Interface
    
    @MainActor
    public func configure(with device: AVCaptureDevice) {
        self.captureDevice = device
        
        logger.info("Configured with capture device: \(device.localizedName)")
        
        // Log device format info
        let format = device.activeFormat
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        logger.info("Device active format: \(dims.width)x\(dims.height)")
        
        if let mtkView = externalView {
            setupDisplayConfigurator(for: mtkView.layer, device: device)
        }
    }
    
    @MainActor
    public func createPreviewView(frame: CGRect) -> MTKView? {
        guard let device = metalDevice else { return nil }
        
        let view = MTKView(frame: frame, device: device)
        configureMetalView(view, isExternal: false)
        view.delegate = self
        previewView = view
        
        return view
    }
    
    @MainActor
    public func checkForExternalDisplay() {
        for session in UIApplication.shared.openSessions {
            guard let windowScene = session.scene as? UIWindowScene else { continue }
            
            if session.role == .windowExternalDisplayNonInteractive {
                logger.info("Found external display session")
                setupExternalDisplay(on: windowScene)
                return
            }
        }
        
        logger.info("No external display session found")
    }
    
    public func submitFrame(_ pixelBuffer: CVPixelBuffer) {
        bufferLock.lock()
        latestPixelBuffer = pixelBuffer
        bufferLock.unlock()
    }
    
    public func submitFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        submitFrame(pixelBuffer)
    }
    
    // MARK: - Scene Notifications
    
    private func setupSceneNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sceneWillConnect(_:)),
            name: UIScene.willConnectNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sceneDidDisconnect(_:)),
            name: UIScene.didDisconnectNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sceneDidActivate(_:)),
            name: UIScene.didActivateNotification,
            object: nil
        )
    }
    
    @MainActor
    @objc private func sceneWillConnect(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene else { return }
        
        logger.info("Scene will connect - role: \(scene.session.role.rawValue)")
        
        if scene.session.role == .windowExternalDisplayNonInteractive {
            logger.info("External display scene connecting")
        }
    }
    
    @MainActor
    @objc private func sceneDidActivate(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene else { return }
        
        let b = scene.screen.bounds
        logger.info("Scene did activate - role: \(scene.session.role.rawValue), screen: x: \(b.origin.x, format: .fixed(precision: 1)) y: \(b.origin.y, format: .fixed(precision: 1)) w: \(b.size.width, format: .fixed(precision: 1)) h: \(b.size.height, format: .fixed(precision: 1))")
        
        if scene.session.role == .windowExternalDisplayNonInteractive {
            logger.info("External display scene activated")
            setupExternalDisplay(on: scene)
        }
    }
    
    @MainActor
    @objc private func sceneDidDisconnect(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene else { return }
        
        logger.info("Scene did disconnect")
        
        if scene == externalWindowScene {
            teardownExternalDisplay()
        }
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
        
        vertex VertexOut vertexPassthrough(uint vertexID [[vertex_id]]) {
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
        
        fragment float4 fragmentPassthrough(VertexOut in [[stage_in]],
                                            texture2d<float> texture [[texture(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            return texture.sample(s, in.texCoord);
        }
        """
        
        let library = try device.makeLibrary(source: shaderSource, options: nil)
        
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "vertexPassthrough")
        descriptor.fragmentFunction = library.makeFunction(name: "fragmentPassthrough")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        
        renderPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }
    
    private func configureMetalView(_ view: MTKView, isExternal: Bool) {
        view.device = metalDevice
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 60
        view.backgroundColor = .black
        
        if isExternal {
            // For external display, don't auto-resize - we control it
            view.autoResizeDrawable = false
            view.contentMode = .scaleAspectFit
        } else {
            view.autoResizeDrawable = true
            view.contentMode = .scaleAspectFit
        }
    }
    
    // MARK: - External Display Setup
    
    @MainActor
    private func setupExternalDisplay(on windowScene: UIWindowScene) {
        if externalWindowScene == windowScene {
            logger.info("Already set up on this scene")
            return
        }
        
        teardownExternalDisplay()
        
        guard let device = metalDevice else { return }
        
        self.externalWindowScene = windowScene
        
        let screen = windowScene.screen
        let screenBounds = screen.bounds
        let nativeBounds = screen.nativeBounds
        
        logger.info("Setting up external display...")
        logger.info("Screen bounds (points): \(screenBounds.width)x\(screenBounds.height)")
        logger.info("Native bounds (pixels): \(nativeBounds.width)x\(nativeBounds.height)")
        logger.info("Screen scale: \(screen.scale)")
        
        // Store target drawable size
        targetDrawableSize = CGSize(width: nativeBounds.width, height: nativeBounds.height)
        
        // Create window on the external window scene
        let window = UIWindow(windowScene: windowScene)
        window.frame = screenBounds
        window.backgroundColor = .black
        
        // Create Metal view
        let mtkView = MTKView(frame: CGRect(origin: .zero, size: screenBounds.size), device: device)
        configureMetalView(mtkView, isExternal: true)
        mtkView.delegate = self
        
        // Explicitly set drawable size to native resolution
        mtkView.drawableSize = targetDrawableSize
        logger.info("Set drawable size to: \(mtkView.drawableSize.width)x\(mtkView.drawableSize.height)")
        
        // Create view controller
        let viewController = ExternalDisplayViewController()
        viewController.view.backgroundColor = .black
        viewController.view.addSubview(mtkView)
        
        mtkView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            mtkView.topAnchor.constraint(equalTo: viewController.view.topAnchor),
            mtkView.bottomAnchor.constraint(equalTo: viewController.view.bottomAnchor),
            mtkView.leadingAnchor.constraint(equalTo: viewController.view.leadingAnchor),
            mtkView.trailingAnchor.constraint(equalTo: viewController.view.trailingAnchor)
        ])
        
        window.rootViewController = viewController
        window.isHidden = false
        
        self.externalWindow = window
        self.externalView = mtkView
        
        stateLock.lock()
        _isExternalDisplayConnected = true
        _externalDisplayResolution = nativeBounds.size
        stateLock.unlock()
        
        // Setup configurator if we have a device
        if let captureDevice = captureDevice {
            setupDisplayConfigurator(for: mtkView.layer, device: captureDevice)
        }
        
        logger.info("External display ready - \(Int(nativeBounds.width))x\(Int(nativeBounds.height)) pixels")
        
        let frameRate = activeFrameRate
        onExternalDisplayChanged?(true, nativeBounds.size, frameRate)
    }
    
    @MainActor
    private func setupDisplayConfigurator(for layer: CALayer, device: AVCaptureDevice) {
        // Log device info
        let format = device.activeFormat
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let minDuration = device.activeVideoMinFrameDuration
        let fps = minDuration.seconds > 0 ? 1.0 / minDuration.seconds : 0
        
        logger.info("Setting up configurator for device format: \(dims.width)x\(dims.height) @ \(fps) fps")
        
        // Check capabilities
        let frameRateSupported = AVCaptureExternalDisplayConfigurator.isMatchingFrameRateSupported
        let colorSpaceSupported = AVCaptureExternalDisplayConfigurator.isBypassingColorSpaceConversionSupported
        let resolutionSupported = AVCaptureExternalDisplayConfigurator.isPreferredResolutionSupported
        
        logger.info("External display capabilities - frameRate: \(frameRateSupported), colorSpace: \(colorSpaceSupported), resolution: \(resolutionSupported)")
        
        // Create configuration
        let displayConfig = AVCaptureExternalDisplayConfiguration()
        
        if frameRateSupported {
            displayConfig.shouldMatchFrameRate = true
            logger.info("Enabled frame rate matching")
        }
        
        if colorSpaceSupported {
            displayConfig.bypassColorSpaceConversion = true
            logger.info("Enabled color space bypass")
        }
        
        if resolutionSupported {
            displayConfig.preferredResolution = dims
            logger.info("Set preferred resolution to \(dims.width)x\(dims.height)")
        }
        
        // Create the configurator
        let configurator = AVCaptureExternalDisplayConfigurator(
            device: device,
            previewLayer: layer,
            configuration: displayConfig
        )
        
        self.displayConfigurator = configurator
        
        logger.info("Configurator isActive: \(configurator.isActive)")
        logger.info("Configurator activeExternalDisplayFrameRate: \(configurator.activeExternalDisplayFrameRate)")
        
        if configurator.isActive {
            stateLock.lock()
            _activeFrameRate = configurator.activeExternalDisplayFrameRate
            stateLock.unlock()
            logger.info("Configurator active at \(self.activeFrameRate) fps")
        } else {
            logger.warning("Configurator is not active")
        }
        
        logger.info("AVCaptureExternalDisplayConfigurator created")
    }
    
    @MainActor
    private func teardownExternalDisplay() {
        displayConfigurator?.stop()
        displayConfigurator = nil
        
        externalView?.delegate = nil
        externalView = nil
        externalWindow?.isHidden = true
        externalWindow = nil
        externalWindowScene = nil
        targetDrawableSize = .zero
        
        stateLock.lock()
        _isExternalDisplayConnected = false
        _externalDisplayResolution = .zero
        _activeFrameRate = 0
        stateLock.unlock()
        
        logger.info("External display disconnected")
        
        onExternalDisplayChanged?(false, .zero, 0)
    }
}

// MARK: - MTKViewDelegate

extension HDMIDisplayManager: MTKViewDelegate {
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        logger.info("Drawable size changed to \(size.width)x\(size.height)")
        
        // If this is the external view and size doesn't match target, fix it
        if view == externalView && targetDrawableSize.width > 0 {
            if size != targetDrawableSize {
                logger.info("Correcting drawable size from \(size.width)x\(size.height) to \(self.targetDrawableSize.width)x\(self.targetDrawableSize.height)")
                view.drawableSize = targetDrawableSize
            }
        }
    }
    
    public func draw(in view: MTKView) {
        bufferLock.lock()
        let pixelBuffer = latestPixelBuffer
        bufferLock.unlock()
        
        guard let pixelBuffer = pixelBuffer,
              let textureCache = textureCache,
              let commandQueue = commandQueue,
              let renderPipeline = renderPipeline,
              let drawable = view.currentDrawable else {
            return
        }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture
        )
        
        guard status == kCVReturnSuccess,
              let cvTex = cvTexture,
              let texture = CVMetalTextureGetTexture(cvTex),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }
        
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        descriptor.colorAttachments[0].storeAction = .store
        
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }
        
        encoder.setRenderPipelineState(renderPipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

// MARK: - External Display View Controller

private class ExternalDisplayViewController: UIViewController {
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
}

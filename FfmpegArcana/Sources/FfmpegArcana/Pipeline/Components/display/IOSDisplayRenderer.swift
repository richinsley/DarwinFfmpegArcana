// Sources/FfmpegArcana/Pipeline/Components/Display/IOSDisplayRenderer.swift

#if canImport(UIKit) && !os(macOS)
import UIKit
import MetalKit
import AVFoundation

public final class IOSDisplayRenderer: NSObject, DisplayRenderer, @unchecked Sendable {
    
    // MARK: - Properties
    
    public var metalDevice: MTLDevice?
    public weak var previewView: MTKView?
    
    private var externalWindow: UIWindow?
    private var externalMetalView: MTKView?
    
    public var isExternalDisplayConnected: Bool {
        externalWindow != nil
    }
    
    public var externalView: MTKView? {
        externalMetalView
    }
    
    public var onExternalDisplayChanged: ((Bool, String?) -> Void)?
    
    // MARK: - Init
    
    public override init() {
        super.init()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Preview
    
    @MainActor
    public func createPreviewView(frame: CGRect) -> MTKView? {
        guard let device = metalDevice ?? MTLCreateSystemDefaultDevice() else { return nil }
        metalDevice = device
        
        let view = MTKView(frame: frame, device: device)
        configureMetalView(view)
        previewView = view
        return view
    }
    
    @MainActor
    public func attachPreviewView(_ view: MTKView) {
        previewView = view
        if metalDevice == nil {
            metalDevice = view.device ?? MTLCreateSystemDefaultDevice()
        }
    }
    
    // MARK: - External Display Observation
    
    @MainActor
    public func startExternalDisplayObservation() {
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
        
        // Check for existing external display
        checkForExternalDisplay()
    }
    
    @MainActor
    public func stopExternalDisplayObservation() {
        NotificationCenter.default.removeObserver(self, name: UIScene.didActivateNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIScene.didDisconnectNotification, object: nil)
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
        configureMetalView(mtkView)
        
        let viewController = UIViewController()
        viewController.view = mtkView
        viewController.view.backgroundColor = .black
        
        window.rootViewController = viewController
        window.makeKeyAndVisible()
        
        self.externalWindow = window
        self.externalMetalView = mtkView
        
        let resolution = "\(Int(screen.bounds.width))x\(Int(screen.bounds.height))"
        onExternalDisplayChanged?(true, resolution)
    }
    
    @MainActor
    public func teardownExternalDisplay() {
        guard externalWindow != nil else { return }
        
        externalMetalView = nil
        externalWindow?.isHidden = true
        externalWindow = nil
        
        onExternalDisplayChanged?(false, nil)
    }
    
    // MARK: - Helpers
    
    private func configureMetalView(_ view: MTKView) {
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.enableSetNeedsDisplay = false
        view.isPaused = true
        view.backgroundColor = .black
        view.autoResizeDrawable = true
    }
}
#endif
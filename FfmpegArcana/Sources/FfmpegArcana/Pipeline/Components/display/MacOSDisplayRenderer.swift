// Sources/FfmpegArcana/Pipeline/Components/Display/MacOSDisplayRenderer.swift

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import MetalKit
import AVFoundation

public final class MacOSDisplayRenderer: NSObject, DisplayRenderer, @unchecked Sendable {
    
    // MARK: - Properties
    
    public var metalDevice: MTLDevice?
    public weak var previewView: MTKView?
    
    private var externalWindow: NSWindow?
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
        
        // Convert CGRect to NSRect (they're the same on macOS but be explicit)
        let nsFrame = NSRect(x: frame.origin.x, y: frame.origin.y, 
                             width: frame.size.width, height: frame.size.height)
        
        let view = MTKView(frame: nsFrame, device: device)
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
            selector: #selector(screensDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        
        // Check for existing external displays
        checkForExternalDisplay()
    }
    
    @MainActor
    public func stopExternalDisplayObservation() {
        NotificationCenter.default.removeObserver(
            self, 
            name: NSApplication.didChangeScreenParametersNotification, 
            object: nil
        )
    }
    
    @MainActor
    @objc private func screensDidChange(_ notification: Notification) {
        // Re-evaluate external displays
        if NSScreen.screens.count > 1 {
            if externalWindow == nil {
                checkForExternalDisplay()
            }
        } else {
            teardownExternalDisplay()
        }
    }
    
    @MainActor
    private func checkForExternalDisplay() {
        let screens = NSScreen.screens
        guard screens.count > 1,
              let mainScreen = NSScreen.main else { return }
        
        // Find first non-main screen
        for screen in screens where screen != mainScreen {
            setupExternalDisplay(on: screen)
            return
        }
    }
    
    @MainActor
    private func setupExternalDisplay(on screen: NSScreen) {
        teardownExternalDisplay()
        
        guard let device = metalDevice else { return }
        
        let frame = screen.frame
        
        // Create borderless window on external screen
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = .normal
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.isReleasedWhenClosed = false
        
        let mtkView = MTKView(frame: NSRect(origin: .zero, size: frame.size), device: device)
        configureMetalView(mtkView)
        
        window.contentView = mtkView
        window.makeKeyAndOrderFront(nil)
        
        // Enter fullscreen on external display
        if !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
        
        self.externalWindow = window
        self.externalMetalView = mtkView
        
        let resolution = "\(Int(frame.width))x\(Int(frame.height))"
        onExternalDisplayChanged?(true, resolution)
    }
    
    @MainActor
    public func teardownExternalDisplay() {
        guard externalWindow != nil else { return }
        
        if externalWindow?.styleMask.contains(.fullScreen) == true {
            externalWindow?.toggleFullScreen(nil)
        }
        
        externalMetalView = nil
        externalWindow?.close()
        externalWindow = nil
        
        onExternalDisplayChanged?(false, nil)
    }
    
    // MARK: - Helpers
    
    private func configureMetalView(_ view: MTKView) {
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.enableSetNeedsDisplay = false
        view.isPaused = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.autoResizeDrawable = true
    }
}
#endif
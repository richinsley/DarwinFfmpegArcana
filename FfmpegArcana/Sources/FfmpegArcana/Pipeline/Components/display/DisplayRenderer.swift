// Sources/FfmpegArcana/Pipeline/Components/Display/DisplayRenderer.swift

import Foundation
import MetalKit
import AVFoundation

// MARK: - Display Renderer Protocol

/// Abstracts platform-specific display/windowing for DisplaySink
public protocol DisplayRenderer: AnyObject {
    /// The Metal device used for rendering
    var metalDevice: MTLDevice? { get set }
    
    /// Create a preview view for embedding in host UI
    @MainActor
    func createPreviewView(frame: CGRect) -> MTKView?
    
    /// Attach to an existing MTKView
    @MainActor
    func attachPreviewView(_ view: MTKView)
    
    /// Get the current preview view (if any)
    var previewView: MTKView? { get }
    
    /// Whether external display is connected
    var isExternalDisplayConnected: Bool { get }
    
    /// Get the external display view (if any)
    var externalView: MTKView? { get }
    
    /// Start observing for external display connections
    @MainActor
    func startExternalDisplayObservation()
    
    /// Stop observing for external display connections
    @MainActor
    func stopExternalDisplayObservation()
    
    /// Callback when external display connects/disconnects
    var onExternalDisplayChanged: ((Bool, String?) -> Void)? { get set }
    
    /// Tear down external display resources
    @MainActor
    func teardownExternalDisplay()
}

// MARK: - External Display Info

public struct ExternalDisplayInfo: Sendable {
    public let resolution: String
    public let refreshRate: Double
    public let name: String?
    
    public init(resolution: String, refreshRate: Double = 60.0, name: String? = nil) {
        self.resolution = resolution
        self.refreshRate = refreshRate
        self.name = name
    }
}
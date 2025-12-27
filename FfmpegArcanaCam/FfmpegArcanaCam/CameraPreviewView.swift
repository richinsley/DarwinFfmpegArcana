// CameraPreviewView.swift
// Main UI for camera preview and HDMI status

import SwiftUI
import MetalKit
import AVFoundation

struct CameraPreviewView: View {
    @State private var cameraManager = CameraCaptureManager(configuration: .hd1080p60)
    @State private var displayManager = HDMIDisplayManager()
    @State private var previewView: MetalPreviewView?
    @State private var isRunning = false
    @State private var errorMessage: String?
    @State private var externalDisplayInfo = "Not connected"
    @State private var isExternalConnected = false
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                    .ignoresSafeArea()
                
                if let preview = previewView {
                    preview
                        .ignoresSafeArea()
                }
                
                if !isRunning && errorMessage == nil {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.5)
                }
                
                if let error = errorMessage {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundColor(.yellow)
                        Text(error)
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                        Button("Retry") {
                            Task { await startCapture(size: geometry.size) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                }
                
                if isRunning {
                    VStack {
                        StatusBarView(
                            cameraInfo: "\(cameraManager.currentResolution) @ \(String(format: "%.0f", cameraManager.currentFrameRate)) fps",
                            externalDisplayInfo: externalDisplayInfo,
                            isExternalConnected: isExternalConnected
                        )
                        .padding(.top, 8)
                        
                        Spacer()
                        
                        HStack {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(.green)
                                    .frame(width: 10, height: 10)
                                Text("Live")
                                    .font(.subheadline.bold())
                                    .foregroundColor(.white)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: Capsule())
                            
                            Spacer()
                            
                            if cameraManager.isHDREnabled {
                                Text("HDR")
                                    .font(.caption.bold())
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.orange, in: Capsule())
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 32)
                    }
                }
            }
            .onAppear {
                Task {
                    await startCapture(size: geometry.size)
                }
            }
            .onDisappear {
                Task {
                    await cameraManager.stop()
                }
            }
        }
        .statusBar(hidden: true)
        .persistentSystemOverlays(.hidden)
    }
    
    private func startCapture(size: CGSize) async {
        errorMessage = nil
        
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted {
                errorMessage = "Camera permission denied"
                return
            }
        } else if status != .authorized {
            errorMessage = "Camera permission denied. Please enable in Settings."
            return
        }
        
        // Create preview view
        if let mtkView = displayManager.createPreviewView(frame: CGRect(origin: .zero, size: size)) {
            previewView = MetalPreviewView(mtkView: mtkView)
        }
        
        // Connect camera to display manager
        cameraManager.onFrame = { sampleBuffer in
            displayManager.submitFrame(sampleBuffer)
        }
        
        // Start capture first
        do {
            try await cameraManager.start()
            isRunning = true
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        
        // Configure display manager with the capture device for HDMI format matching
        if let device = cameraManager.videoDevice_ {
            displayManager.configure(with: device)
        }
        
        // Check for already-connected external display
        displayManager.checkForExternalDisplay()
        
        // Set up callback for external display changes
        displayManager.onExternalDisplayChanged = { connected, resolution, frameRate in
            isExternalConnected = connected
            if connected {
                if frameRate > 0 {
                    externalDisplayInfo = "HDMI: \(Int(resolution.width))x\(Int(resolution.height)) @ \(String(format: "%.0f", frameRate))fps"
                } else {
                    externalDisplayInfo = "HDMI: \(Int(resolution.width))x\(Int(resolution.height))"
                }
            } else {
                externalDisplayInfo = "Not connected"
            }
        }
    }
}

// MARK: - Metal Preview View Wrapper

struct MetalPreviewView: UIViewRepresentable {
    let mtkView: MTKView
    
    func makeUIView(context: Context) -> MTKView {
        return mtkView
    }
    
    func updateUIView(_ uiView: MTKView, context: Context) {}
}

// MARK: - Status Bar

struct StatusBarView: View {
    let cameraInfo: String
    let externalDisplayInfo: String
    let isExternalConnected: Bool
    
    var body: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "camera.fill")
                    .font(.caption)
                Text(cameraInfo)
                    .font(.caption.monospacedDigit())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            
            Spacer()
            
            HStack(spacing: 6) {
                Image(systemName: isExternalConnected ? "display" : "display.trianglebadge.exclamationmark")
                    .font(.caption)
                    .foregroundColor(isExternalConnected ? .green : .secondary)
                Text(externalDisplayInfo)
                    .font(.caption.monospacedDigit())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .padding(.horizontal, 16)
    }
}

#Preview {
    CameraPreviewView()
}

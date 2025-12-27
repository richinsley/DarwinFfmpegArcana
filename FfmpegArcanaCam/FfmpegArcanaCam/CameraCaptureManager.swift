// CameraCaptureManager.swift
// Direct camera capture with optimal format selection

import Foundation
import AVFoundation
import CoreMedia
import os

// Configuration is a simple value type - no actor isolation needed
struct CameraConfiguration: Sendable {
    var position: AVCaptureDevice.Position = .back
    var preferredWidth: Int = 1920
    var preferredHeight: Int = 1080
    var preferredFrameRate: Double = 30
    var enableHDR: Bool = false
    
    static let hd1080p60 = CameraConfiguration(preferredWidth: 1920, preferredHeight: 1080, preferredFrameRate: 60)
    static let hd1080p30 = CameraConfiguration(preferredWidth: 1920, preferredHeight: 1080, preferredFrameRate: 30)
    static let uhd4k30 = CameraConfiguration(preferredWidth: 3840, preferredHeight: 2160, preferredFrameRate: 30)
}

// Wrap the callback to be Sendable
final class FrameCallback: @unchecked Sendable {
    var handler: ((CMSampleBuffer) -> Void)?
}

final class CameraCaptureManager: NSObject, @unchecked Sendable {
    
    // MARK: - Published State (read from main thread)
    
    private let _isRunning = OSAllocatedUnfairLock(initialState: false)
    private let _currentResolution = OSAllocatedUnfairLock(initialState: "Unknown")
    private let _currentFrameRate = OSAllocatedUnfairLock(initialState: 0.0)
    private let _isHDREnabled = OSAllocatedUnfairLock(initialState: false)
    private let _error = OSAllocatedUnfairLock<String?>(initialState: nil)
    
    var isRunning: Bool { _isRunning.withLock { $0 } }
    var currentResolution: String { _currentResolution.withLock { $0 } }
    var currentFrameRate: Double { _currentFrameRate.withLock { $0 } }
    var isHDREnabled: Bool { _isHDREnabled.withLock { $0 } }
    var error: String? { _error.withLock { $0 } }
    var captureSession_: AVCaptureSession { captureSession }
    var videoDevice_: AVCaptureDevice? { videoDevice }
    
    // MARK: - Capture Session
    
    private let captureSession = AVCaptureSession()
    private var videoDevice: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var videoOutput: AVCaptureVideoDataOutput?
    
    private let sessionQueue = DispatchQueue(label: "camera.session", qos: .userInitiated)
    private let outputQueue = DispatchQueue(label: "camera.output", qos: .userInitiated)
    
    // Frame callback
    let frameCallback = FrameCallback()
    
    var onFrame: ((CMSampleBuffer) -> Void)? {
        get { frameCallback.handler }
        set { frameCallback.handler = newValue }
    }
    
    // MARK: - Configuration
    
    private let config: CameraConfiguration
    
    // MARK: - Initialization
    
    init(configuration: CameraConfiguration = .hd1080p30) {
        self.config = configuration
        super.init()
    }
    
    // MARK: - Public Interface
    
    func start() async throws {
        guard !isRunning else { return }
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [self] in
                do {
                    try setupCaptureSession()
                    captureSession.startRunning()
                    
                    _isRunning.withLock { $0 = true }
                    updateStateFromDevice()
                    
                    continuation.resume()
                } catch {
                    _error.withLock { $0 = error.localizedDescription }
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [self] in
                captureSession.stopRunning()
                _isRunning.withLock { $0 = false }
                continuation.resume()
            }
        }
    }
    
    // MARK: - Private Setup (called on sessionQueue)
    
    private func setupCaptureSession() throws {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        
        // Remove existing inputs/outputs
        captureSession.inputs.forEach { captureSession.removeInput($0) }
        captureSession.outputs.forEach { captureSession.removeOutput($0) }
        
        // Get camera device
        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: config.position
        ) else {
            throw CameraError.noCameraAvailable
        }
        videoDevice = device
        
        // Add input
        let input = try AVCaptureDeviceInput(device: device)
        guard captureSession.canAddInput(input) else {
            throw CameraError.cannotAddInput
        }
        captureSession.addInput(input)
        videoInput = input
        
        // Configure format
        try configureDeviceFormat(device)
        
        // Add output
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: outputQueue)
        
        guard captureSession.canAddOutput(output) else {
            throw CameraError.cannotAddOutput
        }
        captureSession.addOutput(output)
        videoOutput = output
        
        // Optimize connection
        if let connection = output.connection(with: .video) {
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .off
            }
        }
    }
    
    private func configureDeviceFormat(_ device: AVCaptureDevice) throws {
        let targetWidth = config.preferredWidth
        let targetHeight = config.preferredHeight
        let targetFrameRate = config.preferredFrameRate
        
        let scoredFormats = device.formats.compactMap { format -> (AVCaptureDevice.Format, Int)? in
            let desc = format.formatDescription
            let dimensions = CMVideoFormatDescriptionGetDimensions(desc)
            
            let supportsFrameRate = format.videoSupportedFrameRateRanges.contains { range in
                range.minFrameRate <= targetFrameRate && targetFrameRate <= range.maxFrameRate
            }
            guard supportsFrameRate else { return nil }
            
            var score = 0
            
            if dimensions.width == targetWidth && dimensions.height == targetHeight {
                score += 1000
            } else if dimensions.width >= targetWidth && dimensions.height >= targetHeight {
                score += 500 - abs(Int(dimensions.width) - targetWidth) / 100
            } else {
                score += 100
            }
            
            if !format.isVideoBinned {
                score += 50
            }
            
            if config.enableHDR && format.isVideoHDRSupported {
                score += 100
            }
            
            return (format, score)
        }
        
        guard let (bestFormat, _) = scoredFormats.max(by: { $0.1 < $1.1 }) else {
            throw CameraError.noSuitableFormat
        }
        
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        
        device.activeFormat = bestFormat
        
        if let range = bestFormat.videoSupportedFrameRateRanges.first(where: {
            $0.minFrameRate <= targetFrameRate && targetFrameRate <= $0.maxFrameRate
        }) {
            let frameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFrameRate))
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
        }
        
        if bestFormat.isVideoHDRSupported {
            device.automaticallyAdjustsVideoHDREnabled = false
            device.isVideoHDREnabled = config.enableHDR
        }
    }
    
    private func updateStateFromDevice() {
        guard let device = videoDevice else { return }
        
        let desc = device.activeFormat.formatDescription
        let dimensions = CMVideoFormatDescriptionGetDimensions(desc)
        
        _currentResolution.withLock { $0 = "\(dimensions.width)x\(dimensions.height)" }
        _currentFrameRate.withLock { $0 = 1.0 / device.activeVideoMinFrameDuration.seconds }
        _isHDREnabled.withLock { $0 = device.isVideoHDREnabled }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraCaptureManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        frameCallback.handler?(sampleBuffer)
    }
    
    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Could track dropped frames here
    }
}

// MARK: - Errors

enum CameraError: Error, LocalizedError {
    case noCameraAvailable
    case cannotAddInput
    case cannotAddOutput
    case noSuitableFormat
    case invalidState
    
    var errorDescription: String? {
        switch self {
        case .noCameraAvailable: return "No camera available"
        case .cannotAddInput: return "Cannot add camera input"
        case .cannotAddOutput: return "Cannot add video output"
        case .noSuitableFormat: return "No suitable video format found"
        case .invalidState: return "Invalid state"
        }
    }
}

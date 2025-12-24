/**
 * MediaFifo.swift
 * 
 * Swift wrappers for thread-safe media FIFOs with semaphore-based flow control.
 */

import Foundation
import CFfmpegWrapper

// MARK: - FIFO Errors

public enum FifoError: Error, LocalizedError {
    case flowDisabled
    case fifoFull
    case timeout
    case invalidParameters
    case unknown(code: Int32)
    
    init(code: Int32) {
        switch code {
        case FF_FIFO_OK: self = .unknown(code: code) // shouldn't happen
        case FF_FIFO_INVALID_PARAMS: self = .invalidParameters
        case FF_FIFO_FLOW_DISABLED: self = .flowDisabled
        case FF_FIFO_FULL: self = .fifoFull
        case FF_FIFO_TIMEOUT: self = .timeout
        default: self = .unknown(code: code)
        }
    }
    
    public var errorDescription: String? {
        switch self {
        case .flowDisabled: return "FIFO flow is disabled"
        case .fifoFull: return "FIFO is full"
        case .timeout: return "Operation timed out"
        case .invalidParameters: return "Invalid parameters"
        case .unknown(let code): return "Unknown FIFO error: \(code)"
        }
    }
}

// MARK: - FIFO Mode

public enum FifoMode: Sendable {
    /// Single producer/consumer, lock-free. Fastest but undefined behavior with multiple threads.
    case lockless
    /// Multi producer/consumer safe with mutex. Slower but thread-safe.
    case blocking
    
    var cValue: FFifoMode {
        switch self {
        case .lockless: return FF_FIFO_MODE_LOCKLESS
        case .blocking: return FF_FIFO_MODE_BLOCKING
        }
    }
}

// MARK: - Frame FIFO

/// Thread-safe FIFO for AVFrame with semaphore-based blocking and flow control.
public final class FrameFifo: @unchecked Sendable {
    private let ctx: OpaquePointer
    
    /// Create a frame FIFO with specified capacity.
    /// - Parameters:
    ///   - capacity: Maximum number of frames the FIFO can hold
    ///   - mode: Threading mode (lockless for single producer/consumer, blocking for multi-threaded)
    public init(capacity: Int, mode: FifoMode = .lockless) {
        ctx = ff_frame_fifo_create(UInt32(capacity), mode.cValue)
    }
    
    deinit {
        ff_frame_fifo_destroy(ctx)
    }
    
    // MARK: Flow Control
    
    /// Enable or disable flow. When disabled, write operations return immediately with flowDisabled error.
    public var flowEnabled: Bool {
        get { ff_frame_fifo_get_flow_enabled(ctx) }
        set { ff_frame_fifo_set_flow_enabled(ctx, newValue) }
    }
    
    // MARK: Write Operations
    
    /// Block until write space is available.
    /// - Throws: FifoError if flow is disabled
    public func waitForWriteSpace() throws {
        let result = ff_frame_fifo_wait_write(ctx)
        if result != FF_FIFO_OK {
            throw FifoError(code: result)
        }
    }
    
    /// Wait for write space with timeout.
    /// - Parameter milliseconds: Timeout in milliseconds
    /// - Throws: FifoError.timeout if timed out, or other errors
    public func waitForWriteSpace(timeout milliseconds: Int) throws {
        let result = ff_frame_fifo_wait_write_timed(ctx, Int32(milliseconds))
        if result != FF_FIFO_OK {
            throw FifoError(code: result)
        }
    }
    
    /// Try to acquire write space without blocking.
    /// - Returns: true if space available, false otherwise
    public func tryWaitForWriteSpace() -> Bool {
        ff_frame_fifo_try_write(ctx) == FF_FIFO_OK
    }
    
    /// Write a frame to the FIFO. The FIFO clones the frame internally.
    /// - Parameter frame: The frame to write
    /// - Throws: FifoError if flow disabled or FIFO full
    public func write(_ frame: Frame) throws {
        let result = ff_frame_fifo_write(ctx, frame.ptr)
        if result != FF_FIFO_OK {
            throw FifoError(code: result)
        }
    }
    
    /// Preempt: push frame to front of queue.
    /// - Parameter frame: The frame to preempt
    /// - Throws: FifoError if flow disabled or FIFO full
    public func preempt(_ frame: Frame) throws {
        let result = ff_frame_fifo_preempt(ctx, frame.ptr)
        if result != FF_FIFO_OK {
            throw FifoError(code: result)
        }
    }
    
    // MARK: Read Operations
    
    /// Block until read data is available.
    /// - Throws: FifoError if flow disabled
    public func waitForReadData() throws {
        let result = ff_frame_fifo_wait_read(ctx)
        if result != FF_FIFO_OK {
            throw FifoError(code: result)
        }
    }
    
    /// Wait for read data with timeout.
    /// - Parameter milliseconds: Timeout in milliseconds
    /// - Throws: FifoError.timeout if timed out
    public func waitForReadData(timeout milliseconds: Int) throws {
        let result = ff_frame_fifo_wait_read_timed(ctx, Int32(milliseconds))
        if result != FF_FIFO_OK {
            throw FifoError(code: result)
        }
    }
    
    /// Try to check for read data without blocking.
    /// - Returns: true if data available, false otherwise
    public func tryWaitForReadData() -> Bool {
        ff_frame_fifo_try_read(ctx) == FF_FIFO_OK
    }
    
    /// Read a frame from the FIFO. Caller owns the returned frame.
    /// - Returns: The frame, or nil if FIFO is empty
    /// - Throws: FifoError on error
    public func read() throws -> Frame? {
        var framePtr: UnsafeMutablePointer<AVFrame>?
        let result = ff_frame_fifo_read(ctx, &framePtr)
        
        if result != FF_FIFO_OK {
            throw FifoError(code: result)
        }
        
        guard let ptr = framePtr else { return nil }
        return Frame(taking: ptr)
    }
    
    // MARK: Status
    
    /// Number of frames currently in the FIFO
    public var count: Int {
        Int(ff_frame_fifo_count(ctx))
    }
    
    /// Whether at least one frame has been read from this FIFO
    public var hasBeenRead: Bool {
        ff_frame_fifo_has_been_read(ctx)
    }
}

// MARK: - Packet FIFO

/// Thread-safe FIFO for AVPacket with semaphore-based blocking and flow control.
public final class PacketFifo: @unchecked Sendable {
    private let ctx: OpaquePointer
    
    /// Create a packet FIFO with specified capacity.
    public init(capacity: Int, mode: FifoMode = .lockless) {
        ctx = ff_packet_fifo_create(UInt32(capacity), mode.cValue)
    }
    
    deinit {
        ff_packet_fifo_destroy(ctx)
    }
    
    // MARK: Flow Control
    
    public var flowEnabled: Bool {
        get { ff_packet_fifo_get_flow_enabled(ctx) }
        set { ff_packet_fifo_set_flow_enabled(ctx, newValue) }
    }
    
    // MARK: Write Operations
    
    public func waitForWriteSpace() throws {
        let result = ff_packet_fifo_wait_write(ctx)
        if result != FF_FIFO_OK {
            throw FifoError(code: result)
        }
    }
    
    public func waitForWriteSpace(timeout milliseconds: Int) throws {
        let result = ff_packet_fifo_wait_write_timed(ctx, Int32(milliseconds))
        if result != FF_FIFO_OK {
            throw FifoError(code: result)
        }
    }
    
    public func tryWaitForWriteSpace() -> Bool {
        ff_packet_fifo_try_write(ctx) == FF_FIFO_OK
    }
    
    public func write(_ packet: Packet) throws {
        let result = ff_packet_fifo_write(ctx, packet.ptr)
        if result != FF_FIFO_OK {
            throw FifoError(code: result)
        }
    }
    
    public func preempt(_ packet: Packet) throws {
        let result = ff_packet_fifo_preempt(ctx, packet.ptr)
        if result != FF_FIFO_OK {
            throw FifoError(code: result)
        }
    }
    
    // MARK: Read Operations
    
    public func waitForReadData() throws {
        let result = ff_packet_fifo_wait_read(ctx)
        if result != FF_FIFO_OK {
            throw FifoError(code: result)
        }
    }
    
    public func waitForReadData(timeout milliseconds: Int) throws {
        let result = ff_packet_fifo_wait_read_timed(ctx, Int32(milliseconds))
        if result != FF_FIFO_OK {
            throw FifoError(code: result)
        }
    }
    
    public func tryWaitForReadData() -> Bool {
        ff_packet_fifo_try_read(ctx) == FF_FIFO_OK
    }
    
    public func read() throws -> Packet? {
        var packetPtr: UnsafeMutablePointer<AVPacket>?
        let result = ff_packet_fifo_read(ctx, &packetPtr)
        
        if result != FF_FIFO_OK {
            throw FifoError(code: result)
        }
        
        guard let ptr = packetPtr else { return nil }
        return Packet(taking: ptr)
    }
    
    // MARK: Status
    
    public var count: Int {
        Int(ff_packet_fifo_count(ctx))
    }
    
    public var hasBeenRead: Bool {
        ff_packet_fifo_has_been_read(ctx)
    }
}

// MARK: - Async Extensions

extension FrameFifo {
    /// Async version of waitForWriteSpace - runs blocking wait on a background thread
    public func waitForWriteSpaceAsync() async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try self.waitForWriteSpace()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Async version of waitForReadData
    public func waitForReadDataAsync() async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try self.waitForReadData()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Write frame asynchronously, waiting for space if needed
    public func writeAsync(_ frame: Frame) async throws {
        try await waitForWriteSpaceAsync()
        try write(frame)
    }
    
    /// Read frame asynchronously, waiting for data if needed
    public func readAsync() async throws -> Frame? {
        try await waitForReadDataAsync()
        return try read()
    }
}

extension PacketFifo {
    public func waitForWriteSpaceAsync() async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try self.waitForWriteSpace()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    public func waitForReadDataAsync() async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try self.waitForReadData()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    public func writeAsync(_ packet: Packet) async throws {
        try await waitForWriteSpaceAsync()
        try write(packet)
    }
    
    public func readAsync() async throws -> Packet? {
        try await waitForReadDataAsync()
        return try read()
    }
}

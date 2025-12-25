/**
 * CmdFifo.swift
 * 
 * Swift wrappers for pooled command structures with explicit ref counting.
 * No ARC magic - you call addRef/release manually like COM.
 */

import Foundation
import CFfmpegWrapper

// MARK: - Command Types

public enum CmdType: UInt32 {
    case none = 0
    case frame = 1
    case packet = 2
    case flush = 3
    case eos = 4
    case seek = 5
    case config = 6
    case user = 0x1000
    
    init(_ ffType: FFCmdType) {
        self = CmdType(rawValue: ffType.rawValue) ?? .none
    }
    
    var ffType: FFCmdType {
        FFCmdType(rawValue: rawValue)
    }
}

// MARK: - FIFO Errors

public enum CmdFifoError: Error, LocalizedError {
    case flowDisabled
    case fifoFull
    case timeout
    case invalidParameters
    case poolExhausted
    case unknown(code: Int32)
    
    init(code: Int32) {
        switch code {
        case FF_CMD_FIFO_OK: self = .unknown(code: code)
        case FF_CMD_FIFO_INVALID_PARAMS: self = .invalidParameters
        case FF_CMD_FIFO_FLOW_DISABLED: self = .flowDisabled
        case FF_CMD_FIFO_FULL: self = .fifoFull
        case FF_CMD_FIFO_TIMEOUT: self = .timeout
        default: self = .unknown(code: code)
        }
    }
    
    public var errorDescription: String? {
        switch self {
        case .flowDisabled: return "FIFO flow is disabled"
        case .fifoFull: return "FIFO is full"
        case .timeout: return "Operation timed out"
        case .invalidParameters: return "Invalid parameters"
        case .poolExhausted: return "Command pool exhausted"
        case .unknown(let code): return "Unknown error: \(code)"
        }
    }
}

// MARK: - Command Pool

/// Pool of reusable command structures. Commands are acquired, used, and released back.
public final class CmdPool {
    private let pool: OpaquePointer
    
    /// Create a command pool.
    /// - Parameters:
    ///   - initialSize: Number of commands to pre-allocate
    ///   - maxSize: Maximum pool size (0 = unlimited growth)
    public init(initialSize: Int = 32, maxSize: Int = 0) {
        pool = ff_cmd_pool_create(UInt32(initialSize), UInt32(maxSize))
    }
    
    deinit {
        ff_cmd_pool_destroy(pool)
    }
    
    /// Acquire a command from the pool. Refcount starts at 1.
    /// - Returns: A command, or nil if pool is exhausted
    public func acquire() -> Cmd? {
        guard let ptr = ff_cmd_pool_acquire(pool) else { return nil }
        return Cmd(ptr)
    }
    
    /// Pool statistics
    public var totalCount: Int { Int(ff_cmd_pool_total_count(pool)) }
    public var freeCount: Int { Int(ff_cmd_pool_free_count(pool)) }
    public var inUseCount: Int { Int(ff_cmd_pool_in_use_count(pool)) }
}

// MARK: - Command

/// A pooled command structure. YOU are responsible for calling release() when done.
/// This is NOT an ARC-managed object - treat it like a COM interface.
public final class Cmd {
    internal let ptr: UnsafeMutablePointer<FFCmd>
    
    internal init(_ ptr: UnsafeMutablePointer<FFCmd>) {
        self.ptr = ptr
    }
    
    // MARK: Ref Counting - CALL THESE MANUALLY
    
    /// Increment reference count. Returns new count.
    @discardableResult
    public func addRef() -> Int32 {
        return ptr.pointee.ref.AddRef(ptr)
    }
    
    /// Decrement reference count. Returns new count.
    /// When count hits 0, command returns to pool.
    /// WARNING: Do not use this Cmd instance after release returns 0.
    @discardableResult
    public func release() -> Int32 {
        return ptr.pointee.ref.Release(ptr)
    }
    
    // MARK: Properties
    
    public var type: CmdType {
        get { CmdType(ptr.pointee.type) }
        set { ptr.pointee.type = newValue.ffType }
    }
    
    public var pts: Int64 {
        get { ptr.pointee.pts }
        set { ptr.pointee.pts = newValue }
    }
    
    public var dts: Int64 {
        get { ptr.pointee.dts }
        set { ptr.pointee.dts = newValue }
    }
    
    public var flags: UInt32 {
        get { ptr.pointee.flags }
        set { ptr.pointee.flags = newValue }
    }
    
    public var streamIndex: UInt32 {
        get { ptr.pointee.stream_index }
        set { ptr.pointee.stream_index = newValue }
    }
    
    public var data: UnsafeMutableRawPointer? {
        get { ptr.pointee.data }
    }
    
    /// Check if this is a sentinel command (EOS or FLUSH)
    public var isSentinel: Bool {
        ff_cmd_is_sentinel(ptr)
    }
    
    /// Check if this carries media data (FRAME or PACKET)
    public var isMedia: Bool {
        ff_cmd_is_media(ptr)
    }
    
    // MARK: Data Access
    
    /// Get data as AVFrame pointer (only valid if type == .frame)
    public var frameData: UnsafeMutablePointer<AVFrame>? {
        guard type == .frame, let data = ptr.pointee.data else { return nil }
        return data.assumingMemoryBound(to: AVFrame.self)
    }
    
    /// Get data as AVPacket pointer (only valid if type == .packet)
    public var packetData: UnsafeMutablePointer<AVPacket>? {
        guard type == .packet, let data = ptr.pointee.data else { return nil }
        return data.assumingMemoryBound(to: AVPacket.self)
    }
    
    // MARK: Initialization Helpers
    
    /// Initialize as a frame command.
    /// - Parameter frame: The AVFrame pointer. You must manage the frame's lifecycle.
    public func initFrame(_ frame: UnsafeMutablePointer<AVFrame>?) {
        ff_cmd_init(ptr, FF_CMD_FRAME)
        if let frame = frame {
            ff_cmd_set_data(ptr, frame, ff_frame_ref_interface())
        }
    }
    
    /// Initialize as a packet command.
    /// - Parameter packet: The AVPacket pointer. You must manage the packet's lifecycle.
    public func initPacket(_ packet: UnsafeMutablePointer<AVPacket>?) {
        ff_cmd_init(ptr, FF_CMD_PACKET)
        if let packet = packet {
            ff_cmd_set_data(ptr, packet, ff_packet_ref_interface())
        }
    }
    
    /// Initialize as EOS (end of stream) command.
    public func initEOS() {
        ff_cmd_init(ptr, FF_CMD_EOS)
    }
    
    /// Initialize as flush command.
    public func initFlush() {
        ff_cmd_init(ptr, FF_CMD_FLUSH)
    }
    
    /// Initialize as seek command.
    public func initSeek(position: Double, flags: UInt32 = 0) {
        ff_cmd_init(ptr, FF_CMD_SEEK)
        // For seek, we'd typically allocate FFSeekParams, but keeping it simple
        self.pts = Int64(position * 1_000_000) // microseconds
        self.flags = flags
    }
    
    /// Clear any data payload (calls release on ref-counted data).
    public func clearData() {
        ff_cmd_clear_data(ptr)
    }
}

// MARK: - Command FIFO

/// Thread-safe command FIFO with semaphore-based blocking.
/// Commands flow through with explicit ownership transfer - no hidden ref counting.
public final class CmdFifo {
    private let fifo: OpaquePointer
    
    public enum Mode {
        case lockless   // Single producer/consumer, fastest
        case blocking   // Multi producer/consumer safe
        
        var ffMode: FFCmdFifoMode {
            switch self {
            case .lockless: return FF_CMD_FIFO_LOCKLESS
            case .blocking: return FF_CMD_FIFO_BLOCKING
            }
        }
    }
    
    public init(capacity: Int, mode: Mode = .lockless) {
        fifo = ff_cmd_fifo_create(UInt32(capacity), mode.ffMode)
    }
    
    deinit {
        ff_cmd_fifo_destroy(fifo)
    }
    
    // MARK: Flow Control
    
    public var flowEnabled: Bool {
        get { ff_cmd_fifo_get_flow_enabled(fifo) }
        set { ff_cmd_fifo_set_flow_enabled(fifo, newValue) }
    }
    
    // MARK: Write Operations
    
    /// Block until write space available.
    public func waitForWriteSpace() throws {
        let result = ff_cmd_fifo_wait_write(fifo)
        if result != FF_CMD_FIFO_OK {
            throw CmdFifoError(code: result)
        }
    }
    
    /// Wait for write space with timeout.
    public func waitForWriteSpace(timeout msecs: Int) throws {
        let result = ff_cmd_fifo_wait_write_timed(fifo, Int32(msecs))
        if result != FF_CMD_FIFO_OK {
            throw CmdFifoError(code: result)
        }
    }
    
    /// Try to acquire write space without blocking.
    public func tryWaitForWriteSpace() -> Bool {
        ff_cmd_fifo_try_write(fifo) == FF_CMD_FIFO_OK
    }
    
    /// Write a command to the FIFO. Ownership transfers to FIFO.
    /// Do NOT call release() on the command after writing.
    public func write(_ cmd: Cmd) throws {
        let result = ff_cmd_fifo_write(fifo, cmd.ptr)
        if result != FF_CMD_FIFO_OK {
            throw CmdFifoError(code: result)
        }
    }
    
    // MARK: Read Operations
    
    /// Block until read data available.
    public func waitForReadData() throws {
        let result = ff_cmd_fifo_wait_read(fifo)
        if result != FF_CMD_FIFO_OK {
            throw CmdFifoError(code: result)
        }
    }
    
    /// Wait for read data with timeout.
    public func waitForReadData(timeout msecs: Int) throws {
        let result = ff_cmd_fifo_wait_read_timed(fifo, Int32(msecs))
        if result != FF_CMD_FIFO_OK {
            throw CmdFifoError(code: result)
        }
    }
    
    /// Try to check for read data without blocking.
    public func tryWaitForReadData() -> Bool {
        ff_cmd_fifo_try_read(fifo) == FF_CMD_FIFO_OK
    }
    
    /// Read a command from the FIFO. Ownership transfers to caller.
    /// YOU must call release() on the returned command when done.
    public func read() throws -> Cmd? {
        var cmdPtr: UnsafeMutablePointer<FFCmd>?
        let result = ff_cmd_fifo_read(fifo, &cmdPtr)
        
        if result != FF_CMD_FIFO_OK {
            throw CmdFifoError(code: result)
        }
        
        guard let ptr = cmdPtr else { return nil }
        return Cmd(ptr)
    }
    
    /// Preempt: push command to front of queue.
    public func preempt(_ cmd: Cmd) throws {
        let result = ff_cmd_fifo_preempt(fifo, cmd.ptr)
        if result != FF_CMD_FIFO_OK {
            throw CmdFifoError(code: result)
        }
    }
    
    // MARK: Status
    
    public var count: Int { Int(ff_cmd_fifo_count(fifo)) }
    public var hasBeenRead: Bool { ff_cmd_fifo_has_been_read(fifo) }
}

// MARK: - Usage Example (in comments)

/*
 Producer:
 
     let pool = CmdPool(initialSize: 64)
     let fifo = CmdFifo(capacity: 10, mode: .blocking)
     fifo.flowEnabled = true
     
     // Send a frame
     guard let cmd = pool.acquire() else { throw CmdFifoError.poolExhausted }
     cmd.initFrame(myAVFrame)
     cmd.pts = framePts
     
     try fifo.waitForWriteSpace()
     try fifo.write(cmd)
     // Don't release cmd - ownership transferred to FIFO
     
     // Signal end of stream
     guard let eosCmd = pool.acquire() else { throw CmdFifoError.poolExhausted }
     eosCmd.initEOS()
     try fifo.waitForWriteSpace()
     try fifo.write(eosCmd)

 Consumer:
 
     while true {
         try fifo.waitForReadData()
         guard let cmd = try fifo.read() else { continue }
         defer { cmd.release() }  // MUST release when done
         
         switch cmd.type {
         case .frame:
             if let frame = cmd.frameData {
                 processFrame(frame)
             }
         case .eos:
             break // exit loop
         default:
             break
         }
     }
*/
/**
 * FfmpegArcana Test Harness
 */

import Foundation
import FfmpegArcana
import CFfmpegWrapper

func main() {
    print("""
    ╔══════════════════════════════════════════╗
    ║  FfmpegArcana Test Harness               ║
    ╚══════════════════════════════════════════╝
    """)

    let args = CommandLine.arguments

    if args.count < 2 {
        printUsage()
        return
    }

    switch args[1] {
    case "version":
        printVersions()

    case "info":
        guard args.count >= 3 else {
            print("Usage: fftest info <video_file>")
            exit(1)
        }
        printVideoInfo(path: args[2])

    case "decode":
        guard args.count >= 3 else {
            print("Usage: fftest decode <video_file> [frame_count]")
            exit(1)
        }
        let count = args.count >= 4 ? Int(args[3]) ?? 30 : 30
        decodeVideo(path: args[2], maxFrames: count)

    case "fifo":
        guard args.count >= 3 else {
            print("Usage: fftest fifo <video_file> [frame_count]")
            exit(1)
        }
        let count = args.count >= 4 ? Int(args[3]) ?? 30 : 30
        testFifoPipeline(path: args[2], maxFrames: count)

    case "test":
        runTests()

    default:
        print("Unknown command: \(args[1])")
        printUsage()
        exit(1)
    }
}

func printUsage() {
    print("""
    Usage: fftest <command> [options]

    Commands:
      version              Show FFmpeg versions
      info <file>          Show video info
      decode <file> [n]    Decode n frames (default: 30)
      fifo <file> [n]      Test FIFO pipeline with n frames
      test                 Run basic tests
    """)
}

func printVersions() {
    print("""
    FFmpeg Versions:
      avcodec:  \(FFmpeg.avcodecVersion)
      avformat: \(FFmpeg.avformatVersion)
      avutil:   \(FFmpeg.avutilVersion)
    """)
}

func printVideoInfo(path: String) {
    do {
        let demuxer = try Demuxer(url: path)
        let info = try demuxer.videoInfo()

        print("""

        \(path)
        ─────────────────────────────────────
          Resolution:  \(info.width) x \(info.height)
          Pixel fmt:   \(info.pixelFormat)
          Frame rate:  \(String(format: "%.2f", info.frameRate)) fps
          Duration:    \(String(format: "%.2f", info.duration)) sec
          Streams:     \(demuxer.streamCount)
        """)
    } catch {
        print("Error: \(error.localizedDescription)")
        exit(1)
    }
}

func decodeVideo(path: String, maxFrames: Int) {
    do {
        let decoder = try VideoDecoder(url: path, outputFormat: .bgra, useHardware: true)
        let info = decoder.videoInfo

        print("\nDecoding: \(path)")
        print("Video: \(info.width)x\(info.height) @ \(String(format: "%.2f", info.frameRate)) fps")
        print("Hardware: \(decoder.useHardwareAcceleration ? "yes" : "no")\n")

        var count = 0
        let start = Date()

        try decoder.decodeAll { frame in
            count += 1
            if count % 10 == 0 || count == 1 {
                print("  Frame \(frame.frameNumber): \(frame.width)x\(frame.height) @ \(String(format: "%.3f", frame.timestamp))s")
            }
            return count < maxFrames
        }

        let elapsed = Date().timeIntervalSince(start)
        let fps = Double(count) / elapsed

        print("""

        ─────────────────────────────────────
        Decoded: \(count) frames in \(String(format: "%.2f", elapsed))s
        Speed:   \(String(format: "%.1f", fps)) fps (\(String(format: "%.1fx", fps / info.frameRate)) realtime)
        """)
    } catch {
        print("Error: \(error.localizedDescription)")
        exit(1)
    }
}

func testFifoPipeline(path: String, maxFrames: Int) {
    do {
        let decoder = try VideoDecoder(url: path, outputFormat: .bgra, useHardware: true)
        let info = decoder.videoInfo

        print("\nCmd FIFO Pipeline Test: \(path)")
        print("Video: \(info.width)x\(info.height) @ \(String(format: "%.2f", info.frameRate)) fps")
        print("Hardware: \(decoder.useHardwareAcceleration ? "yes" : "no")")

        // Create command pool and FIFO
        let pool = CmdPool(initialSize: 32, maxSize: 64)
        let fifo = CmdFifo(capacity: 10, mode: .blocking)
        fifo.flowEnabled = true

        var consumerCount = 0
        let start = Date()
        let startSem = DispatchSemaphore(value: 0)

        // Producer thread - decode and push frame commands
        let producerThread = Thread {
            startSem.signal()

            var count = 0
            do {
                while count < maxFrames {
                    guard let decoded = try decoder.decodeNextFrame() else { break }
                    
                    // Acquire a command from pool
                    guard let cmd = pool.acquire() else {
                        print("  [Producer] Pool exhausted!")
                        break
                    }
                    
                    // Initialize as frame command
                    // Note: We need to clone the frame since decoded.frame will be reused
                    let frameClone = av_frame_clone(decoded.frame.avFrame)
                    cmd.initFrame(frameClone)
                    cmd.pts = Int64(count)
                    cmd.streamIndex = 0
                    
                    // Wait for write space and push
                    try fifo.waitForWriteSpace()
                    try fifo.write(cmd)
                    // Ownership transferred to FIFO - don't release cmd
                    
                    count += 1
                    
                    if count % 10 == 0 {
                        print("  [Producer] Pushed frame \(count), FIFO: \(fifo.count), Pool free: \(pool.freeCount)")
                    }
                }
            } catch {
                print("  [Producer] Error: \(error)")
            }
            
            print("  [Producer] Done, produced \(count) frames")
            
            // Send EOS command
            do {
                if let eosCmd = pool.acquire() {
                    eosCmd.initEOS()
                    try fifo.waitForWriteSpace()
                    try fifo.write(eosCmd)
                    print("  [Producer] Sent EOS")
                }
            } catch {
                print("  [Producer] Error sending EOS: \(error)")
            }
        }

        // Consumer thread - pull commands from FIFO
        let consumerThread = Thread {
            startSem.signal()

            do {
                loop: while true {
                    // Block waiting for data
                    try fifo.waitForReadData()
                    
                    guard let cmd = try fifo.read() else { continue }
                    defer { cmd.release() }  // MUST release when done
                    
                    switch cmd.type {
                    case .frame:
                        consumerCount += 1
                        if consumerCount % 10 == 0 {
                            if let frame = cmd.frameData {
                                print("  [Consumer] Got frame \(consumerCount): \(frame.pointee.width)x\(frame.pointee.height)")
                            }
                        }
                        // Frame data is released when cmd is released (via data_ref)
                        
                    case .eos:
                        print("  [Consumer] Received EOS")
                        break loop
                        
                    case .flush:
                        print("  [Consumer] Received FLUSH")
                        
                    default:
                        print("  [Consumer] Unknown command type: \(cmd.type)")
                    }
                }
            } catch CmdFifoError.flowDisabled {
                print("  [Consumer] Flow disabled, exiting")
            } catch {
                print("  [Consumer] Error: \(error)")
            }
            
            print("  [Consumer] Done, consumed \(consumerCount) frames")
        }

        print("\nStarting pipeline...\n")
        print("  Pool: \(pool.totalCount) total, \(pool.freeCount) free\n")
        
        producerThread.start()
        consumerThread.start()

        // Wait for both to actually start
        startSem.wait()
        startSem.wait()

        // Wait for threads to complete
        while producerThread.isExecuting || consumerThread.isExecuting {
            Thread.sleep(forTimeInterval: 0.01)
        }

        let elapsed = Date().timeIntervalSince(start)
        let fps = Double(consumerCount) / elapsed

        print("""

        ─────────────────────────────────────
        Pipeline Results:
          Frames:    \(consumerCount) consumed
          Time:      \(String(format: "%.2f", elapsed))s
          Throughput: \(String(format: "%.1f", fps)) fps
          Pool:      \(pool.inUseCount) in use, \(pool.freeCount) free
          FIFO read: \(fifo.hasBeenRead ? "yes" : "no")
        """)
    } catch {
        print("Error: \(error.localizedDescription)")
        exit(1)
    }
}

func runTests() {
    print("Running tests...\n")

    var passed = 0, failed = 0

    func test(_ name: String, _ block: () throws -> Bool) {
        do {
            if try block() {
                print("  ✓ \(name)")
                passed += 1
            } else {
                print("  ✗ \(name)")
                failed += 1
            }
        } catch {
            print("  ✗ \(name): \(error)")
            failed += 1
        }
    }

    test("Versions not empty") {
        !FFmpeg.avcodecVersion.isEmpty && !FFmpeg.avformatVersion.isEmpty
    }

    test("PixelFormat descriptions") {
        PixelFormat.yuv420p.description == "yuv420p" && PixelFormat.bgra.description == "bgra"
    }

    test("Hardware format detection") {
        !PixelFormat.yuv420p.isHardware && PixelFormat.videoToolbox.isHardware
    }

    test("Frame allocation") {
        let f = try Frame()
        return f.width == 0 && f.height == 0
    }

    test("Frame with buffer") {
        let f = try Frame(width: 1920, height: 1080, pixelFormat: .bgra)
        return f.width == 1920 && f.height == 1080 && f.data(plane: 0) != nil
    }

    test("Packet allocation") {
        _ = try Packet()
        return true
    }

    test("Scaler creation") {
        _ = try Scaler(srcWidth: 1920, srcHeight: 1080, srcFormat: .yuv420p,
                       dstWidth: 1280, dstHeight: 720, dstFormat: .bgra)
        return true
    }

    test("Demuxer invalid path throws") {
        do { _ = try Demuxer(url: "/nonexistent.mp4"); return false }
        catch { return true }
    }

    // CmdPool and CmdFifo tests
    test("CmdPool creation") {
        let pool = CmdPool(initialSize: 10, maxSize: 20)
        return pool.totalCount == 10 && pool.freeCount == 10 && pool.inUseCount == 0
    }

    test("CmdPool acquire/release") {
        let pool = CmdPool(initialSize: 5, maxSize: 10)
        
        guard let cmd = pool.acquire() else { return false }
        guard pool.inUseCount == 1 else { return false }
        
        cmd.release()
        return pool.inUseCount == 0 && pool.freeCount == 5
    }

    test("CmdFifo creation") {
        let fifo = CmdFifo(capacity: 10, mode: .lockless)
        return fifo.count == 0 && !fifo.flowEnabled
    }

    test("CmdFifo flow control") {
        let fifo = CmdFifo(capacity: 10, mode: .lockless)
        fifo.flowEnabled = true
        let enabled = fifo.flowEnabled
        fifo.flowEnabled = false
        return enabled && !fifo.flowEnabled
    }

    test("CmdFifo write/read with EOS") {
        let pool = CmdPool(initialSize: 5)
        let fifo = CmdFifo(capacity: 5, mode: .blocking)
        fifo.flowEnabled = true
        
        // Send an EOS command
        guard let cmd = pool.acquire() else { return false }
        cmd.initEOS()
        
        guard fifo.tryWaitForWriteSpace() else { return false }
        try fifo.write(cmd)
        // Don't release - ownership transferred
        
        guard fifo.count == 1 else { return false }
        
        // Read it back
        guard fifo.tryWaitForReadData() else { return false }
        guard let readCmd = try fifo.read() else { return false }
        defer { readCmd.release() }  // Must release
        
        return readCmd.type == .eos && readCmd.isSentinel && fifo.count == 0
    }

    test("CmdFifo capacity limit") {
        let pool = CmdPool(initialSize: 10)
        let fifo = CmdFifo(capacity: 2, mode: .blocking)
        fifo.flowEnabled = true
        
        // Fill the FIFO
        for _ in 0..<2 {
            guard let cmd = pool.acquire() else { return false }
            cmd.initFlush()
            _ = fifo.tryWaitForWriteSpace()
            try fifo.write(cmd)
        }
        
        // Third write should not have space available
        return !fifo.tryWaitForWriteSpace()
    }

    test("Cmd types") {
        let pool = CmdPool(initialSize: 5)
        
        guard let cmd1 = pool.acquire() else { return false }
        cmd1.initEOS()
        guard cmd1.type == .eos && cmd1.isSentinel && !cmd1.isMedia else { 
            cmd1.release()
            return false 
        }
        cmd1.release()
        
        guard let cmd2 = pool.acquire() else { return false }
        cmd2.initFlush()
        guard cmd2.type == .flush && cmd2.isSentinel else {
            cmd2.release()
            return false
        }
        cmd2.release()
        
        return true
    }

    print("\n─────────────────────────────────────")
    print("Results: \(passed) passed, \(failed) failed")

    if failed > 0 { exit(1) }
}

main()
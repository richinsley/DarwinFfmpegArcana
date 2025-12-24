/**
 * FfmpegArcana Test Harness
 */

import Foundation
import FfmpegArcana

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

        print("\nFIFO Pipeline Test: \(path)")
        print("Video: \(info.width)x\(info.height) @ \(String(format: "%.2f", info.frameRate)) fps")
        print("Hardware: \(decoder.useHardwareAcceleration ? "yes" : "no")")

        // Create a frame FIFO with capacity for 10 frames
        let fifo = FrameFifo(capacity: 10, mode: .lockless)
        fifo.flowEnabled = true

        var producerDone = false
        var consumerCount = 0
        let start = Date()

        // Producer thread - decode and push frames
        let producerThread = Thread {
            var count = 0
            do {
                while count < maxFrames {
                    guard let decoded = try decoder.decodeNextFrame() else { break }
                    
                    // Wait for write space and push
                    try fifo.waitForWriteSpace()
                    try fifo.write(decoded.frame)
                    count += 1
                    
                    if count % 10 == 0 {
                        print("  [Producer] Pushed frame \(count), FIFO count: \(fifo.count)")
                    }
                }
            } catch {
                print("  [Producer] Error: \(error)")
            }
            
            print("  [Producer] Done, produced \(count) frames")
            producerDone = true
            
            // Disable flow to unblock consumer if waiting
            fifo.flowEnabled = false
        }

        // Consumer thread - pull frames from FIFO
        let consumerThread = Thread {
            do {
                while true {
                    // Try to wait for data with timeout
                    let waitResult = fifo.tryWaitForReadData()
                    
                    if !waitResult {
                        if producerDone && fifo.count == 0 {
                            break
                        }
                        // Brief sleep before retry
                        Thread.sleep(forTimeInterval: 0.001)
                        continue
                    }
                    
                    if let frame = try fifo.read() {
                        consumerCount += 1
                        if consumerCount % 10 == 0 {
                            print("  [Consumer] Got frame \(consumerCount): \(frame.width)x\(frame.height)")
                        }
                    }
                }
            } catch FifoError.flowDisabled {
                // Expected when producer finishes
            } catch {
                print("  [Consumer] Error: \(error)")
            }
            
            print("  [Consumer] Done, consumed \(consumerCount) frames")
        }

        print("\nStarting pipeline...\n")
        
        producerThread.start()
        consumerThread.start()

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

    // FIFO tests
    test("FrameFifo creation") {
        let fifo = FrameFifo(capacity: 10, mode: .lockless)
        return fifo.count == 0 && !fifo.flowEnabled
    }

    test("FrameFifo flow control") {
        let fifo = FrameFifo(capacity: 10, mode: .lockless)
        fifo.flowEnabled = true
        let enabled = fifo.flowEnabled
        fifo.flowEnabled = false
        return enabled && !fifo.flowEnabled
    }

    test("FrameFifo write/read") {
        let fifo = FrameFifo(capacity: 5, mode: .blocking)
        fifo.flowEnabled = true
        
        let frame = try Frame(width: 640, height: 480, pixelFormat: .bgra)
        
        // Should be able to get write space
        guard fifo.tryWaitForWriteSpace() else { return false }
        try fifo.write(frame)
        
        guard fifo.count == 1 else { return false }
        
        // Should be able to read
        guard fifo.tryWaitForReadData() else { return false }
        guard let readFrame = try fifo.read() else { return false }
        
        return readFrame.width == 640 && readFrame.height == 480 && fifo.count == 0
    }

    test("PacketFifo creation") {
        let fifo = PacketFifo(capacity: 20, mode: .blocking)
        return fifo.count == 0
    }

    test("FIFO capacity limit") {
        let fifo = FrameFifo(capacity: 2, mode: .blocking)
        fifo.flowEnabled = true
        
        let frame = try Frame(width: 100, height: 100, pixelFormat: .bgra)
        
        // Fill the FIFO
        _ = fifo.tryWaitForWriteSpace()
        try fifo.write(frame)
        _ = fifo.tryWaitForWriteSpace()
        try fifo.write(frame)
        
        // Third write should not have space available (non-blocking check)
        return !fifo.tryWaitForWriteSpace()
    }

    print("\n─────────────────────────────────────")
    print("Results: \(passed) passed, \(failed) failed")

    if failed > 0 { exit(1) }
}

main()
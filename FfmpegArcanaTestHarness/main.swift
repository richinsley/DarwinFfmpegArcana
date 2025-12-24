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

    print("\n─────────────────────────────────────")
    print("Results: \(passed) passed, \(failed) failed")

    if failed > 0 { exit(1) }
}

main()

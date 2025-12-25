import SwiftUI
import FfmpegArcana

struct ContentView: View {
    @State private var avcodecVersion = "Loading..."
    @State private var avformatVersion = "Loading..."
    @State private var avutilVersion = "Loading..."
    @State private var poolStats = "Not tested"
    @State private var fifoStats = "Not tested"
    
    var body: some View {
        NavigationView {
            List {
                Section("FFmpeg Versions") {
                    LabeledContent("avcodec", value: avcodecVersion)
                    LabeledContent("avformat", value: avformatVersion)
                    LabeledContent("avutil", value: avutilVersion)
                }
                
                Section("CmdPool Test") {
                    Text(poolStats)
                        .font(.system(.body, design: .monospaced))
                    
                    Button("Run Pool Test") {
                        testPool()
                    }
                }
                
                Section("CmdFifo Test") {
                    Text(fifoStats)
                        .font(.system(.body, design: .monospaced))
                    
                    Button("Run FIFO Test") {
                        testFifo()
                    }
                }
            }
            .navigationTitle("FfmpegArcana")
        }
        .onAppear {
            loadVersions()
        }
    }
    
    func loadVersions() {
        avcodecVersion = FFmpeg.avcodecVersion
        avformatVersion = FFmpeg.avformatVersion
        avutilVersion = FFmpeg.avutilVersion
    }
    
    func testPool() {
        let pool = CmdPool(initialSize: 10, maxSize: 20)
        
        var results: [String] = []
        results.append("Initial: \(pool.totalCount) total, \(pool.freeCount) free")
        
        // Acquire some commands
        var cmds: [Cmd] = []
        for i in 0..<5 {
            if let cmd = pool.acquire() {
                cmd.initEOS()
                cmd.pts = Int64(i * 1000)
                cmds.append(cmd)
            }
        }
        
        results.append("After acquire 5: \(pool.inUseCount) in use")
        
        // Release them
        for cmd in cmds {
            cmd.release()
        }
        
        results.append("After release: \(pool.freeCount) free")
        
        poolStats = results.joined(separator: "\n")
    }
    
    func testFifo() {
        let pool = CmdPool(initialSize: 10)
        let fifo = CmdFifo(capacity: 5, mode: .blocking)
        fifo.flowEnabled = true
        
        var results: [String] = []
        
        do {
            // Write some commands
            for i in 0..<3 {
                guard let cmd = pool.acquire() else { break }
                cmd.type = .frame
                cmd.pts = Int64(i * 33333)  // ~30fps timestamps
                cmd.streamIndex = 0
                
                if fifo.tryWaitForWriteSpace() {
                    try fifo.write(cmd)
                    results.append("Wrote cmd \(i), pts=\(cmd.pts)")
                }
            }
            
            // Send EOS
            if let eos = pool.acquire() {
                eos.initEOS()
                if fifo.tryWaitForWriteSpace() {
                    try fifo.write(eos)
                    results.append("Wrote EOS")
                }
            }
            
            results.append("FIFO count: \(fifo.count)")
            
            // Read them back
            while fifo.tryWaitForReadData() {
                if let cmd = try fifo.read() {
                    defer { cmd.release() }
                    
                    switch cmd.type {
                    case .frame:
                        results.append("Read frame, pts=\(cmd.pts)")
                    case .eos:
                        results.append("Read EOS ✓")
                    default:
                        results.append("Read \(cmd.type)")
                    }
                }
            }
            
            results.append("Pool: \(pool.inUseCount) in use, \(pool.freeCount) free")
            
        } catch {
            results.append("Error: \(error)")
        }
        
        fifoStats = results.joined(separator: "\n")
    }
}

#Preview {
    ContentView()
}

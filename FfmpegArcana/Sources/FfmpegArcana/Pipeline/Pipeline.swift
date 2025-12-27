// Sources/FfmpegArcana/Pipeline/Pipeline.swift

import Foundation

public class Pipeline {
    
    public private(set) var components: [String: PipelineComponent] = [:]
    public private(set) var connections: [(output: String, input: String)] = []  // "component.port"
    
    public enum State: Equatable {
        case idle
        case ready
        case running
        case paused
        case error(String)  // Store error message instead of Error for Equatable
        
        public static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle): return true
            case (.ready, .ready): return true
            case (.running, .running): return true
            case (.paused, .paused): return true
            case (.error(let a), .error(let b)): return a == b
            default: return false
            }
        }
    }
    
    public private(set) var state: State = .idle
    public var onStateChanged: ((State) -> Void)?
    
    public init() {}
    
    // MARK: - Construction
    
    public func add(_ component: PipelineComponent) {
        components[component.id] = component
    }
    
    public func remove(_ componentId: String) throws {
        guard state != .running else {
            throw ComponentError(code: 400, message: "Cannot remove component while running")
        }
        
        // Disconnect all connections involving this component
        connections.removeAll { conn in
            conn.output.hasPrefix(componentId + ".") || conn.input.hasPrefix(componentId + ".")
        }
        
        components.removeValue(forKey: componentId)
    }
    
    public func connect(_ outputPath: String, to inputPath: String) throws {
        let (_, outputPort) = try resolveOutput(outputPath)
        let (_, inputPort) = try resolveInput(inputPath)
        
        try outputPort.connect(to: inputPort)
        connections.append((output: outputPath, input: inputPath))
    }
    
    public func disconnect(_ outputPath: String, from inputPath: String) throws {
        let (_, outputPort) = try resolveOutput(outputPath)
        let (_, inputPort) = try resolveInput(inputPath)
        
        outputPort.disconnect(from: inputPort)
        connections.removeAll { $0.output == outputPath && $0.input == inputPath }
    }
    
    // MARK: - Lifecycle
    
    public func prepare() async throws {
        for component in components.values {
            try await component.prepare()
        }
        state = .ready
        onStateChanged?(state)
    }
    
    public func start() async throws {
        guard state == .ready || state == .paused else {
            throw ComponentError.invalidState
        }
        
        // Start sinks first, then processors, then sources
        // This ensures downstream is ready before data flows
        let sorted = topologicalSort()
        
        for componentId in sorted.reversed() {
            if let component = components[componentId] {
                try await component.start()
            }
        }
        
        state = .running
        onStateChanged?(state)
    }
    
    public func pause() async throws {
        // Stop sources first to stop data flow
        let sorted = topologicalSort()
        
        for componentId in sorted {
            if let component = components[componentId] {
                try await component.pause()
            }
        }
        
        state = .paused
        onStateChanged?(state)
    }
    
    public func stop() async throws {
        let sorted = topologicalSort()
        
        for componentId in sorted {
            if let component = components[componentId] {
                try await component.stop()
            }
        }
        
        state = .idle
        onStateChanged?(state)
    }
    
    // MARK: - Parameter Access
    
    public func setParameter(_ path: String, value: Any) throws {
        let parts = path.split(separator: ".")
        guard parts.count == 2,
              let component = components[String(parts[0])] else {
            throw ComponentError(code: 401, message: "Invalid parameter path: \(path)")
        }
        
        try component.setParameter(String(parts[1]), value: value)
    }
    
    public func getParameter(_ path: String) -> Any? {
        let parts = path.split(separator: ".")
        guard parts.count == 2,
              let component = components[String(parts[0])] else { return nil }
        
        return component.getParameter(String(parts[1]))
    }
    
    public func getParameterDefinition(for path: String) -> ParameterDefinition? {
        let parts = path.split(separator: ".")
        guard parts.count == 2,
              let component = components[String(parts[0])] else { return nil }
        
        return component.parameters.definition(for: String(parts[1]))
    }
    
    // MARK: - Helpers
    
    private func resolveOutput(_ path: String) throws -> (PipelineComponent, OutputPort) {
        let parts = path.split(separator: ".")
        guard parts.count == 2 else {
            throw ComponentError(code: 402, message: "Invalid output path: \(path)")
        }
        
        guard let component = components[String(parts[0])] else {
            throw ComponentError(code: 403, message: "Component not found: \(parts[0])")
        }
        
        guard let port = component.outputPorts[String(parts[1])] else {
            throw ComponentError(code: 404, message: "Output port not found: \(parts[1])")
        }
        
        return (component, port)
    }
    
    private func resolveInput(_ path: String) throws -> (PipelineComponent, InputPort) {
        let parts = path.split(separator: ".")
        guard parts.count == 2 else {
            throw ComponentError(code: 405, message: "Invalid input path: \(path)")
        }
        
        guard let component = components[String(parts[0])] else {
            throw ComponentError(code: 406, message: "Component not found: \(parts[0])")
        }
        
        guard let port = component.inputPorts[String(parts[1])] else {
            throw ComponentError(code: 407, message: "Input port not found: \(parts[1])")
        }
        
        return (component, port)
    }
    
    private func topologicalSort() -> [String] {
        // Build adjacency list (output -> input means output should start after input)
        var inDegree: [String: Int] = [:]
        var adjacency: [String: [String]] = [:]
        
        for id in components.keys {
            inDegree[id] = 0
            adjacency[id] = []
        }
        
        for (output, input) in connections {
            let outputComp = String(output.split(separator: ".")[0])
            let inputComp = String(input.split(separator: ".")[0])
            
            adjacency[outputComp]?.append(inputComp)
            inDegree[inputComp] = (inDegree[inputComp] ?? 0) + 1
        }
        
        // Kahn's algorithm
        var queue = components.keys.filter { inDegree[$0] == 0 }
        var result: [String] = []
        
        while !queue.isEmpty {
            let node = queue.removeFirst()
            result.append(node)
            
            for neighbor in adjacency[node] ?? [] {
                inDegree[neighbor] = (inDegree[neighbor] ?? 1) - 1
                if inDegree[neighbor] == 0 {
                    queue.append(neighbor)
                }
            }
        }
        
        return result
    }
}
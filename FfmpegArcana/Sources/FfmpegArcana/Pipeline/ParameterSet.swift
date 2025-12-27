// Sources/FfmpegArcana/Pipeline/ParameterSet.swift

import Foundation

// MARK: - Parameter Definition

public struct ParameterDefinition {
    public let key: String
    public let displayName: String
    public let type: ParameterType
    public let defaultValue: Any
    public let readOnly: Bool
    
    // Type-specific constraints
    public var range: ClosedRange<Double>?      // For numeric
    public var options: [ParameterOption]?      // For enumeration
    public var step: Double?                    // For numeric (optional)
    
    public init(
        key: String,
        displayName: String,
        type: ParameterType,
        defaultValue: Any,
        readOnly: Bool = false
    ) {
        self.key = key
        self.displayName = displayName
        self.type = type
        self.defaultValue = defaultValue
        self.readOnly = readOnly
    }
    
    // Convenience builders
    
    public static func bool(_ key: String, display: String, default: Bool, readOnly: Bool = false) -> ParameterDefinition {
        ParameterDefinition(key: key, displayName: display, type: .bool, defaultValue: `default`, readOnly: readOnly)
    }
    
    public static func float(_ key: String, display: String, default: Double, range: ClosedRange<Double>, readOnly: Bool = false) -> ParameterDefinition {
        var def = ParameterDefinition(key: key, displayName: display, type: .float, defaultValue: `default`, readOnly: readOnly)
        def.range = range
        return def
    }
    
    public static func int(_ key: String, display: String, default: Int, range: ClosedRange<Int>, readOnly: Bool = false) -> ParameterDefinition {
        var def = ParameterDefinition(key: key, displayName: display, type: .int, defaultValue: `default`, readOnly: readOnly)
        def.range = Double(range.lowerBound)...Double(range.upperBound)
        return def
    }
    
    public static func enumeration(_ key: String, display: String, options: [ParameterOption], default: String, readOnly: Bool = false) -> ParameterDefinition {
        var def = ParameterDefinition(key: key, displayName: display, type: .enumeration, defaultValue: `default`, readOnly: readOnly)
        def.options = options
        return def
    }
    
    public static func readout(_ key: String, display: String, type: ParameterType = .string) -> ParameterDefinition {
        ParameterDefinition(key: key, displayName: display, type: type, defaultValue: "", readOnly: true)
    }
}

public enum ParameterType: String, Codable {
    case bool
    case int
    case float
    case string
    case enumeration
}

public struct ParameterOption: Codable, Equatable {
    public let value: String
    public let displayName: String
    
    public init(_ value: String, display: String? = nil) {
        self.value = value
        self.displayName = display ?? value
    }
}

// MARK: - Parameter Set

public class ParameterSet {
    private var definitions: [String: ParameterDefinition] = [:]
    private var values: [String: Any] = [:]
    private let lock = NSLock()
    
    public var allDefinitions: [ParameterDefinition] {
        lock.lock()
        defer { lock.unlock() }
        return Array(definitions.values)
    }
    
    public var keys: [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(definitions.keys)
    }
    
    public func add(_ definition: ParameterDefinition) {
        lock.lock()
        defer { lock.unlock() }
        definitions[definition.key] = definition
        if values[definition.key] == nil {
            values[definition.key] = definition.defaultValue
        }
    }
    
    public func definition(for key: String) -> ParameterDefinition? {
        lock.lock()
        defer { lock.unlock() }
        return definitions[key]
    }
    
    public func get(_ key: String) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }
    
    public func set(_ key: String, value: Any) throws {
        lock.lock()
        defer { lock.unlock() }
        
        guard let def = definitions[key] else {
            throw ParameterError.unknownParameter(key)
        }
        
        guard !def.readOnly else {
            throw ParameterError.readOnly(key)
        }
        
        // Type validation
        try validateType(value, for: def)
        
        // Range validation
        if let range = def.range, let numericValue = value as? Double {
            guard range.contains(numericValue) else {
                throw ParameterError.outOfRange(key, value: numericValue, range: range)
            }
        }
        
        values[key] = value
    }
    
    /// Update a read-only value (internal use)
    public func updateReadOnly(_ key: String, value: Any) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }
    
    private func validateType(_ value: Any, for definition: ParameterDefinition) throws {
        let valid: Bool
        switch definition.type {
        case .bool:
            valid = value is Bool
        case .int:
            valid = value is Int || value is Int32 || value is Int64
        case .float:
            valid = value is Double || value is Float || value is CGFloat
        case .string:
            valid = value is String
        case .enumeration:
            if let strValue = value as? String, let options = definition.options {
                valid = options.contains { $0.value == strValue }
            } else {
                valid = false
            }
        }
        
        guard valid else {
            throw ParameterError.typeMismatch(definition.key, expected: definition.type, got: value)
        }
    }
}

public enum ParameterError: Error, LocalizedError {
    case unknownParameter(String)
    case readOnly(String)
    case typeMismatch(String, expected: ParameterType, got: Any)
    case outOfRange(String, value: Double, range: ClosedRange<Double>)
    
    public var errorDescription: String? {
        switch self {
        case .unknownParameter(let key):
            return "Unknown parameter: \(key)"
        case .readOnly(let key):
            return "Parameter is read-only: \(key)"
        case .typeMismatch(let key, let expected, let got):
            return "Type mismatch for \(key): expected \(expected), got \(type(of: got))"
        case .outOfRange(let key, let value, let range):
            return "Value \(value) out of range \(range) for \(key)"
        }
    }
}
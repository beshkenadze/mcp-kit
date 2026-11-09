import Foundation

public protocol ToolInput: Decodable, Sendable {
    static var descriptions: [String: String] { get }
}

extension ToolInput {
    public static var descriptions: [String: String] { [:] }
}

public protocol ToolInputEnum: RawRepresentable, CaseIterable, Decodable, Sendable where RawValue == String {}

extension ToolInputEnum {
    static var schemaValues: [String] { allCases.map(\.rawValue) }
    static func schemaSample() throws -> Any {
        guard let first = allCases.first else { throw SchemaFailure(reason: "An input enum must have a case") }
        return first
    }
}

public enum MCPKitServerError: Error, LocalizedError {
    case unsupportedInput(tool: String, reason: String)
    case duplicateTool(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedInput(let tool, let reason): "Unsupported input for \(tool): \(reason)"
        case .duplicateTool(let name): "Duplicate tool: \(name)"
        }
    }
}

struct SchemaFailure: Error, LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

final class SchemaFailureState {
    var error: (any Error)?
}

final class SchemaDecoder: Decoder {
    var codingPath: [any CodingKey] = []
    let userInfo: [CodingUserInfoKey: Any] = [:]
    var properties: [String: Value] = [:]
    var required: Set<String> = []
    var optional: Set<String> = []
    var schema: Value?
    var isKeyed = false
    var ancestors: [ObjectIdentifier] = []
    var failureState = SchemaFailureState()

    static func input<T: ToolInput>(_ type: T.Type) throws -> Value {
        let decoder = SchemaDecoder()
        _ = try decoder.sample(type)
        if let error = decoder.failureState.error { throw error }
        guard let schema = decoder.schema, schema.objectValue?["type"] == .string("object") else {
            throw SchemaFailure(reason: "The input root must be an object")
        }
        return schema
    }

    func sample<T: Decodable>(_ type: T.Type) throws -> T {
        do { return try record(type) }
        catch {
            if failureState.error == nil { failureState.error = error }
            throw error
        }
    }

    private func unsupported(_ reason: String) -> SchemaFailure {
        let error = SchemaFailure(reason: reason)
        if failureState.error == nil { failureState.error = error }
        return error
    }

    private func record<T: Decodable>(_ type: T.Type) throws -> T {
        let identifier = ObjectIdentifier(type)
        guard !ancestors.contains(identifier) else { throw SchemaFailure(reason: "Recursive input: \(type)") }
        ancestors.append(identifier)
        defer { ancestors.removeLast() }
        if type == String.self { schema = .object(["type": .string("string")]); return String("") as! T }
        if type == Bool.self { schema = .object(["type": .string("boolean")]); return Bool(false) as! T }
        if type == Int.self { schema = .object(["type": .string("integer")]); return Int(0) as! T }
        if type == Int8.self { schema = .object(["type": .string("integer")]); return Int8(0) as! T }
        if type == Int16.self { schema = .object(["type": .string("integer")]); return Int16(0) as! T }
        if type == Int32.self { schema = .object(["type": .string("integer")]); return Int32(0) as! T }
        if type == Int64.self { schema = .object(["type": .string("integer")]); return Int64(0) as! T }
        if type == UInt.self { schema = .object(["type": .string("integer")]); return UInt(0) as! T }
        if type == UInt8.self { schema = .object(["type": .string("integer")]); return UInt8(0) as! T }
        if type == UInt16.self { schema = .object(["type": .string("integer")]); return UInt16(0) as! T }
        if type == UInt32.self { schema = .object(["type": .string("integer")]); return UInt32(0) as! T }
        if type == UInt64.self { schema = .object(["type": .string("integer")]); return UInt64(0) as! T }
        if type == Float.self { schema = .object(["type": .string("number")]); return Float(0) as! T }
        if type == Double.self { schema = .object(["type": .string("number")]); return Double(0) as! T }
        if type == URL.self {
            schema = .object(["type": .string("string"), "format": .string("uri")])
            return URL(string: "https://example.com")! as! T
        }
        if let enumeration = type as? any ToolInputEnum.Type {
            schema = .object(["type": .string("string"), "enum": .array(enumeration.schemaValues.map(Value.string))])
            return try enumeration.schemaSample() as! T
        }
        if let collection = type as? any SchemaCollection.Type {
            return try collection.sample(using: self) as! T
        }
        let value = try T(from: self)
        if schema == nil {
            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .struct, mirror.children.isEmpty { isKeyed = true }
        }
        if let descriptions = (type as? any ToolInput.Type)?.descriptions {
            for (key, description) in descriptions {
                guard var field = properties[key]?.objectValue else {
                    throw unsupported("Description references unknown field '\(key)' in \(type)")
                }
                field["description"] = .string(description)
                properties[key] = .object(field)
            }
        }
        if isKeyed { updateObject() }
        guard schema != nil else { throw SchemaFailure(reason: "No decodable shape for \(type)") }
        return value
    }

    func updateObject() {
        schema = .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.sorted().map(Value.string)),
            "additionalProperties": .bool(false)
        ])
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        isKeyed = true
        updateObject()
        return KeyedDecodingContainer(Fields<Key>(decoder: self))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        throw unsupported("Unsupported unkeyed input at \(codingPath.map(\.stringValue).joined(separator: "."))")
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        throw unsupported("Unsupported single-value input at \(codingPath.map(\.stringValue).joined(separator: "."))")
    }

    struct Fields<Key: CodingKey>: KeyedDecodingContainerProtocol {
        let decoder: SchemaDecoder
        var codingPath: [any CodingKey] { decoder.codingPath }
        var allKeys: [Key] { [] }
        func contains(_ key: Key) -> Bool { true }
        func decodeNil(forKey key: Key) throws -> Bool {
            decoder.optional.insert(key.stringValue)
            return false
        }

        func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
            let child = SchemaDecoder()
            child.failureState = decoder.failureState
            child.ancestors = decoder.ancestors
            child.codingPath = codingPath + [key]
            let value = try child.sample(type)
            decoder.properties[key.stringValue] = child.schema
            if !decoder.optional.contains(key.stringValue) { decoder.required.insert(key.stringValue) }
            decoder.updateObject()
            return value
        }
        func decode(_ type: String.Type, forKey key: Key) throws -> String { try decodeValue(type, forKey: key) }
        func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try decodeValue(type, forKey: key) }
        func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try decodeValue(type, forKey: key) }
        func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try decodeValue(type, forKey: key) }
        func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try decodeValue(type, forKey: key) }
        func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try decodeValue(type, forKey: key) }
        func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try decodeValue(type, forKey: key) }
        func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try decodeValue(type, forKey: key) }
        func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try decodeValue(type, forKey: key) }
        func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try decodeValue(type, forKey: key) }
        func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try decodeValue(type, forKey: key) }
        func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try decodeValue(type, forKey: key) }
        func decode(_ type: Float.Type, forKey key: Key) throws -> Float { try decodeValue(type, forKey: key) }
        func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try decodeValue(type, forKey: key) }

        private func decodeValue<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
            try decode(type, forKey: key)
        }

        func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
            throw decoder.unsupported("Use a nested Decodable type for \(key.stringValue)")
        }
        func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
            throw decoder.unsupported("Use an Array property for \(key.stringValue)")
        }
        func superDecoder() throws -> any Decoder { throw decoder.unsupported("Superclass decoding is unsupported") }
        func superDecoder(forKey key: Key) throws -> any Decoder { throw decoder.unsupported("Superclass decoding is unsupported") }
    }
}

private protocol SchemaCollection {
    static func sample(using decoder: SchemaDecoder) throws -> Any
}

extension Array: SchemaCollection where Element: Decodable {
    fileprivate static func sample(using decoder: SchemaDecoder) throws -> Any {
        let child = SchemaDecoder()
        child.failureState = decoder.failureState
        child.ancestors = decoder.ancestors
        child.codingPath = decoder.codingPath
        let element = try child.sample(Element.self)
        decoder.schema = .object(["type": .string("array"), "items": child.schema!])
        return [element]
    }
}

extension Dictionary: SchemaCollection where Key == String, Value: Decodable {
    fileprivate static func sample(using decoder: SchemaDecoder) throws -> Any {
        let child = SchemaDecoder()
        child.failureState = decoder.failureState
        child.ancestors = decoder.ancestors
        child.codingPath = decoder.codingPath
        let value = try child.sample(Value.self)
        decoder.schema = .object(["type": .string("object"), "additionalProperties": child.schema!])
        return ["key": value]
    }
}


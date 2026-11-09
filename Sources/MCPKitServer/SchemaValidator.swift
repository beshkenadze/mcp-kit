import Foundation

enum SchemaValidator {
    static func validate(_ value: Value, against schema: Value, path: String = "$") throws {
        func fail(_ reason: String, at field: String? = nil) -> ArgumentFailure {
            ArgumentFailure(path: field ?? path, reason: reason)
        }
        guard value != .null else { throw fail("Null is not allowed; omit optional fields") }
        let fields = schema.objectValue ?? [:]
        let type = fields["type"]?.stringValue ?? ""
        switch type {
        case "object":
            guard let object = value.objectValue else { throw fail("Expected object") }
            let properties = fields["properties"]?.objectValue ?? [:]
            for key in fields["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
                guard object[key] != nil else { throw fail("Required field is missing", at: "\(path).\(key)") }
            }
            for key in object.keys.sorted() {
                let childPath = "\(path).\(key)"
                if let child = properties[key] {
                    try validate(object[key]!, against: child, path: childPath)
                } else if fields["additionalProperties"] == .bool(false) {
                    throw fail("Unknown field", at: childPath)
                } else if let child = fields["additionalProperties"], child.objectValue != nil {
                    try validate(object[key]!, against: child, path: childPath)
                }
            }
        case "array":
            guard let array = value.arrayValue else { throw fail("Expected array") }
            if let items = fields["items"] {
                for (index, element) in array.enumerated() {
                    try validate(element, against: items, path: "\(path)[\(index)]")
                }
            }
        case "string":
            switch value {
            case .string, .data: break
            default: throw fail("Expected string")
            }
        case "integer", "number":
            guard let number = Double(value), number.isFinite,
                  type != "integer" || number.rounded(.towardZero) == number else {
                throw fail("Expected \(type)")
            }
            if let minimum = fields["minimum"].flatMap({ Double($0) }), number < minimum {
                throw fail("Must be at least \(minimum)")
            }
            if let maximum = fields["maximum"].flatMap({ Double($0) }), number > maximum {
                throw fail("Must be at most \(maximum)")
            }
        case "boolean":
            guard value.boolValue != nil else { throw fail("Expected boolean") }
        default:
            throw fail("Unsupported schema type '\(type)'")
        }
        if let allowed = fields["enum"]?.arrayValue, !allowed.contains(value) {
            throw fail("Expected one of \(allowed)")
        }
    }
}

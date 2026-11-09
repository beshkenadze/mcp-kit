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
            if let minimum = fields["minItems"]?.intValue, array.count < minimum {
                throw fail("Must contain at least \(minimum) items")
            }
            if let maximum = fields["maxItems"]?.intValue, array.count > maximum {
                throw fail("Must contain at most \(maximum) items")
            }
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
            let count = value.description.unicodeScalars.count
            if let minimum = fields["minLength"]?.intValue, count < minimum {
                throw fail("Must contain at least \(minimum) characters")
            }
            if let maximum = fields["maxLength"]?.intValue, count > maximum {
                throw fail("Must contain at most \(maximum) characters")
            }
        case "integer", "number":
            guard let number = Double(value), number.isFinite,
                  type != "integer" || number.rounded(.towardZero) == number else {
                throw fail("Expected \(type)")
            }
            if let minimum = fields["minimum"].flatMap({ Double($0) }),
               compare(number, integer: value.intValue, to: minimum) == .orderedAscending {
                throw fail("Must be at least \(minimum)")
            }
            if let maximum = fields["maximum"].flatMap({ Double($0) }),
               compare(number, integer: value.intValue, to: maximum) == .orderedDescending {
                throw fail("Must be at most \(maximum)")
            }
        case "boolean":
            guard value.boolValue != nil else { throw fail("Expected boolean") }
        default:
            throw fail("Unsupported schema type '\(type)'")
        }
        let enumValue: Value = if case .data = value { .string(value.description) } else { value }
        if let allowed = fields["enum"]?.arrayValue, !allowed.contains(enumValue) {
            throw fail("Expected one of \(allowed)")
        }
    }

    private static func compare(_ number: Double, integer: Int?, to bound: Double) -> ComparisonResult {
        if let integer {
            if bound >= Double(Int.max) { return .orderedAscending }
            if bound < Double(Int.min) { return .orderedDescending }
            let floor = bound.rounded(.down)
            let limit = Int(floor)
            if integer < limit { return .orderedAscending }
            if integer > limit { return .orderedDescending }
            return bound == floor ? .orderedSame : .orderedAscending
        }
        return number < bound ? .orderedAscending : number > bound ? .orderedDescending : .orderedSame
    }
}

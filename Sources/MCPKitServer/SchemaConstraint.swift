public enum SchemaConstraint: Sendable {
    case range(ClosedRange<Double>)
    case length(ClosedRange<Int>)
    case items(ClosedRange<Int>)

    func apply(to field: inout [String: Value]) throws {
        switch self {
        case .range(let bounds):
            guard field["type"] == .string("number") || field["type"] == .string("integer") else {
                throw SchemaFailure(reason: "range requires a numeric field")
            }
            guard bounds.lowerBound.isFinite, bounds.upperBound.isFinite else {
                throw SchemaFailure(reason: "range bounds must be finite")
            }
            field["minimum"] = .double(bounds.lowerBound)
            field["maximum"] = .double(bounds.upperBound)
        case .length(let bounds):
            guard field["type"] == .string("string") else {
                throw SchemaFailure(reason: "length requires a string field")
            }
            guard bounds.lowerBound >= 0 else { throw SchemaFailure(reason: "length bounds must be nonnegative") }
            field["minLength"] = .int(bounds.lowerBound)
            field["maxLength"] = .int(bounds.upperBound)
        case .items(let bounds):
            guard field["type"] == .string("array") else {
                throw SchemaFailure(reason: "items requires an array field")
            }
            guard bounds.lowerBound >= 0 else { throw SchemaFailure(reason: "items bounds must be nonnegative") }
            field["minItems"] = .int(bounds.lowerBound)
            field["maxItems"] = .int(bounds.upperBound)
        }
    }
}

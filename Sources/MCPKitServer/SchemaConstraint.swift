public enum SchemaConstraint: Sendable {
    case range(ClosedRange<Double>)

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
        }
    }
}

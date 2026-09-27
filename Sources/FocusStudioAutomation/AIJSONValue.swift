import Foundation

/// A JSON document a tool returns as structured data next to its text: ids,
/// absolute paths, counts, durations and sizes an external client can use
/// without parsing prose. Sendable and comparable, unlike the
/// `[String: Any]` the tools take as arguments; ``init(jsonObject:)`` and
/// ``jsonObject`` convert to and from what `JSONSerialization` reads and writes.
public enum AIJSONValue: Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AIJSONValue])
    case object([String: AIJSONValue])

    public init(_ value: Bool) { self = .bool(value) }

    public init(_ value: Int) { self = .number(Double(value)) }

    /// JSON has no NaN or infinity; those become null.
    public init(_ value: Double) { self = value.isFinite ? .number(value) : .null }

    public init(_ value: String) { self = .string(value) }

    /// An absolute file path.
    public init(_ url: URL) { self = .string(url.path) }

    /// ISO 8601 with a time zone, e.g. `2026-09-23T10:15:00Z`.
    public init(_ date: Date) { self = .string(ISO8601DateFormatter().string(from: date)) }

    /// A number rounded to `places` decimals, which keeps times and positions
    /// short (`12.345` rather than `12.345000000000001`).
    public static func rounded(_ value: Double, places: Int = 3) -> AIJSONValue {
        guard value.isFinite else { return .null }
        let factor = pow(10, Double(max(0, places)))
        return .number((value * factor).rounded() / factor)
    }

    /// Converts `JSONSerialization` output (NSNull, NSNumber, String, arrays
    /// and string-keyed dictionaries, in any nesting). Nil for anything else,
    /// such as a Date or a non-finite number.
    public init?(jsonObject value: Any) {
        switch value {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            // Booleans arrive as NSNumber too; only the CFBoolean singletons are booleans.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                guard number.doubleValue.isFinite else { return nil }
                self = .number(number.doubleValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            var items: [AIJSONValue] = []
            items.reserveCapacity(array.count)
            for element in array {
                guard let item = AIJSONValue(jsonObject: element) else { return nil }
                items.append(item)
            }
            self = .array(items)
        case let dictionary as [String: Any]:
            var fields: [String: AIJSONValue] = [:]
            for (key, element) in dictionary {
                guard let field = AIJSONValue(jsonObject: element) else { return nil }
                fields[key] = field
            }
            self = .object(fields)
        default:
            return nil
        }
    }

    /// The value as `JSONSerialization` takes it. Whole numbers come back as
    /// `Int` so `as? Int` works on the other side. Note that
    /// `JSONSerialization` writes fractions with 17 significant digits
    /// (`0.33300000000000002`); ``jsonData(prettyPrinted:)`` writes them short.
    public var jsonObject: Any {
        switch self {
        case .null:
            return NSNull()
        case let .bool(value):
            return value
        case let .number(value):
            if value == value.rounded(), abs(value) < 9_007_199_254_740_992, let whole = Int(exactly: value) { return whole }
            return value
        case let .string(value):
            return value
        case let .array(items):
            return items.map(\.jsonObject)
        case let .object(fields):
            return fields.mapValues(\.jsonObject)
        }
    }

    /// UTF-8 JSON with sorted keys and numbers in their shortest form
    /// (`0.333`, `12`), which keeps large results small for a client's
    /// output limit. Throws only for a non-finite number built by hand.
    public func jsonData(prettyPrinted: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted] : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    // MARK: - Reading

    public subscript(key: String) -> AIJSONValue? {
        guard case let .object(fields) = self else { return nil }
        return fields[key]
    }

    public subscript(index: Int) -> AIJSONValue? {
        guard case let .array(items) = self, items.indices.contains(index) else { return nil }
        return items[index]
    }

    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case let .number(value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        guard case let .number(value) = self, value == value.rounded() else { return nil }
        return Int(exactly: value)
    }

    public var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    public var arrayValue: [AIJSONValue]? {
        if case let .array(items) = self { return items }
        return nil
    }

    public var objectValue: [String: AIJSONValue]? {
        if case let .object(fields) = self { return fields }
        return nil
    }

    public var isNull: Bool { self == .null }
}

extension AIJSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AIJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: AIJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a JSON value.")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(items): try container.encode(items)
        case let .object(fields): try container.encode(fields)
        }
    }
}

extension AIJSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: AIJSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, AIJSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

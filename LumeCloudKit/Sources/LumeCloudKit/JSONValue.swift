import Foundation

/// Any JSON value. Payload `data` is a `[String: JSONValue]`, so fields this
/// app version doesn't know survive a decode → encode round trip verbatim
/// (PROTOCOL.md §2.5).
///
/// Numbers are `Double`. Integral values within ±2^53 encode without a
/// fraction (`1`, never `1.0`), both through `Codable` and `canonicalJSON()`.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Convenience

extension JSONValue {
    public var isNull: Bool {
        if case .null = self { true } else { false }
    }

    public var boolValue: Bool? {
        if case let .bool(value) = self { value } else { nil }
    }

    public var doubleValue: Double? {
        if case let .number(value) = self { value } else { nil }
    }

    /// The number as an `Int` when it is integral and in range.
    public var intValue: Int? {
        guard case let .number(value) = self, value.rounded(.towardZero) == value,
              let int = Int(exactly: value) else { return nil }
        return int
    }

    public var stringValue: String? {
        if case let .string(value) = self { value } else { nil }
    }

    public var arrayValue: [JSONValue]? {
        if case let .array(value) = self { value } else { nil }
    }

    public var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { value } else { nil }
    }

    /// The member `key` of an object, or `nil` for a missing key or a non-object.
    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByStringLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(nilLiteral _: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

// MARK: - Codable

extension JSONValue: Codable {
    /// Integral doubles up to this magnitude are encoded as integers.
    static let maxExactInteger = 9_007_199_254_740_992.0 // 2^53

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .number(value):
            if value.rounded(.towardZero) == value, abs(value) <= Self.maxExactInteger {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }
}

// MARK: - Canonical JSON

extension JSONValue {
    /// The canonical UTF-8 JSON of this value (PROTOCOL.md §2.5):
    ///
    /// - object keys sorted at every level, by UTF-16 code units (the order of
    ///   JavaScript's default sort and Kotlin's `String.compareTo`);
    /// - no insignificant whitespace;
    /// - strings escaped exactly like `JSON.stringify`: `\"`, `\\`, `\b`, `\f`,
    ///   `\n`, `\r`, `\t`, other control characters as lowercase `\u00xx`, and
    ///   everything else (including `/` and non-ASCII) literal;
    /// - numbers formatted like JavaScript's `Number.prototype.toString`
    ///   (integers without a fraction, `0.00001`, `1e-7`, `1e+21`).
    ///
    /// Throws `.nonFiniteNumber` for NaN or infinity.
    public func canonicalJSON() throws -> Data {
        var output = ""
        try Self.write(self, to: &output)
        return Data(output.utf8)
    }

    private static func write(_ value: JSONValue, to output: inout String) throws {
        switch value {
        case .null:
            output += "null"
        case let .bool(bool):
            output += bool ? "true" : "false"
        case let .number(number):
            output += try formatNumber(number)
        case let .string(string):
            writeString(string, to: &output)
        case let .array(array):
            output += "["
            for (index, element) in array.enumerated() {
                if index > 0 { output += "," }
                try write(element, to: &output)
            }
            output += "]"
        case let .object(object):
            output += "{"
            let keys = object.keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
            for (index, key) in keys.enumerated() {
                if index > 0 { output += "," }
                writeString(key, to: &output)
                output += ":"
                try write(object[key]!, to: &output)
            }
            output += "}"
        }
    }

    private static func writeString(_ string: String, to output: inout String) {
        output += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{00}" ..< "\u{20}":
                let hex = String(scalar.value, radix: 16)
                output += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
    }

    /// ECMAScript `Number::toString(10)`, fed by Swift's shortest round-trip digits.
    static func formatNumber(_ value: Double) throws -> String {
        guard value.isFinite else { throw LumeCloudCryptoError.nonFiniteNumber }
        if value == 0 { return "0" } // also -0, like JavaScript

        // Swift's `description` yields the shortest digits that round-trip,
        // as `d.ddd`, `0.000ddd` or `d.ddde±x`.
        var text = Substring(value.magnitude.description)
        var exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exponent = Int(text[text.index(after: e)...])!
            text = text[..<e]
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let integerPart = parts[0]
        let fractionPart = parts.count > 1 ? parts[1] : ""
        var digits = Array(integerPart + fractionPart)
        // value = 0.digits × 10^n
        var n = integerPart.count + exponent
        while digits.first == "0" {
            digits.removeFirst()
            n -= 1
        }
        while digits.last == "0" {
            digits.removeLast()
        }
        let k = digits.count
        let digitString = String(digits)

        var result: String
        if k <= n, n <= 21 {
            result = digitString + String(repeating: "0", count: n - k)
        } else if n > 0, n <= 21 {
            result = String(digits[..<n]) + "." + String(digits[n...])
        } else if n > -6, n <= 0 {
            result = "0." + String(repeating: "0", count: -n) + digitString
        } else {
            let e = n - 1
            let sign = e < 0 ? "-" : "+"
            let mantissa = k == 1 ? digitString : String(digits[0]) + "." + String(digits[1...])
            result = mantissa + "e" + sign + String(abs(e))
        }
        return value < 0 ? "-" + result : result
    }
}

import Foundation

/// A number that may arrive as a JSON number, a numeric string ("2.5", as Postgres numerics
/// sometimes do), a bool, or be missing. `@Flex var calories: Double?`
@propertyWrapper
public struct Flex: Codable, Hashable, Sendable {
    public var wrappedValue: Double?
    public init() { wrappedValue = nil }
    public init(wrappedValue: Double?) { self.wrappedValue = wrappedValue }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { wrappedValue = nil }
        else if let d = try? c.decode(Double.self) { wrappedValue = d.isFinite ? d : nil }
        else if let s = try? c.decode(String.self) { wrappedValue = Double(s.trimmingCharacters(in: .whitespaces)) }
        else if let b = try? c.decode(Bool.self) { wrappedValue = b ? 1 : 0 }
        else { wrappedValue = nil }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wrappedValue)
    }
}

/// Text that may arrive as a string or a number (ids), or be missing.
@propertyWrapper
public struct FlexText: Codable, Hashable, Sendable {
    public var wrappedValue: String?
    public init() { wrappedValue = nil }
    public init(wrappedValue: String?) { self.wrappedValue = wrappedValue }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { wrappedValue = nil }
        else if let s = try? c.decode(String.self) { wrappedValue = s }
        else if let i = try? c.decode(Int.self) { wrappedValue = String(i) }
        else if let d = try? c.decode(Double.self) { wrappedValue = String(d) }
        else { wrappedValue = nil }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    public func decode(_ type: Flex.Type, forKey key: Key) throws -> Flex {
        try decodeIfPresent(type, forKey: key) ?? Flex(wrappedValue: nil)
    }
    public func decode(_ type: FlexText.Type, forKey key: Key) throws -> FlexText {
        try decodeIfPresent(type, forKey: key) ?? FlexText(wrappedValue: nil)
    }
}

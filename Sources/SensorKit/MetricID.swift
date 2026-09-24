/// A stable, namespaced identifier for one measurable quantity.
///
/// These strings are a **public contract**: they end up inside shared widget
/// documents (M4), so a widget authored on an M4 Max has to name its metrics in
/// a way an Intel MacBook can either resolve or knowingly reject. Renaming a
/// `MetricID` after release breaks every document that mentions it -- treat
/// them like API, not like internal symbols.
///
/// Convention: `domain.quantity[.qualifier]`, with an index segment where the
/// hardware can have more than one of something (`gpu.0.utilization`).
public struct MetricID: Hashable, Sendable, RawRepresentable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public var description: String { rawValue }
}

extension MetricID: Codable {
    public init(from decoder: any Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

import Foundation

/// An array that skips elements that fail to decode, so one malformed entry from the server
/// doesn't fail the whole response. Don't use it where positions matter (tracks, chapters).
public struct LossyArray<Element> {
    public var elements: [Element]

    public init(_ elements: [Element]) {
        self.elements = elements
    }
}

extension LossyArray: Sendable where Element: Sendable {}
extension LossyArray: Equatable where Element: Equatable {}
extension LossyArray: Hashable where Element: Hashable {}

extension LossyArray: Decodable where Element: Decodable {
    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        elements.reserveCapacity(container.count ?? 0)
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                // A failed decode doesn't advance the container; consume the element.
                _ = try container.decode(SkippedElement.self)
            }
        }
        self.elements = elements
    }

    private struct SkippedElement: Decodable {
        init(from decoder: any Decoder) throws {}
    }
}

extension LossyArray: Encodable where Element: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(elements)
    }
}

extension KeyedDecodingContainer {
    /// Decodes an array at `key`, skipping elements that fail to decode.
    public func decodeLossyArrayIfPresent<Element: Decodable>(
        _ type: Element.Type, forKey key: Key
    ) throws -> [Element]? {
        try decodeIfPresent(LossyArray<Element>.self, forKey: key)?.elements
    }
}

import Foundation

/// A number the server may send as a JSON number or a numeric string (JavaScript sums over old
/// rows can turn into strings). Anything else, including `null`, decodes as `nil`.
struct LenientDouble: Decodable {
    let value: Double?

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            value = number
        } else if let string = try? container.decode(String.self) {
            value = Double(string.trimmingCharacters(in: .whitespaces)).flatMap { $0.isFinite ? $0 : nil }
        } else {
            value = nil
        }
    }
}

extension KeyedDecodingContainer {
    /// The number or numeric string at `key`, or `nil` if it's missing, `null`, or not numeric.
    func decodeLenientDouble(forKey key: Key) -> Double? {
        (try? decodeIfPresent(LenientDouble.self, forKey: key))?.value
    }

    /// A dictionary of numbers, skipping values that aren't numbers or numeric strings.
    func decodeLenientDoubleDictionary(forKey key: Key) throws -> [String: Double]? {
        try decodeIfPresent([String: LenientDouble].self, forKey: key)?.compactMapValues(\.value)
    }
}

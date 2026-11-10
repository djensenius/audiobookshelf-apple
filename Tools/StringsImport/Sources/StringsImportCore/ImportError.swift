/// Errors that stop catalog generation.
public enum ImportError: Error, Equatable, CustomStringConvertible {
    case missingSource(fileName: String)
    case unknownLocale(fileName: String, identifier: String)
    case duplicateLocale(identifier: String)
    case invalidFile(fileName: String, reason: String)

    public var description: String {
        switch self {
        case .missingSource(let fileName):
            "missing source strings file \(fileName).json"
        case .unknownLocale(let fileName, let identifier):
            "\(fileName).json maps to '\(identifier)', which is not a canonical Apple locale identifier; "
                + "add it to LocaleMapping.overrides"
        case .duplicateLocale(let identifier):
            "more than one strings file maps to '\(identifier)'"
        case .invalidFile(let fileName, let reason):
            "\(fileName).json: \(reason)"
        }
    }
}

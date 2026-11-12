import Foundation

/// The metadata of a comic's `ComicInfo.xml` (the ComicRack schema) that the reader uses.
public struct ComicInfo: Sendable, Hashable {
    public var title: String?
    public var series: String?
    public var number: String?
    /// The page count the file claims; the archive's images are what count.
    public var pageCount: Int?
    /// `<Manga>YesAndRightToLeft</Manga>`: the reader defaults to right to left (ADR 0008 §7).
    public var isRightToLeft = false
    /// The `<Page Image="…">` indexes (0-based, in ComicRack's page order) that show alone in a
    /// spread: `DoublePage="True"` or `Type="FrontCover"`.
    public var singlePageImages: Set<Int> = []

    public init(
        title: String? = nil, series: String? = nil, number: String? = nil, pageCount: Int? = nil,
        isRightToLeft: Bool = false, singlePageImages: Set<Int> = []
    ) {
        self.title = title
        self.series = series
        self.number = number
        self.pageCount = pageCount
        self.isRightToLeft = isRightToLeft
        self.singlePageImages = singlePageImages
    }

    /// Parses `ComicInfo.xml`; `nil` if it isn't XML with a `ComicInfo` root.
    public init?(xml: Data) {
        let parser = XMLParser(data: xml)
        let delegate = Delegate()
        parser.delegate = delegate
        guard parser.parse(), delegate.sawRoot else { return nil }
        self = delegate.info
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var info = ComicInfo()
        var sawRoot = false
        private var path: [String] = []
        private var text = ""

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?, attributes: [String: String] = [:]
        ) {
            if path.isEmpty {
                guard elementName == "ComicInfo" else { return parser.abortParsing() }
                sawRoot = true
            }
            path.append(elementName)
            text = ""
            if path == ["ComicInfo", "Pages", "Page"], let image = attributes["Image"].flatMap({ Int($0) }),
                attributes["DoublePage"]?.lowercased() == "true" || attributes["Type"] == "FrontCover"
            {
                info.singlePageImages.insert(image)
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?
        ) {
            defer { path.removeLast() }
            guard path.count == 2 else { return }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let nonEmpty = value.isEmpty ? nil : value
            switch elementName {
            case "Title": info.title = nonEmpty
            case "Series": info.series = nonEmpty
            case "Number": info.number = nonEmpty
            case "PageCount": info.pageCount = Int(value)
            case "Manga": info.isRightToLeft = value == "YesAndRightToLeft"
            default: break
            }
        }
    }
}

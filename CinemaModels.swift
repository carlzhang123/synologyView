import Foundation

enum CinemaLibraryKind: String, Codable, CaseIterable, Identifiable {
    case movies
    case tvShows
    case personalVideos

    var id: Self { self }

    var title: String {
        switch self {
        case .movies:
            return "电影"
        case .tvShows:
            return "电视剧"
        case .personalVideos:
            return "个人视频"
        }
    }

    var systemImage: String {
        switch self {
        case .movies:
            return "film"
        case .tvShows:
            return "tv"
        case .personalVideos:
            return "video"
        }
    }

    var usesKodiMetadata: Bool {
        self != .personalVideos
    }
}

struct CinemaLibraryFolder: Codable, Identifiable, Hashable {
    let kind: CinemaLibraryKind
    let path: String

    var id: String { "\(kind.rawValue):\(path)" }

    var displayName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

enum KodiMediaType: String, Codable {
    case movie
    case tvShow
    case episode
}

struct KodiMetadata: Codable, Equatable {
    let mediaType: KodiMediaType
    let title: String
    let originalTitle: String?
    let sortTitle: String?
    let plot: String?
    let year: Int?
    let premiered: String?
    let runtimeMinutes: Int?
    let rating: Double?
    let genres: [String]
    let studio: String?
    let season: Int?
    let episode: Int?
    let uniqueIDs: [String: String]
}

enum KodiNFOParserError: LocalizedError {
    case invalidDocument
    case unsupportedRootElement

    var errorDescription: String? {
        switch self {
        case .invalidDocument:
            return "NFO 文件格式无效"
        case .unsupportedRootElement:
            return "不是受支持的 Kodi 电影、电视剧或剧集 NFO"
        }
    }
}

struct KodiNFOParser {
    func parse(_ data: Data) throws -> KodiMetadata {
        let delegate = KodiNFOXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate

        guard parser.parse() else {
            throw parser.parserError ?? KodiNFOParserError.invalidDocument
        }
        return try delegate.metadata()
    }
}

private final class KodiNFOXMLDelegate: NSObject, XMLParserDelegate {
    private var rootElement = ""
    private var currentElement = ""
    private var currentText = ""
    private var currentUniqueIDType: String?
    private var values: [String: [String]] = [:]
    private var uniqueIDs: [String: String] = [:]

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if rootElement.isEmpty {
            rootElement = elementName.lowercased()
        }
        currentElement = elementName.lowercased()
        currentText = ""
        currentUniqueIDType = currentElement == "uniqueid" ? attributeDict["type"] : nil
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let element = elementName.lowercased()
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if element == "uniqueid" {
            uniqueIDs[currentUniqueIDType ?? "default"] = text
        } else {
            values[element, default: []].append(text)
        }
        currentText = ""
    }

    func metadata() throws -> KodiMetadata {
        let mediaType: KodiMediaType
        switch rootElement {
        case "movie":
            mediaType = .movie
        case "tvshow":
            mediaType = .tvShow
        case "episodedetails":
            mediaType = .episode
        default:
            throw KodiNFOParserError.unsupportedRootElement
        }

        return KodiMetadata(
            mediaType: mediaType,
            title: first("title") ?? first("originaltitle") ?? "",
            originalTitle: first("originaltitle"),
            sortTitle: first("sorttitle"),
            plot: first("plot"),
            year: first("year").flatMap(Int.init),
            premiered: first("premiered"),
            runtimeMinutes: first("runtime").flatMap(Int.init),
            rating: first("rating").flatMap(Double.init),
            genres: values["genre"] ?? [],
            studio: first("studio"),
            season: first("season").flatMap(Int.init),
            episode: first("episode").flatMap(Int.init),
            uniqueIDs: uniqueIDs
        )
    }

    private func first(_ key: String) -> String? {
        values[key]?.first
    }
}

struct CinemaViewingState: Codable, Equatable {
    var isFavorite = false
    var isWatched = false
    var lastPlayedAt: Date?
}

struct CinemaViewingStateStore {
    private let defaults = UserDefaults.standard

    func load(serverURLString: String, account: String) -> [String: CinemaViewingState] {
        guard let data = defaults.data(forKey: key(serverURLString: serverURLString, account: account)),
              let states = try? JSONDecoder().decode([String: CinemaViewingState].self, from: data) else {
            return [:]
        }
        return states
    }

    func save(
        _ states: [String: CinemaViewingState],
        serverURLString: String,
        account: String
    ) {
        guard let data = try? JSONEncoder().encode(states) else { return }
        defaults.set(data, forKey: key(serverURLString: serverURLString, account: account))
    }

    func update(
        path: String,
        serverURLString: String,
        account: String,
        mutation: (inout CinemaViewingState) -> Void
    ) {
        var states = load(serverURLString: serverURLString, account: account)
        var state = states[path] ?? CinemaViewingState()
        mutation(&state)
        states[path] = state
        save(states, serverURLString: serverURLString, account: account)
    }

    private func key(serverURLString: String, account: String) -> String {
        "synology.cinemaViewingStates.\(serverURLString).\(account)"
    }
}

struct CinemaLibraryCache: Codable {
    let updatedAt: Date
    let items: [CinemaScannedItem]
}

struct CinemaLibraryCacheStore {
    private let defaults = UserDefaults.standard

    func load(serverURLString: String, account: String) -> CinemaLibraryCache? {
        guard let data = defaults.data(forKey: key(serverURLString: serverURLString, account: account)) else {
            return nil
        }
        return try? JSONDecoder().decode(CinemaLibraryCache.self, from: data)
    }

    func save(_ items: [CinemaScannedItem], serverURLString: String, account: String) {
        let cache = CinemaLibraryCache(updatedAt: Date(), items: items)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        defaults.set(data, forKey: key(serverURLString: serverURLString, account: account))
    }

    private func key(serverURLString: String, account: String) -> String {
        "synology.cinemaCache.\(serverURLString).\(account)"
    }
}

struct CinemaLibrarySettingsStore {
    private let defaults = UserDefaults.standard

    func load(serverURLString: String, account: String) -> [CinemaLibraryFolder] {
        guard let data = defaults.data(forKey: key(serverURLString: serverURLString, account: account)),
              let folders = try? JSONDecoder().decode([CinemaLibraryFolder].self, from: data) else {
            return []
        }
        return folders
    }

    func save(_ folders: [CinemaLibraryFolder], serverURLString: String, account: String) {
        guard let data = try? JSONEncoder().encode(folders) else { return }
        defaults.set(data, forKey: key(serverURLString: serverURLString, account: account))
    }

    private func key(serverURLString: String, account: String) -> String {
        "synology.cinemaLibraries.\(serverURLString).\(account)"
    }
}

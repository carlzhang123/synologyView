import Foundation

struct CinemaIndexServiceSettings: Equatable {
    var serverURLString: String
    var token: String
}

struct CinemaIndexServiceSettingsStore {
    static let defaultServerURLString = "https://nas.carlzhang.ltd:52234/"

    private let defaults = UserDefaults.standard
    private let serverKey = "synology.cinemaIndex.serverURL"
    private let tokenService = "SynologyView.cinemaIndex.token"
    private let tokenAccount = "default"

    func load() -> CinemaIndexServiceSettings {
        CinemaIndexServiceSettings(
            serverURLString: defaults.string(forKey: serverKey) ?? Self.defaultServerURLString,
            token: KeychainStore.read(service: tokenService, account: tokenAccount) ?? ""
        )
    }

    func save(_ settings: CinemaIndexServiceSettings) {
        defaults.set(settings.serverURLString.trimmingCharacters(in: .whitespacesAndNewlines), forKey: serverKey)
        KeychainStore.save(
            settings.token.trimmingCharacters(in: .whitespacesAndNewlines),
            service: tokenService,
            account: tokenAccount
        )
    }
}

struct CinemaIndexSnapshot {
    let folders: [CinemaLibraryFolder]
    let items: [CinemaScannedItem]
}

enum CinemaIndexServiceError: LocalizedError {
    case invalidURL
    case missingToken
    case invalidResponse
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "媒体索引服务地址无效"
        case .missingToken: return "请先在设置中填写媒体索引服务 Token"
        case .invalidResponse: return "媒体索引服务返回了无法识别的数据"
        case .server(let statusCode): return "媒体索引服务请求失败（HTTP \(statusCode)）"
        }
    }
}

struct CinemaIndexServiceClient {
    private let baseURL: URL
    private let token: String
    private let session: URLSession

    init(settings: CinemaIndexServiceSettings, session: URLSession = .shared) throws {
        guard let url = URL(string: settings.serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw CinemaIndexServiceError.invalidURL
        }
        let token = settings.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw CinemaIndexServiceError.missingToken }
        baseURL = url
        self.token = token
        self.session = session
    }

    func loadSnapshot() async throws -> CinemaIndexSnapshot {
        async let librariesRequest: [IndexLibrary] = request(path: "api/v1/libraries/")
        async let mediaRequest = loadAllMedia()
        let (libraries, media) = try await (librariesRequest, mediaRequest)

        let folders = libraries.compactMap { library -> CinemaLibraryFolder? in
            guard library.enabled, let kind = CinemaLibraryKind(indexValue: library.type) else { return nil }
            return CinemaLibraryFolder(kind: kind, path: library.synologyPath)
        }
        var items = media.compactMap(CinemaScannedItem.init(indexMedia:))
        let librariesByID = Dictionary(uniqueKeysWithValues: libraries.map { ($0.id, $0) })
        let tvEpisodes = media.filter { $0.libraryType == "tv_show" && !$0.deleted }
        let showsByFolder = Dictionary(grouping: tvEpisodes) { media in
            showFolder(for: media, library: librariesByID[media.libraryID])
        }
        items.append(contentsOf: showsByFolder.compactMap { folder, episodes in
            guard !folder.isEmpty, let first = episodes.first else { return nil }
            return CinemaScannedItem(indexShowFolder: folder, sample: first)
        })
        return CinemaIndexSnapshot(folders: folders, items: items)
    }

    private func loadAllMedia() async throws -> [IndexMedia] {
        var url: URL? = endpoint(path: "api/v1/media/", queryItems: [
            URLQueryItem(name: "limit", value: "500"),
            URLQueryItem(name: "ordering", value: "title")
        ])
        var results: [IndexMedia] = []
        while let pageURL = url {
            try Task.checkCancellation()
            let page: IndexMediaPage = try await request(url: pageURL)
            results.append(contentsOf: page.results.filter { !$0.deleted })
            url = page.next.flatMap(nextPageURL)
        }
        return results
    }

    private func request<T: Decodable>(path: String) async throws -> T {
        guard let url = endpoint(path: path) else { throw CinemaIndexServiceError.invalidURL }
        return try await request(url: url)
    }

    private func request<T: Decodable>(url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CinemaIndexServiceError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw CinemaIndexServiceError.server(response.statusCode) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            if let date = ISO8601DateFormatter.fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Invalid ISO 8601 date"
            )
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw CinemaIndexServiceError.invalidResponse
        }
    }

    private func endpoint(path: String, queryItems: [URLQueryItem] = []) -> URL? {
        let url = baseURL.appending(path: path)
        guard !queryItems.isEmpty else { return url }
        return url.appending(queryItems: queryItems)
    }

    private func nextPageURL(_ value: String) -> URL? {
        guard let suppliedURL = URL(string: value),
              let components = URLComponents(url: suppliedURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        return endpoint(path: "api/v1/media/", queryItems: components.queryItems ?? [])
    }

    private func showFolder(for media: IndexMedia, library: IndexLibrary?) -> String {
        guard let library else { return media.parentPath }
        let relativeComponents = media.relativePath.split(separator: "/")
        guard relativeComponents.count > 1 else { return library.synologyPath }
        return library.synologyPath + "/" + relativeComponents[0]
    }
}

private extension ISO8601DateFormatter {
    static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private struct IndexLibrary: Decodable {
    let id: Int
    let name: String
    let type: String
    let synologyPath: String
    let enabled: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, type, enabled
        case synologyPath = "synology_path"
    }
}

private struct IndexMediaPage: Decodable {
    let next: String?
    let results: [IndexMedia]
}

private struct IndexMedia: Decodable {
    let id: String
    let libraryID: Int
    let libraryType: String
    let mediaType: String
    let synologyPath: String
    let parentPath: String
    let relativePath: String
    let title: String
    let createdAt: Date
    let modifiedAt: Date
    let posterPath: String?
    let fanartPath: String?
    let seasonPosterPath: String?
    let thumbnailPath: String?
    let metadata: IndexMetadata?
    let deleted: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, metadata, deleted
        case libraryID = "library_id"
        case libraryType = "library_type"
        case mediaType = "media_type"
        case synologyPath = "synology_path"
        case parentPath = "parent_path"
        case relativePath = "relative_path"
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
        case posterPath = "poster_path"
        case fanartPath = "fanart_path"
        case seasonPosterPath = "season_poster_path"
        case thumbnailPath = "thumbnail_path"
    }
}

private struct IndexMetadata: Decodable {
    let originalTitle: String?
    let sortTitle: String?
    let plot: String?
    let year: String?
    let premiered: String?
    let runtimeMinutes: String?
    let genres: [String]?
    let studio: String?
    let season: String?
    let episode: String?
    let uniqueIDs: [String: String]?

    enum CodingKeys: String, CodingKey {
        case plot, year, premiered, genres, studio, season, episode
        case originalTitle = "originaltitle"
        case sortTitle = "sorttitle"
        case runtimeMinutes = "runtime"
        case uniqueIDs = "unique_ids"
    }
}

private extension CinemaLibraryKind {
    init?(indexValue: String) {
        switch indexValue {
        case "movie": self = .movies
        case "tv_show": self = .tvShows
        case "personal_video": self = .personalVideos
        default: return nil
        }
    }
}

private extension CinemaScannedItem {
    init?(indexMedia media: IndexMedia) {
        guard let kind = CinemaLibraryKind(indexValue: media.libraryType) else { return nil }
        let kodiType: KodiMediaType?
        switch kind {
        case .movies: kodiType = .movie
        case .tvShows: kodiType = .episode
        case .personalVideos: kodiType = nil
        }
        let metadata = kodiType.map { type in
            KodiMetadata(
                mediaType: type,
                title: media.title,
                originalTitle: media.metadata?.originalTitle,
                sortTitle: media.metadata?.sortTitle,
                plot: media.metadata?.plot,
                year: media.metadata?.year.flatMap(Int.init),
                premiered: media.metadata?.premiered,
                runtimeMinutes: media.metadata?.runtimeMinutes.flatMap(Int.init),
                rating: nil,
                genres: media.metadata?.genres ?? [],
                studio: media.metadata?.studio,
                season: media.metadata?.season.flatMap(Int.init),
                episode: media.metadata?.episode.flatMap(Int.init),
                uniqueIDs: media.metadata?.uniqueIDs ?? [:]
            )
        }
        self.init(
            id: media.id,
            libraryKind: kind,
            folderPath: media.parentPath,
            videoPath: media.synologyPath,
            nfoPath: nil,
            posterPath: kind == .tvShows ? media.preferredEpisodeArtworkPath : media.posterPath,
            fanartPath: media.fanartPath,
            metadata: metadata,
            sourceModifiedAt: media.modifiedAt,
            sourceCreatedAt: media.createdAt,
            sourceSignature: nil
        )
    }


    init(indexShowFolder folder: String, sample: IndexMedia) {
        let title = URL(fileURLWithPath: folder).lastPathComponent
        self.init(
            id: "index-show:\(folder)",
            libraryKind: .tvShows,
            folderPath: folder,
            videoPath: nil,
            nfoPath: nil,
            posterPath: sample.posterPath,
            fanartPath: sample.fanartPath,
            metadata: KodiMetadata(
                mediaType: .tvShow,
                title: title,
                originalTitle: nil,
                sortTitle: nil,
                plot: nil,
                year: nil,
                premiered: nil,
                runtimeMinutes: nil,
                rating: nil,
                genres: [],
                studio: nil,
                season: nil,
                episode: nil,
                uniqueIDs: [:]
            ),
            sourceModifiedAt: sample.modifiedAt,
            sourceCreatedAt: nil,
            sourceSignature: nil
        )
    }
}

private extension IndexMedia {
    var preferredEpisodeArtworkPath: String? {
        [thumbnailPath, seasonPosterPath, posterPath]
            .compactMap { path in
                guard let path, !path.isEmpty else { return nil }
                return path
            }
            .first
    }
}

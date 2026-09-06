import Foundation

struct CinemaScannedItem: Codable, Identifiable, Equatable {
    let id: String
    let libraryKind: CinemaLibraryKind
    let folderPath: String
    let videoPath: String?
    let nfoPath: String?
    let posterPath: String?
    let fanartPath: String?
    let metadata: KodiMetadata?
    let sourceModifiedAt: Date?
    let sourceSignature: String?

    var deduplicationKey: String {
        if let videoPath {
            return "\(libraryKind.rawValue):video:\(videoPath)"
        }
        if metadata?.mediaType == .tvShow {
            return "\(libraryKind.rawValue):show:\(folderPath)"
        }
        return "\(libraryKind.rawValue):item:\(id)"
    }

    var displaySortTitle: String {
        let sortTitle = metadata?.sortTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return sortTitle.isEmpty ? displayTitle : sortTitle
    }

    var displayTitle: String {
        let title = metadata?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty {
            return title
        }
        guard let videoPath else {
            return URL(fileURLWithPath: folderPath).lastPathComponent
        }
        return URL(fileURLWithPath: videoPath).deletingPathExtension().lastPathComponent
    }

    var shouldAppearInLibrary: Bool {
        metadata?.mediaType == .tvShow || videoPath != nil
    }
}

struct CinemaLibraryScanner {
    typealias FolderLoader = (String) async throws -> [SynologyFileItem]
    typealias DataLoader = (String) async throws -> Data

    private let loadFolder: FolderLoader
    private let loadData: DataLoader
    private let nfoParser = KodiNFOParser()

    init(
        loadFolder: @escaping FolderLoader,
        loadData: @escaping DataLoader
    ) {
        self.loadFolder = loadFolder
        self.loadData = loadData
    }

    func scan(
        _ libraries: [CinemaLibraryFolder],
        cachedItems: [CinemaScannedItem] = []
    ) async throws -> [CinemaScannedItem] {
        var scannedItems: [CinemaScannedItem] = []
        let cachedItemsByID = Dictionary(uniqueKeysWithValues: cachedItems.map { ($0.id, $0) })

        for library in libraries {
            try Task.checkCancellation()
            scannedItems.append(contentsOf: try await scanFolder(
                library.path,
                kind: library.kind,
                cachedItemsByID: cachedItemsByID
            ))
        }

        return Dictionary(grouping: scannedItems.filter(\.shouldAppearInLibrary), by: \.deduplicationKey)
            .compactMap { preferredItem(from: $0.value) }
            .sorted {
                $0.displaySortTitle.localizedStandardCompare($1.displaySortTitle) == .orderedAscending
            }
    }

    private func preferredItem(from items: [CinemaScannedItem]) -> CinemaScannedItem? {
        items.max { lhs, rhs in
            qualityScore(for: lhs) < qualityScore(for: rhs)
        }
    }

    private func qualityScore(for item: CinemaScannedItem) -> Int {
        var score = 0
        if !(item.metadata?.title.isEmpty ?? true) { score += 4 }
        if item.posterPath != nil { score += 2 }
        if item.fanartPath != nil { score += 1 }
        return score
    }

    private func scanFolder(
        _ path: String,
        kind: CinemaLibraryKind,
        cachedItemsByID: [String: CinemaScannedItem]
    ) async throws -> [CinemaScannedItem] {
        try Task.checkCancellation()
        let items = try await loadFolder(path)
        let files = items.filter { !$0.isDirectory }
        var results = try await scannedItems(
            in: path,
            files: files,
            kind: kind,
            cachedItemsByID: cachedItemsByID
        )

        for directory in items where directory.isDirectory {
            results.append(contentsOf: try await scanFolder(
                directory.path,
                kind: kind,
                cachedItemsByID: cachedItemsByID
            ))
        }

        return results
    }

    private func scannedItems(
        in folderPath: String,
        files: [SynologyFileItem],
        kind: CinemaLibraryKind,
        cachedItemsByID: [String: CinemaScannedItem]
    ) async throws -> [CinemaScannedItem] {
        if kind == .personalVideos {
            return files.filter(\.isVideo).map {
                CinemaScannedItem(
                    id: $0.path,
                    libraryKind: kind,
                    folderPath: folderPath,
                    videoPath: $0.path,
                    nfoPath: nil,
                    posterPath: nil,
                    fanartPath: nil,
                    metadata: nil,
                    sourceModifiedAt: $0.modifiedTime,
                    sourceSignature: signature(for: [$0])
                )
            }
        }

        let videoFiles = files.filter(\.isVideo)
        let imageFiles = files.filter(\.isImage)
        let nfoFiles = files.filter { URL(fileURLWithPath: $0.name).pathExtension.lowercased() == "nfo" }
        var results: [CinemaScannedItem] = []

        for nfoFile in nfoFiles {
            try Task.checkCancellation()
            let baseName = URL(fileURLWithPath: nfoFile.name).deletingPathExtension().lastPathComponent
            let exactlyMatchingVideo = videoFiles.first {
                URL(fileURLWithPath: $0.name).deletingPathExtension().lastPathComponent
                    .localizedCaseInsensitiveCompare(baseName) == .orderedSame
            }
            let currentSignature = signature(for: [nfoFile] + videoFiles + imageFiles)

            if let cachedItem = cachedItemsByID[nfoFile.path],
               cachedItem.libraryKind == kind,
               cachedItem.sourceSignature == currentSignature,
               cachedItem.shouldAppearInLibrary {
                results.append(cachedItem)
                continue
            }

            guard let data = try? await loadData(nfoFile.path),
                  let metadata = try? nfoParser.parse(data) else {
                continue
            }

            let matchingVideo = exactlyMatchingVideo ?? (metadata.mediaType == .movie ? videoFiles.first : nil)
            results.append(
                CinemaScannedItem(
                    id: nfoFile.path,
                    libraryKind: kind,
                    folderPath: folderPath,
                    videoPath: matchingVideo?.path,
                    nfoPath: nfoFile.path,
                    posterPath: artworkPath(named: "poster", baseName: baseName, in: imageFiles),
                    fanartPath: artworkPath(named: "fanart", baseName: baseName, in: imageFiles),
                    metadata: metadata,
                    sourceModifiedAt: sourceModifiedAt(for: nfoFile, video: matchingVideo, images: imageFiles),
                    sourceSignature: currentSignature
                )
            )
        }

        return results
    }

    private func sourceModifiedAt(
        for nfoFile: SynologyFileItem,
        video: SynologyFileItem?,
        images: [SynologyFileItem]
    ) -> Date? {
        ([nfoFile] + [video].compactMap { $0 } + images)
            .compactMap(\.modifiedTime)
            .max()
    }

    private func signature(for files: [SynologyFileItem]) -> String {
        files
            .map {
                "\($0.path)|\($0.size ?? -1)|\($0.modifiedTime?.timeIntervalSince1970 ?? -1)"
            }
            .sorted()
            .joined(separator: "\n")
    }

    private func artworkPath(
        named artworkName: String,
        baseName: String,
        in images: [SynologyFileItem]
    ) -> String? {
        let preferredNames = [
            artworkName,
            "\(baseName)-\(artworkName)",
            "\(baseName).\(artworkName)"
        ]

        return images.first { image in
            let imageBaseName = URL(fileURLWithPath: image.name)
                .deletingPathExtension()
                .lastPathComponent
                .lowercased()
            return preferredNames.contains { imageBaseName == $0.lowercased() }
        }?.path
    }
}

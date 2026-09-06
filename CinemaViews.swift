import SwiftUI

private enum CinemaPage: String, CaseIterable, Identifiable {
    case movies
    case tvShows
    case personalVideos
    case playlist

    var id: Self { self }

    var title: String {
        switch self {
        case .movies: return "电影"
        case .tvShows: return "剧集"
        case .personalVideos: return "视频"
        case .playlist: return "播放列表"
        }
    }
}

struct CinemaHomeView: View {
    let folders: [CinemaLibraryFolder]
    let serverURLString: String
    let account: String
    let isActive: Bool
    @Binding var isScanning: Bool
    let manualSyncToken: UUID
    let scanAction: ([CinemaLibraryFolder], [CinemaScannedItem]) async throws -> [CinemaScannedItem]
    let artworkURLAction: (String?) -> URL?
    let thumbnailURLAction: (String?) -> URL?
    let playAction: (CinemaScannedItem) -> Void
    let playbackProgressAction: (String?) -> TimeInterval
    let playbackDurationAction: (String?) -> TimeInterval
    let clearPlaybackProgressAction: (String?) -> Void
    let viewingStateRevision: Int

    @State private var selectedPage = CinemaPage.movies
    @State private var items: [CinemaScannedItem] = []
    @State private var viewingStates: [String: CinemaViewingState] = [:]
    @State private var errorMessage: String?

    var body: some View {
        List {
            if !folders.isEmpty {
                Section {
                    Picker("影院分类", selection: $selectedPage) {
                        ForEach(CinemaPage.allCases) { page in
                            Text(page.title).tag(page)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            cinemaContent
        }
        .listStyle(.insetGrouped)
        .task(id: CinemaScanRequest(folders: folders, isActive: isActive)) {
            guard isActive else { return }
            loadLocalState()
            await scan()
        }
        .onChange(of: manualSyncToken) {
            Task { await scan() }
        }
        .onChange(of: viewingStateRevision) {
            loadViewingStates()
        }
        .onAppear {
            if isActive {
                loadViewingStates()
            }
        }
        .onChange(of: isActive) {
            if isActive {
                loadViewingStates()
            }
        }
    }

    @ViewBuilder
    private var cinemaContent: some View {
        if folders.isEmpty {
            ContentUnavailableView(
                "尚未配置影院资料库",
                systemImage: "film.stack",
                description: Text("请前往设置，添加电影、电视剧或个人视频文件夹。")
            )
        } else if let errorMessage, items.isEmpty {
            ContentUnavailableView(
                "扫描失败",
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage)
            )
        } else if items.isEmpty {
            ContentUnavailableView(
                "没有找到媒体",
                systemImage: "film",
                description: Text("请检查资料库目录和 NFO 文件后同步。")
            )
        } else {
            switch selectedPage {
            case .movies:
                mediaSection(title: "电影", items: movieItems)
            case .tvShows:
                tvShowContent
            case .personalVideos:
                personalVideoContent
            case .playlist:
                playlistContent
            }
        }
    }

    private var playlistContent: some View {
        Section("播放列表") {
            NavigationLink {
                CinemaFavoritesView(
                    items: favoriteItems,
                    posterURLAction: mediaPosterURL,
                    playAction: playAction,
                    stateAction: viewingState,
                    progressAction: playbackProgressAction,
                    durationAction: playbackDurationAction,
                    favoriteAction: toggleFavorite,
                    watchedAction: toggleWatched
                )
            } label: {
                HStack {
                    Label("收藏夹", systemImage: "star.fill")
                    Spacer()
                    Text("\(favoriteItems.count)")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var tvShowContent: some View {
        let groups = tvShowGroups
        if groups.isEmpty {
            ContentUnavailableView("没有电视剧", systemImage: "tv")
        } else {
            Section("电视剧") {
                ForEach(groups) { group in
                    NavigationLink {
                        TVShowDetailView(
                            group: group,
                            artworkURLAction: artworkURLAction,
                            playAction: playAction,
                            stateAction: viewingState,
                            progressAction: playbackProgressAction,
                            durationAction: playbackDurationAction,
                            favoriteAction: toggleFavorite,
                            watchedAction: toggleWatched,
                            allEpisodesWatchedAction: { isWatched in
                                setWatched(group.episodes, isWatched: isWatched)
                            }
                        )
                    } label: {
                        CinemaMediaRow(
                            item: group.show,
                            posterURL: artworkURLAction(group.show.posterPath),
                            viewingState: tvShowViewingState(for: group),
                            progress: tvShowIsInProgress(group) ? 2 : 0,
                            duration: 0
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var personalVideoContent: some View {
        let roots = folders.filter { $0.kind == .personalVideos }
        if roots.isEmpty {
            ContentUnavailableView("没有个人视频文件夹", systemImage: "folder")
        } else {
            Section("个人视频文件夹") {
                ForEach(roots) { folder in
                    NavigationLink {
                        PersonalVideoFolderView(
                            folderPath: folder.path,
                            items: personalVideoItems,
                            artworkURLAction: artworkURLAction,
                            thumbnailURLAction: thumbnailURLAction,
                            playAction: playAction,
                            stateAction: viewingState,
                            progressAction: playbackProgressAction,
                            durationAction: playbackDurationAction,
                            favoriteAction: toggleFavorite,
                            watchedAction: toggleWatched
                        )
                    } label: {
                        Label(folder.displayName, systemImage: "folder.fill")
                    }
                }
            }
        }
    }

    private func mediaSection(title: String, items: [CinemaScannedItem]) -> some View {
        Section(title) {
            ForEach(items) { item in
                NavigationLink {
                    CinemaMediaDetailView(
                        item: item,
                        posterURL: mediaPosterURL(for: item),
                        viewingState: viewingState(for: item),
                        playbackDuration: playbackDurationAction(item.videoPath),
                        playAction: { playAction(item) },
                        favoriteAction: { toggleFavorite(item) },
                        watchedAction: { toggleWatched(item) }
                    )
                } label: {
                    CinemaMediaRow(
                        item: item,
                        posterURL: mediaPosterURL(for: item),
                        viewingState: viewingState(for: item),
                        progress: playbackProgressAction(item.videoPath),
                        duration: playbackDurationAction(item.videoPath)
                    )
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button {
                        toggleWatched(item)
                    } label: {
                        Label(
                            viewingState(for: item).isWatched ? "未观看" : "已观看",
                            systemImage: viewingState(for: item).isWatched ? "eye.slash" : "eye"
                        )
                    }
                    .tint(.green)

                    Button {
                        toggleFavorite(item)
                    } label: {
                        Label(
                            viewingState(for: item).isFavorite ? "取消收藏" : "收藏",
                            systemImage: viewingState(for: item).isFavorite ? "star.slash" : "star"
                        )
                    }
                    .tint(.orange)
                }
                .contextMenu {
                    Button {
                        toggleFavorite(item)
                    } label: {
                        Label(
                            viewingState(for: item).isFavorite ? "取消收藏" : "收藏",
                            systemImage: viewingState(for: item).isFavorite ? "star.slash" : "star"
                        )
                    }

                    Button {
                        toggleWatched(item)
                    } label: {
                        Label(
                            viewingState(for: item).isWatched ? "标记为未观看" : "标记为已观看",
                            systemImage: viewingState(for: item).isWatched ? "eye.slash" : "eye"
                        )
                    }
                }
            }
        }
    }

    private func mediaPosterURL(for item: CinemaScannedItem) -> URL? {
        if item.libraryKind == .personalVideos {
            return thumbnailURLAction(item.videoPath)
        }
        return artworkURLAction(item.posterPath)
    }

    private var movieItems: [CinemaScannedItem] {
        items
            .filter { $0.libraryKind == .movies && $0.metadata?.mediaType != .tvShow }
            .sorted(by: mediaSort)
    }

    private var personalVideoItems: [CinemaScannedItem] {
        items.filter { $0.libraryKind == .personalVideos }
    }

    private var favoriteItems: [CinemaScannedItem] {
        items.filter { viewingState(for: $0).isFavorite }
    }

    private var tvShowGroups: [TVShowGroup] {
        let shows = items.filter {
            $0.libraryKind == .tvShows && $0.metadata?.mediaType == .tvShow
        }
        let episodes = items.filter {
            $0.libraryKind == .tvShows && $0.metadata?.mediaType == .episode
        }

        return shows
            .map { show in
                TVShowGroup(
                    show: show,
                    episodes: episodes.filter {
                        $0.folderPath == show.folderPath ||
                        $0.folderPath.hasPrefix(show.folderPath + "/")
                    }
                )
            }
            .sorted { mediaSort($0.show, $1.show) }
    }

    private func mediaSort(_ lhs: CinemaScannedItem, _ rhs: CinemaScannedItem) -> Bool {
        let comparison = lhs.displaySortTitle.localizedStandardCompare(rhs.displaySortTitle)
        if comparison == .orderedSame {
            return (lhs.videoPath ?? lhs.id) < (rhs.videoPath ?? rhs.id)
        }
        return comparison == .orderedAscending
    }

    private func viewingState(for item: CinemaScannedItem) -> CinemaViewingState {
        viewingStates[item.videoPath ?? item.id] ?? CinemaViewingState()
    }

    private func tvShowViewingState(for group: TVShowGroup) -> CinemaViewingState {
        var state = viewingState(for: group.show)
        state.isWatched = !group.episodes.isEmpty && group.episodes.allSatisfy {
            viewingState(for: $0).isWatched
        }
        return state
    }

    private func tvShowIsInProgress(_ group: TVShowGroup) -> Bool {
        guard !tvShowViewingState(for: group).isWatched else { return false }
        return group.episodes.contains { episode in
            viewingState(for: episode).isWatched || playbackProgressAction(episode.videoPath) > 1
        }
    }

    private func toggleFavorite(_ item: CinemaScannedItem) {
        updateViewingState(for: item) { $0.isFavorite.toggle() }
    }

    private func toggleWatched(_ item: CinemaScannedItem) {
        let willBeWatched = !viewingState(for: item).isWatched
        updateViewingState(for: item) { $0.isWatched = willBeWatched }
        if willBeWatched {
            clearPlaybackProgressAction(item.videoPath)
        }
    }

    private func setWatched(_ items: [CinemaScannedItem], isWatched: Bool) {
        for item in items {
            let key = item.videoPath ?? item.id
            var state = viewingStates[key] ?? CinemaViewingState()
            state.isWatched = isWatched
            viewingStates[key] = state

            if isWatched {
                clearPlaybackProgressAction(item.videoPath)
            }
        }

        CinemaViewingStateStore().save(
            viewingStates,
            serverURLString: serverURLString,
            account: account
        )
    }

    private func updateViewingState(
        for item: CinemaScannedItem,
        mutation: (inout CinemaViewingState) -> Void
    ) {
        let key = item.videoPath ?? item.id
        var state = viewingStates[key] ?? CinemaViewingState()
        mutation(&state)
        viewingStates[key] = state
        CinemaViewingStateStore().save(
            viewingStates,
            serverURLString: serverURLString,
            account: account
        )
    }

    private func loadLocalState() {
        if let cache = CinemaLibraryCacheStore().load(
            serverURLString: serverURLString,
            account: account
        ) {
            let configuredItems = cache.items.filter { cachedItem in
                cachedItem.shouldAppearInLibrary && folders.contains {
                    $0.kind == cachedItem.libraryKind &&
                    (cachedItem.folderPath == $0.path || cachedItem.folderPath.hasPrefix($0.path + "/"))
                }
            }
            items = Dictionary(grouping: configuredItems, by: \.deduplicationKey)
                .compactMap { $0.value.first }
        }
        loadViewingStates()
    }

    private func loadViewingStates() {
        viewingStates = CinemaViewingStateStore().load(
            serverURLString: serverURLString,
            account: account
        )
    }

    private func scan() async {
        guard !isScanning else { return }
        guard !folders.isEmpty else {
            items = []
            return
        }

        isScanning = true
        errorMessage = nil
        defer { isScanning = false }

        do {
            let scannedItems = try await scanAction(folders, items)
            items = scannedItems
            CinemaLibraryCacheStore().save(
                scannedItems,
                serverURLString: serverURLString,
                account: account
            )
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct CinemaMediaRow: View {
    let item: CinemaScannedItem
    let posterURL: URL?
    let viewingState: CinemaViewingState
    let progress: TimeInterval
    let duration: TimeInterval

    var body: some View {
        HStack(spacing: 12) {
            poster
                .frame(width: 58, height: 82)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(displayTitle)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if viewingState.isFavorite {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                    }
                }

                if viewingState.isWatched {
                    Label("已观看", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }

                if let year = item.metadata?.year {
                    Text(String(year))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if isInProgress {
                    Label("观看中", systemImage: "play.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }

                if let plot = item.metadata?.plot, !plot.isEmpty {
                    Text(plot)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            if item.videoPath != nil {
                Image(systemName: "play.circle.fill")
                    .foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private var isInProgress: Bool {
        progress > 1 && (duration <= 0 || progress < duration - 20)
    }

    private var displayTitle: String {
        guard item.metadata?.mediaType == .episode,
              let episode = item.metadata?.episode else {
            return item.displayTitle
        }
        return "第 \(episode) 集 · \(item.displayTitle)"
    }

    @ViewBuilder
    private var poster: some View {
        if let posterURL {
            AsyncImage(url: posterURL) { phase in
                if case let .success(image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    posterPlaceholder
                }
            }
        } else {
            posterPlaceholder
        }
    }

    private var posterPlaceholder: some View {
        ZStack {
            Color(.tertiarySystemGroupedBackground)
            Image(systemName: item.libraryKind.systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct CinemaMediaDetailView: View {
    let item: CinemaScannedItem
    let posterURL: URL?
    let viewingState: CinemaViewingState
    let playbackDuration: TimeInterval
    let playAction: () -> Void
    let favoriteAction: () -> Void
    let watchedAction: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                CinemaMediaDetailHeader(
                    title: item.displayTitle,
                    mediaType: item.metadata?.mediaType,
                    season: item.metadata?.season,
                    episode: item.metadata?.episode,
                    posterURL: posterURL,
                    placeholderSystemImage: item.libraryKind.systemImage,
                    year: item.metadata?.year,
                    runtimeMinutes: runtimeMinutes,
                    rating: item.metadata?.rating,
                    genres: item.metadata?.genres ?? [],
                    studio: item.metadata?.studio
                )

                CinemaMediaDetailActions(
                    canPlay: item.videoPath != nil,
                    isFavorite: viewingState.isFavorite,
                    isWatched: viewingState.isWatched,
                    playAction: playAction,
                    favoriteAction: favoriteAction,
                    watchedAction: watchedAction
                )

                CinemaMediaDescription(plot: item.metadata?.plot)
            }
            .padding()
        }
        .navigationTitle(item.metadata?.mediaType == .episode ? "剧集详情" : "电影详情")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var runtimeMinutes: Int? {
        if let runtime = item.metadata?.runtimeMinutes, runtime > 0 {
            return runtime
        }
        guard playbackDuration > 0 else { return nil }
        return max(1, Int((playbackDuration / 60).rounded()))
    }
}

private struct CinemaMediaDetailHeader: View {
    let title: String
    let mediaType: KodiMediaType?
    let season: Int?
    let episode: Int?
    let posterURL: URL?
    let placeholderSystemImage: String
    let year: Int?
    let runtimeMinutes: Int?
    let rating: Double?
    let genres: [String]
    let studio: String?

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            CinemaMediaDetailPoster(
                posterURL: posterURL,
                placeholderSystemImage: placeholderSystemImage
            )

            VStack(alignment: .leading, spacing: 9) {
                Text(title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)

                if mediaType == .episode, let season, let episode {
                    Label("第 \(season) 季 · 第 \(episode) 集", systemImage: "tv")
                }

                if let year {
                    Label("\(year) 年", systemImage: "calendar")
                }

                if let runtimeMinutes {
                    Label("\(runtimeMinutes) 分钟", systemImage: "clock")
                }

                if let rating, rating > 0 {
                    Label(rating.formatted(.number.precision(.fractionLength(1))), systemImage: "star.fill")
                }

                if !genres.isEmpty {
                    Text(genres.formatted())
                }

                if let studio, !studio.isEmpty {
                    Text(studio)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct CinemaMediaDetailPoster: View {
    let posterURL: URL?
    let placeholderSystemImage: String

    var body: some View {
        Group {
            if let posterURL {
                AsyncImage(url: posterURL) { phase in
                    if case let .success(image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 124, height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var placeholder: some View {
        ZStack {
            Color(.tertiarySystemGroupedBackground)
            Image(systemName: placeholderSystemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
        }
    }
}

private struct CinemaMediaDetailActions: View {
    let canPlay: Bool
    let isFavorite: Bool
    let isWatched: Bool
    let playAction: () -> Void
    let favoriteAction: () -> Void
    let watchedAction: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Button(action: playAction) {
                Label("播放", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canPlay)

            HStack(spacing: 12) {
                Button(action: favoriteAction) {
                    Label(isFavorite ? "取消收藏" : "收藏", systemImage: isFavorite ? "star.fill" : "star")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(action: watchedAction) {
                    Label(isWatched ? "标记未观看" : "标记已观看", systemImage: isWatched ? "eye.slash" : "eye")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

private struct CinemaMediaDescription: View {
    let plot: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("简介")
                .font(.headline)
            Text(descriptionText)
                .font(.body)
                .foregroundStyle(plotIsEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var plotIsEmpty: Bool {
        plot?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    }

    private var descriptionText: String {
        guard let plot, !plot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "暂无简介"
        }
        return plot
    }
}

private struct CinemaFavoritesView: View {
    let items: [CinemaScannedItem]
    let posterURLAction: (CinemaScannedItem) -> URL?
    let playAction: (CinemaScannedItem) -> Void
    let stateAction: (CinemaScannedItem) -> CinemaViewingState
    let progressAction: (String?) -> TimeInterval
    let durationAction: (String?) -> TimeInterval
    let favoriteAction: (CinemaScannedItem) -> Void
    let watchedAction: (CinemaScannedItem) -> Void

    var body: some View {
        List {
            if items.isEmpty {
                ContentUnavailableView(
                    "还没有收藏",
                    systemImage: "star",
                    description: Text("在电影、剧集或个人视频中左滑或长按即可收藏。")
                )
            } else {
                ForEach(items) { item in
                    Group {
                        if item.libraryKind == .personalVideos {
                            Button {
                                playAction(item)
                            } label: {
                                mediaRow(for: item)
                            }
                            .buttonStyle(.plain)
                            .disabled(item.videoPath == nil)
                        } else {
                            NavigationLink {
                                CinemaMediaDetailView(
                                    item: item,
                                    posterURL: posterURLAction(item),
                                    viewingState: stateAction(item),
                                    playbackDuration: durationAction(item.videoPath),
                                    playAction: { playAction(item) },
                                    favoriteAction: { favoriteAction(item) },
                                    watchedAction: { watchedAction(item) }
                                )
                            } label: {
                                mediaRow(for: item)
                            }
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            watchedAction(item)
                        } label: {
                            Label(
                                stateAction(item).isWatched ? "未观看" : "已观看",
                                systemImage: stateAction(item).isWatched ? "eye.slash" : "eye"
                            )
                        }
                        .tint(.green)

                        Button {
                            favoriteAction(item)
                        } label: {
                            Label("取消收藏", systemImage: "star.slash")
                        }
                        .tint(.orange)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("收藏夹")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func mediaRow(for item: CinemaScannedItem) -> some View {
        CinemaMediaRow(
            item: item,
            posterURL: posterURLAction(item),
            viewingState: stateAction(item),
            progress: progressAction(item.videoPath),
            duration: durationAction(item.videoPath)
        )
    }
}

private struct PersonalVideoFolderView: View {
    let folderPath: String
    let items: [CinemaScannedItem]
    let artworkURLAction: (String?) -> URL?
    let thumbnailURLAction: (String?) -> URL?
    let playAction: (CinemaScannedItem) -> Void
    let stateAction: (CinemaScannedItem) -> CinemaViewingState
    let progressAction: (String?) -> TimeInterval
    let durationAction: (String?) -> TimeInterval
    let favoriteAction: (CinemaScannedItem) -> Void
    let watchedAction: (CinemaScannedItem) -> Void

    var body: some View {
        List {
            if !childFolderPaths.isEmpty {
                Section("文件夹") {
                    ForEach(childFolderPaths, id: \.self) { childPath in
                        NavigationLink {
                            PersonalVideoFolderView(
                                folderPath: childPath,
                                items: items,
                                artworkURLAction: artworkURLAction,
                                thumbnailURLAction: thumbnailURLAction,
                                playAction: playAction,
                                stateAction: stateAction,
                                progressAction: progressAction,
                                durationAction: durationAction,
                                favoriteAction: favoriteAction,
                                watchedAction: watchedAction
                            )
                        } label: {
                            Label(
                                URL(fileURLWithPath: childPath).lastPathComponent,
                                systemImage: "folder.fill"
                            )
                        }
                    }
                }
            }

            if !directVideos.isEmpty {
                Section("视频") {
                    ForEach(directVideos) { item in
                        Button {
                            playAction(item)
                        } label: {
                            CinemaMediaRow(
                                item: item,
                                posterURL: thumbnailURLAction(item.videoPath),
                                viewingState: stateAction(item),
                                progress: progressAction(item.videoPath),
                                duration: durationAction(item.videoPath)
                            )
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                watchedAction(item)
                            } label: {
                                Label(
                                    stateAction(item).isWatched ? "未观看" : "已观看",
                                    systemImage: stateAction(item).isWatched ? "eye.slash" : "eye"
                                )
                            }
                            .tint(.green)

                            Button {
                                favoriteAction(item)
                            } label: {
                                Label(
                                    stateAction(item).isFavorite ? "取消收藏" : "收藏",
                                    systemImage: stateAction(item).isFavorite ? "star.slash" : "star"
                                )
                            }
                            .tint(.orange)
                        }
                    }
                }
            }

            if childFolderPaths.isEmpty && directVideos.isEmpty {
                ContentUnavailableView("此文件夹没有视频", systemImage: "video")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(URL(fileURLWithPath: folderPath).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var directVideos: [CinemaScannedItem] {
        items
            .filter { $0.folderPath == folderPath }
            .sorted {
                $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending
            }
    }

    private var childFolderPaths: [String] {
        let prefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
        let paths = items.compactMap { item -> String? in
            guard item.folderPath.hasPrefix(prefix), item.folderPath != folderPath else {
                return nil
            }
            let relativePath = String(item.folderPath.dropFirst(prefix.count))
            guard let firstComponent = relativePath.split(separator: "/").first else {
                return nil
            }
            return prefix + firstComponent
        }
        return Array(Set(paths)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }
}

private struct TVShowGroup: Identifiable {
    let show: CinemaScannedItem
    let episodes: [CinemaScannedItem]
    var id: String { show.id }
}

private struct TVShowDetailView: View {
    let group: TVShowGroup
    let artworkURLAction: (String?) -> URL?
    let playAction: (CinemaScannedItem) -> Void
    let stateAction: (CinemaScannedItem) -> CinemaViewingState
    let progressAction: (String?) -> TimeInterval
    let durationAction: (String?) -> TimeInterval
    let favoriteAction: (CinemaScannedItem) -> Void
    let watchedAction: (CinemaScannedItem) -> Void
    let allEpisodesWatchedAction: (Bool) -> Void

    var body: some View {
        List {
            Section {
                Button {
                    allEpisodesWatchedAction(!allEpisodesAreWatched)
                } label: {
                    Label(
                        allEpisodesAreWatched ? "全剧标记为未观看" : "全剧标记为已观看",
                        systemImage: allEpisodesAreWatched ? "eye.slash" : "checkmark.circle"
                    )
                }
                .disabled(group.episodes.isEmpty)
            }

            ForEach(seasons, id: \.self) { season in
                Section(season == 0 ? "特别篇" : "第 \(season) 季") {
                    ForEach(episodes(in: season)) { episode in
                        NavigationLink {
                            CinemaMediaDetailView(
                                item: episode,
                                posterURL: artworkURLAction(episode.posterPath ?? group.show.posterPath),
                                viewingState: stateAction(episode),
                                playbackDuration: durationAction(episode.videoPath),
                                playAction: { playAction(episode) },
                                favoriteAction: { favoriteAction(episode) },
                                watchedAction: { watchedAction(episode) }
                            )
                        } label: {
                            CinemaMediaRow(
                                item: episode,
                                posterURL: artworkURLAction(episode.posterPath ?? group.show.posterPath),
                                viewingState: stateAction(episode),
                                progress: progressAction(episode.videoPath),
                                duration: durationAction(episode.videoPath)
                            )
                        }
                        .contextMenu {
                            Button { favoriteAction(episode) } label: {
                                Label("切换收藏", systemImage: "star")
                            }
                            Button { watchedAction(episode) } label: {
                                Label("切换观看状态", systemImage: "eye")
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(group.show.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var allEpisodesAreWatched: Bool {
        !group.episodes.isEmpty && group.episodes.allSatisfy { stateAction($0).isWatched }
    }

    private var seasons: [Int] {
        Set(group.episodes.map { $0.metadata?.season ?? 0 }).sorted()
    }

    private func episodes(in season: Int) -> [CinemaScannedItem] {
        group.episodes
            .filter { ($0.metadata?.season ?? 0) == season }
            .sorted { lhs, rhs in
                let lhsEpisode = lhs.metadata?.episode ?? Int.max
                let rhsEpisode = rhs.metadata?.episode ?? Int.max
                if lhsEpisode != rhsEpisode {
                    return lhsEpisode < rhsEpisode
                }

                let titleComparison = lhs.displaySortTitle.localizedStandardCompare(rhs.displaySortTitle)
                if titleComparison != .orderedSame {
                    return titleComparison == .orderedAscending
                }
                return (lhs.videoPath ?? lhs.id) < (rhs.videoPath ?? rhs.id)
            }
    }
}

private struct CinemaScanRequest: Hashable {
    let folders: [CinemaLibraryFolder]
    let isActive: Bool
}

struct CinemaLibrarySettingsView: View {
    @Binding var folders: [CinemaLibraryFolder]

    let serverURLString: String
    let account: String
    let loadFoldersAction: (String) async -> [SynologyFileItem]

    @State private var selectingKind: CinemaLibraryKind?

    var body: some View {
        List {
            ForEach(CinemaLibraryKind.allCases) { kind in
                Section {
                    let configuredFolders = folders.filter { $0.kind == kind }
                    if configuredFolders.isEmpty {
                        Text("尚未添加文件夹")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(configuredFolders) { folder in
                            Label {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(folder.displayName)
                                    Text(folder.path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            } icon: {
                                Image(systemName: kind.systemImage)
                            }
                        }
                        .onDelete { offsets in
                            removeFolders(of: kind, at: offsets)
                        }
                    }

                    Button {
                        selectingKind = kind
                    } label: {
                        Label("添加" + kind.title + "文件夹", systemImage: "plus")
                    }
                } header: {
                    Text(kind.title)
                } footer: {
                    Text(kind.usesKodiMetadata ? "读取目录中已有的 Kodi NFO、海报和背景图。" : "个人视频仅建立视频索引，不读取或刮削 NFO。")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("影院资料库")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectingKind) { kind in
            CinemaFolderPickerView(
                kind: kind,
                loadFoldersAction: loadFoldersAction
            ) { path in
                addFolder(path: path, kind: kind)
                selectingKind = nil
            }
        }
    }

    private func addFolder(path: String, kind: CinemaLibraryKind) {
        let folder = CinemaLibraryFolder(kind: kind, path: path)
        guard !folders.contains(folder) else { return }

        folders.append(folder)
        folders.sort {
            if $0.kind.rawValue == $1.kind.rawValue {
                return $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
            return $0.kind.rawValue < $1.kind.rawValue
        }
        save()
    }

    private func removeFolders(of kind: CinemaLibraryKind, at offsets: IndexSet) {
        let configuredFolders = folders.filter { $0.kind == kind }
        let idsToRemove = Set(offsets.map { configuredFolders[$0].id })
        folders.removeAll { idsToRemove.contains($0.id) }
        save()
    }

    private func save() {
        CinemaLibrarySettingsStore().save(
            folders,
            serverURLString: serverURLString,
            account: account
        )
    }
}

private struct CinemaFolderPickerView: View {
    let kind: CinemaLibraryKind
    let loadFoldersAction: (String) async -> [SynologyFileItem]
    let selectAction: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var currentPath = ""
    @State private var folders: [SynologyFileItem] = []
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if !currentPath.isEmpty {
                        Button {
                            selectAction(currentPath)
                        } label: {
                            Label("选择当前文件夹", systemImage: "checkmark.circle")
                                .font(.headline)
                        }
                    }
                } footer: {
                    Text(kind.usesKodiMetadata ? "此目录及其子目录将按照 Kodi 本地资料结构扫描。" : "此目录及其子目录中的视频会加入个人视频，不进行刮削。")
                }

                Section("文件夹") {
                    if isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    } else if folders.isEmpty {
                        ContentUnavailableView("没有下级文件夹", systemImage: "folder")
                    } else {
                        ForEach(folders) { folder in
                            Button {
                                currentPath = folder.path
                                Task { await loadFolders() }
                            } label: {
                                HStack {
                                    Label(folder.name, systemImage: "folder.fill")
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(currentPath.isEmpty ? "选择" + kind.title + "文件夹" : folderTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        currentPath = parentPath
                        Task { await loadFolders() }
                    } label: {
                        Label("上一级", systemImage: "arrow.up.folder")
                    }
                    .disabled(currentPath.isEmpty || isLoading)
                }
            }
            .task { await loadFolders() }
        }
    }

    private var folderTitle: String {
        URL(fileURLWithPath: currentPath).lastPathComponent
    }

    private var parentPath: String {
        guard !currentPath.isEmpty else { return "" }
        let path = URL(fileURLWithPath: currentPath).deletingLastPathComponent().path
        return path == "/" ? "" : path
    }

    private func loadFolders() async {
        isLoading = true
        defer { isLoading = false }
        folders = await loadFoldersAction(currentPath)
            .filter(\.isDirectory)
    }
}

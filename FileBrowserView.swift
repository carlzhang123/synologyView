import SwiftUI

struct FileBrowserView: View {
    @Binding var currentPath: String
    let serverURLString: String
    let account: String
    let fileItems: [SynologyFileItem]
    let favoriteItems: [SynologyFileItem]
    let favoriteCurrentPath: String
    let favoriteBrowserItems: [SynologyFileItem]
    let isLoading: Bool
    let uploadProgressItems: [UploadProgressItem]
    let canGoUp: Bool
    let canGoBack: Bool
    let canGoFavoriteBack: Bool
    let refreshAction: () async -> Void
    let loadFavoritesAction: () -> Void
    let refreshFavoriteLocationAction: () async -> Void
    let openFolderAction: (SynologyFileItem) -> Void
    let openFavoriteFolderAction: (SynologyFileItem) -> Void
    let previewAction: (SynologyFileItem, [SynologyFileItem]) -> Void
    let thumbnailURLAction: (SynologyFileItem) -> URL?
    let uploadMediaAction: ([SynologyUploadFile], String) async -> Void
    let renameAction: (SynologyFileItem, String) -> Void
    let moveAction: ([SynologyFileItem], String) -> Void
    let deleteAction: ([SynologyFileItem]) -> Void
    let loadMoveDestinationFoldersAction: (String) async -> [SynologyFileItem]
    let loadSearchFoldersAction: (String) async -> [SynologyFileItem]
    let searchAction: (String, [String]) async throws -> [SynologyFileItem]
    let backAction: () -> Void
    let favoriteBackAction: () -> Void
    let upAction: () -> Void
    let favoriteUpAction: () -> Void
    let logoutAction: () -> Void
    let lastMoveDestinationPath: String

    @State private var selectedTab = FileBrowserTab.files
    @State private var isSelectionMode = false
    @State private var selectedItemIDs = Set<String>()
    @State private var renameItem: SynologyFileItem?
    @State private var renameText = ""
    @State private var moveSelection: FileOperationSelection?
    @State private var deleteSelection: FileOperationSelection?
    @AppStorage("synology.fileDisplayMode") private var displayModeRawValue = FileDisplayMode.list.rawValue
    @State private var fileTransitionEdge: Edge = .trailing
    @State private var favoriteTransitionEdge: Edge = .trailing

    var body: some View {
        ZStack(alignment: .leading) {
            TabView(selection: $selectedTab) {
                FileListView(
                    currentPath: currentPath,
                    items: fileItems,
                    isLoading: isLoading,
                    isSelectionMode: isSelectionMode,
                    selectedItemIDs: $selectedItemIDs,
                    displayMode: displayMode,
                    transitionEdge: fileTransitionEdge,
                    thumbnailURLAction: thumbnailURLAction,
                    refreshAction: refreshAction,
                    openFolderAction: { item in
                        navigateFiles(edge: .trailing) {
                            openFolderAction(item)
                        }
                    },
                    previewAction: previewAction,
                    renameRequestAction: prepareRename,
                    moveRequestAction: { moveSelection = FileOperationSelection(items: [$0]) },
                    deleteRequestAction: { deleteSelection = FileOperationSelection(items: [$0]) }
                )
                .tabItem {
                    Label("文件", systemImage: "folder")
                }
                .tag(FileBrowserTab.files)

                FavoriteListView(
                    currentPath: favoriteCurrentPath,
                    rootItems: favoriteItems,
                    browserItems: favoriteBrowserItems,
                    isLoading: isLoading,
                    isSelectionMode: isSelectionMode,
                    selectedItemIDs: $selectedItemIDs,
                    displayMode: displayMode,
                    transitionEdge: favoriteTransitionEdge,
                    thumbnailURLAction: thumbnailURLAction,
                    refreshAction: refreshFavoriteLocationAction,
                    openFolderAction: { item in
                        navigateFavorites(edge: .trailing) {
                            openFavoriteFolderAction(item)
                        }
                    },
                    previewAction: previewAction,
                    renameRequestAction: prepareRename,
                    moveRequestAction: { moveSelection = FileOperationSelection(items: [$0]) },
                    deleteRequestAction: { deleteSelection = FileOperationSelection(items: [$0]) },
                    loadFavoritesAction: loadFavoritesAction
                )
                .tabItem {
                    Label("收藏夹", systemImage: "star")
                }
                .tag(FileBrowserTab.favorites)

                CinemaPlaceholderView()
                    .tabItem {
                        Label("影院", systemImage: "film")
                    }
                    .tag(FileBrowserTab.cinema)

                SettingsView(
                    serverURLString: serverURLString,
                    account: account,
                    uploadProgressItems: uploadProgressItems,
                    loadSearchFoldersAction: loadSearchFoldersAction,
                    searchAction: searchAction,
                    previewAction: previewAction,
                    logoutAction: logoutAction
                )
                .tabItem {
                    Label("设置", systemImage: "gearshape")
                }
                .tag(FileBrowserTab.settings)
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if isSelectionMode {
                        Button("取消") {
                            clearSelection()
                        }
                    } else if canGoBackInSelectedTab {
                        Button {
                            performBack()
                        } label: {
                            Label("返回", systemImage: "chevron.left")
                        }
                        .disabled(isLoading)
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !isSelectionMode {
                        if supportsFileOperations {
                            PhotoLibraryUploadButton(
                                destinationPath: uploadDestinationPath,
                                isDisabled: isLoading || uploadDestinationPath.isEmpty,
                                uploadAction: uploadMediaAction
                            )

                            Menu {
                                Picker("显示模式", selection: displayModeBinding) {
                                    Label("列表", systemImage: "list.bullet").tag(FileDisplayMode.list)
                                    Label("缩略图", systemImage: "square.grid.2x2").tag(FileDisplayMode.grid)
                                }
                            } label: {
                                Label("显示模式", systemImage: displayMode.iconName)
                            }
                        }

                        if canShowUpButton {
                            Button {
                                if selectedTab == .favorites {
                                    navigateFavorites(edge: .leading, action: favoriteUpAction)
                                } else {
                                    navigateFiles(edge: .leading, action: upAction)
                                }
                            } label: {
                                Label("上一级", systemImage: "arrow.up.folder")
                            }
                            .disabled(isLoading || !canGoUpInSelectedTab)
                        }

                    }

                    if supportsFileOperations {
                        Button(isSelectionMode ? "完成" : "选择") {
                            isSelectionMode ? clearSelection() : beginSelection()
                        }
                        .disabled(isLoading || visibleItems.isEmpty)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if isSelectionMode {
                    SelectionActionBar(
                        selectedCount: selectedItems.count,
                        moveAction: {
                            moveSelection = FileOperationSelection(items: selectedItems)
                        },
                        deleteAction: {
                            deleteSelection = FileOperationSelection(items: selectedItems)
                        }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }

        }
        .onChange(of: selectedTab) {
            clearSelection()
        }
        .simultaneousGesture(edgeBackGesture)
        .alert("重命名", isPresented: renameDialogBinding) {
            TextField("新文件名", text: $renameText)
                .autocorrectionDisabled()
            Button("取消", role: .cancel) {
                renameItem = nil
            }
            Button("保存") {
                guard let renameItem else { return }
                renameAction(renameItem, renameText)
                self.renameItem = nil
            }
        } message: {
            Text(renameItem?.name ?? "")
        }
        .sheet(item: $moveSelection) { selection in
            MoveDestinationPickerView(
                itemCount: selection.items.count,
                itemName: selection.displayName,
                initialPath: initialMoveDestinationPath,
                loadFoldersAction: loadMoveDestinationFoldersAction,
                thumbnailURLAction: thumbnailURLAction,
                cancelAction: {
                    moveSelection = nil
                },
                moveAction: { destinationPath in
                    moveAction(selection.items, destinationPath)
                    clearSelection()
                    moveSelection = nil
                }
            )
        }
        .alert("确认删除", isPresented: deleteDialogBinding) {
            Button("取消", role: .cancel) {
                deleteSelection = nil
            }
            Button("删除", role: .destructive) {
                guard let deleteSelection else {
                    return
                }
                deleteAction(deleteSelection.items)
                clearSelection()
            }
        } message: {
            Text("将删除 \(deleteSelection?.displayName ?? "")，此操作会同步到群晖。")
        }
    }

    private var navigationTitle: String {
        switch selectedTab {
        case .files:
            return title(for: currentPath, rootTitle: "文件")
        case .favorites:
            return title(for: favoriteCurrentPath, rootTitle: "收藏夹")
        case .cinema:
            return "影院"
        case .settings:
            return "设置"
        }
    }

    private var displayMode: FileDisplayMode {
        FileDisplayMode(rawValue: displayModeRawValue) ?? .list
    }

    private var displayModeBinding: Binding<FileDisplayMode> {
        Binding {
            displayMode
        } set: { newValue in
            displayModeRawValue = newValue.rawValue
        }
    }

    private var visibleItems: [SynologyFileItem] {
        switch selectedTab {
        case .files:
            return fileItems
        case .favorites:
            return favoriteCurrentPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? favoriteItems : favoriteBrowserItems
        case .cinema, .settings:
            return []
        }
    }

    private var selectedItems: [SynologyFileItem] {
        visibleItems.filter { selectedItemIDs.contains($0.id) }
    }

    private var canShowUpButton: Bool {
        selectedTab == .files || !favoriteCurrentPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canGoUpInSelectedTab: Bool {
        switch selectedTab {
        case .files:
            return canGoUp
        case .favorites:
            return !favoriteCurrentPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .cinema, .settings:
            return false
        }
    }

    private var canGoBackInSelectedTab: Bool {
        switch selectedTab {
        case .files:
            return canGoBack
        case .favorites:
            return canGoFavoriteBack
        case .cinema, .settings:
            return false
        }
    }

    private var supportsFileOperations: Bool {
        selectedTab == .files || selectedTab == .favorites
    }

    private var renameDialogBinding: Binding<Bool> {
        Binding {
            renameItem != nil
        } set: { isPresented in
            if !isPresented {
                renameItem = nil
            }
        }
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding {
            deleteSelection != nil
        } set: { isPresented in
            if !isPresented {
                deleteSelection = nil
            }
        }
    }

    private var uploadDestinationPath: String {
        switch selectedTab {
        case .files:
            return currentPath.trimmingCharacters(in: .whitespacesAndNewlines)
        case .favorites:
            return favoriteCurrentPath.trimmingCharacters(in: .whitespacesAndNewlines)
        case .cinema, .settings:
            return ""
        }
    }

    private var initialMoveDestinationPath: String {
        let rememberedPath = lastMoveDestinationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rememberedPath.isEmpty {
            return rememberedPath
        }

        switch selectedTab {
        case .files:
            return currentPath.trimmingCharacters(in: .whitespacesAndNewlines)
        case .favorites:
            return favoriteCurrentPath.trimmingCharacters(in: .whitespacesAndNewlines)
        case .cinema, .settings:
            return ""
        }
    }

    private func beginSelection() {
        withAnimation(.easeInOut(duration: 0.18)) {
            isSelectionMode = true
            selectedItemIDs = []
        }
    }

    private func clearSelection() {
        withAnimation(.easeInOut(duration: 0.18)) {
            isSelectionMode = false
            selectedItemIDs = []
        }
    }

    private func prepareRename(_ item: SynologyFileItem) {
        renameText = item.name
        renameItem = item
    }

    private var edgeBackGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                guard !isSelectionMode,
                      canGoBackInSelectedTab,
                      value.startLocation.x < 24,
                      value.translation.width > 70,
                      abs(value.translation.width) > abs(value.translation.height) else {
                    return
                }

                performBack()
            }
    }

    private func performBack() {
        if selectedTab == .favorites {
            navigateFavorites(edge: .leading, action: favoriteBackAction)
        } else {
            navigateFiles(edge: .leading, action: backAction)
        }
    }

    private func navigateFiles(edge: Edge, action: () -> Void) {
        fileTransitionEdge = edge
        action()
    }

    private func navigateFavorites(edge: Edge, action: () -> Void) {
        favoriteTransitionEdge = edge
        action()
    }

    private func title(for path: String, rootTitle: String) -> String {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedPath.isEmpty ? rootTitle : URL(fileURLWithPath: trimmedPath).lastPathComponent
    }
}

private enum FileBrowserTab: Hashable {
    case files
    case favorites
    case cinema
    case settings
}

private enum FileDisplayMode: String, Hashable {
    case list
    case grid

    var iconName: String {
        switch self {
        case .list:
            return "list.bullet"
        case .grid:
            return "square.grid.2x2"
        }
    }
}

private struct FileOperationSelection: Identifiable {
    let id = UUID()
    let items: [SynologyFileItem]

    var displayName: String {
        if items.count == 1 {
            return items[0].name
        }

        return "\(items.count) 个项目"
    }
}

private struct FileListView: View {
    let currentPath: String
    let items: [SynologyFileItem]
    let isLoading: Bool
    let isSelectionMode: Bool
    @Binding var selectedItemIDs: Set<String>
    let displayMode: FileDisplayMode
    let transitionEdge: Edge
    let thumbnailURLAction: (SynologyFileItem) -> URL?
    let refreshAction: () async -> Void
    let openFolderAction: (SynologyFileItem) -> Void
    let previewAction: (SynologyFileItem, [SynologyFileItem]) -> Void
    let renameRequestAction: (SynologyFileItem) -> Void
    let moveRequestAction: (SynologyFileItem) -> Void
    let deleteRequestAction: (SynologyFileItem) -> Void

    var body: some View {
        BrowserListView(
            emptyTitle: "没有文件夹或文件",
            sectionTitle: currentPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "共享文件夹" : "文件夹清单",
            contentID: currentPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "files-root" : currentPath,
            transitionEdge: transitionEdge,
            items: items,
            isLoading: isLoading,
            isSelectionMode: isSelectionMode,
            selectedItemIDs: $selectedItemIDs,
            displayMode: displayMode,
            thumbnailURLAction: thumbnailURLAction,
            refreshAction: refreshAction,
            openFolderAction: openFolderAction,
            previewAction: previewAction,
            renameRequestAction: renameRequestAction,
            moveRequestAction: moveRequestAction,
            deleteRequestAction: deleteRequestAction
        )
    }
}

private struct FavoriteListView: View {
    let currentPath: String
    let rootItems: [SynologyFileItem]
    let browserItems: [SynologyFileItem]
    let isLoading: Bool
    let isSelectionMode: Bool
    @Binding var selectedItemIDs: Set<String>
    let displayMode: FileDisplayMode
    let transitionEdge: Edge
    let thumbnailURLAction: (SynologyFileItem) -> URL?
    let refreshAction: () async -> Void
    let openFolderAction: (SynologyFileItem) -> Void
    let previewAction: (SynologyFileItem, [SynologyFileItem]) -> Void
    let renameRequestAction: (SynologyFileItem) -> Void
    let moveRequestAction: (SynologyFileItem) -> Void
    let deleteRequestAction: (SynologyFileItem) -> Void
    let loadFavoritesAction: () -> Void

    private var isRoot: Bool {
        currentPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        BrowserListView(
            emptyTitle: isRoot ? "没有收藏夹" : "没有文件夹或文件",
            sectionTitle: isRoot ? "群晖收藏夹" : "文件夹清单",
            contentID: isRoot ? "favorites-root" : currentPath,
            transitionEdge: transitionEdge,
            items: isRoot ? rootItems : browserItems,
            isLoading: isLoading,
            isSelectionMode: isSelectionMode,
            selectedItemIDs: $selectedItemIDs,
            displayMode: displayMode,
            thumbnailURLAction: thumbnailURLAction,
            refreshAction: refreshAction,
            openFolderAction: openFolderAction,
            previewAction: previewAction,
            renameRequestAction: renameRequestAction,
            moveRequestAction: moveRequestAction,
            deleteRequestAction: deleteRequestAction
        )
        .task {
            if isRoot {
                loadFavoritesAction()
            }
        }
    }
}

private struct BrowserListView: View {
    @State private var thumbnailRefreshToken = UUID()

    let emptyTitle: String
    let sectionTitle: String
    let contentID: String
    let transitionEdge: Edge
    let items: [SynologyFileItem]
    let isLoading: Bool
    let isSelectionMode: Bool
    @Binding var selectedItemIDs: Set<String>
    let displayMode: FileDisplayMode
    let thumbnailURLAction: (SynologyFileItem) -> URL?
    let refreshAction: () async -> Void
    let openFolderAction: (SynologyFileItem) -> Void
    let previewAction: (SynologyFileItem, [SynologyFileItem]) -> Void
    let renameRequestAction: (SynologyFileItem) -> Void
    let moveRequestAction: (SynologyFileItem) -> Void
    let deleteRequestAction: (SynologyFileItem) -> Void

    var body: some View {
        ZStack {
            browserContent
                .id(contentID)
                .transition(.push(from: transitionEdge))
        }
        .clipped()
        .animation(.smooth(duration: 0.32), value: contentID)
        .animation(.easeInOut(duration: 0.18), value: isSelectionMode)
    }

    @ViewBuilder
    private var browserContent: some View {
        switch displayMode {
        case .list:
            listContent
        case .grid:
            gridContent
        }
    }

    private var listContent: some View {
        List {
            if items.isEmpty {
                EmptyFolderSection(title: emptyTitle, isLoading: isLoading)
            } else {
                FileListSection(
                    title: sectionTitle,
                    items: items,
                    isSelectionMode: isSelectionMode,
                    selectedItemIDs: $selectedItemIDs,
                    thumbnailURLAction: refreshedThumbnailURL,
                    openFolderAction: openFolderAction,
                    previewAction: previewAction,
                    renameRequestAction: renameRequestAction,
                    moveRequestAction: moveRequestAction,
                    deleteRequestAction: deleteRequestAction
                )
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await refreshContent()
        }
    }

    private var gridContent: some View {
        ScrollView {
            if items.isEmpty {
                EmptyFolderSection(title: emptyTitle, isLoading: isLoading)
                    .padding(.top, 24)
            } else {
                LazyVGrid(columns: gridColumns, spacing: 12) {
                    ForEach(items) { item in
                        FileThumbnailTile(
                            item: item,
                            thumbnailURL: refreshedThumbnailURL(for: item),
                            isSelected: selectedItemIDs.contains(item.id),
                            isSelectionMode: isSelectionMode,
                            action: {
                                activate(item)
                            }
                        )
                        .contextMenu {
                            fileOperationMenu(for: item)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
        }
        .refreshable {
            await refreshContent()
        }
        .background(Color(.systemGroupedBackground))
    }

    private func refreshContent() async {
        await refreshAction()
        thumbnailRefreshToken = UUID()
    }

    private func refreshedThumbnailURL(for item: SynologyFileItem) -> URL? {
        guard let url = thumbnailURLAction(item),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return thumbnailURLAction(item)
        }

        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "thumbnailRefresh", value: thumbnailRefreshToken.uuidString))
        components.queryItems = queryItems
        return components.url
    }

    private var gridColumns: [GridItem] {
        [
            GridItem(.flexible(minimum: 0), spacing: 12),
            GridItem(.flexible(minimum: 0), spacing: 12),
            GridItem(.flexible(minimum: 0), spacing: 12)
        ]
    }

    private func activate(_ item: SynologyFileItem) {
        if isSelectionMode {
            toggleSelection(for: item)
        } else if item.isDirectory {
            openFolderAction(item)
        } else {
            previewAction(item, items)
        }
    }

    private func toggleSelection(for item: SynologyFileItem) {
        withAnimation(.easeInOut(duration: 0.16)) {
            if selectedItemIDs.contains(item.id) {
                selectedItemIDs.remove(item.id)
            } else {
                selectedItemIDs.insert(item.id)
            }
        }
    }

    @ViewBuilder
    private func fileOperationMenu(for item: SynologyFileItem) -> some View {
        Button {
            renameRequestAction(item)
        } label: {
            Label("重命名", systemImage: "pencil")
        }

        Button {
            moveRequestAction(item)
        } label: {
            Label("移动到", systemImage: "folder")
        }

        Button(role: .destructive) {
            deleteRequestAction(item)
        } label: {
            Label("删除", systemImage: "trash")
        }
    }
}

private struct SelectionActionBar: View {
    let selectedCount: Int
    let moveAction: () -> Void
    let deleteAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("已选择 \(selectedCount) 项")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                moveAction()
            } label: {
                Label("移动", systemImage: "folder")
            }
            .disabled(selectedCount == 0)

            Button(role: .destructive) {
                deleteAction()
            } label: {
                Label("删除", systemImage: "trash")
            }
            .disabled(selectedCount == 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct CinemaPlaceholderView: View {
    var body: some View {
        Color(.systemBackground)
            .ignoresSafeArea()
    }
}

private struct SettingsView: View {
    let serverURLString: String
    let account: String
    let uploadProgressItems: [UploadProgressItem]
    let loadSearchFoldersAction: (String) async -> [SynologyFileItem]
    let searchAction: (String, [String]) async throws -> [SynologyFileItem]
    let previewAction: (SynologyFileItem, [SynologyFileItem]) -> Void
    let logoutAction: () -> Void

    var body: some View {
        List {
            Section("账号") {
                Label(account.isEmpty ? "Synology View" : account, systemImage: "person.crop.circle")
                Label(serverURLString, systemImage: "server.rack")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("搜索") {
                NavigationLink {
                    AdvancedSearchView(
                        loadFoldersAction: loadSearchFoldersAction,
                        searchAction: searchAction,
                        previewAction: previewAction
                    )
                } label: {
                    Label("高级搜索", systemImage: "doc.text.magnifyingglass")
                }
            }

            Section("任务") {
                NavigationLink {
                    UploadProgressListView(items: uploadProgressItems)
                } label: {
                    HStack {
                        Label("上传进度", systemImage: "arrow.up.circle")
                        Spacer()
                        Text(uploadProgressSummary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    logoutAction()
                } label: {
                    Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var uploadProgressSummary: String {
        let activeCount = uploadProgressItems.filter { $0.status == .queued || $0.status == .uploading }.count
        if activeCount > 0 {
            return "\(activeCount) 个进行中"
        }

        return uploadProgressItems.isEmpty ? "无任务" : "\(uploadProgressItems.count) 个任务"
    }
}

private struct UploadProgressListView: View {
    let items: [UploadProgressItem]

    var body: some View {
        List {
            if items.isEmpty {
                ContentUnavailableView("没有上传任务", systemImage: "arrow.up.circle")
            } else {
                ForEach(items) { item in
                    UploadProgressRow(item: item)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("上传进度")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct UploadProgressRow: View {
    let item: UploadProgressItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.fileName)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(item.destinationPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Text(item.progressText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(iconColor)
            }

            if item.status == .uploading || item.status == .queued {
                ProgressView(value: item.progress)
            }

            if let errorMessage = item.errorMessage, item.status == .failed {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    private var iconName: String {
        switch item.status {
        case .queued:
            return "clock"
        case .uploading:
            return "arrow.up.circle"
        case .finished:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch item.status {
        case .queued:
            return .secondary
        case .uploading:
            return .blue
        case .finished:
            return .green
        case .failed:
            return .red
        }
    }
}

private struct EmptyFolderSection: View {
    let title: String
    let isLoading: Bool

    var body: some View {
        Section {
            HStack {
                Spacer()
                if isLoading {
                    ProgressView()
                } else {
                    ContentUnavailableView(title, systemImage: "folder")
                }
                Spacer()
            }
            .padding(.vertical, 24)
        }
    }
}

private struct MoveDestinationPickerView: View {
    let itemCount: Int
    let itemName: String
    let initialPath: String
    let loadFoldersAction: (String) async -> [SynologyFileItem]
    let thumbnailURLAction: (SynologyFileItem) -> URL?
    let cancelAction: () -> Void
    let moveAction: (String) -> Void
    @State private var currentPath: String
    @State private var folders: [SynologyFileItem] = []
    @State private var isLoading = false

    init(
        itemCount: Int,
        itemName: String,
        initialPath: String,
        loadFoldersAction: @escaping (String) async -> [SynologyFileItem],
        thumbnailURLAction: @escaping (SynologyFileItem) -> URL?,
        cancelAction: @escaping () -> Void,
        moveAction: @escaping (String) -> Void
    ) {
        self.itemCount = itemCount
        self.itemName = itemName
        self.initialPath = initialPath
        self.loadFoldersAction = loadFoldersAction
        self.thumbnailURLAction = thumbnailURLAction
        self.cancelAction = cancelAction
        self.moveAction = moveAction
        _currentPath = State(initialValue: initialPath)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(itemCount == 1 ? "移动项目" : "移动多个项目")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(itemName)
                            .font(.headline)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 4)
                }

                Section("目标文件夹") {
                    Button {
                        moveAction(currentPath)
                    } label: {
                        Label("移到这里", systemImage: "folder")
                            .font(.headline)
                    }
                    .disabled(currentPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    } else if folders.isEmpty {
                        ContentUnavailableView("此文件夹为空", systemImage: "folder")
                    } else {
                        ForEach(folders) { item in
                            if item.isDirectory {
                                Button {
                                    currentPath = item.path
                                    Task {
                                        await loadFolders()
                                    }
                                } label: {
                                    destinationRow(for: item)
                                }
                                .buttonStyle(.plain)
                            } else {
                                destinationRow(for: item)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(destinationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        cancelAction()
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        currentPath = parentPath(for: currentPath)
                        Task {
                            await loadFolders()
                        }
                    } label: {
                        Label("上一级", systemImage: "arrow.up.folder")
                    }
                    .disabled(isLoading || currentPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button {
                        Task {
                            await loadFolders()
                        }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
            .task {
                await loadFolders()
            }
        }
    }

    private func destinationRow(for item: SynologyFileItem) -> some View {
        FileRow(
            name: item.name,
            detail: item.detail,
            isDirectory: item.isDirectory,
            isVideo: item.isVideo,
            isImage: item.isImage,
            isPreviewable: item.isPreviewable,
            thumbnailURL: thumbnailURLAction(item),
            isSelected: false,
            isSelectionMode: false,
            showsAccessory: item.isDirectory
        )
        .contentShape(Rectangle())
    }

    private var destinationTitle: String {
        let trimmedPath = currentPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedPath.isEmpty ? "选择共享文件夹" : URL(fileURLWithPath: trimmedPath).lastPathComponent
    }

    private func loadFolders() async {
        isLoading = true
        defer { isLoading = false }
        folders = await loadFoldersAction(currentPath)
    }

    private func parentPath(for path: String) -> String {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty, trimmedPath != "/" else {
            return ""
        }

        let parent = URL(fileURLWithPath: trimmedPath).deletingLastPathComponent().path
        return parent == "/" ? "" : parent
    }
}

private struct FileListSection: View {
    let title: String
    let items: [SynologyFileItem]
    let isSelectionMode: Bool
    @Binding var selectedItemIDs: Set<String>
    let thumbnailURLAction: (SynologyFileItem) -> URL?
    let openFolderAction: (SynologyFileItem) -> Void
    let previewAction: (SynologyFileItem, [SynologyFileItem]) -> Void
    let renameRequestAction: (SynologyFileItem) -> Void
    let moveRequestAction: (SynologyFileItem) -> Void
    let deleteRequestAction: (SynologyFileItem) -> Void

    var body: some View {
        Section(title) {
            ForEach(items) { item in
                Button {
                    if isSelectionMode {
                        toggleSelection(for: item)
                    } else if item.isDirectory {
                        openFolderAction(item)
                    } else {
                        previewAction(item, items)
                    }
                } label: {
                    FileRow(
                        name: item.name,
                        detail: item.detail,
                        isDirectory: item.isDirectory,
                        isVideo: item.isVideo,
                        isImage: item.isImage,
                        isPreviewable: item.isPreviewable,
                        thumbnailURL: thumbnailURLAction(item),
                        isSelected: selectedItemIDs.contains(item.id),
                        isSelectionMode: isSelectionMode,
                        showsAccessory: true
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        deleteRequestAction(item)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }

                    Button {
                        moveRequestAction(item)
                    } label: {
                        Label("移动", systemImage: "folder")
                    }
                    .tint(.indigo)

                    Button {
                        renameRequestAction(item)
                    } label: {
                        Label("重命名", systemImage: "pencil")
                    }
                    .tint(.blue)
                }
                .contextMenu {
                    Button {
                        renameRequestAction(item)
                    } label: {
                        Label("重命名", systemImage: "pencil")
                    }

                    Button {
                        moveRequestAction(item)
                    } label: {
                        Label("移动到", systemImage: "folder")
                    }

                    Button(role: .destructive) {
                        deleteRequestAction(item)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
        }
    }

    private func toggleSelection(for item: SynologyFileItem) {
        withAnimation(.easeInOut(duration: 0.16)) {
            if selectedItemIDs.contains(item.id) {
                selectedItemIDs.remove(item.id)
            } else {
                selectedItemIDs.insert(item.id)
            }
        }
    }
}

private struct FileThumbnailTile: View {
    let item: SynologyFileItem
    let thumbnailURL: URL?
    let isSelected: Bool
    let isSelectionMode: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                GeometryReader { proxy in
                    ZStack(alignment: .topTrailing) {
                        thumbnailContent
                            .frame(width: proxy.size.width, height: proxy.size.width)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                        if isSelectionMode {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(isSelected ? .blue : .white)
                                .shadow(radius: 2)
                                .padding(8)
                        } else if item.isVideo {
                            Image(systemName: "play.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                                .shadow(radius: 3)
                                .padding(8)
                        }
                    }
                }
                .aspectRatio(1, contentMode: .fit)

                Text(item.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 150, alignment: .top)
            .padding(8)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var thumbnailContent: some View {
        if let thumbnailURL, item.isPreviewable {
            AsyncImage(url: thumbnailURL, transaction: Transaction(animation: .easeInOut(duration: 0.18))) { phase in
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFill()
                case .empty:
                    thumbnailPlaceholder
                        .overlay {
                            ProgressView()
                        }
                case .failure:
                    thumbnailPlaceholder
                @unknown default:
                    thumbnailPlaceholder
                }
            }
        } else {
            thumbnailPlaceholder
        }
    }

    private var thumbnailPlaceholder: some View {
        ZStack {
            Color(.tertiarySystemGroupedBackground)
            Image(systemName: iconName)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(iconColor)
        }
    }

    private var iconName: String {
        if item.isDirectory {
            return "folder.fill"
        }

        if item.isVideo {
            return "play.rectangle.fill"
        }

        if item.isImage {
            return "photo.fill"
        }

        return "doc.fill"
    }

    private var iconColor: Color {
        if item.isDirectory {
            return .blue
        }

        if item.isVideo {
            return .orange
        }

        if item.isImage {
            return .green
        }

        return .secondary
    }
}

private struct FileRow: View {
    let name: String
    let detail: String
    let isDirectory: Bool
    let isVideo: Bool
    let isImage: Bool
    let isPreviewable: Bool
    let thumbnailURL: URL?
    let isSelected: Bool
    let isSelectionMode: Bool
    let showsAccessory: Bool

    var body: some View {
        HStack(spacing: 12) {
            if isSelectionMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .frame(width: 24)
            }

            thumbnailContent
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.headline)
                    .foregroundStyle(.primary)

                if !detail.isEmpty {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if !isSelectionMode, showsAccessory, isDirectory || isPreviewable {
                Image(systemName: isDirectory ? "chevron.right" : "play.circle")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var thumbnailContent: some View {
        if let thumbnailURL, isPreviewable {
            AsyncImage(url: thumbnailURL, transaction: Transaction(animation: .easeInOut(duration: 0.18))) { phase in
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFill()
                case .empty:
                    thumbnailPlaceholder
                        .overlay { ProgressView() }
                case .failure:
                    thumbnailPlaceholder
                @unknown default:
                    thumbnailPlaceholder
                }
            }
        } else {
            thumbnailPlaceholder
        }
    }

    private var thumbnailPlaceholder: some View {
        ZStack {
            Color(.tertiarySystemGroupedBackground)
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
        }
    }

    private var iconName: String {
        if isDirectory {
            return "folder.fill"
        }

        if isVideo {
            return "play.rectangle.fill"
        }

        if isImage {
            return "photo.fill"
        }

        return "doc.fill"
    }

    private var iconColor: Color {
        if isDirectory {
            return .blue
        }

        if isVideo {
            return .orange
        }

        if isImage {
            return .green
        }

        return .secondary
    }
}

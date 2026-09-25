import SwiftUI
import UIKit

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
    @Binding var allowsInsecureConnections: Bool
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
    let retryUploadAction: (UUID) -> Void
    let createFolderAction: (String, String) -> Void
    let saveImageAction: (SynologyFileItem) async -> String
    let renameAction: (SynologyFileItem, String) -> Void
    let moveAction: ([SynologyFileItem], String) -> Void
    let deleteAction: ([SynologyFileItem]) -> Void
    let loadMoveDestinationFoldersAction: (String) async -> [SynologyFileItem]
    let loadSearchFoldersAction: (String) async -> [SynologyFileItem]
    let searchAction: (String, [String]) async throws -> [SynologyFileItem]
    let scanCinemaAction: ([CinemaLibraryFolder], [CinemaScannedItem]) async throws -> CinemaIndexSnapshot
    let cinemaArtworkURLAction: (String?) -> URL?
    let cinemaThumbnailURLAction: (String?) -> URL?
    let previewCinemaAction: (CinemaScannedItem) -> Void
    let cinemaPlaybackProgressAction: (String?) -> TimeInterval
    let cinemaPlaybackDurationAction: (String?) -> TimeInterval
    let clearCinemaPlaybackProgressAction: (String?) -> Void
    let cinemaViewingStateRevision: Int
    let backAction: () -> Void
    let favoriteBackAction: () -> Void
    let fileRootAction: () -> Void
    let favoriteRootAction: () -> Void
    let logoutAction: () -> Void
    let lastMoveDestinationPath: String

    @State private var selectedTab = FileBrowserTab.files
    @State private var isSelectionMode = false
    @State private var selectedItemIDs = Set<String>()
    @State private var renameItem: SynologyFileItem?
    @State private var renameText = ""
    @State private var isCreateFolderDialogPresented = false
    @State private var newFolderName = ""
    @State private var imageSaveMessage: String?
    @State private var moveSelection: FileOperationSelection?
    @State private var deleteSelection: FileOperationSelection?
    @AppStorage("synology.fileDisplayMode") private var displayModeRawValue = FileDisplayMode.list.rawValue
    @State private var fileTransitionEdge: Edge = .trailing
    @State private var favoriteTransitionEdge: Edge = .trailing
    @State private var backSwipeOffset: CGFloat = 0
    @State private var isCompletingInteractiveBack = false
    @State private var cinemaLibraryFolders: [CinemaLibraryFolder] = []
    @State private var isCinemaSyncing = false
    @State private var cinemaManualSyncToken = UUID()

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
                    backSwipeOffset: selectedTab == .files ? backSwipeOffset : 0,
                    suppressPathAnimation: isCompletingInteractiveBack,
                    thumbnailURLAction: thumbnailURLAction,
                    refreshAction: refreshAction,
                    openFolderAction: { item in
                        navigateFiles(edge: .trailing) {
                            openFolderAction(item)
                        }
                    },
                    previewAction: previewAction,
                    saveImageAction: saveImage,
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
                    backSwipeOffset: selectedTab == .favorites ? backSwipeOffset : 0,
                    suppressPathAnimation: isCompletingInteractiveBack,
                    thumbnailURLAction: thumbnailURLAction,
                    refreshAction: refreshFavoriteLocationAction,
                    openFolderAction: { item in
                        navigateFavorites(edge: .trailing) {
                            openFavoriteFolderAction(item)
                        }
                    },
                    previewAction: previewAction,
                    saveImageAction: saveImage,
                    renameRequestAction: prepareRename,
                    moveRequestAction: { moveSelection = FileOperationSelection(items: [$0]) },
                    deleteRequestAction: { deleteSelection = FileOperationSelection(items: [$0]) },
                    loadFavoritesAction: loadFavoritesAction
                )
                .tabItem {
                    Label("收藏夹", systemImage: "star")
                }
                .tag(FileBrowserTab.favorites)

                CinemaHomeView(
                    folders: cinemaLibraryFolders,
                    serverURLString: serverURLString,
                    account: account,
                    isActive: selectedTab == .cinema,
                    isScanning: $isCinemaSyncing,
                    manualSyncToken: cinemaManualSyncToken,
                    scanAction: scanCinemaAction,
                    artworkURLAction: cinemaArtworkURLAction,
                    thumbnailURLAction: cinemaThumbnailURLAction,
                    playAction: previewCinemaAction,
                    playbackProgressAction: cinemaPlaybackProgressAction,
                    playbackDurationAction: cinemaPlaybackDurationAction,
                    clearPlaybackProgressAction: clearCinemaPlaybackProgressAction,
                    viewingStateRevision: cinemaViewingStateRevision
                )
                    .tabItem {
                        Label("影院", systemImage: "film")
                    }
                    .tag(FileBrowserTab.cinema)

                SettingsView(
                    serverURLString: serverURLString,
                    account: account,
                    uploadProgressItems: uploadProgressItems,
                    retryUploadAction: retryUploadAction,
                    allowsInsecureConnections: $allowsInsecureConnections,
                    cinemaLibraryFolders: $cinemaLibraryFolders,
                    isCinemaSyncing: isCinemaSyncing,
                    syncCinemaAction: { cinemaManualSyncToken = UUID() },
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
                            Button {
                                newFolderName = ""
                                isCreateFolderDialogPresented = true
                            } label: {
                                Label("新建文件夹", systemImage: "folder.badge.plus")
                            }
                            .disabled(isLoading || uploadDestinationPath.isEmpty)

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
        .task(id: cinemaSettingsIdentity) {
            cinemaLibraryFolders = CinemaLibrarySettingsStore().load(
                serverURLString: serverURLString,
                account: account
            )
        }
        .onAppear {
            NativeTabBarTapMonitor.shared.start { index in
                handleRepeatedTabTap(at: index)
            }
        }
        .onDisappear {
            NativeTabBarTapMonitor.shared.stop()
        }
        .onChange(of: selectedTab) {
            clearSelection()
        }
        .simultaneousGesture(edgeBackGesture)
        .alert("新建文件夹", isPresented: $isCreateFolderDialogPresented) {
            TextField("文件夹名称", text: $newFolderName)
                .autocorrectionDisabled()
            Button("取消", role: .cancel) {}
            Button("创建") {
                createFolderAction(newFolderName, uploadDestinationPath)
            }
            .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("将在当前目录中创建文件夹。")
        }
        .alert("保存图片", isPresented: imageSaveDialogBinding) {
            Button("好", role: .cancel) {
                imageSaveMessage = nil
            }
        } message: {
            Text(imageSaveMessage ?? "")
        }
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

    private var cinemaSettingsIdentity: String {
        "\(serverURLString)|\(account)"
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

    private var imageSaveDialogBinding: Binding<Bool> {
        Binding {
            imageSaveMessage != nil
        } set: { isPresented in
            if !isPresented {
                imageSaveMessage = nil
            }
        }
    }

    private func saveImage(_ item: SynologyFileItem) {
        Task {
            imageSaveMessage = await saveImageAction(item)
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
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard !isSelectionMode,
                      !isLoading,
                      canGoBackInSelectedTab,
                      value.startLocation.x < 28,
                      value.translation.width > 0,
                      abs(value.translation.width) > abs(value.translation.height) else {
                    return
                }

                backSwipeOffset = value.translation.width
            }
            .onEnded { value in
                guard backSwipeOffset > 0 else {
                    return
                }

                let shouldReturn = value.translation.width > 120
                    || value.predictedEndTranslation.width > 220

                if shouldReturn {
                    isCompletingInteractiveBack = true
                    withAnimation(.smooth(duration: 0.18)) {
                        backSwipeOffset = max(value.translation.width, 430)
                    }

                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(180))
                        performBack()
                        backSwipeOffset = 0
                        try? await Task.sleep(for: .milliseconds(100))
                        isCompletingInteractiveBack = false
                    }
                } else {
                    withAnimation(.smooth(duration: 0.22)) {
                        backSwipeOffset = 0
                    }
                }
            }
    }

    private func performBack() {
        if selectedTab == .favorites {
            navigateFavorites(edge: .leading, action: favoriteBackAction)
        } else {
            navigateFiles(edge: .leading, action: backAction)
        }
    }

    private func handleRepeatedTabTap(at index: Int) {
        switch index {
        case 0:
            navigateFiles(edge: .leading, action: fileRootAction)
        case 1:
            navigateFavorites(edge: .leading, action: favoriteRootAction)
        default:
            break
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

@MainActor
private final class NativeTabBarTapMonitor: NSObject, UIGestureRecognizerDelegate {
    static let shared = NativeTabBarTapMonitor()

    private var action: ((Int) -> Void)?
    private weak var tabBar: UITabBar?
    private var recognizer: UITapGestureRecognizer?
    private var lastIndex: Int?
    private var lastTapDate = Date.distantPast

    func start(action: @escaping (Int) -> Void) {
        self.action = action
        attachIfPossible()
        DispatchQueue.main.async { [weak self] in self?.attachIfPossible() }
    }

    func stop() {
        if let recognizer {
            tabBar?.removeGestureRecognizer(recognizer)
        }
        recognizer = nil
        tabBar = nil
        action = nil
        lastIndex = nil
        lastTapDate = .distantPast
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    private func attachIfPossible() {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        guard let visibleTabBar = windows.lazy.compactMap({ self.findTabBar(in: $0) }).first else { return }
        guard tabBar !== visibleTabBar else { return }
        stopKeepingAction()
        tabBar = visibleTabBar
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        visibleTabBar.addGestureRecognizer(recognizer)
        self.recognizer = recognizer
    }

    private func stopKeepingAction() {
        if let recognizer {
            tabBar?.removeGestureRecognizer(recognizer)
        }
        recognizer = nil
        tabBar = nil
    }

    private func findTabBar(in view: UIView) -> UITabBar? {
        if let tabBar = view as? UITabBar, !tabBar.isHidden, tabBar.alpha > 0 {
            return tabBar
        }
        for subview in view.subviews {
            if let tabBar = findTabBar(in: subview) {
                return tabBar
            }
        }
        return nil
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  let tabBar,
                  let itemCount = tabBar.items?.count,
                  itemCount > 0,
                  tabBar.bounds.width > 0 else { return }

            let location = recognizer.location(in: tabBar)
            guard tabBar.bounds.contains(location) else { return }
            let visualIndex = min(max(Int(location.x / tabBar.bounds.width * CGFloat(itemCount)), 0), itemCount - 1)
            let index = tabBar.effectiveUserInterfaceLayoutDirection == .rightToLeft
                ? itemCount - visualIndex - 1
                : visualIndex
            let now = Date()

            if lastIndex == index, now.timeIntervalSince(lastTapDate) <= 0.7 {
                lastIndex = nil
                lastTapDate = .distantPast
                action?(index)
            } else {
                lastIndex = index
                lastTapDate = now
            }
    }
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

private struct BrowserPageSnapshot: Identifiable {
    let path: String
    let items: [SynologyFileItem]

    var id: String {
        path.isEmpty ? "browser-root" : path
    }
}

private struct FileListView: View {
    @State private var pageHistory: [BrowserPageSnapshot] = []

    let currentPath: String
    let items: [SynologyFileItem]
    let isLoading: Bool
    let isSelectionMode: Bool
    @Binding var selectedItemIDs: Set<String>
    let displayMode: FileDisplayMode
    let transitionEdge: Edge
    let backSwipeOffset: CGFloat
    let suppressPathAnimation: Bool
    let thumbnailURLAction: (SynologyFileItem) -> URL?
    let refreshAction: () async -> Void
    let openFolderAction: (SynologyFileItem) -> Void
    let previewAction: (SynologyFileItem, [SynologyFileItem]) -> Void
    let saveImageAction: (SynologyFileItem) -> Void
    let renameRequestAction: (SynologyFileItem) -> Void
    let moveRequestAction: (SynologyFileItem) -> Void
    let deleteRequestAction: (SynologyFileItem) -> Void

    var body: some View {
        ZStack {
            ForEach(pageHistory) { page in
                browserPage(path: page.path, items: page.items)
                    .allowsHitTesting(false)
            }

            browserPage(path: currentPath, items: items)
                .offset(x: backSwipeOffset)
                .shadow(color: .black.opacity(backSwipeOffset > 0 ? 0.18 : 0), radius: 8, x: -4)
                .id(currentPath)
                .transition(.push(from: transitionEdge))
        }
        .clipped()
        .animation(suppressPathAnimation ? nil : .smooth(duration: 0.32), value: currentPath)
        .onChange(of: currentPath) { _, newPath in
            reconcileHistory(for: newPath)
        }
        .onChange(of: isLoading) { wasLoading, isLoading in
            if wasLoading, !isLoading, pageHistory.last?.path == currentPath {
                pageHistory.removeLast()
            }
        }
    }

    private func browserPage(path: String, items: [SynologyFileItem]) -> some View {
        BrowserListView(
            emptyTitle: "没有文件夹或文件",
            sectionTitle: path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "共享文件夹" : "文件夹清单",
            contentID: path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "files-root" : path,
            transitionEdge: transitionEdge,
            items: items,
            isLoading: isLoading,
            isSelectionMode: isSelectionMode,
            selectedItemIDs: $selectedItemIDs,
            displayMode: displayMode,
            thumbnailURLAction: thumbnailURLAction,
            refreshAction: refreshAction,
            openFolderAction: { item in
                withAnimation(.smooth(duration: 0.32)) {
                    pageHistory.append(BrowserPageSnapshot(path: path, items: items))
                }
                openFolderAction(item)
            },
            previewAction: previewAction,
            saveImageAction: saveImageAction,
            renameRequestAction: renameRequestAction,
            moveRequestAction: moveRequestAction,
            deleteRequestAction: deleteRequestAction
        )
    }

    private func reconcileHistory(for newPath: String) {
        if pageHistory.last?.path == newPath {
            pageHistory.removeLast()
        } else if newPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pageHistory.removeAll()
        }
    }
}

private struct FavoriteListView: View {
    @State private var pageHistory: [BrowserPageSnapshot] = []

    let currentPath: String
    let rootItems: [SynologyFileItem]
    let browserItems: [SynologyFileItem]
    let isLoading: Bool
    let isSelectionMode: Bool
    @Binding var selectedItemIDs: Set<String>
    let displayMode: FileDisplayMode
    let transitionEdge: Edge
    let backSwipeOffset: CGFloat
    let suppressPathAnimation: Bool
    let thumbnailURLAction: (SynologyFileItem) -> URL?
    let refreshAction: () async -> Void
    let openFolderAction: (SynologyFileItem) -> Void
    let previewAction: (SynologyFileItem, [SynologyFileItem]) -> Void
    let saveImageAction: (SynologyFileItem) -> Void
    let renameRequestAction: (SynologyFileItem) -> Void
    let moveRequestAction: (SynologyFileItem) -> Void
    let deleteRequestAction: (SynologyFileItem) -> Void
    let loadFavoritesAction: () -> Void

    private var isRoot: Bool {
        currentPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var currentItems: [SynologyFileItem] {
        isRoot ? rootItems : browserItems
    }

    var body: some View {
        ZStack {
            ForEach(pageHistory) { page in
                browserPage(path: page.path, items: page.items)
                    .allowsHitTesting(false)
            }

            browserPage(path: currentPath, items: currentItems)
                .offset(x: backSwipeOffset)
                .shadow(color: .black.opacity(backSwipeOffset > 0 ? 0.18 : 0), radius: 8, x: -4)
                .id(currentPath)
                .transition(.push(from: transitionEdge))
        }
        .clipped()
        .animation(suppressPathAnimation ? nil : .smooth(duration: 0.32), value: currentPath)
        .onChange(of: currentPath) { _, newPath in
            reconcileHistory(for: newPath)
        }
        .onChange(of: isLoading) { wasLoading, isLoading in
            if wasLoading, !isLoading, pageHistory.last?.path == currentPath {
                pageHistory.removeLast()
            }
        }
        .task {
            if isRoot {
                loadFavoritesAction()
            }
        }
    }

    private func browserPage(path: String, items: [SynologyFileItem]) -> some View {
        let pageIsRoot = path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return BrowserListView(
            emptyTitle: pageIsRoot ? "没有收藏夹" : "没有文件夹或文件",
            sectionTitle: pageIsRoot ? "群晖收藏夹" : "文件夹清单",
            contentID: pageIsRoot ? "favorites-root" : path,
            transitionEdge: transitionEdge,
            items: items,
            isLoading: isLoading,
            isSelectionMode: isSelectionMode,
            selectedItemIDs: $selectedItemIDs,
            displayMode: displayMode,
            thumbnailURLAction: thumbnailURLAction,
            refreshAction: refreshAction,
            openFolderAction: { item in
                withAnimation(.smooth(duration: 0.32)) {
                    pageHistory.append(BrowserPageSnapshot(path: path, items: items))
                }
                openFolderAction(item)
            },
            previewAction: previewAction,
            saveImageAction: saveImageAction,
            renameRequestAction: renameRequestAction,
            moveRequestAction: moveRequestAction,
            deleteRequestAction: deleteRequestAction
        )
    }

    private func reconcileHistory(for newPath: String) {
        if pageHistory.last?.path == newPath {
            pageHistory.removeLast()
        } else if newPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pageHistory.removeAll()
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
    let saveImageAction: (SynologyFileItem) -> Void
    let renameRequestAction: (SynologyFileItem) -> Void
    let moveRequestAction: (SynologyFileItem) -> Void
    let deleteRequestAction: (SynologyFileItem) -> Void

    var body: some View {
        browserContent
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
                    saveImageAction: saveImageAction,
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
            GridItem(
                .adaptive(minimum: 104, maximum: 160),
                spacing: 12,
                alignment: .top
            )
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

        if item.isImage {
            Button {
                saveImageAction(item)
            } label: {
                Label("保存到相册", systemImage: "square.and.arrow.down")
            }
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

private struct CinemaIndexServiceSettingsView: View {
    @State private var settings = CinemaIndexServiceSettings(
        serverURLString: CinemaIndexServiceSettingsStore.defaultServerURLString,
        token: ""
    )

    var body: some View {
        Form {
            Section("连接") {
                TextField("服务地址", text: $settings.serverURLString)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                SecureField("Bearer Token", text: $settings.token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section {
                Text("影院同步将从该服务读取资料库和媒体索引；视频播放、海报访问、收藏夹及播放记录仍使用原有方式。Token 只保存在本机钥匙串中。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("媒体索引服务")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            settings = CinemaIndexServiceSettingsStore().load()
        }
        .onDisappear {
            CinemaIndexServiceSettingsStore().save(settings)
        }
    }
}

private struct SettingsView: View {
    let serverURLString: String
    let account: String
    let uploadProgressItems: [UploadProgressItem]
    let retryUploadAction: (UUID) -> Void
    @Binding var allowsInsecureConnections: Bool
    @Binding var cinemaLibraryFolders: [CinemaLibraryFolder]
    let isCinemaSyncing: Bool
    let syncCinemaAction: () -> Void
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

            Section("影院") {
                NavigationLink {
                    CinemaIndexServiceSettingsView()
                } label: {
                    Label("媒体索引服务", systemImage: "server.rack")
                }

                Button {
                    syncCinemaAction()
                } label: {
                    HStack {
                        Label(
                            isCinemaSyncing ? "正在同步影院资料" : "立即同步影院资料",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                        Spacer()
                        if isCinemaSyncing {
                            ProgressView()
                        }
                    }
                }
                .disabled(isCinemaSyncing)

                if let lastCinemaSyncAt {
                    LabeledContent("上次同步") {
                        Text(
                            lastCinemaSyncAt,
                            format: .dateTime.year().month().day().hour().minute()
                        )
                        .environment(\.locale, Locale(identifier: "zh-Hans-CN"))
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }

            Section("任务") {
                NavigationLink {
                    UploadProgressListView(items: uploadProgressItems, retryAction: retryUploadAction)
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

            Section("连接安全") {
                Toggle("允许不安全访问", isOn: $allowsInsecureConnections)
                    .tint(.orange)

                Text("仅在服务器证书过期等情况下临时开启。开启后，HTTPS 连接可能被窃听或篡改。")
                    .font(.footnote)
                    .foregroundStyle(allowsInsecureConnections ? .orange : .secondary)
            }

            Section("存储") {
                NavigationLink {
                    LocalTemporaryFilesView(uploadProgressItems: uploadProgressItems)
                } label: {
                    Label("本地临时文件", systemImage: "externaldrive")
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

    private var lastCinemaSyncAt: Date? {
        CinemaLibraryCacheStore().load(
            serverURLString: serverURLString,
            account: account
        )?.updatedAt
    }

    private var uploadProgressSummary: String {
        let activeCount = uploadProgressItems.filter { $0.status == .queued || $0.status == .uploading }.count
        if activeCount > 0 {
            return "\(activeCount) 个进行中"
        }

        return uploadProgressItems.isEmpty ? "无任务" : "\(uploadProgressItems.count) 个任务"
    }
}

private struct LocalTemporaryFilesView: View {
    let uploadProgressItems: [UploadProgressItem]

    @State private var items: [LocalTemporaryFileItem] = []
    @State private var showsClearConfirmation = false
    @State private var cleanupMessage: String?

    var body: some View {
        List {
            Section {
                LabeledContent("文件数量", value: "\(items.count)")
                LabeledContent("占用空间", value: formattedSize(totalSize))
            } footer: {
                Text("这里只显示 Synology View 创建的临时文件，不会操作系统或其他应用的数据。正在上传的文件会受到保护。")
            }

            Section("文件") {
                if items.isEmpty {
                    ContentUnavailableView("没有临时文件", systemImage: "checkmark.circle")
                } else {
                    ForEach(items) { item in
                        temporaryFileRow(item)
                    }
                    .onDelete(perform: deleteItems)
                }
            }

            if !items.isEmpty {
                Section {
                    Button("清理全部临时文件", systemImage: "trash", role: .destructive) {
                        showsClearConfirmation = true
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("本地临时文件")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            reload()
        }
        .task {
            reload()
        }
        .confirmationDialog(
            "清理全部临时文件？",
            isPresented: $showsClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清理", role: .destructive) {
                clearAll()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("上传失败后用于重试的文件也会被删除；正在上传的文件不会被删除。")
        }
        .alert("清理结果", isPresented: Binding(
            get: { cleanupMessage != nil },
            set: { if !$0 { cleanupMessage = nil } }
        )) {
            Button("好") {
                cleanupMessage = nil
            }
        } message: {
            Text(cleanupMessage ?? "")
        }
    }

    private var totalSize: Int64 {
        items.reduce(0) { $0 + $1.size }
    }

    private var protectedPaths: Set<String> {
        var paths = Set<String>()
        for item in uploadProgressItems where item.status == .queued || item.status == .uploading {
            paths.insert(
                FileManager.default.temporaryDirectory
                    .appendingPathComponent("SynologyViewMultipart-\(item.id.uuidString).body")
                    .standardizedFileURL.path
            )
            if let sourceFilePath = item.sourceFilePath {
                paths.insert(
                    URL(fileURLWithPath: sourceFilePath)
                        .deletingLastPathComponent()
                        .standardizedFileURL.path
                )
            }
        }
        return paths
    }

    @ViewBuilder
    private func temporaryFileRow(_ item: LocalTemporaryFileItem) -> some View {
        let isProtected = isProtected(item)
        HStack(spacing: 12) {
            Image(systemName: "doc")
                .foregroundStyle(isProtected ? .orange : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(isProtected ? "正在使用 · \(formattedSize(item.size))" : formattedSize(item.size))
                    .font(.caption)
                    .foregroundStyle(isProtected ? .orange : .secondary)
            }
        }
        .deleteDisabled(isProtected)
    }

    private func reload() {
        items = LocalTemporaryFileStore.loadItems()
    }

    private func deleteItems(at offsets: IndexSet) {
        let candidates = offsets.map { items[$0] }
            .filter { !isProtected($0) }
        let failureCount = LocalTemporaryFileStore.remove(candidates)
        reload()
        if failureCount > 0 {
            cleanupMessage = "有 \(failureCount) 个项目未能删除，请稍后重试。"
        }
    }

    private func clearAll() {
        let candidates = items.filter { !isProtected($0) }
        let protectedCount = items.count - candidates.count
        let failureCount = LocalTemporaryFileStore.remove(candidates)
        reload()

        if failureCount > 0 {
            cleanupMessage = "有 \(failureCount) 个项目未能删除，请稍后重试。"
        } else if protectedCount > 0 {
            cleanupMessage = "已清理可删除文件；保留了 \(protectedCount) 个正在使用的项目。"
        } else {
            cleanupMessage = "临时文件已全部清理。"
        }
    }

    private func formattedSize(_ size: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private func isProtected(_ item: LocalTemporaryFileItem) -> Bool {
        let itemPath = item.url.standardizedFileURL.path
        return protectedPaths.contains { protectedPath in
            itemPath == protectedPath || itemPath.hasPrefix(protectedPath + "/")
        }
    }
}

private struct LocalTemporaryFileItem: Identifiable {
    let url: URL
    let size: Int64

    var id: String { url.standardizedFileURL.path }
    var displayName: String { url.lastPathComponent }
}

private enum LocalTemporaryFileStore {
    private static let containerDirectoryNames = ["SynologyViewUploads", "SynologyViewPhotoPicker"]
    private static let rootPrefixes = ["SynologyViewMultipart-", "SynologyViewQuickLook-"]

    static func loadItems() -> [LocalTemporaryFileItem] {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
        var fileURLs: [URL] = []

        if let rootContents = try? fileManager.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) {
            for url in rootContents where rootPrefixes.contains(where: { url.lastPathComponent.hasPrefix($0) }) {
                fileURLs.append(contentsOf: regularFiles(at: url))
            }
        }

        for directoryName in containerDirectoryNames {
            let directory = temporaryDirectory.appendingPathComponent(directoryName, isDirectory: true)
            if let children = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) {
                for child in children {
                    fileURLs.append(contentsOf: regularFiles(at: child))
                }
            }
        }

        return fileURLs.map { url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            return LocalTemporaryFileItem(
                url: url,
                size: Int64(values?.fileSize ?? 0)
            )
        }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    static func remove(_ items: [LocalTemporaryFileItem]) -> Int {
        let fileManager = FileManager.default
        var failureCount = 0
        for item in items {
            do {
                try fileManager.removeItem(at: item.url)
            } catch {
                failureCount += 1
            }
        }

        removeEmptyManagedDirectories()
        return failureCount
    }

    private static func regularFiles(at url: URL) -> [URL] {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
        if values?.isRegularFile == true {
            return [url]
        }
        guard values?.isDirectory == true else { return [] }

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            files.append(fileURL)
        }
        return files
    }

    private static func removeEmptyManagedDirectories() {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
        var managedDirectories = containerDirectoryNames.map {
            temporaryDirectory.appendingPathComponent($0, isDirectory: true)
        }
        if let rootContents = try? fileManager.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            managedDirectories.append(contentsOf: rootContents.filter {
                $0.lastPathComponent.hasPrefix("SynologyViewQuickLook-")
            })
        }

        for root in managedDirectories {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            let directories = (enumerator.allObjects as? [URL] ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted { $0.path.count > $1.path.count }
            for directory in directories + [root] {
                guard let contents = try? fileManager.contentsOfDirectory(atPath: directory.path),
                      contents.isEmpty else { continue }
                try? fileManager.removeItem(at: directory)
            }
        }
    }
}

private struct UploadProgressListView: View {
    let items: [UploadProgressItem]
    let retryAction: (UUID) -> Void

    var body: some View {
        List {
            if items.isEmpty {
                ContentUnavailableView("没有上传任务", systemImage: "arrow.up.circle")
            } else {
                ForEach(items) { item in
                    UploadProgressRow(item: item, retryAction: retryAction)
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
    let retryAction: (UUID) -> Void

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

            if item.status == .failed {
                Button {
                    retryAction(item.id)
                } label: {
                    Label("重新上传", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
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
    let saveImageAction: (SynologyFileItem) -> Void
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
                    if item.isImage {
                        Button {
                            saveImageAction(item)
                        } label: {
                            Label("保存", systemImage: "square.and.arrow.down")
                        }
                        .tint(.green)
                    }

                    Button {
                        deleteRequestAction(item)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                    .tint(.red)

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
                    if item.isImage {
                        Button {
                            saveImageAction(item)
                        } label: {
                            Label("保存到相册", systemImage: "square.and.arrow.down")
                        }
                    }

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

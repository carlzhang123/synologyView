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
    let canGoUp: Bool
    let refreshAction: () -> Void
    let loadFavoritesAction: () -> Void
    let refreshFavoriteLocationAction: () -> Void
    let openFolderAction: (SynologyFileItem) -> Void
    let openFavoriteFolderAction: (SynologyFileItem) -> Void
    let previewAction: (SynologyFileItem) -> Void
    let renameAction: (SynologyFileItem, String) -> Void
    let moveAction: ([SynologyFileItem], String) -> Void
    let deleteAction: ([SynologyFileItem]) -> Void
    let loadMoveDestinationFoldersAction: (String) async -> [SynologyFileItem]
    let upAction: () -> Void
    let favoriteUpAction: () -> Void
    let logoutAction: () -> Void
    let lastMoveDestinationPath: String

    @State private var selectedTab = FileBrowserTab.files
    @State private var isMenuPresented = false
    @State private var isSelectionMode = false
    @State private var selectedItemIDs = Set<String>()
    @State private var renameItem: SynologyFileItem?
    @State private var renameText = ""
    @State private var moveSelection: FileOperationSelection?
    @State private var deleteSelection: FileOperationSelection?

    var body: some View {
        ZStack(alignment: .leading) {
            TabView(selection: $selectedTab) {
                FileListView(
                    currentPath: currentPath,
                    items: fileItems,
                    isLoading: isLoading,
                    isSelectionMode: isSelectionMode,
                    selectedItemIDs: $selectedItemIDs,
                    openFolderAction: openFolderAction,
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
                    openFolderAction: openFavoriteFolderAction,
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
            }
            .navigationTitle(navigationTitle)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if isSelectionMode {
                        Button("取消") {
                            clearSelection()
                        }
                    } else {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isMenuPresented = true
                            }
                        } label: {
                            Label("菜单", systemImage: "line.3.horizontal")
                        }
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !isSelectionMode {
                        if canShowUpButton {
                            Button {
                                selectedTab == .favorites ? favoriteUpAction() : upAction()
                            } label: {
                                Label("上一级", systemImage: "arrow.up.folder")
                            }
                            .disabled(isLoading || !canGoUpInSelectedTab)
                        }

                        Button {
                            selectedTab == .favorites ? refreshFavoriteLocationAction() : refreshAction()
                        } label: {
                            Label("刷新", systemImage: "arrow.clockwise")
                        }
                        .disabled(isLoading)
                    }

                    Button(isSelectionMode ? "完成" : "选择") {
                        isSelectionMode ? clearSelection() : beginSelection()
                    }
                    .disabled(isLoading || visibleItems.isEmpty)
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
                }
            }

            if isMenuPresented {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isMenuPresented = false
                    }
                } label: {
                    Color.black.opacity(0.28)
                        .ignoresSafeArea()
                }
                .buttonStyle(.plain)

                SideMenuView(
                    serverURLString: serverURLString,
                    account: account,
                    logoutAction: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isMenuPresented = false
                        }
                        logoutAction()
                    }
                )
                .transition(.move(edge: .leading))
                .zIndex(1)
            }
        }
        .onChange(of: selectedTab) {
            clearSelection()
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
        .confirmationDialog("确认删除", item: $deleteSelection) { selection in
            Button("删除 \(selection.items.count) 个项目", role: .destructive) {
                deleteAction(selection.items)
                clearSelection()
                deleteSelection = nil
            }
            Button("取消", role: .cancel) {
                deleteSelection = nil
            }
        } message: { selection in
            Text(selection.displayName)
        }
    }

    private var navigationTitle: String {
        switch selectedTab {
        case .files:
            return title(for: currentPath, rootTitle: "文件")
        case .favorites:
            return title(for: favoriteCurrentPath, rootTitle: "收藏夹")
        }
    }

    private var visibleItems: [SynologyFileItem] {
        switch selectedTab {
        case .files:
            return fileItems
        case .favorites:
            return favoriteCurrentPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? favoriteItems : favoriteBrowserItems
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
        }
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
        }
    }

    private func beginSelection() {
        isSelectionMode = true
        selectedItemIDs = []
    }

    private func clearSelection() {
        isSelectionMode = false
        selectedItemIDs = []
    }

    private func prepareRename(_ item: SynologyFileItem) {
        renameText = item.name
        renameItem = item
    }

    private func title(for path: String, rootTitle: String) -> String {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedPath.isEmpty ? rootTitle : URL(fileURLWithPath: trimmedPath).lastPathComponent
    }
}

private enum FileBrowserTab: Hashable {
    case files
    case favorites
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
    let openFolderAction: (SynologyFileItem) -> Void
    let previewAction: (SynologyFileItem) -> Void
    let renameRequestAction: (SynologyFileItem) -> Void
    let moveRequestAction: (SynologyFileItem) -> Void
    let deleteRequestAction: (SynologyFileItem) -> Void

    var body: some View {
        BrowserListView(
            emptyTitle: "没有文件夹或文件",
            sectionTitle: currentPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "共享文件夹" : "文件夹清单",
            items: items,
            isLoading: isLoading,
            isSelectionMode: isSelectionMode,
            selectedItemIDs: $selectedItemIDs,
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
    let openFolderAction: (SynologyFileItem) -> Void
    let previewAction: (SynologyFileItem) -> Void
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
            items: isRoot ? rootItems : browserItems,
            isLoading: isLoading,
            isSelectionMode: isSelectionMode,
            selectedItemIDs: $selectedItemIDs,
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
    let emptyTitle: String
    let sectionTitle: String
    let items: [SynologyFileItem]
    let isLoading: Bool
    let isSelectionMode: Bool
    @Binding var selectedItemIDs: Set<String>
    let openFolderAction: (SynologyFileItem) -> Void
    let previewAction: (SynologyFileItem) -> Void
    let renameRequestAction: (SynologyFileItem) -> Void
    let moveRequestAction: (SynologyFileItem) -> Void
    let deleteRequestAction: (SynologyFileItem) -> Void

    var body: some View {
        List {
            if items.isEmpty {
                EmptyFolderSection(title: emptyTitle, isLoading: isLoading)
            } else {
                FileListSection(
                    title: sectionTitle,
                    items: items,
                    isSelectionMode: isSelectionMode,
                    selectedItemIDs: $selectedItemIDs,
                    openFolderAction: openFolderAction,
                    previewAction: previewAction,
                    renameRequestAction: renameRequestAction,
                    moveRequestAction: moveRequestAction,
                    deleteRequestAction: deleteRequestAction
                )
            }
        }
        .listStyle(.insetGrouped)
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
                Label("移动", systemImage: "folder.badge.arrow.right")
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

private struct SideMenuView: View {
    let serverURLString: String
    let account: String
    let logoutAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "externaldrive.connected.to.line.below.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.blue)

                Text(account.isEmpty ? "Synology View" : account)
                    .font(.headline)

                Text(serverURLString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(20)

            Divider()

            Button(role: .destructive) {
                logoutAction()
            } label: {
                Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
            }

            Spacer()
        }
        .frame(width: 300)
        .frame(maxHeight: .infinity)
        .background(Color(.systemBackground))
        .safeAreaPadding(.top)
        .safeAreaPadding(.bottom)
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
        cancelAction: @escaping () -> Void,
        moveAction: @escaping (String) -> Void
    ) {
        self.itemCount = itemCount
        self.itemName = itemName
        self.initialPath = initialPath
        self.loadFoldersAction = loadFoldersAction
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
                        Label("移到这里", systemImage: "folder.badge.arrow.right")
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
                        ContentUnavailableView("没有下级文件夹", systemImage: "folder")
                    } else {
                        ForEach(folders) { folder in
                            Button {
                                currentPath = folder.path
                                Task {
                                    await loadFolders()
                                }
                            } label: {
                                FileRow(
                                    name: folder.name,
                                    detail: folder.detail,
                                    isDirectory: true,
                                    isVideo: false,
                                    isImage: false,
                                    isPreviewable: false,
                                    isSelected: false,
                                    isSelectionMode: false
                                )
                            }
                            .buttonStyle(.plain)
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
    let openFolderAction: (SynologyFileItem) -> Void
    let previewAction: (SynologyFileItem) -> Void
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
                        previewAction(item)
                    }
                } label: {
                    FileRow(
                        name: item.name,
                        detail: item.detail,
                        isDirectory: item.isDirectory,
                        isVideo: item.isVideo,
                        isImage: item.isImage,
                        isPreviewable: item.isPreviewable,
                        isSelected: selectedItemIDs.contains(item.id),
                        isSelectionMode: isSelectionMode
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
                        Label("移动", systemImage: "folder.badge.arrow.right")
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
                        Label("移动到", systemImage: "folder.badge.arrow.right")
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
        if selectedItemIDs.contains(item.id) {
            selectedItemIDs.remove(item.id)
        } else {
            selectedItemIDs.insert(item.id)
        }
    }
}

private struct FileRow: View {
    let name: String
    let detail: String
    let isDirectory: Bool
    let isVideo: Bool
    let isImage: Bool
    let isPreviewable: Bool
    let isSelected: Bool
    let isSelectionMode: Bool

    var body: some View {
        HStack(spacing: 12) {
            if isSelectionMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .frame(width: 24)
            }

            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 24)

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

            if !isSelectionMode, isDirectory || isPreviewable {
                Image(systemName: isDirectory ? "chevron.right" : "play.circle")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
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

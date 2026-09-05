import SwiftUI

struct SearchResultsView: View {
    let fileName: String
    let folderPaths: [String]
    let searchAction: (String, [String]) async throws -> [SynologyFileItem]
    let previewAction: (SynologyFileItem, [SynologyFileItem]) -> Void

    @State private var results: [SynologyFileItem] = []
    @State private var isSearching = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if isSearching {
                HStack {
                    Spacer()
                    ProgressView("正在搜索")
                    Spacer()
                }
                .padding(.vertical, 24)
            } else if let errorMessage {
                ContentUnavailableView(
                    "搜索失败",
                    systemImage: "exclamationmark.magnifyingglass",
                    description: Text(errorMessage)
                )
            } else if results.isEmpty {
                ContentUnavailableView.search(text: fileName)
            } else {
                ForEach(results) { item in
                    Button {
                        guard item.isPreviewable else { return }
                        previewAction(item, results)
                    } label: {
                        SearchResultRow(item: item)
                    }
                    .buttonStyle(.plain)
                    .disabled(!item.isPreviewable)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("搜索结果")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: SearchRequestID(fileName: fileName, folderPaths: folderPaths)) {
            await performSearch()
        }
    }

    private func performSearch() async {
        isSearching = true
        errorMessage = nil
        defer { isSearching = false }

        do {
            results = try await searchAction(fileName, folderPaths)
        } catch is CancellationError {
            return
        } catch {
            results = []
            errorMessage = error.localizedDescription
        }
    }
}

private struct SearchResultRow: View {
    let item: SynologyFileItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(item.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if item.isPreviewable {
                Image(systemName: "eye")
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    private var iconName: String {
        if item.isDirectory { return "folder.fill" }
        if item.isVideo { return "film.fill" }
        if item.isImage { return "photo.fill" }
        return "doc.fill"
    }

    private var iconColor: Color {
        if item.isDirectory { return .blue }
        if item.isVideo { return .purple }
        if item.isImage { return .green }
        return .secondary
    }
}

struct AdvancedSearchView: View {
    let loadFoldersAction: (String) async -> [SynologyFileItem]
    let searchAction: (String, [String]) async throws -> [SynologyFileItem]
    let previewAction: (SynologyFileItem, [SynologyFileItem]) -> Void

    @State private var fileName = ""
    @State private var selectedPaths = Set<String>()
    @State private var isPathPickerPresented = false
    @State private var submittedRequest: SearchRequest?

    var body: some View {
        Form {
            Section("搜索条件") {
                TextField("文件名", text: $fileName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button {
                    isPathPickerPresented = true
                } label: {
                    HStack {
                        Label("文件所在路径", systemImage: "folder")
                        Spacer()
                        Text(pathSummary)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !selectedPaths.isEmpty {
                Section("已选路径") {
                    ForEach(selectedPaths.sorted(), id: \.self) { path in
                        HStack {
                            Text(path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                selectedPaths.remove(path)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("移除路径")
                        }
                    }
                }
            }

            Section {
                Button {
                    submittedRequest = SearchRequest(
                        fileName: fileName.trimmingCharacters(in: .whitespacesAndNewlines),
                        folderPaths: selectedPaths.sorted()
                    )
                } label: {
                    Label("开始搜索", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .disabled(fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedPaths.isEmpty)
            }
        }
        .navigationTitle("高级搜索")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isPathPickerPresented) {
            SearchPathPickerView(
                selectedPaths: $selectedPaths,
                loadFoldersAction: loadFoldersAction
            )
        }
        .navigationDestination(item: $submittedRequest) { request in
            SearchResultsView(
                fileName: request.fileName,
                folderPaths: request.folderPaths,
                searchAction: searchAction,
                previewAction: previewAction
            )
        }
    }

    private var pathSummary: String {
        selectedPaths.isEmpty ? "请选择（可多选）" : "已选 \(selectedPaths.count) 个"
    }
}

private struct SearchPathPickerView: View {
    @Binding var selectedPaths: Set<String>
    let loadFoldersAction: (String) async -> [SynologyFileItem]

    @Environment(\.dismiss) private var dismiss
    @State private var currentPath = ""
    @State private var folders: [SynologyFileItem] = []
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            List {
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
                        SearchPathRow(
                            folder: folder,
                            isSelected: selectedPaths.contains(folder.path),
                            toggleAction: { toggle(folder.path) },
                            openAction: {
                                currentPath = folder.path
                                Task { await loadFolders() }
                            }
                        )
                    }
                }
            }
            .navigationTitle(pathTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        currentPath = parentPath(for: currentPath)
                        Task { await loadFolders() }
                    } label: {
                        Label("上一级", systemImage: "arrow.up.folder")
                    }
                    .disabled(currentPath.isEmpty || isLoading)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await loadFolders() }
        }
    }

    private var pathTitle: String {
        currentPath.isEmpty ? "选择搜索路径" : URL(fileURLWithPath: currentPath).lastPathComponent
    }

    private func toggle(_ path: String) {
        if selectedPaths.contains(path) {
            selectedPaths.remove(path)
        } else {
            selectedPaths.insert(path)
        }
    }

    private func loadFolders() async {
        isLoading = true
        defer { isLoading = false }
        folders = await loadFoldersAction(currentPath)
    }

    private func parentPath(for path: String) -> String {
        guard !path.isEmpty else { return "" }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return parent == "/" ? "" : parent
    }
}

private struct SearchPathRow: View {
    let folder: SynologyFileItem
    let isSelected: Bool
    let toggleAction: () -> Void
    let openAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggleAction) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSelected ? "取消选择 \(folder.name)" : "选择 \(folder.name)")

            Button(action: openAction) {
                HStack {
                    Label(folder.name, systemImage: "folder.fill")
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

private struct SearchRequest: Identifiable, Hashable {
    let fileName: String
    let folderPaths: [String]

    var id: SearchRequestID {
        SearchRequestID(fileName: fileName, folderPaths: folderPaths)
    }
}

private struct SearchRequestID: Hashable {
    let fileName: String
    let folderPaths: [String]
}

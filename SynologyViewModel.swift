import Foundation
import Observation
import Photos

@MainActor
@Observable
final class SynologyViewModel {
    var serverURLString = ""
    var savedServers: [String] = []
    var account = ""
    var password = ""
    var pendingOTPCode = ""
    var isOTPDialogPresented = false
    var trustsThisDevice = true
    var allowsInsecureConnections = false {
        didSet {
            settingsStore.saveAllowsInsecureConnections(allowsInsecureConnections)
        }
    }
    var statusMessage = "尚未连接"
    var isLoading = false
    var discoveredAPIs: [SynologyAPIInfo] = []
    var fileStationAPIs: [SynologyAPIInfo] = []
    var currentPath = ""
    var fileItems: [SynologyFileItem] = []
    var favoriteItems: [SynologyFileItem] = []
    var favoriteCurrentPath = ""
    var favoriteBrowserItems: [SynologyFileItem] = []
    var lastMoveDestinationPath = ""
    var previewItem: SynologyFilePreviewItem?
    var uploadProgressItems: [UploadProgressItem] = []

    private(set) var authAPI: SynologyAPIInfo?
    private(set) var fileStationListAPI: SynologyAPIInfo?
    private(set) var fileStationDownloadAPI: SynologyAPIInfo?
    private(set) var fileStationFavoriteAPI: SynologyAPIInfo?
    private(set) var fileStationThumbAPI: SynologyAPIInfo?
    private(set) var fileStationUploadAPI: SynologyAPIInfo?
    private(set) var fileStationCreateFolderAPI: SynologyAPIInfo?
    private(set) var fileStationRenameAPI: SynologyAPIInfo?
    private(set) var fileStationCopyMoveAPI: SynologyAPIInfo?
    private(set) var fileStationDeleteAPI: SynologyAPIInfo?
    private(set) var fileStationSearchAPI: SynologyAPIInfo?
    private var sessionID: String?
    private var pathHistory: [String] = []
    private var favoritePathHistory: [String] = []
    private var previewImageItems: [SynologyFileItem] = []
    private var didAttemptAutoLogin = false
    private let settingsStore = SynologyLoginSettingsStore()
    private let fileOperationSettingsStore = FileOperationSettingsStore()
    private let uploadProgressStore = UploadProgressStore()
    private let playbackProgressStore = PlaybackProgressStore()

    init() {
        let settings = settingsStore.load()
        serverURLString = settings.lastServer
        savedServers = settings.savedServers
        account = settings.lastAccount
        allowsInsecureConnections = settings.allowsInsecureConnections
        password = settingsStore.loadPassword(serverURLString: settings.lastServer, account: settings.lastAccount) ?? ""
        lastMoveDestinationPath = fileOperationSettingsStore.loadLastMoveDestinationPath()
        uploadProgressItems = uploadProgressStore.load()

        BackgroundUploadManager.shared.setEventHandler { [weak self] event in
            Task { @MainActor in
                self?.applyBackgroundUploadEvent(event)
            }
        }
        Task { [weak self] in
            let activeTaskIDs = await BackgroundUploadManager.shared.activeTaskIDs()
            self?.reconcilePersistedUploads(activeTaskIDs: activeTaskIDs)
            self?.cleanupOrphanedTemporaryFiles(activeTaskIDs: activeTaskIDs)
        }
    }

    var isConnected: Bool {
        sessionID != nil
    }

    var canGoUp: Bool {
        !currentPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canGoBack: Bool {
        !pathHistory.isEmpty || !normalizedPath(currentPath).isEmpty
    }

    var canGoFavoriteBack: Bool {
        !favoritePathHistory.isEmpty || !normalizedPath(favoriteCurrentPath).isEmpty
    }

    func login() async {
        await authenticateAndLoad(otpCode: nil)
    }

    func loginWithOTP() async {
        await authenticateAndLoad(otpCode: pendingOTPCode)
    }

    func autoLoginIfPossible() async {
        guard !didAttemptAutoLogin, !isConnected else {
            return
        }

        didAttemptAutoLogin = true
        let trimmedServer = serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedServer.isEmpty, !trimmedAccount.isEmpty, !password.isEmpty else {
            return
        }

        statusMessage = "正在自动登录"
        await authenticateAndLoad(otpCode: nil)
    }

    func selectServer(_ server: String) {
        serverURLString = server
        let settings = settingsStore.load()
        if settings.lastServer == server, !settings.lastAccount.isEmpty {
            account = settings.lastAccount
            password = settingsStore.loadPassword(serverURLString: server, account: settings.lastAccount) ?? password
        }
    }

    func logout() {
        sessionID = nil
        currentPath = ""
        fileItems = []
        favoriteItems = []
        favoriteCurrentPath = ""
        favoriteBrowserItems = []
        pathHistory = []
        favoritePathHistory = []
        previewItem = nil
        previewImageItems = []
        statusMessage = "已退出登录"
    }

    func loadCurrentLocation() async {
        await runNetworkOperation {
            guard let sessionID else {
                throw SynologyClientError.notAuthenticated
            }

            let client = try SynologyClient(serverURLString: serverURLString, sessionID: sessionID)
            let apis = discoveredAPIs.isEmpty ? try await client.discoverAPIs() : discoveredAPIs
            applyDiscoveredAPIs(apis)

            guard let fileStationListAPI else {
                throw SynologyClientError.missingAPI("SYNO.FileStation.List")
            }

            try await reloadCurrentLocation(using: client, listAPI: fileStationListAPI)
        }
    }

    func loadFavorites() async {
        await runNetworkOperation {
            guard let sessionID else {
                throw SynologyClientError.notAuthenticated
            }

            let client = try SynologyClient(serverURLString: serverURLString, sessionID: sessionID)
            let apis = discoveredAPIs.isEmpty ? try await client.discoverAPIs() : discoveredAPIs
            applyDiscoveredAPIs(apis)

            guard let fileStationFavoriteAPI else {
                throw SynologyClientError.missingAPI("SYNO.FileStation.Favorite")
            }

            favoriteItems = try await client.loadFavorites(api: fileStationFavoriteAPI)
            favoriteCurrentPath = ""
            favoriteBrowserItems = []
            statusMessage = "读取到 \(favoriteItems.count) 个收藏夹"
        }
    }

    func loadFavoriteCurrentLocation() async {
        await runNetworkOperation {
            guard let sessionID else {
                throw SynologyClientError.notAuthenticated
            }

            let client = try SynologyClient(serverURLString: serverURLString, sessionID: sessionID)
            let apis = discoveredAPIs.isEmpty ? try await client.discoverAPIs() : discoveredAPIs
            applyDiscoveredAPIs(apis)

            guard let fileStationListAPI else {
                throw SynologyClientError.missingAPI("SYNO.FileStation.List")
            }

            let path = normalizedPath(favoriteCurrentPath)
            if path.isEmpty {
                guard let fileStationFavoriteAPI else {
                    throw SynologyClientError.missingAPI("SYNO.FileStation.Favorite")
                }
                favoriteItems = try await client.loadFavorites(api: fileStationFavoriteAPI)
                favoriteBrowserItems = []
                statusMessage = "读取到 \(favoriteItems.count) 个收藏夹"
            } else {
                favoriteBrowserItems = try await client.loadFolder(api: fileStationListAPI, path: path)
                favoriteCurrentPath = path
                statusMessage = "读取到 \(favoriteBrowserItems.count) 个收藏夹项目"
            }
        }
    }

    func openFolder(_ item: SynologyFileItem) async {
        guard item.isDirectory else {
            return
        }

        await navigateFiles(to: item.path, recordsHistory: true)
    }

    func openFavoriteFolder(_ item: SynologyFileItem) async {
        guard item.isDirectory else {
            return
        }

        await navigateFavorites(to: item.path, recordsHistory: true)
    }

    func openParentFolder() async {
        let path = normalizedPath(currentPath)
        guard !path.isEmpty else {
            return
        }

        await navigateFiles(to: parentPath(for: path), recordsHistory: true, historyPath: path)
    }

    func openFavoriteParentFolder() async {
        let path = normalizedPath(favoriteCurrentPath)
        guard !path.isEmpty else {
            return
        }

        await navigateFavorites(to: parentPath(for: path), recordsHistory: true, historyPath: path)
    }

    func goBack() async {
        guard !isLoading else {
            return
        }
        let current = normalizedPath(currentPath)
        guard !current.isEmpty else { return }
        let targetPath = pathHistory.last ?? parentPath(for: current)
        await navigateFiles(to: targetPath, recordsHistory: false)
    }

    func goFavoriteBack() async {
        guard !isLoading else {
            return
        }
        let current = normalizedPath(favoriteCurrentPath)
        guard !current.isEmpty else { return }
        let targetPath = favoritePathHistory.last ?? parentPath(for: current)
        await navigateFavorites(to: targetPath, recordsHistory: false)
    }

    func returnToFileRoot() async {
        guard !isLoading, !normalizedPath(currentPath).isEmpty else { return }
        await navigateFiles(to: "", recordsHistory: false)
        if normalizedPath(currentPath).isEmpty {
            pathHistory.removeAll()
        }
    }

    func returnToFavoriteRoot() async {
        guard !isLoading, !normalizedPath(favoriteCurrentPath).isEmpty else { return }
        await navigateFavorites(to: "", recordsHistory: false)
        if normalizedPath(favoriteCurrentPath).isEmpty {
            favoritePathHistory.removeAll()
        }
    }

    private func navigateFiles(to path: String, recordsHistory: Bool, historyPath: String? = nil) async {
        await runNetworkOperation {
            let normalizedTargetPath = normalizedPath(path)
            let (client, listAPI) = try await fileListContext()
            let targetItems = try await loadFileItems(at: normalizedTargetPath, using: client, listAPI: listAPI)

            if recordsHistory {
                pathHistory.append(historyPath ?? normalizedPath(currentPath))
            } else if !pathHistory.isEmpty {
                pathHistory.removeLast()
            }

            currentPath = normalizedTargetPath
            fileItems = targetItems
            statusMessage = normalizedTargetPath.isEmpty ? "读取到 \(targetItems.count) 个共享文件夹" : "读取到 \(targetItems.count) 个项目"
        }
    }

    private func navigateFavorites(to path: String, recordsHistory: Bool, historyPath: String? = nil) async {
        await runNetworkOperation {
            let normalizedTargetPath = normalizedPath(path)
            let (client, listAPI) = try await fileListContext()
            let targetItems: [SynologyFileItem]

            if normalizedTargetPath.isEmpty {
                guard let fileStationFavoriteAPI else {
                    throw SynologyClientError.missingAPI("SYNO.FileStation.Favorite")
                }
                targetItems = try await client.loadFavorites(api: fileStationFavoriteAPI)
            } else {
                targetItems = try await client.loadFolder(api: listAPI, path: normalizedTargetPath)
            }

            if recordsHistory {
                favoritePathHistory.append(historyPath ?? normalizedPath(favoriteCurrentPath))
            } else if !favoritePathHistory.isEmpty {
                favoritePathHistory.removeLast()
            }

            favoriteCurrentPath = normalizedTargetPath
            if normalizedTargetPath.isEmpty {
                favoriteItems = targetItems
                favoriteBrowserItems = []
                statusMessage = "读取到 \(targetItems.count) 个收藏夹"
            } else {
                favoriteBrowserItems = targetItems
                statusMessage = "读取到 \(targetItems.count) 个收藏夹项目"
            }
        }
    }

    func preview(_ item: SynologyFileItem, in contextItems: [SynologyFileItem]) {
        do {
            guard item.isPreviewable else {
                throw SynologyClientError.unsupportedPreview
            }

            let imageItems = item.isImage ? contextItems.filter(\.isImage) : []
            previewImageItems = imageItems
            previewItem = try previewItem(for: item, imageItems: imageItems)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func showPreviousImage() {
        showAdjacentImage(offset: -1)
    }

    func showNextImage() {
        showAdjacentImage(offset: 1)
    }

    private func showAdjacentImage(offset: Int) {
        // Image swiping is handled inside ImagePreview now. Keep this for older call sites.
    }

    private func previewItem(for item: SynologyFileItem, imageItems: [SynologyFileItem] = []) throws -> SynologyFilePreviewItem {
        guard item.isPreviewable else {
            throw SynologyClientError.unsupportedPreview
        }

        guard let sessionID else {
            throw SynologyClientError.notAuthenticated
        }

        let client = try SynologyClient(serverURLString: serverURLString, sessionID: sessionID)
        let playbackURLs = try client.downloadURLVariants(api: fileStationDownloadAPI, for: item.path)
        guard let url = playbackURLs.first else {
            throw SynologyClientError.invalidURL
        }
        let imageGallery = try imageItems.map { imageItem in
            SynologyImagePreviewItem(
                file: imageItem,
                url: try client.downloadURL(api: fileStationDownloadAPI, for: imageItem.path)
            )
        }

        return SynologyFilePreviewItem(
            file: item,
            url: url,
            playbackURLs: item.isVideo ? playbackURLs : [url],
            resumeTime: playbackProgressStore.progress(for: item.path),
            knownDuration: playbackProgressStore.duration(for: item.path),
            imageGallery: imageGallery
        )
    }

    func preview(_ item: SynologyFileItem) {
        do {
            guard item.isPreviewable else {
                throw SynologyClientError.unsupportedPreview
            }

            let imageItems = item.isImage ? [item] : []
            previewImageItems = imageItems
            previewItem = try previewItem(for: item, imageItems: imageItems)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func savePlaybackProgress(_ progress: TimeInterval, for item: SynologyFilePreviewItem) {
        playbackProgressStore.save(progress, for: item.file.path)
        CinemaViewingStateStore().update(
            path: item.file.path,
            serverURLString: serverURLString,
            account: account
        ) { $0.lastPlayedAt = Date() }
    }

    func savePlaybackDuration(_ duration: TimeInterval, for item: SynologyFilePreviewItem) {
        playbackProgressStore.saveDuration(duration, for: item.file.path)
    }

    func clearPlaybackProgress(for item: SynologyFilePreviewItem) {
        playbackProgressStore.clear(for: item.file.path)
        CinemaViewingStateStore().update(
            path: item.file.path,
            serverURLString: serverURLString,
            account: account
        ) {
            $0.isWatched = true
            $0.lastPlayedAt = Date()
        }
    }

    func playbackProgress(for path: String?) -> TimeInterval {
        guard let path else { return 0 }
        return playbackProgressStore.progress(for: path)
    }

    func playbackDuration(for path: String?) -> TimeInterval {
        guard let path else { return 0 }
        return playbackProgressStore.duration(for: path)
    }

    func clearCinemaPlaybackProgress(for path: String?) {
        guard let path else { return }
        playbackProgressStore.clear(for: path)
    }

    func thumbnailURL(for item: SynologyFileItem) -> URL? {
        guard item.isPreviewable,
              sessionID != nil,
              let client = try? SynologyClient(serverURLString: serverURLString, sessionID: sessionID) else {
            return nil
        }

        return try? client.thumbnailURL(api: fileStationThumbAPI, for: item.path)
    }

    func scanCinemaLibraries(
        _ libraries: [CinemaLibraryFolder],
        cachedItems: [CinemaScannedItem]
    ) async throws -> CinemaIndexSnapshot {
        let settings = CinemaIndexServiceSettingsStore().load()
        return try await CinemaIndexServiceClient(settings: settings).loadSnapshot()
    }

    func cinemaThumbnailURL(for path: String?) -> URL? {
        guard let path, let sessionID,
              let client = try? SynologyClient(serverURLString: serverURLString, sessionID: sessionID) else {
            return nil
        }
        return try? client.thumbnailURL(api: fileStationThumbAPI, for: path, size: "medium")
    }

    func cinemaArtworkURL(for path: String?) -> URL? {
        guard let path, let sessionID,
              let client = try? SynologyClient(serverURLString: serverURLString, sessionID: sessionID) else {
            return nil
        }
        return try? client.downloadURL(api: fileStationDownloadAPI, for: path)
    }

    func previewCinemaItem(_ item: CinemaScannedItem) {
        guard let videoPath = item.videoPath else { return }
        let file = SynologyFileItem(
            id: videoPath,
            name: URL(fileURLWithPath: videoPath).lastPathComponent,
            path: videoPath,
            isDirectory: false,
            size: nil,
            modifiedTime: nil,
            createdTime: item.sourceCreatedAt
        )
        preview(file)
    }

    func searchFiles(named fileName: String, in folderPaths: [String]) async throws -> [SynologyFileItem] {
        let cleanName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            return []
        }
        guard let sessionID else {
            throw SynologyClientError.notAuthenticated
        }

        let client = try SynologyClient(serverURLString: serverURLString, sessionID: sessionID)
        let apis = discoveredAPIs.isEmpty ? try await client.discoverAPIs() : discoveredAPIs
        applyDiscoveredAPIs(apis)
        guard let fileStationSearchAPI else {
            throw SynologyClientError.missingAPI("SYNO.FileStation.Search")
        }

        var paths = folderPaths
            .map(normalizedPath)
            .filter { !$0.isEmpty }
        if paths.isEmpty {
            guard let fileStationListAPI else {
                throw SynologyClientError.missingAPI("SYNO.FileStation.List")
            }
            paths = try await client.loadSharedFolders(api: fileStationListAPI).map(\.path)
        }
        guard !paths.isEmpty else {
            return []
        }

        return try await client.search(
            api: fileStationSearchAPI,
            fileName: cleanName,
            folderPaths: paths
        )
    }

    func loadSearchFolders(at path: String) async -> [SynologyFileItem] {
        await loadMoveDestinationFolders(at: path).filter(\.isDirectory)
    }

    func createFolder(named name: String, in parentPath: String) async {
        await runNetworkOperation {
            let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let destination = normalizedPath(parentPath)
            guard !cleanName.isEmpty, !cleanName.contains("/") else {
                throw SynologyClientError.invalidFileName
            }
            guard !destination.isEmpty else {
                throw SynologyClientError.invalidDestinationPath
            }
            guard let sessionID else {
                throw SynologyClientError.notAuthenticated
            }

            let client = try SynologyClient(serverURLString: serverURLString, sessionID: sessionID)
            let apis = discoveredAPIs.isEmpty ? try await client.discoverAPIs() : discoveredAPIs
            applyDiscoveredAPIs(apis)

            guard let fileStationCreateFolderAPI else {
                throw SynologyClientError.missingAPI("SYNO.FileStation.CreateFolder")
            }

            try await client.createFolder(api: fileStationCreateFolderAPI, parentPath: destination, name: cleanName)
            try await reloadAfterFileOperation(using: client)
            statusMessage = "已新建文件夹 \(cleanName)"
        }
    }

    func saveImageToPhotoLibrary(_ item: SynologyFileItem) async -> String {
        guard item.isImage else {
            return "该文件不是支持保存的图片"
        }
        guard let sessionID else {
            return SynologyClientError.notAuthenticated.localizedDescription
        }

        do {
            let authorizationStatus = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard authorizationStatus == .authorized || authorizationStatus == .limited else {
                return "没有照片添加权限，请在系统设置中允许访问照片。"
            }

            let client = try SynologyClient(serverURLString: serverURLString, sessionID: sessionID)
            let data = try await client.downloadData(api: fileStationDownloadAPI, for: item.path)
            let fileName = item.name
            try await PHPhotoLibrary.shared().performChanges {
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = fileName
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: options)
            }
            return "“\(item.name)”已保存到手机相册"
        } catch {
            return "保存失败：\(error.localizedDescription)"
        }
    }

    func rename(_ item: SynologyFileItem, to newName: String) async {
        await runNetworkOperation {
            let cleanName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanName.isEmpty, !cleanName.contains("/") else {
                throw SynologyClientError.invalidFileName
            }

            guard let sessionID else {
                throw SynologyClientError.notAuthenticated
            }

            let client = try SynologyClient(serverURLString: serverURLString, sessionID: sessionID)
            let apis = discoveredAPIs.isEmpty ? try await client.discoverAPIs() : discoveredAPIs
            applyDiscoveredAPIs(apis)

            guard let fileStationRenameAPI else {
                throw SynologyClientError.missingAPI("SYNO.FileStation.Rename")
            }

            try await client.rename(api: fileStationRenameAPI, item: item, newName: cleanName)
            try await reloadAfterFileOperation(using: client)
            statusMessage = "已重命名为 \(cleanName)"
        }
    }

    func move(_ item: SynologyFileItem, to destinationFolderPath: String) async {
        await move([item], to: destinationFolderPath)
    }

    func move(_ items: [SynologyFileItem], to destinationFolderPath: String) async {
        await runNetworkOperation {
            let destination = normalizedPath(destinationFolderPath)
            guard !destination.isEmpty else {
                throw SynologyClientError.invalidDestinationPath
            }
            guard !items.isEmpty else {
                return
            }

            guard let sessionID else {
                throw SynologyClientError.notAuthenticated
            }

            let client = try SynologyClient(serverURLString: serverURLString, sessionID: sessionID)
            let apis = discoveredAPIs.isEmpty ? try await client.discoverAPIs() : discoveredAPIs
            applyDiscoveredAPIs(apis)

            guard let fileStationCopyMoveAPI else {
                throw SynologyClientError.missingAPI("SYNO.FileStation.CopyMove")
            }

            try await client.move(api: fileStationCopyMoveAPI, items: items, destinationFolderPath: destination)
            lastMoveDestinationPath = destination
            fileOperationSettingsStore.saveLastMoveDestinationPath(destination)
            try await reloadAfterFileOperation(using: client)
            statusMessage = "已移动 \(items.count) 个项目到 \(destination)"
        }
    }

    func upload(_ files: [SynologyUploadFile], to destinationPath: String) async {
        let destination = normalizedPath(destinationPath)
        guard !destination.isEmpty else {
            statusMessage = SynologyClientError.invalidDestinationPath.localizedDescription
            cleanupUploadFiles(files)
            return
        }
        guard !files.isEmpty else {
            return
        }

        let newItems = files.map { file in
            UploadProgressItem(
                id: UUID(),
                fileName: file.fileName,
                destinationPath: destination,
                progress: 0,
                status: .queued,
                errorMessage: nil,
                sourceFilePath: file.fileURL.path,
                creationDate: file.creationDate
            )
        }
        uploadProgressItems.append(contentsOf: newItems)
        uploadProgressStore.save(uploadProgressItems)
        statusMessage = "已加入上传队列：\(files.count) 个项目"

        Task {
            await uploadFilesInBackground(files, progressItems: newItems, destination: destination)
        }
    }

    private func uploadFilesInBackground(
        _ files: [SynologyUploadFile],
        progressItems: [UploadProgressItem],
        destination: String
    ) async {
        do {
            guard let sessionID else {
                throw SynologyClientError.notAuthenticated
            }

            let client = try SynologyClient(serverURLString: serverURLString, sessionID: sessionID)
            let apis = discoveredAPIs.isEmpty ? try await client.discoverAPIs() : discoveredAPIs
            applyDiscoveredAPIs(apis)

            guard let fileStationUploadAPI else {
                throw SynologyClientError.missingAPI("SYNO.FileStation.Upload")
            }

            await withTaskGroup(of: (UUID, String?).self) { group in
                for (file, item) in zip(files, progressItems) {
                    let itemID = item.id
                    updateUploadItem(itemID, status: .uploading, progress: 0.01)
                    group.addTask { [weak self] in
                        do {
                            try await client.upload(
                                api: fileStationUploadAPI,
                                file: file,
                                to: destination,
                                taskID: itemID
                            ) { progress in
                                Task { @MainActor [weak self] in
                                    self?.updateUploadItem(itemID, status: .uploading, progress: progress)
                                }
                            }
                            try? FileManager.default.removeItem(at: file.fileURL.deletingLastPathComponent())
                            return (itemID, nil)
                        } catch {
                            return (itemID, error.localizedDescription)
                        }
                    }
                }

                for await (itemID, errorMessage) in group {
                    if let errorMessage {
                        updateUploadItem(itemID, status: .failed, errorMessage: errorMessage)
                    } else {
                        updateUploadItem(itemID, status: .finished, progress: 1)
                    }
                }
            }

            try await reloadAfterFileOperation(using: client)
            statusMessage = "上传任务已完成"
        } catch {
            for item in progressItems where uploadStatus(for: item.id) != .finished {
                updateUploadItem(item.id, status: .failed, errorMessage: error.localizedDescription)
            }
            statusMessage = error.localizedDescription
            if shouldReturnToLogin(for: error) {
                logout(message: "连接已失效，请重新登录")
            }
        }
    }

    func retryUpload(_ id: UUID) {
        guard let item = uploadProgressItems.first(where: { $0.id == id }), item.status == .failed else {
            return
        }
        guard let sourceFilePath = item.sourceFilePath,
              FileManager.default.fileExists(atPath: sourceFilePath) else {
            updateUploadItem(id, status: .failed, progress: 0, errorMessage: "原始临时文件已被系统清理，请重新选择文件")
            return
        }

        let file = SynologyUploadFile(
            fileURL: URL(fileURLWithPath: sourceFilePath),
            fileName: item.fileName,
            creationDate: item.creationDate
        )
        updateUploadItem(id, status: .queued, progress: 0)
        guard let progressItem = uploadProgressItems.first(where: { $0.id == id }) else { return }
        Task {
            await uploadFilesInBackground([file], progressItems: [progressItem], destination: item.destinationPath)
        }
    }

    func delete(_ items: [SynologyFileItem]) async {
        await runNetworkOperation {
            guard !items.isEmpty else {
                return
            }

            guard let sessionID else {
                throw SynologyClientError.notAuthenticated
            }

            let client = try SynologyClient(serverURLString: serverURLString, sessionID: sessionID)
            let apis = discoveredAPIs.isEmpty ? try await client.discoverAPIs() : discoveredAPIs
            applyDiscoveredAPIs(apis)

            guard let fileStationDeleteAPI else {
                throw SynologyClientError.missingAPI("SYNO.FileStation.Delete")
            }

            try await client.delete(api: fileStationDeleteAPI, items: items)
            try await reloadAfterFileOperation(using: client)
            statusMessage = "已删除 \(items.count) 个项目"
        }
    }

    private func uploadStatus(for id: UUID) -> UploadProgressStatus? {
        uploadProgressItems.first(where: { $0.id == id })?.status
    }

    private func updateUploadItem(
        _ id: UUID,
        status: UploadProgressStatus,
        progress: Double? = nil,
        errorMessage: String? = nil
    ) {
        guard let index = uploadProgressItems.firstIndex(where: { $0.id == id }) else {
            return
        }

        if status == .uploading,
           uploadProgressItems[index].status == .finished || uploadProgressItems[index].status == .failed {
            return
        }

        uploadProgressItems[index].status = status
        if let progress {
            uploadProgressItems[index].progress = min(max(progress, 0), 1)
        }
        uploadProgressItems[index].errorMessage = errorMessage
        uploadProgressStore.save(uploadProgressItems)
    }

    private func applyBackgroundUploadEvent(_ event: BackgroundUploadEvent) {
        updateUploadItem(
            event.taskID,
            status: event.status,
            progress: event.progress,
            errorMessage: event.errorMessage
        )
    }

    private func reconcilePersistedUploads(activeTaskIDs: Set<UUID>) {
        for index in uploadProgressItems.indices {
            let item = uploadProgressItems[index]
            guard item.status == .queued || item.status == .uploading else { continue }
            if activeTaskIDs.contains(item.id) {
                uploadProgressItems[index].status = .uploading
            } else {
                uploadProgressItems[index].status = .failed
                uploadProgressItems[index].errorMessage = "上传任务未能在系统清理后恢复"
            }
        }
        uploadProgressStore.save(uploadProgressItems)
    }

    private func cleanupOrphanedTemporaryFiles(activeTaskIDs: Set<UUID>) {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
        let protectedNames = Set(activeTaskIDs.map { "SynologyViewMultipart-\($0.uuidString).body" })
        let protectedSourceDirectories = Set(uploadProgressItems.compactMap { item -> String? in
            guard item.status == .failed, let sourceFilePath = item.sourceFilePath else { return nil }
            return URL(fileURLWithPath: sourceFilePath).deletingLastPathComponent().standardizedFileURL.path
        })
        let cutoffDate = Date().addingTimeInterval(-24 * 60 * 60)

        if let files = try? fileManager.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            for file in files where file.lastPathComponent.hasPrefix("SynologyViewMultipart-") {
                guard !protectedNames.contains(file.lastPathComponent),
                      let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                      (values.contentModificationDate ?? .distantPast) < cutoffDate else { continue }
                try? fileManager.removeItem(at: file)
            }

            // Quick Look directories can only survive when the app was terminated before
            // the preview's onDisappear cleanup ran, so they are safe to remove at launch.
            for file in files where file.lastPathComponent.hasPrefix("SynologyViewQuickLook-") {
                try? fileManager.removeItem(at: file)
            }
        }

        for directoryName in ["SynologyViewUploads", "SynologyViewPhotoPicker"] {
            let directory = temporaryDirectory.appendingPathComponent(directoryName, isDirectory: true)
            guard let children = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for child in children {
                guard !protectedSourceDirectories.contains(child.standardizedFileURL.path),
                      let values = try? child.resourceValues(forKeys: [.contentModificationDateKey]),
                      (values.contentModificationDate ?? .distantPast) < cutoffDate else { continue }
                try? fileManager.removeItem(at: child)
            }
        }
    }

    private func cleanupUploadFiles(_ files: [SynologyUploadFile]) {
        for file in files {
            try? FileManager.default.removeItem(at: file.fileURL.deletingLastPathComponent())
        }
    }

    func loadMoveDestinationFolders(at path: String) async -> [SynologyFileItem] {
        do {
            guard let sessionID else {
                throw SynologyClientError.notAuthenticated
            }

            let client = try SynologyClient(serverURLString: serverURLString, sessionID: sessionID)
            let apis = discoveredAPIs.isEmpty ? try await client.discoverAPIs() : discoveredAPIs
            applyDiscoveredAPIs(apis)

            guard let fileStationListAPI else {
                throw SynologyClientError.missingAPI("SYNO.FileStation.List")
            }

            let normalizedFolderPath = normalizedPath(path)
            let items: [SynologyFileItem]
            if normalizedFolderPath.isEmpty {
                items = try await client.loadSharedFolders(api: fileStationListAPI)
            } else {
                items = try await client.loadFolder(api: fileStationListAPI, path: normalizedFolderPath)
            }

            return items
        } catch {
            statusMessage = error.localizedDescription
            return []
        }
    }

    private func authenticateAndLoad(otpCode: String?) async {
        isLoading = true
        statusMessage = otpCode == nil ? "正在连接服务器" : "正在验证两步验证码"
        defer { isLoading = false }

        do {
            try await authenticateAndLoadFolders(otpCode: otpCode)
        } catch SynologyClientError.apiError(403, "SYNO.API.Auth") where otpCode == nil {
            pendingOTPCode = ""
            isOTPDialogPresented = true
            statusMessage = "需要两步验证码"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func authenticateAndLoadFolders(otpCode: String?) async throws {
        let normalizedServerURLString = try normalizedServerURLString(serverURLString)
        let deviceID = settingsStore.loadDeviceID(serverURLString: normalizedServerURLString, account: account)
        let client = try SynologyClient(serverURLString: normalizedServerURLString)
        let apis = discoveredAPIs.isEmpty ? try await client.discoverAPIs() : discoveredAPIs
        guard let authAPI = apis.first(where: { $0.name == "SYNO.API.Auth" }) else {
            throw SynologyClientError.missingAPI("SYNO.API.Auth")
        }

        applyDiscoveredAPIs(apis)
        let loginResult = try await client.login(
            account: account,
            password: password,
            otpCode: otpCode,
            savedDeviceID: deviceID,
            shouldTrustDevice: trustsThisDevice,
            authAPI: authAPI
        )

        guard let fileStationListAPI else {
            throw SynologyClientError.missingAPI("SYNO.FileStation.List")
        }

        sessionID = loginResult.sid
        serverURLString = normalizedServerURLString
        currentPath = ""
        favoriteItems = []
        favoriteCurrentPath = ""
        favoriteBrowserItems = []
        pathHistory = []
        favoritePathHistory = []

        let authenticatedClient = try SynologyClient(serverURLString: normalizedServerURLString, sessionID: loginResult.sid)
        fileItems = try await authenticatedClient.loadSharedFolders(api: fileStationListAPI)

        settingsStore.save(
            serverURLString: normalizedServerURLString,
            account: account,
            password: password,
            deviceID: loginResult.deviceID
        )
        savedServers = settingsStore.load().savedServers
        pendingOTPCode = ""
        isOTPDialogPresented = false
        statusMessage = "登录成功，读取到 \(fileItems.count) 个共享文件夹"
    }

    private func applyDiscoveredAPIs(_ apis: [SynologyAPIInfo]) {
        discoveredAPIs = apis
        fileStationAPIs = apis.filter { $0.name.localizedCaseInsensitiveContains("FileStation") }
        authAPI = apis.first { $0.name == "SYNO.API.Auth" }
        fileStationListAPI = apis.first { $0.name == "SYNO.FileStation.List" }
        fileStationDownloadAPI = apis.first { $0.name == "SYNO.FileStation.Download" }
        fileStationFavoriteAPI = apis.first { $0.name == "SYNO.FileStation.Favorite" }
        fileStationThumbAPI = apis.first { $0.name == "SYNO.FileStation.Thumb" }
        fileStationUploadAPI = apis.first { $0.name == "SYNO.FileStation.Upload" }
        fileStationCreateFolderAPI = apis.first { $0.name == "SYNO.FileStation.CreateFolder" }
        fileStationRenameAPI = apis.first { $0.name == "SYNO.FileStation.Rename" }
        fileStationCopyMoveAPI = apis.first { $0.name == "SYNO.FileStation.CopyMove" }
        fileStationDeleteAPI = apis.first { $0.name == "SYNO.FileStation.Delete" }
        fileStationSearchAPI = apis.first { $0.name == "SYNO.FileStation.Search" }
    }

    private func normalizedServerURLString(_ string: String) throws -> String {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              components.scheme != nil,
              components.host != nil else {
            throw SynologyClientError.invalidURL
        }

        if let range = components.path.range(of: "/webapi/") {
            components.path = String(components.path[..<range.lowerBound])
        } else if components.path.hasSuffix("/webapi") {
            components.path = String(components.path.dropLast("/webapi".count))
        }

        if components.path.isEmpty {
            components.path = "/"
        } else if !components.path.hasSuffix("/") {
            components.path += "/"
        }

        components.query = nil
        components.fragment = nil

        guard let url = components.url else {
            throw SynologyClientError.invalidURL
        }

        return url.absoluteString
    }

    private func normalizedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }

        return trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
    }

    private func parentPath(for path: String) -> String {
        let normalized = normalizedPath(path)
        guard normalized != "/" else {
            return ""
        }

        let parent = URL(fileURLWithPath: normalized).deletingLastPathComponent().path
        return parent == "/" ? "" : parent
    }

    private func fileListContext() async throws -> (SynologyClient, SynologyAPIInfo) {
        guard let sessionID else {
            throw SynologyClientError.notAuthenticated
        }

        let client = try SynologyClient(serverURLString: serverURLString, sessionID: sessionID)
        let apis = discoveredAPIs.isEmpty ? try await client.discoverAPIs() : discoveredAPIs
        applyDiscoveredAPIs(apis)

        guard let fileStationListAPI else {
            throw SynologyClientError.missingAPI("SYNO.FileStation.List")
        }

        return (client, fileStationListAPI)
    }

    private func loadFileItems(at path: String, using client: SynologyClient, listAPI: SynologyAPIInfo) async throws -> [SynologyFileItem] {
        let normalizedTargetPath = normalizedPath(path)
        if normalizedTargetPath.isEmpty {
            return try await client.loadSharedFolders(api: listAPI)
        }

        return try await client.loadFolder(api: listAPI, path: normalizedTargetPath)
    }

    private func reloadAfterFileOperation(using client: SynologyClient) async throws {
        guard let fileStationListAPI else {
            throw SynologyClientError.missingAPI("SYNO.FileStation.List")
        }

        try await reloadCurrentLocation(using: client, listAPI: fileStationListAPI)

        if !favoriteItems.isEmpty, let fileStationFavoriteAPI {
            favoriteItems = try await client.loadFavorites(api: fileStationFavoriteAPI)
        }

        if !normalizedPath(favoriteCurrentPath).isEmpty {
            favoriteBrowserItems = try await client.loadFolder(api: fileStationListAPI, path: normalizedPath(favoriteCurrentPath))
        }
    }

    private func reloadCurrentLocation(using client: SynologyClient, listAPI: SynologyAPIInfo) async throws {
        let path = normalizedPath(currentPath)
        if path.isEmpty {
            fileItems = try await client.loadSharedFolders(api: listAPI)
            statusMessage = "读取到 \(fileItems.count) 个共享文件夹"
        } else {
            fileItems = try await client.loadFolder(api: listAPI, path: path)
            currentPath = path
            statusMessage = "读取到 \(fileItems.count) 个项目"
        }
    }

    private func runNetworkOperation(_ operation: () async throws -> Void) async {
        isLoading = true
        defer { isLoading = false }

        do {
            try await operation()
        } catch is CancellationError {
            return
        } catch {
            if isRequestCancellation(error) {
                return
            }

            statusMessage = error.localizedDescription
            if shouldReturnToLogin(for: error) {
                logout(message: "连接已失效，请重新登录")
            }
        }
    }

    private func logout(message: String) {
        sessionID = nil
        currentPath = ""
        fileItems = []
        favoriteItems = []
        favoriteCurrentPath = ""
        favoriteBrowserItems = []
        pathHistory = []
        favoritePathHistory = []
        previewItem = nil
        previewImageItems = []
        statusMessage = message
    }

    private func isRequestCancellation(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return urlError.code == .cancelled
        }

        return false
    }

    private func shouldReturnToLogin(for error: Error) -> Bool {
        if let clientError = error as? SynologyClientError {
            switch clientError {
            case .httpError, .notAuthenticated:
                return true
            case let .apiError(code, _):
                return code == 105 || code == 106 || code == 107 || code == 119 || code == 407
            default:
                return false
            }
        }

        return error is URLError
    }
}

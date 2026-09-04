import Foundation
import Observation

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

    private(set) var authAPI: SynologyAPIInfo?
    private(set) var fileStationListAPI: SynologyAPIInfo?
    private(set) var fileStationDownloadAPI: SynologyAPIInfo?
    private(set) var fileStationFavoriteAPI: SynologyAPIInfo?
    private(set) var fileStationRenameAPI: SynologyAPIInfo?
    private(set) var fileStationCopyMoveAPI: SynologyAPIInfo?
    private(set) var fileStationDeleteAPI: SynologyAPIInfo?
    private var sessionID: String?
    private let settingsStore = SynologyLoginSettingsStore()
    private let fileOperationSettingsStore = FileOperationSettingsStore()
    private let playbackProgressStore = PlaybackProgressStore()

    init() {
        let settings = settingsStore.load()
        serverURLString = settings.lastServer
        savedServers = settings.savedServers
        account = settings.lastAccount
        password = settingsStore.loadPassword(serverURLString: settings.lastServer, account: settings.lastAccount) ?? ""
        lastMoveDestinationPath = fileOperationSettingsStore.loadLastMoveDestinationPath()
    }

    var isConnected: Bool {
        sessionID != nil
    }

    var canGoUp: Bool {
        !currentPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func login() async {
        await authenticateAndLoad(otpCode: nil)
    }

    func loginWithOTP() async {
        await authenticateAndLoad(otpCode: pendingOTPCode)
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
        previewItem = nil
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

        currentPath = item.path
        await loadCurrentLocation()
    }

    func openFavoriteFolder(_ item: SynologyFileItem) async {
        guard item.isDirectory else {
            return
        }

        favoriteCurrentPath = item.path
        await loadFavoriteCurrentLocation()
    }

    func openParentFolder() async {
        let path = normalizedPath(currentPath)
        guard !path.isEmpty else {
            return
        }

        currentPath = parentPath(for: path)
        await loadCurrentLocation()
    }

    func openFavoriteParentFolder() async {
        let path = normalizedPath(favoriteCurrentPath)
        guard !path.isEmpty else {
            return
        }

        favoriteCurrentPath = parentPath(for: path)
        await loadFavoriteCurrentLocation()
    }

    func preview(_ item: SynologyFileItem) {
        do {
            guard item.isPreviewable else {
                throw SynologyClientError.unsupportedPreview
            }

            guard let sessionID else {
                throw SynologyClientError.notAuthenticated
            }

            let client = try SynologyClient(serverURLString: serverURLString, sessionID: sessionID)
            let url = try client.downloadURL(api: fileStationDownloadAPI, for: item.path)
            previewItem = SynologyFilePreviewItem(
                file: item,
                url: url,
                resumeTime: playbackProgressStore.progress(for: item.path)
            )
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func savePlaybackProgress(_ progress: TimeInterval, for item: SynologyFilePreviewItem) {
        playbackProgressStore.save(progress, for: item.file.path)
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

            return items.filter(\.isDirectory)
        } catch {
            statusMessage = error.localizedDescription
            return []
        }
    }

    private func authenticateAndLoad(otpCode: String?) async {
        isLoading = true
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
        fileStationRenameAPI = apis.first { $0.name == "SYNO.FileStation.Rename" }
        fileStationCopyMoveAPI = apis.first { $0.name == "SYNO.FileStation.CopyMove" }
        fileStationDeleteAPI = apis.first { $0.name == "SYNO.FileStation.Delete" }
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
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

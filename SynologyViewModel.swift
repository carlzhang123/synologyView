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
    var previewItem: SynologyFilePreviewItem?

    private(set) var authAPI: SynologyAPIInfo?
    private(set) var fileStationListAPI: SynologyAPIInfo?
    private var sessionID: String?
    private let settingsStore = SynologyLoginSettingsStore()

    init() {
        let settings = settingsStore.load()
        serverURLString = settings.lastServer
        savedServers = settings.savedServers
        account = settings.lastAccount
        password = settingsStore.loadPassword(serverURLString: settings.lastServer, account: settings.lastAccount) ?? ""
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

            let path = normalizedPath(currentPath)
            if path.isEmpty {
                fileItems = try await client.loadSharedFolders(api: fileStationListAPI)
                statusMessage = "读取到 \(fileItems.count) 个共享文件夹"
            } else {
                fileItems = try await client.loadFolder(api: fileStationListAPI, path: path)
                currentPath = path
                statusMessage = "读取到 \(fileItems.count) 个项目"
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

    func openParentFolder() async {
        let path = normalizedPath(currentPath)
        guard !path.isEmpty else {
            return
        }

        currentPath = parentPath(for: path)
        await loadCurrentLocation()
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
            let url = try client.downloadURL(for: item.path)
            previewItem = SynologyFilePreviewItem(file: item, url: url)
        } catch {
            statusMessage = error.localizedDescription
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

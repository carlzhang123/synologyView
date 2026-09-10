import Foundation

struct SynologyClient {
    let webAPIBaseURL: URL
    let sessionID: String?
    private let networkSession: URLSession

    init(serverURLString: String, sessionID: String? = nil) throws {
        guard let inputURL = URL(string: serverURLString) else {
            throw SynologyClientError.invalidURL
        }

        self.webAPIBaseURL = try Self.webAPIBaseURL(from: inputURL)
        self.sessionID = sessionID
        self.networkSession = SynologyNetworkSession.make()
    }

    func discoverAPIs() async throws -> [SynologyAPIInfo] {
        let url = try makeURL(
            path: "query.cgi",
            queryItems: [
                URLQueryItem(name: "api", value: "SYNO.API.Info"),
                URLQueryItem(name: "version", value: "1"),
                URLQueryItem(name: "method", value: "query"),
                URLQueryItem(name: "query", value: "all")
            ]
        )

        let response: SynologyInfoResponse = try await request(url)
        guard response.success, let data = response.data else {
            throw SynologyClientError.apiError(response.error?.code, apiName: "SYNO.API.Info")
        }

        return data.map { name, value in
            SynologyAPIInfo(
                name: name,
                minVersion: value.minVersion,
                maxVersion: value.maxVersion,
                path: value.path,
                requestFormat: value.requestFormat
            )
        }
        .sorted { $0.name < $1.name }
    }

    func login(
        account: String,
        password: String,
        otpCode: String?,
        savedDeviceID: String?,
        shouldTrustDevice: Bool,
        authAPI: SynologyAPIInfo
    ) async throws -> SynologyLoginResult {
        var parameters = [
            URLQueryItem(name: "account", value: account),
            URLQueryItem(name: "passwd", value: password),
            URLQueryItem(name: "session", value: "FileStation"),
            URLQueryItem(name: "format", value: "sid")
        ]

        let trimmedOTP = otpCode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedOTP.isEmpty {
            parameters.append(URLQueryItem(name: "otp_code", value: trimmedOTP))
        }

        if let savedDeviceID, !savedDeviceID.isEmpty {
            parameters.append(URLQueryItem(name: "device_id", value: savedDeviceID))
        }

        if shouldTrustDevice {
            parameters.append(URLQueryItem(name: "enable_device_token", value: "yes"))
            parameters.append(URLQueryItem(name: "device_name", value: "Synology View"))
        }

        let url = try makeAPIURL(
            api: authAPI,
            method: "login",
            version: min(authAPI.maxVersion, 7),
            parameters: parameters,
            includeSession: false
        )

        let response: SynologyAuthResponse = try await request(url)
        guard response.success, let sid = response.data?.sid, !sid.isEmpty else {
            throw SynologyClientError.apiError(response.error?.code, apiName: authAPI.name)
        }

        return SynologyLoginResult(sid: sid, deviceID: response.data?.deviceID)
    }

    func loadSharedFolders(api: SynologyAPIInfo) async throws -> [SynologyFileItem] {
        let url = try makeAPIURL(
            api: api,
            method: "list_share",
            version: api.maxVersion,
            parameters: [
                URLQueryItem(name: "limit", value: "200"),
                URLQueryItem(name: "offset", value: "0"),
                URLQueryItem(name: "additional", value: "[\"real_path\",\"owner\",\"time\",\"perm\",\"mount_point_type\"]")
            ],
            includeSession: true
        )

        let response: SynologyFileListResponse = try await request(url)
        guard response.success, let shares = response.data?.shares else {
            throw SynologyClientError.apiError(response.error?.code, apiName: api.name)
        }

        return shares.map(\.fileItem).sortedByKindAndName()
    }

    func loadFolder(api: SynologyAPIInfo, path: String) async throws -> [SynologyFileItem] {
        let pageSize = 500
        var offset = 0
        var allFiles: [SynologyFilePayload] = []

        while true {
            try Task.checkCancellation()
            let url = try makeAPIURL(
                api: api,
                method: "list",
                version: api.maxVersion,
                parameters: [
                    URLQueryItem(name: "folder_path", value: path),
                    URLQueryItem(name: "limit", value: "\(pageSize)"),
                    URLQueryItem(name: "offset", value: "\(offset)"),
                    URLQueryItem(name: "additional", value: "[\"real_path\",\"size\",\"owner\",\"time\",\"type\"]")
                ],
                includeSession: true
            )

            let response: SynologyFileListResponse = try await request(url)
            guard response.success, let data = response.data, let files = data.files else {
                throw SynologyClientError.apiError(response.error?.code, apiName: api.name)
            }

            allFiles.append(contentsOf: files)
            offset += files.count

            if files.isEmpty || offset >= (data.total ?? Int.max) || (data.total == nil && files.count < pageSize) {
                break
            }
        }

        return allFiles.map(\.fileItem).sortedByKindAndName()
    }

    func loadFavorites(api: SynologyAPIInfo) async throws -> [SynologyFileItem] {
        let url = try makeAPIURL(
            api: api,
            method: "list",
            version: min(api.maxVersion, 2),
            parameters: [
                URLQueryItem(name: "limit", value: "0"),
                URLQueryItem(name: "offset", value: "0"),
                URLQueryItem(name: "status_filter", value: "valid"),
                URLQueryItem(name: "additional", value: "[\"real_path\",\"size\",\"owner\",\"time\",\"type\"]")
            ],
            includeSession: true
        )

        let response: SynologyFavoriteListResponse = try await request(url)
        guard response.success, let favorites = response.data?.favorites else {
            throw SynologyClientError.apiError(response.error?.code, apiName: api.name)
        }

        return favorites.map(\.fileItem).sortedByKindAndName()
    }

    func search(
        api: SynologyAPIInfo,
        fileName: String,
        folderPaths: [String]
    ) async throws -> [SynologyFileItem] {
        var results: [SynologyFileItem] = []

        for folderPath in folderPaths {
            for attempt in 0..<3 {
                let taskID = try await startSearch(api: api, fileName: fileName, folderPath: folderPath)
                let taskResults = try await waitForSearchResults(api: api, taskID: taskID)
                try? await stopSearch(api: api, taskID: taskID)

                if !taskResults.isEmpty {
                    results.append(contentsOf: taskResults)
                    break
                }

                if attempt < 2 {
                    try await Task.sleep(for: .milliseconds(350))
                }
            }
        }

        return Dictionary(grouping: results, by: \.path)
            .compactMap { $0.value.first }
            .sortedByKindAndName()
    }

    private func startSearch(
        api: SynologyAPIInfo,
        fileName: String,
        folderPath: String
    ) async throws -> String {
        let url = try makeAPIURL(
            api: api,
            method: "start",
            version: min(api.maxVersion, 2),
            parameters: [
                URLQueryItem(name: "folder_path", value: try jsonEncodedString([folderPath])),
                URLQueryItem(name: "pattern", value: fileName),
                URLQueryItem(name: "recursive", value: "true"),
                URLQueryItem(name: "filetype", value: "all")
            ],
            includeSession: true
        )

        let response: SynologyFileOperationResponse = try await request(url)
        guard response.success, let taskID = response.data?.taskid, !taskID.isEmpty else {
            throw SynologyClientError.apiError(response.error?.code, apiName: api.name)
        }
        return taskID
    }

    private func waitForSearchResults(
        api: SynologyAPIInfo,
        taskID: String
    ) async throws -> [SynologyFileItem] {
        for _ in 0..<60 {
            try Task.checkCancellation()
            let url = try makeAPIURL(
                api: api,
                method: "list",
                version: min(api.maxVersion, 2),
                parameters: [
                    URLQueryItem(name: "taskid", value: taskID),
                    URLQueryItem(name: "offset", value: "0"),
                    URLQueryItem(name: "limit", value: "1000"),
                    URLQueryItem(name: "additional", value: "[\"size\",\"time\",\"type\"]")
                ],
                includeSession: true
            )

            let response: SynologyFileListResponse = try await request(url)
            guard response.success, let data = response.data else {
                throw SynologyClientError.apiError(response.error?.code, apiName: api.name)
            }
            if data.finished == true {
                return (data.files ?? []).map(\.fileItem)
            }
            try await Task.sleep(for: .milliseconds(250))
        }

        throw SynologyClientError.httpError(nil)
    }

    private func stopSearch(api: SynologyAPIInfo, taskID: String) async throws {
        let url = try makeAPIURL(
            api: api,
            method: "stop",
            version: min(api.maxVersion, 2),
            parameters: [URLQueryItem(name: "taskid", value: taskID)],
            includeSession: true
        )
        let response: SynologyFileOperationResponse = try await request(url)
        guard response.success else {
            throw SynologyClientError.apiError(response.error?.code, apiName: api.name)
        }
    }

    func createFolder(api: SynologyAPIInfo, parentPath: String, name: String) async throws {
        let url = try makeAPIURL(
            api: api,
            method: "create",
            version: min(api.maxVersion, 2),
            parameters: [
                URLQueryItem(name: "folder_path", value: try jsonEncodedString([parentPath])),
                URLQueryItem(name: "name", value: try jsonEncodedString([name])),
                URLQueryItem(name: "force_parent", value: "false")
            ],
            includeSession: true
        )

        let response: SynologyFileOperationResponse = try await request(url)
        guard response.success else {
            throw SynologyClientError.apiError(response.error?.code, apiName: api.name)
        }
    }

    func rename(api: SynologyAPIInfo, item: SynologyFileItem, newName: String) async throws {
        let url = try makeAPIURL(
            api: api,
            method: "rename",
            version: api.maxVersion,
            parameters: [
                URLQueryItem(name: "path", value: try jsonEncodedString([item.path])),
                URLQueryItem(name: "name", value: try jsonEncodedString([newName]))
            ],
            includeSession: true
        )

        let response: SynologyFileOperationResponse = try await request(url)
        guard response.success else {
            throw SynologyClientError.apiError(response.error?.code, apiName: api.name)
        }
    }

    func move(api: SynologyAPIInfo, items: [SynologyFileItem], destinationFolderPath: String) async throws {
        let url = try makeAPIURL(
            api: api,
            method: "start",
            version: min(api.maxVersion, 3),
            parameters: [
                URLQueryItem(name: "path", value: try jsonEncodedString(items.map(\.path))),
                URLQueryItem(name: "dest_folder_path", value: try jsonEncodedString(destinationFolderPath)),
                URLQueryItem(name: "remove_src", value: "true"),
                URLQueryItem(name: "accurate_progress", value: "true")
            ],
            includeSession: true
        )

        let response: SynologyFileOperationResponse = try await request(url)
        guard response.success, let taskID = response.data?.taskid, !taskID.isEmpty else {
            throw SynologyClientError.apiError(response.error?.code, apiName: api.name)
        }

        try await waitForOperationCompletion(api: api, taskID: taskID)
    }

    func delete(api: SynologyAPIInfo, items: [SynologyFileItem]) async throws {
        let url = try makeAPIURL(
            api: api,
            method: "start",
            version: min(api.maxVersion, 2),
            parameters: [
                URLQueryItem(name: "path", value: try jsonEncodedString(items.map(\.path))),
                URLQueryItem(name: "accurate_progress", value: "true"),
                URLQueryItem(name: "recursive", value: "true")
            ],
            includeSession: true
        )

        let response: SynologyFileOperationResponse = try await request(url)
        guard response.success, let taskID = response.data?.taskid, !taskID.isEmpty else {
            throw SynologyClientError.apiError(response.error?.code, apiName: api.name)
        }

        try await waitForOperationCompletion(api: api, taskID: taskID)
    }

    func upload(
        api: SynologyAPIInfo,
        file: SynologyUploadFile,
        to destinationPath: String,
        taskID: UUID,
        progressHandler: @escaping (Double) -> Void
    ) async throws {
        guard sessionID != nil else {
            throw SynologyClientError.notAuthenticated
        }

        let url = try makeAPIURL(
            api: api,
            method: "upload",
            version: min(api.maxVersion, 2),
            parameters: [],
            includeSession: true
        )
        let boundary = "Boundary-\(UUID().uuidString)"
        let multipartURL = try makeMultipartUploadFile(
            sourceFile: file,
            destinationPath: destinationPath,
            boundary: boundary,
            taskID: taskID
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await BackgroundUploadManager.shared.upload(
            request: request,
            fileURL: multipartURL,
            taskID: taskID,
            progressHandler: progressHandler,
            allowsInsecureConnections: SynologyNetworkSession.allowsInsecureConnections
        )
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw SynologyClientError.httpError((response as? HTTPURLResponse)?.statusCode)
        }

        let uploadResponse = try JSONDecoder().decode(SynologyUploadResponse.self, from: data)
        guard uploadResponse.success else {
            throw SynologyClientError.apiError(uploadResponse.error?.code, apiName: api.name)
        }
        progressHandler(1)
    }

    func thumbnailURL(api: SynologyAPIInfo?, for path: String, size: String = "small") throws -> URL {
        guard sessionID != nil else {
            throw SynologyClientError.notAuthenticated
        }

        let parameters = [
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "size", value: size)
        ]

        if let api {
            return try makeAPIURL(
                api: api,
                method: "get",
                version: api.maxVersion,
                parameters: parameters,
                includeSession: true
            )
        }

        var queryItems = [
            URLQueryItem(name: "api", value: "SYNO.FileStation.Thumb"),
            URLQueryItem(name: "version", value: "2"),
            URLQueryItem(name: "method", value: "get")
        ]
        queryItems.append(contentsOf: parameters)

        if let sessionID {
            queryItems.append(URLQueryItem(name: "_sid", value: sessionID))
        }

        return try makeURL(path: "entry.cgi", queryItems: queryItems)
    }

    func downloadURL(api: SynologyAPIInfo?, for path: String) throws -> URL {
        try downloadURLVariants(api: api, for: path).first ?? makeDownloadURL(api: api, pathValue: path, mode: "open")
    }

    func downloadData(api: SynologyAPIInfo?, for path: String) async throws -> Data {
        let url = try downloadURL(api: api, for: path)
        var request = URLRequest(url: url)
        request.timeoutInterval = 30

        let (data, response) = try await networkSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw SynologyClientError.httpError((response as? HTTPURLResponse)?.statusCode)
        }
        return data
    }

    func downloadURLVariants(api: SynologyAPIInfo?, for path: String) throws -> [URL] {
        guard sessionID != nil else {
            throw SynologyClientError.notAuthenticated
        }

        let pathValues = [
            path,
            try jsonEncodedString(path),
            try jsonEncodedString([path])
        ]
        let modes = ["open", "download"]

        var urls: [URL] = []
        for mode in modes {
            for pathValue in pathValues {
                for candidateAPI in [api, nil] {
                    let url = try makeDownloadURL(api: candidateAPI, pathValue: pathValue, mode: mode)
                    if !urls.contains(url) {
                        urls.append(url)
                    }
                }
            }
        }
        return urls
    }

    private func makeDownloadURL(api: SynologyAPIInfo?, pathValue: String, mode: String) throws -> URL {
        let parameters = [
            URLQueryItem(name: "path", value: pathValue),
            URLQueryItem(name: "mode", value: mode)
        ]

        if let api {
            return try makeAPIURL(
                api: api,
                method: "download",
                version: api.maxVersion,
                parameters: parameters,
                includeSession: true
            )
        }

        var queryItems = [
            URLQueryItem(name: "api", value: "SYNO.FileStation.Download"),
            URLQueryItem(name: "version", value: "2"),
            URLQueryItem(name: "method", value: "download")
        ]
        queryItems.append(contentsOf: parameters)

        if let sessionID {
            queryItems.append(URLQueryItem(name: "_sid", value: sessionID))
        }

        return try makeURL(path: "entry.cgi", queryItems: queryItems)
    }

    private func waitForOperationCompletion(api: SynologyAPIInfo, taskID: String) async throws {
        for _ in 0..<12 {
            let url = try makeAPIURL(
                api: api,
                method: "status",
                version: min(api.maxVersion, 3),
                parameters: [
                    URLQueryItem(name: "taskid", value: try jsonEncodedString(taskID))
                ],
                includeSession: true
            )

            let response: SynologyFileOperationResponse = try await request(url)
            guard response.success else {
                throw SynologyClientError.apiError(response.error?.code, apiName: api.name)
            }

            if response.data?.finished == true {
                return
            }

            try await Task.sleep(for: .milliseconds(500))
        }
    }

    private func makeMultipartUploadFile(
        sourceFile: SynologyUploadFile,
        destinationPath: String,
        boundary: String,
        taskID: UUID
    ) throws -> URL {
        let multipartURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SynologyViewMultipart-\(taskID.uuidString).body")
        if FileManager.default.fileExists(atPath: multipartURL.path) {
            try FileManager.default.removeItem(at: multipartURL)
        }
        FileManager.default.createFile(atPath: multipartURL.path, contents: nil)

        let handle = try FileHandle(forWritingTo: multipartURL)
        defer { try? handle.close() }

        try appendFormField(name: "path", value: destinationPath, boundary: boundary, to: handle)
        try appendFormField(name: "create_parents", value: "false", boundary: boundary, to: handle)
        try appendFormField(name: "overwrite", value: "true", boundary: boundary, to: handle)
        try appendFileField(sourceFile, boundary: boundary, to: handle)
        try handle.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))

        return multipartURL
    }

    private func appendFormField(name: String, value: String, boundary: String, to handle: FileHandle) throws {
        let field = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
        try handle.write(contentsOf: Data(field.utf8))
    }

    private func appendFileField(_ sourceFile: SynologyUploadFile, boundary: String, to handle: FileHandle) throws {
        let header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(sourceFile.fileName)\"\r\nContent-Type: application/octet-stream\r\n\r\n"
        try handle.write(contentsOf: Data(header.utf8))

        let input = try FileHandle(forReadingFrom: sourceFile.fileURL)
        defer { try? input.close() }

        while true {
            let chunk = try input.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty {
                break
            }
            try handle.write(contentsOf: chunk)
        }
    }

    private static func webAPIBaseURL(from inputURL: URL) throws -> URL {
        guard var components = URLComponents(url: inputURL, resolvingAgainstBaseURL: false),
              components.scheme != nil,
              components.host != nil else {
            throw SynologyClientError.invalidURL
        }

        let path = inputURL.path
        if let range = path.range(of: "/webapi/") {
            components.path = String(path[..<range.upperBound])
        } else if path.hasSuffix("/webapi") {
            components.path = path + "/"
        } else {
            components.path = "/webapi/"
        }

        components.query = nil
        components.fragment = nil

        guard let url = components.url else {
            throw SynologyClientError.invalidURL
        }

        return url
    }

    private func makeAPIURL(
        api: SynologyAPIInfo,
        method: String,
        version: Int,
        parameters: [URLQueryItem],
        includeSession: Bool
    ) throws -> URL {
        var queryItems = [
            URLQueryItem(name: "api", value: api.name),
            URLQueryItem(name: "version", value: "\(version)"),
            URLQueryItem(name: "method", value: method)
        ]
        queryItems.append(contentsOf: parameters)

        if includeSession, let sessionID {
            queryItems.append(URLQueryItem(name: "_sid", value: sessionID))
        }

        return try makeURL(path: api.path, queryItems: queryItems)
    }

    private func makeURL(path: String, queryItems: [URLQueryItem]) throws -> URL {
        let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let url = webAPIBaseURL.appendingPathComponent(cleanPath)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw SynologyClientError.invalidURL
        }

        components.percentEncodedQueryItems = queryItems.map { item in
            URLQueryItem(
                name: percentEncodedQueryComponent(item.name),
                value: item.value.map(percentEncodedQueryComponent)
            )
        }

        guard let finalURL = components.url else {
            throw SynologyClientError.invalidURL
        }

        return finalURL
    }

    private func percentEncodedQueryComponent(_ value: String) -> String {
        var allowedCharacters = CharacterSet.urlQueryAllowed
        allowedCharacters.remove(charactersIn: "+&=?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? value
    }

    private func jsonEncodedString<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw SynologyClientError.decodingFailed
        }

        return string
    }

    private func request<Response: Decodable>(_ url: URL) async throws -> Response {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20

        let (data, response) = try await networkSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw SynologyClientError.httpError((response as? HTTPURLResponse)?.statusCode)
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw SynologyClientError.decodingFailed
        }
    }
}

enum SynologyNetworkSession {
    static var allowsInsecureConnections: Bool {
        UserDefaults.standard.bool(forKey: SynologyLoginSettingsStore.allowsInsecureConnectionsKey)
    }

    private static let secureSession = makeSession(allowsInsecureConnections: false)
    private static let insecureSession = makeSession(allowsInsecureConnections: true)

    static func make() -> URLSession {
        allowsInsecureConnections ? insecureSession : secureSession
    }

    private static func makeSession(allowsInsecureConnections: Bool) -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(
            memoryCapacity: 8 * 1024 * 1024,
            diskCapacity: 64 * 1024 * 1024
        )
        return URLSession(
            configuration: configuration,
            delegate: ServerTrustDelegate(allowsInsecureConnections: allowsInsecureConnections),
            delegateQueue: nil
        )
    }
}

private final class ServerTrustDelegate: NSObject, URLSessionDelegate {
    private let allowsInsecureConnections: Bool

    init(allowsInsecureConnections: Bool) {
        self.allowsInsecureConnections = allowsInsecureConnections
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard allowsInsecureConnections,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }
}

struct BackgroundUploadEvent: Sendable {
    let taskID: UUID
    let progress: Double
    let status: UploadProgressStatus
    let errorMessage: String?
}

final class BackgroundUploadManager: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = BackgroundUploadManager()
    static let sessionIdentifier = "com.synologyview.background-upload"

    private struct ActiveUpload {
        let continuation: CheckedContinuation<(Data, URLResponse), Error>
        let progressHandler: (Double) -> Void
    }

    private let stateQueue = DispatchQueue(label: "com.synologyview.background-upload.state")
    private var activeUploads: [Int: ActiveUpload] = [:]
    private var responseData: [Int: Data] = [:]
    private var eventHandler: ((BackgroundUploadEvent) -> Void)?
    private var pendingEvents: [BackgroundUploadEvent] = []
    private var backgroundEventsCompletionHandler: (() -> Void)?

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.allowsCellularAccess = true
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
        _ = session
    }

    func upload(
        request: URLRequest,
        fileURL: URL,
        taskID: UUID,
        progressHandler: @escaping (Double) -> Void,
        allowsInsecureConnections: Bool
    ) async throws -> (Data, URLResponse) {
        _ = allowsInsecureConnections
        return try await withCheckedThrowingContinuation { continuation in
            let task = session.uploadTask(with: request, fromFile: fileURL)
            task.taskDescription = taskID.uuidString
            stateQueue.sync {
                activeUploads[task.taskIdentifier] = ActiveUpload(
                    continuation: continuation,
                    progressHandler: progressHandler
                )
                responseData[task.taskIdentifier] = Data()
            }
            task.resume()
        }
    }

    func setEventHandler(_ handler: @escaping (BackgroundUploadEvent) -> Void) {
        let events = stateQueue.sync { () -> [BackgroundUploadEvent] in
            eventHandler = handler
            defer { pendingEvents.removeAll() }
            return pendingEvents
        }
        events.forEach(handler)
    }

    func activeTaskIDs() async -> Set<UUID> {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                continuation.resume(returning: Set(tasks.compactMap { task in
                    task.taskDescription.flatMap(UUID.init(uuidString:))
                }))
            }
        }
    }

    func handleEvents(completionHandler: @escaping () -> Void) {
        stateQueue.sync {
            backgroundEventsCompletionHandler = completionHandler
        }
        _ = session
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard SynologyNetworkSession.allowsInsecureConnections,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0,
              let taskID = task.taskDescription.flatMap(UUID.init(uuidString:)) else {
            return
        }

        let progress = min(max(Double(totalBytesSent) / Double(totalBytesExpectedToSend), 0), 1)
        let handler = stateQueue.sync { activeUploads[task.taskIdentifier]?.progressHandler }
        handler?(progress)
        emit(BackgroundUploadEvent(taskID: taskID, progress: progress, status: .uploading, errorMessage: nil))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        stateQueue.sync {
            responseData[dataTask.taskIdentifier, default: Data()].append(data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let taskID = task.taskDescription.flatMap(UUID.init(uuidString:))
        let result = stateQueue.sync { () -> (ActiveUpload?, Data) in
            (activeUploads.removeValue(forKey: task.taskIdentifier), responseData.removeValue(forKey: task.taskIdentifier) ?? Data())
        }

        if let taskID {
            try? FileManager.default.removeItem(at: multipartFileURL(for: taskID))
            let event = completionEvent(taskID: taskID, data: result.1, response: task.response, error: error)
            emit(event)
        }

        if let activeUpload = result.0 {
            if let error {
                activeUpload.continuation.resume(throwing: error)
            } else if let response = task.response {
                activeUpload.continuation.resume(returning: (result.1, response))
            } else {
                activeUpload.continuation.resume(throwing: SynologyClientError.httpError(nil))
            }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completionHandler = stateQueue.sync { () -> (() -> Void)? in
            defer { backgroundEventsCompletionHandler = nil }
            return backgroundEventsCompletionHandler
        }
        DispatchQueue.main.async {
            completionHandler?()
        }
    }

    private func completionEvent(
        taskID: UUID,
        data: Data,
        response: URLResponse?,
        error: Error?
    ) -> BackgroundUploadEvent {
        if let error {
            return BackgroundUploadEvent(taskID: taskID, progress: 0, status: .failed, errorMessage: error.localizedDescription)
        }
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            return BackgroundUploadEvent(taskID: taskID, progress: 0, status: .failed, errorMessage: "后台上传请求失败")
        }
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              payload["success"] as? Bool == true else {
            return BackgroundUploadEvent(taskID: taskID, progress: 0, status: .failed, errorMessage: "群晖未能完成后台上传")
        }
        return BackgroundUploadEvent(taskID: taskID, progress: 1, status: .finished, errorMessage: nil)
    }

    private func emit(_ event: BackgroundUploadEvent) {
        let handler = stateQueue.sync { () -> ((BackgroundUploadEvent) -> Void)? in
            guard let eventHandler else {
                pendingEvents.append(event)
                return nil
            }
            return eventHandler
        }
        handler?(event)
    }

    private func multipartFileURL(for taskID: UUID) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SynologyViewMultipart-\(taskID.uuidString).body")
    }
}

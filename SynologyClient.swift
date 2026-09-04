import Foundation

struct SynologyClient {
    let webAPIBaseURL: URL
    let sessionID: String?

    init(serverURLString: String, sessionID: String? = nil) throws {
        guard let inputURL = URL(string: serverURLString) else {
            throw SynologyClientError.invalidURL
        }

        self.webAPIBaseURL = try Self.webAPIBaseURL(from: inputURL)
        self.sessionID = sessionID
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
        let url = try makeAPIURL(
            api: api,
            method: "list",
            version: api.maxVersion,
            parameters: [
                URLQueryItem(name: "folder_path", value: path),
                URLQueryItem(name: "limit", value: "500"),
                URLQueryItem(name: "offset", value: "0"),
                URLQueryItem(name: "additional", value: "[\"real_path\",\"size\",\"owner\",\"time\",\"type\"]")
            ],
            includeSession: true
        )

        let response: SynologyFileListResponse = try await request(url)
        guard response.success, let files = response.data?.files else {
            throw SynologyClientError.apiError(response.error?.code, apiName: api.name)
        }

        return files.map(\.fileItem).sortedByKindAndName()
    }

    func downloadURL(for path: String) throws -> URL {
        guard sessionID != nil else {
            throw SynologyClientError.notAuthenticated
        }

        return try makeURL(
            path: "entry.cgi",
            queryItems: [
                URLQueryItem(name: "api", value: "SYNO.FileStation.Download"),
                URLQueryItem(name: "version", value: "2"),
                URLQueryItem(name: "method", value: "download"),
                URLQueryItem(name: "path", value: path),
                URLQueryItem(name: "mode", value: "open"),
                URLQueryItem(name: "_sid", value: sessionID)
            ]
        )
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

        components.queryItems = queryItems

        guard let finalURL = components.url else {
            throw SynologyClientError.invalidURL
        }

        return finalURL
    }

    private func request<Response: Decodable>(_ url: URL) async throws -> Response {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
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

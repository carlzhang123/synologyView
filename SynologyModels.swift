import Foundation

struct SynologyAPIInfo: Identifiable, Equatable {
    let name: String
    let minVersion: Int
    let maxVersion: Int
    let path: String
    let requestFormat: String?

    var id: String { name }
}

struct SynologyLoginResult: Equatable {
    let sid: String
    let deviceID: String?
}

struct SynologyFilePreviewItem: Identifiable, Equatable {
    let file: SynologyFileItem
    let url: URL
    let playbackURLs: [URL]
    let resumeTime: TimeInterval
    let knownDuration: TimeInterval
    let imageGallery: [SynologyImagePreviewItem]

    var id: String { file.id }
}

struct SynologyImagePreviewItem: Identifiable, Equatable {
    let file: SynologyFileItem
    let url: URL

    var id: String { file.path }
}

struct SynologyUploadFile: Equatable {
    let fileURL: URL
    let fileName: String
    let creationDate: Date?
}

struct UploadProgressItem: Identifiable, Equatable {
    let id: UUID
    let fileName: String
    let destinationPath: String
    var progress: Double
    var status: UploadProgressStatus
    var errorMessage: String?

    var progressText: String {
        switch status {
        case .queued:
            return "等待中"
        case .uploading:
            return "\(Int(progress * 100))%"
        case .finished:
            return "已完成"
        case .failed:
            return "失败"
        }
    }
}

enum UploadProgressStatus: Equatable {
    case queued
    case uploading
    case finished
    case failed
}

struct SynologyFileItem: Identifiable, Equatable {
    let id: String
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64?
    let modifiedTime: Date?

    var detail: String {
        var parts: [String] = []

        if isDirectory {
            parts.append("文件夹")
        } else if isVideo {
            parts.append("视频")
        } else if isImage {
            parts.append("图片")
        } else {
            parts.append("文件")
        }

        if let size {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }

        if let modifiedTime {
            parts.append(modifiedTime.formatted(date: .numeric, time: .shortened))
        }

        return parts.joined(separator: " · ")
    }

    var isPreviewable: Bool {
        isVideo || isImage
    }

    var isVideo: Bool {
        let videoExtensions: Set<String> = ["avi", "m2ts", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "mts", "ts", "webm", "wmv"]
        return videoExtensions.contains(fileExtension)
    }

    var isImage: Bool {
        let imageExtensions: Set<String> = ["bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp"]
        return imageExtensions.contains(fileExtension)
    }

    private var fileExtension: String {
        let nameExtension = URL(fileURLWithPath: name).pathExtension.lowercased()
        if !nameExtension.isEmpty {
            return nameExtension
        }

        return URL(fileURLWithPath: path).pathExtension.lowercased()
    }
}

struct SynologyInfoResponse: Decodable {
    let success: Bool
    let data: [String: SynologyAPIInfoPayload]?
    let error: SynologyErrorPayload?
}

struct SynologyAPIInfoPayload: Decodable {
    let minVersion: Int
    let maxVersion: Int
    let path: String
    let requestFormat: String?
}

struct SynologyAuthResponse: Decodable {
    let success: Bool
    let data: SynologyAuthPayload?
    let error: SynologyErrorPayload?
}

struct SynologyAuthPayload: Decodable {
    let sid: String
    let deviceID: String?

    private enum CodingKeys: String, CodingKey {
        case sid
        case deviceID = "device_id"
    }
}

struct SynologyFileListResponse: Decodable {
    let success: Bool
    let data: SynologyFileListData?
    let error: SynologyErrorPayload?
}

struct SynologyFileListData: Decodable {
    let shares: [SynologyFilePayload]?
    let files: [SynologyFilePayload]?
    let finished: Bool?
}

struct SynologyFavoriteListResponse: Decodable {
    let success: Bool
    let data: SynologyFavoriteListData?
    let error: SynologyErrorPayload?
}

struct SynologyFavoriteListData: Decodable {
    let favorites: [SynologyFavoritePayload]?
}

struct SynologyFavoritePayload: Decodable {
    let name: String
    let path: String
    let isdir: Bool
    let status: String?
    let additional: SynologyFileAdditionalPayload?

    var fileItem: SynologyFileItem {
        SynologyFileItem(
            id: "favorite:\(path)",
            name: name,
            path: path,
            isDirectory: isdir,
            size: additional?.size,
            modifiedTime: additional?.time?.modifiedDate
        )
    }
}

struct SynologyFileOperationResponse: Decodable {
    let success: Bool
    let data: SynologyFileOperationData?
    let error: SynologyErrorPayload?
}

struct SynologyUploadResponse: Decodable {
    let success: Bool
    let error: SynologyErrorPayload?
}

struct SynologyFileOperationData: Decodable {
    let taskid: String?
    let finished: Bool?
}

struct SynologyFilePayload: Decodable {
    let name: String
    let path: String
    let isdir: Bool
    let additional: SynologyFileAdditionalPayload?

    var fileItem: SynologyFileItem {
        SynologyFileItem(
            id: path,
            name: name,
            path: path,
            isDirectory: isdir,
            size: additional?.size,
            modifiedTime: additional?.time?.modifiedDate
        )
    }
}

struct SynologyFileAdditionalPayload: Decodable {
    let size: Int64?
    let time: SynologyFileTimePayload?
}

struct SynologyFileTimePayload: Decodable {
    let mtime: Int?

    var modifiedDate: Date? {
        guard let mtime else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(mtime))
    }
}

struct SynologyErrorPayload: Decodable {
    let code: Int
}

extension Array where Element == SynologyFileItem {
    func sortedByKindAndName() -> [SynologyFileItem] {
        sorted { first, second in
            if first.isDirectory != second.isDirectory {
                return first.isDirectory
            }

            if first.isVideo != second.isVideo {
                return first.isVideo
            }

            if first.isImage != second.isImage {
                return first.isImage
            }

            return first.name.localizedStandardCompare(second.name) == .orderedAscending
        }
    }
}

enum SynologyClientError: LocalizedError, Equatable {
    case invalidURL
    case httpError(Int?)
    case apiError(Int?, apiName: String)
    case missingAPI(String)
    case notAuthenticated
    case decodingFailed
    case unsupportedPreview
    case invalidFileName
    case invalidDestinationPath

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "服务器地址无效"
        case let .httpError(statusCode):
            return "HTTP 请求失败：\(statusCode.map(String.init) ?? "未知状态码")"
        case let .apiError(code, apiName):
            return Self.apiErrorDescription(code: code, apiName: apiName)
        case let .missingAPI(name):
            return "没有发现接口：\(name)"
        case .notAuthenticated:
            return "请先登录"
        case .decodingFailed:
            return "无法解析群晖返回的数据"
        case .unsupportedPreview:
            return "当前文件暂不支持预览"
        case .invalidFileName:
            return "文件名无效，不能为空，也不能包含 /"
        case .invalidDestinationPath:
            return "目标文件夹路径无效"
        }
    }

    private static func apiErrorDescription(code: Int?, apiName: String) -> String {
        guard let code else {
            return "\(apiName) 返回未知错误"
        }

        if apiName == "SYNO.API.Auth" {
            switch code {
            case 400:
                return "登录失败：账号或密码错误，或登录参数无效（400）"
            case 401:
                return "登录失败：账号已停用（401）"
            case 402:
                return "登录失败：账号没有权限使用此服务（402）"
            case 403:
                return "登录失败：此账号需要两步验证码，请填写验证码后重试（403）"
            case 404:
                return "登录失败：两步验证码错误（404）"
            case 406:
                return "登录失败：账号被要求启用两步验证后才能登录（406）"
            case 407:
                return "登录失败：尝试次数过多，IP 可能已被群晖暂时封锁（407）"
            default:
                return "登录失败：SYNO.API.Auth 返回错误 \(code)"
            }
        }

        if apiName == "SYNO.FileStation.List" {
            switch code {
            case 400:
                return "读取文件夹失败：FileStation 参数无效，可能是路径不存在或账号无权访问（400）"
            case 401:
                return "读取文件夹失败：账号没有 FileStation 权限（401）"
            case 402:
                return "读取文件夹失败：路径不存在（402）"
            case 407:
                return "读取文件夹失败：当前 session 已失效，请重新登录（407）"
            default:
                return "读取文件夹失败：SYNO.FileStation.List 返回错误 \(code)"
            }
        }

        if apiName == "SYNO.FileStation.Favorite" {
            switch code {
            case 400:
                return "读取收藏夹失败：参数无效（400）"
            case 401:
                return "读取收藏夹失败：账号没有 FileStation 权限（401）"
            case 407:
                return "读取收藏夹失败：当前 session 已失效，请重新登录（407）"
            default:
                return "读取收藏夹失败：SYNO.FileStation.Favorite 返回错误 \(code)"
            }
        }

        if apiName == "SYNO.FileStation.Rename" {
            switch code {
            case 400:
                return "重命名失败：参数无效（400）"
            case 401:
                return "重命名失败：没有 FileStation 权限（401）"
            case 407:
                return "重命名失败：当前 session 已失效，请重新登录（407）"
            case 1200:
                return "重命名失败：群晖无法完成该重命名（1200）"
            default:
                return "重命名失败：SYNO.FileStation.Rename 返回错误 \(code)"
            }
        }

        if apiName == "SYNO.FileStation.CopyMove" {
            switch code {
            case 400:
                return "移动失败：参数无效（400）"
            case 401:
                return "移动失败：没有 FileStation 权限（401）"
            case 407:
                return "移动失败：当前 session 已失效，请重新登录（407）"
            case 1001:
                return "移动失败：群晖无法移动该文件或文件夹（1001）"
            case 1002:
                return "移动失败：目标文件夹发生错误（1002）"
            case 1003:
                return "移动失败：目标位置已有同名项目，需要选择覆盖或跳过（1003）"
            case 1004:
                return "移动失败：文件和文件夹同名冲突（1004）"
            default:
                return "移动失败：SYNO.FileStation.CopyMove 返回错误 \(code)"
            }
        }

        if apiName == "SYNO.FileStation.Delete" {
            switch code {
            case 400:
                return "删除失败：参数无效（400）"
            case 401:
                return "删除失败：没有 FileStation 权限（401）"
            case 407:
                return "删除失败：当前 session 已失效，请重新登录（407）"
            case 900:
                return "删除失败：群晖无法删除这些文件或文件夹（900）"
            default:
                return "删除失败：SYNO.FileStation.Delete 返回错误 \(code)"
            }
        }

        return "\(apiName) 返回错误 \(code)"
    }
}

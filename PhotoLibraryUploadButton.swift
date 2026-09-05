import CoreTransferable
import Foundation
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct PhotoLibraryUploadButton: View {
    let destinationPath: String
    let isDisabled: Bool
    let uploadAction: ([SynologyUploadFile], String) async -> Void

    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var isPreparingUpload = false
    @State private var errorMessage: String?

    var body: some View {
        PhotosPicker(
            selection: $selectedItems,
            maxSelectionCount: 20,
            matching: .any(of: [.images, .videos]),
            preferredItemEncoding: .current
        ) {
            Label("上传", systemImage: isPreparingUpload ? "arrow.triangle.2.circlepath" : "square.and.arrow.up")
        }
        .disabled(isDisabled || isPreparingUpload)
        .onChange(of: selectedItems) {
            guard !selectedItems.isEmpty else {
                return
            }

            let items = selectedItems
            selectedItems = []
            Task {
                await prepareAndUpload(items)
            }
        }
        .alert("上传失败", isPresented: errorBinding) {
            Button("好", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding {
            errorMessage != nil
        } set: { isPresented in
            if !isPresented {
                errorMessage = nil
            }
        }
    }

    private func prepareAndUpload(_ items: [PhotosPickerItem]) async {
        isPreparingUpload = true
        defer { isPreparingUpload = false }

        do {
            let files = try await items.asyncCompactMap { item in
                try await uploadFile(from: item)
            }
            guard !files.isEmpty else {
                return
            }

            await uploadAction(files, destinationPath)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func uploadFile(from item: PhotosPickerItem) async throws -> SynologyUploadFile? {
        guard let pickedFile = try await item.loadTransferable(type: PhotoLibraryTransferFile.self) else {
            return nil
        }

        let metadata = metadata(for: item.itemIdentifier)
        let creationDate = metadata.creationDate
        let fileName = metadata.fileName ?? pickedFile.url.lastPathComponent
        let uploadURL = try copyFileForUpload(pickedFile.url, fileName: fileName, creationDate: creationDate)
        try? FileManager.default.removeItem(at: pickedFile.url.deletingLastPathComponent())

        return SynologyUploadFile(
            fileURL: uploadURL,
            fileName: fileName,
            creationDate: creationDate
        )
    }

    private func metadata(for itemIdentifier: String?) -> (fileName: String?, creationDate: Date?) {
        guard let itemIdentifier else {
            return (nil, nil)
        }

        let result = PHAsset.fetchAssets(withLocalIdentifiers: [itemIdentifier], options: nil)
        guard let asset = result.firstObject else {
            return (nil, nil)
        }

        let fileName = PHAssetResource.assetResources(for: asset).first?.originalFilename
        return (fileName, asset.creationDate)
    }

    private func copyFileForUpload(_ sourceURL: URL, fileName: String, creationDate: Date?) throws -> URL {
        let uploadsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SynologyViewUploads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: uploadsDirectory, withIntermediateDirectories: true)

        let destinationURL = uploadsDirectory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

        if let creationDate {
            try? FileManager.default.setAttributes(
                [
                    .creationDate: creationDate,
                    .modificationDate: creationDate
                ],
                ofItemAtPath: destinationURL.path
            )
        }

        return destinationURL
    }

}

private struct PhotoLibraryTransferFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            try Self.copyTransferredFile(received.file)
        }
        FileRepresentation(importedContentType: .movie) { received in
            try Self.copyTransferredFile(received.file)
        }
    }

    private static func copyTransferredFile(_ sourceURL: URL) throws -> PhotoLibraryTransferFile {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SynologyViewPhotoPicker", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let destinationURL = directory.appendingPathComponent(sourceURL.lastPathComponent)
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return PhotoLibraryTransferFile(url: destinationURL)
    }
}

private extension Array {
    func asyncCompactMap<T>(_ transform: (Element) async throws -> T?) async throws -> [T] {
        var values: [T] = []
        for element in self {
            if let value = try await transform(element) {
                values.append(value)
            }
        }
        return values
    }
}

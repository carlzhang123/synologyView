//
//  ContentView.swift
//  SynologyView
//
//  Created by 张杰 on 2026/9/4.
//

import SwiftUI

struct ContentView: View {
    @State private var model = SynologyViewModel()
    @State private var cinemaViewingStateRevision = 0

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            if model.isConnected {
                FileBrowserView(
                    currentPath: $model.currentPath,
                    serverURLString: model.serverURLString,
                    account: model.account,
                    fileItems: model.fileItems,
                    favoriteItems: model.favoriteItems,
                    favoriteCurrentPath: model.favoriteCurrentPath,
                    favoriteBrowserItems: model.favoriteBrowserItems,
                    isLoading: model.isLoading,
                    uploadProgressItems: model.uploadProgressItems,
                    canGoUp: model.canGoUp,
                    canGoBack: model.canGoBack,
                    canGoFavoriteBack: model.canGoFavoriteBack,
                    refreshAction: {
                        await model.loadCurrentLocation()
                    },
                    loadFavoritesAction: {
                        Task { await model.loadFavorites() }
                    },
                    refreshFavoriteLocationAction: {
                        await model.loadFavoriteCurrentLocation()
                    },
                    openFolderAction: { item in
                        Task { await model.openFolder(item) }
                    },
                    openFavoriteFolderAction: { item in
                        Task { await model.openFavoriteFolder(item) }
                    },
                    previewAction: { item, contextItems in
                        model.preview(item, in: contextItems)
                    },
                    thumbnailURLAction: { item in
                        model.thumbnailURL(for: item)
                    },
                    uploadMediaAction: { files, destinationPath in
                        await model.upload(files, to: destinationPath)
                    },
                    renameAction: { item, newName in
                        Task { await model.rename(item, to: newName) }
                    },
                    moveAction: { items, destinationPath in
                        Task { await model.move(items, to: destinationPath) }
                    },
                    deleteAction: { items in
                        Task { await model.delete(items) }
                    },
                    loadMoveDestinationFoldersAction: { path in
                        await model.loadMoveDestinationFolders(at: path)
                    },
                    loadSearchFoldersAction: { path in
                        await model.loadSearchFolders(at: path)
                    },
                    searchAction: { fileName, paths in
                        try await model.searchFiles(named: fileName, in: paths)
                    },
                    scanCinemaAction: { libraries, cachedItems in
                        try await model.scanCinemaLibraries(libraries, cachedItems: cachedItems)
                    },
                    cinemaArtworkURLAction: { path in
                        model.cinemaArtworkURL(for: path)
                    },
                    cinemaThumbnailURLAction: { path in
                        model.cinemaThumbnailURL(for: path)
                    },
                    previewCinemaAction: { item in
                        model.previewCinemaItem(item)
                    },
                    cinemaPlaybackProgressAction: { path in
                        model.playbackProgress(for: path)
                    },
                    cinemaPlaybackDurationAction: { path in
                        model.playbackDuration(for: path)
                    },
                    clearCinemaPlaybackProgressAction: { path in
                        model.clearCinemaPlaybackProgress(for: path)
                    },
                    cinemaViewingStateRevision: cinemaViewingStateRevision,
                    backAction: {
                        Task { await model.goBack() }
                    },
                    favoriteBackAction: {
                        Task { await model.goFavoriteBack() }
                    },
                    upAction: {
                        Task { await model.openParentFolder() }
                    },
                    favoriteUpAction: {
                        Task { await model.openFavoriteParentFolder() }
                    },
                    logoutAction: {
                        model.logout()
                    },
                    lastMoveDestinationPath: model.lastMoveDestinationPath
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                LoginView(
                    serverURLString: $model.serverURLString,
                    savedServers: model.savedServers,
                    account: $model.account,
                    password: $model.password,
                    isOTPDialogPresented: $model.isOTPDialogPresented,
                    otpCode: $model.pendingOTPCode,
                    trustsThisDevice: $model.trustsThisDevice,
                    isLoading: model.isLoading,
                    statusMessage: model.statusMessage,
                    selectServerAction: { server in
                        model.selectServer(server)
                    },
                    loginAction: {
                        Task { await model.login() }
                    },
                    loginWithOTPAction: {
                        Task { await model.loginWithOTP() }
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .fullScreenCover(item: $model.previewItem) { item in
            MediaPreviewView(
                item: item,
                savePlaybackProgress: { progress in
                    model.savePlaybackProgress(progress, for: item)
                },
                savePlaybackDuration: { duration in
                    model.savePlaybackDuration(duration, for: item)
                },
                clearPlaybackProgress: {
                    model.clearPlaybackProgress(for: item)
                }
            )
            .onDisappear {
                cinemaViewingStateRevision += 1
            }
        }
        .animation(.easeInOut(duration: 0.22), value: model.isConnected)
        .task {
            await model.autoLoginIfPossible()
        }
    }
}

#Preview {
    ContentView()
}

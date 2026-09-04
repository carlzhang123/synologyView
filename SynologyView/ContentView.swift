//
//  ContentView.swift
//  SynologyView
//
//  Created by 张杰 on 2026/9/4.
//

import SwiftUI

struct ContentView: View {
    @State private var model = SynologyViewModel()

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
                    canGoUp: model.canGoUp,
                    refreshAction: {
                        Task { await model.loadCurrentLocation() }
                    },
                    loadFavoritesAction: {
                        Task { await model.loadFavorites() }
                    },
                    refreshFavoriteLocationAction: {
                        Task { await model.loadFavoriteCurrentLocation() }
                    },
                    openFolderAction: { item in
                        Task { await model.openFolder(item) }
                    },
                    openFavoriteFolderAction: { item in
                        Task { await model.openFavoriteFolder(item) }
                    },
                    previewAction: { item in
                        model.preview(item)
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
            }
        }
        .fullScreenCover(item: $model.previewItem) { item in
            MediaPreviewView(
                item: item,
                savePlaybackProgress: { progress in
                    model.savePlaybackProgress(progress, for: item)
                }
            )
        }
    }
}

#Preview {
    ContentView()
}

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
                    statusMessage: model.statusMessage,
                    fileItems: model.fileItems,
                    isLoading: model.isLoading,
                    canGoUp: model.canGoUp,
                    refreshAction: {
                        Task { await model.loadCurrentLocation() }
                    },
                    openFolderAction: { item in
                        Task { await model.openFolder(item) }
                    },
                    previewAction: { item in
                        model.preview(item)
                    },
                    upAction: {
                        Task { await model.openParentFolder() }
                    },
                    logoutAction: {
                        model.logout()
                    }
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
            }
        }
        .sheet(item: $model.previewItem) { item in
            MediaPreviewView(item: item)
        }
    }
}

#Preview {
    ContentView()
}

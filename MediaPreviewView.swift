import AVKit
import SwiftUI

struct MediaPreviewView: View {
    let item: SynologyFilePreviewItem

    var body: some View {
        Group {
            if item.file.isVideo {
                VideoPreview(fileName: item.file.name, url: item.url)
            } else if item.file.isImage {
                ImagePreview(fileName: item.file.name, url: item.url)
            } else {
                ContentUnavailableView("无法预览", systemImage: "doc")
            }
        }
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
    }
}

private struct VideoPreview: View {
    let fileName: String
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
                .ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else {
                ProgressView()
                    .tint(.white)
            }

            MediaPreviewCloseButton(fileName: fileName) {
                dismiss()
            }
        }
        .statusBarHidden()
        .task {
            let player = AVPlayer(url: url)
            self.player = player
            player.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}

private struct ImagePreview: View {
    let fileName: String
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
                .ignoresSafeArea()

            AsyncImage(url: url, transaction: Transaction(animation: .default)) { phase in
                switch phase {
                case .empty:
                    ProgressView()
                        .tint(.white)
                case let .success(image):
                    ScrollView([.horizontal, .vertical]) {
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding()
                    }
                case .failure:
                    ContentUnavailableView("图片加载失败", systemImage: "photo")
                        .foregroundStyle(.white)
                @unknown default:
                    ContentUnavailableView("图片加载失败", systemImage: "photo")
                        .foregroundStyle(.white)
                }
            }

            MediaPreviewCloseButton(fileName: fileName) {
                dismiss()
            }
        }
        .statusBarHidden()
    }
}

private struct MediaPreviewCloseButton: View {
    let fileName: String
    let action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left")
                    .fontWeight(.semibold)
                Text(fileName)
                    .lineLimit(1)
            }
            .font(.subheadline)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.black.opacity(0.55), in: Capsule())
        }
        .padding(.top, 12)
        .padding(.leading, 12)
    }
}

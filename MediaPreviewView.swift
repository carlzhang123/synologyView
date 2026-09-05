import AVKit
import SwiftUI
import UIKit

#if canImport(MobileVLCKit)
import MobileVLCKit
#endif

struct MediaPreviewView: View {
    let item: SynologyFilePreviewItem
    let savePlaybackProgress: (TimeInterval) -> Void
    let savePlaybackDuration: (TimeInterval) -> Void
    let clearPlaybackProgress: () -> Void

    var body: some View {
        Group {
            if item.file.isVideo {
                VideoPreview(
                    fileName: item.file.name,
                    url: item.url,
                    playbackURLs: item.playbackURLs,
                    resumeTime: item.resumeTime,
                    knownDuration: item.knownDuration,
                    savePlaybackProgress: savePlaybackProgress,
                    savePlaybackDuration: savePlaybackDuration,
                    clearPlaybackProgress: clearPlaybackProgress
                )
            } else if item.file.isImage {
                ImagePreview(
                    initialImage: SynologyImagePreviewItem(file: item.file, url: item.url),
                    images: item.imageGallery
                )
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
    let playbackURLs: [URL]
    let resumeTime: TimeInterval
    let knownDuration: TimeInterval
    let savePlaybackProgress: (TimeInterval) -> Void
    let savePlaybackDuration: (TimeInterval) -> Void
    let clearPlaybackProgress: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var timeObserverToken: Any?
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    @State private var scrubStartTime: TimeInterval?
    @State private var scrubPreview: VideoScrubPreview?
    @State private var isDraggingControlBar = false
    @State private var isAspectFill = false
    @State private var panOffset = CGSize.zero
    @State private var showsControls = true
    @State private var isPlaying = false
    @State private var isSeeking = false
    @State private var pendingSeekTarget: TimeInterval?
    @State private var seekDisplayAnchorDate = Date.distantPast
    @State private var seekDisplayTask: Task<Void, Never>?
    @State private var playbackErrorMessage: String?
    @State private var itemStatusObservation: NSKeyValueObservation?
    @State private var playbackDiagnosticTask: Task<Void, Never>?
    @State private var mediaMetadataTask: Task<Void, Never>?
    @State private var vlcStartupWatchdogTask: Task<Void, Never>?
    @State private var localPlaybackClockTask: Task<Void, Never>?
    @State private var localPlaybackClockAnchorDate = Date.distantPast
    @State private var localPlaybackClockAnchorTime: TimeInterval = 0
    @State private var hasTrustedDuration = false
    @State private var usesVLCFallback = false
    @State private var vlcController = VLCPlaybackController()
    @State private var vlcPlaybackState = VLCPlaybackState()
    @State private var playbackURLIndex = 0
    @State private var currentPlaybackURL: URL?
    @State private var failedVLCPlaybackURLs = Set<URL>()
    @State private var hasCompletedPlayback = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
                .ignoresSafeArea()

            if usesVLCFallback {
                VLCFallbackVideoPlayer(
                    fileName: fileName,
                    url: currentPlaybackURL ?? orderedPlaybackURLs.first ?? url,
                    resumeTime: resumeTime,
                    knownDuration: knownDuration,
                    isAspectFill: isAspectFill,
                    panOffset: panOffset,
                    playbackState: $vlcPlaybackState,
                    controller: vlcController,
                    toggleControlsAction: toggleControls,
                    toggleAspectFillAction: toggleAspectFill,
                    scrubChangedAction: handleScrubChanged,
                    scrubEndedAction: handleScrubEnded,
                    scrubCancelledAction: cancelScrubbing,
                    viewportPanChangedAction: updateViewportPan
                )
                .ignoresSafeArea()
            } else if let player {
                CustomVideoPlayerSurface(
                    player: player,
                    isAspectFill: isAspectFill,
                    panOffset: panOffset,
                    toggleControlsAction: toggleControls,
                    toggleAspectFillAction: toggleAspectFill,
                    scrubChangedAction: handleScrubChanged,
                    scrubEndedAction: handleScrubEnded,
                    scrubCancelledAction: cancelScrubbing,
                    viewportPanChangedAction: updateViewportPan
                )
                .ignoresSafeArea()
            } else {
                ProgressView()
                    .tint(.white)
            }

            VideoGestureCaptureLayer(
                panOffset: panOffset,
                allowsViewportPan: isAspectFill,
                setPanOffset: updateViewportPan,
                singleTapAction: toggleControls,
                doubleTapAction: toggleAspectFill,
                scrubChangedAction: handleScrubChanged,
                scrubEndedAction: handleScrubEnded,
                scrubCancelledAction: cancelScrubbing
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()

            if let scrubPreview {
                VideoScrubOverlay(
                    preview: scrubPreview
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            }

            if let playbackErrorMessage {
                VideoPlaybackErrorView(message: playbackErrorMessage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

        }
        .overlay(alignment: .topLeading) {
            if showsControls {
                MediaPreviewCloseButton(fileName: fileName) {
                    dismiss()
                }
                .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if showsControls, canShowVideoControls {
                VideoControlsBar(
                    currentTime: currentTime,
                    duration: resolvedDuration(),
                    isPlaying: isPlaying,
                    isSeekable: isCurrentPlaybackSeekable,
                    playPauseAction: {
                        togglePlayback()
                    },
                    seekAction: { time in
                        seek(to: time)
                    },
                    seekPreviewAction: { time in
                        seekDuringScrub(to: time)
                    },
                    editingChangedAction: { isEditing in
                        isDraggingControlBar = isEditing
                    }
                )
                .transition(.opacity)
            }
        }
        .statusBarHidden()
        .task {
            startInitialPlayback()
            await observeNativePlaybackEnd()
        }
        .onDisappear {
            if !hasCompletedPlayback {
                saveCurrentProgress()
            }
            cleanupPlayback()
        }
        .onChange(of: vlcPlaybackState) {
            guard usesVLCFallback else {
                return
            }

            if vlcPlaybackState.hasDurationUpperBound {
                constrainPlaybackDuration(to: vlcPlaybackState.duration)
            } else {
                acceptPlaybackDuration(vlcPlaybackState.duration)
            }
            handleVLCPlaybackState(vlcPlaybackState)
            guard !hasCompletedPlayback,
                  let displayTime = displayPlaybackTime(from: vlcPlaybackState.currentTime) else {
                return
            }

            currentTime = displayTime
            syncLocalPlaybackClock(to: displayTime)
            if displayTime > 1 {
                saveProgressIfNeeded(displayTime)
            }
        }
    }

    private var orderedPlaybackURLs: [URL] {
        let urls = playbackURLs.isEmpty ? [url] : playbackURLs
        return urls.reduce(into: []) { result, candidate in
            if !result.contains(candidate) {
                result.append(candidate)
            }
        }
    }

    private var canShowVideoControls: Bool {
        player != nil || usesVLCFallback
    }

    private var isTransportStreamFile: Bool {
        ["m2ts", "mts", "ts"].contains(URL(fileURLWithPath: fileName).pathExtension.lowercased())
    }

    private var isCurrentPlaybackSeekable: Bool {
        if usesVLCFallback {
            return resolvedDuration() > 0
        }

        guard let player else {
            return false
        }

        if currentPlaybackURL?.isFileURL == true {
            return resolvedDuration() > 0
        }

        guard let item = player.currentItem else {
            return false
        }

        if !item.seekableTimeRanges.isEmpty {
            return true
        }

        return item.duration.seconds.isFinite && item.duration.seconds > 0 && item.status == .readyToPlay
    }

    private func startInitialPlayback() {
        if knownDuration.isFinite, knownDuration > 0 {
            duration = knownDuration
            hasTrustedDuration = false
        }

        playbackURLIndex = 0
        let firstURL = orderedPlaybackURLs.first ?? url
#if canImport(MobileVLCKit)
        startVLCPlayback(from: firstURL, reason: "MobileVLCKit is the default video player")
#else
        startPlayback(from: firstURL, resumeFromSavedProgress: true, allowsURLFallback: true, allowsLocalFallback: true)
#endif
    }

    private func startVLCPlayback(from playbackURL: URL, reason: String) {
        playbackDiagnosticTask?.cancel()
        playbackDiagnosticTask = nil
        removeProgressObserver()
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        player?.pause()
        player = nil
        currentPlaybackURL = playbackURL
        failedVLCPlaybackURLs.remove(playbackURL)
        currentTime = resumeTime > 1 ? resumeTime : 0
        duration = knownDuration.isFinite && knownDuration > 0 ? knownDuration : 0
        hasTrustedDuration = false
        if duration > 0 {
        }
        isPlaying = true
        isSeeking = false
        clearSeekProtection()
        scrubStartTime = nil
        scrubPreview = nil
        isDraggingControlBar = false
        usesVLCFallback = true
        playbackErrorMessage = nil
        startMediaDurationProbe(for: playbackURL)
        startVLCStartupWatchdog(for: playbackURL)
        startLocalPlaybackClockIfNeeded()
    }

    private func startPlayback(from playbackURL: URL, resumeFromSavedProgress: Bool, allowsURLFallback: Bool, allowsLocalFallback: Bool) {
        removeProgressObserver()
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        player?.pause()
        player = nil
        isPlaying = false
        isSeeking = false
        playbackErrorMessage = nil
        currentPlaybackURL = playbackURL


        let playerItem = AVPlayerItem(asset: playbackAsset(for: playbackURL))
        observeStatus(for: playerItem, allowsURLFallback: allowsURLFallback, allowsLocalFallback: allowsLocalFallback)
        let player = AVPlayer(playerItem: playerItem)
        player.automaticallyWaitsToMinimizeStalling = true

        if resumeFromSavedProgress, resumeTime > 1 {
            let time = CMTime(seconds: resumeTime, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        addProgressObserver(to: player)
        self.player = player
        player.play()
        isPlaying = true
    }

    private func playbackAsset(for playbackURL: URL) -> AVURLAsset {
        guard !playbackURL.isFileURL,
              let mimeType = overrideMIMEType(for: fileName) else {
            return AVURLAsset(url: playbackURL)
        }

        return AVURLAsset(
            url: playbackURL,
            options: [AVURLAssetOverrideMIMETypeKey: mimeType]
        )
    }

    private func overrideMIMEType(for fileName: String) -> String? {
        switch URL(fileURLWithPath: fileName).pathExtension.lowercased() {
        case "mp4", "m4v":
            return "video/mp4"
        case "mov":
            return "video/quicktime"
        case "mkv":
            return "video/x-matroska"
        case "m2ts", "mts", "ts":
            return "video/mp2t"
        case "webm":
            return "video/webm"
        default:
            return nil
        }
    }

    private func cleanupPlayback() {
        playbackDiagnosticTask?.cancel()
        playbackDiagnosticTask = nil
        mediaMetadataTask?.cancel()
        mediaMetadataTask = nil
        vlcStartupWatchdogTask?.cancel()
        vlcStartupWatchdogTask = nil
        stopLocalPlaybackClock()
        clearSeekProtection()
        removeProgressObserver()
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        vlcController.stop()
        vlcController.reset()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        usesVLCFallback = false
        isPlaying = false
    }

    private func observeStatus(for item: AVPlayerItem, allowsURLFallback: Bool, allowsLocalFallback: Bool) {
        itemStatusObservation?.invalidate()
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { observedItem, _ in
            Task { @MainActor in
                switch observedItem.status {
                case .readyToPlay:
                    acceptPlaybackDuration(observedItem.duration.seconds)
                    currentTime = player?.currentTime().seconds ?? currentTime
                    playbackErrorMessage = nil
                    diagnosePlayableTracks(for: observedItem, allowsLocalFallback: allowsLocalFallback)
                case .failed:
                    isPlaying = false
                    if allowsLocalFallback, shouldPreferVLCFallback(for: observedItem.error) {
                        startVLCFallback(reason: "remote URL probes as media but AVPlayer cannot open it")
                        return
                    }
                    if allowsURLFallback, playNextRemoteURL() {
                        return
                    }
                    if allowsLocalFallback, shouldAttemptVLCFallback(for: observedItem.error) {
                        startVLCFallback(reason: "AVPlayer failed after all remote candidates")
                    } else {
                        playbackErrorMessage = playbackErrorDescription(for: observedItem.error)
                    }
                case .unknown:
                    break
                @unknown default:
                    playbackErrorMessage = "播放器返回了未知状态"
                    isPlaying = false
                }
            }
        }
    }

    private func diagnosePlayableTracks(for item: AVPlayerItem, allowsLocalFallback: Bool) {
        playbackDiagnosticTask?.cancel()
        playbackDiagnosticTask = Task {
            do {
                let tracks = try await item.asset.load(.tracks)
                var mediaTracks: [VideoTrackDiagnostic] = []
                for track in tracks {
                    let mediaType = track.mediaType
                    guard mediaType == .video || mediaType == .audio else {
                        continue
                    }

                    let isPlayable = try await track.load(.isPlayable)
                    let isDecodable = try await track.load(.isDecodable)
                    mediaTracks.append(
                        VideoTrackDiagnostic(
                            mediaType: mediaType,
                            isPlayable: isPlayable,
                            isDecodable: isDecodable
                        )
                    )
                }

                try Task.checkCancellation()
                let videoTracks = mediaTracks.filter { $0.mediaType == .video }
                let audioTracks = mediaTracks.filter { $0.mediaType == .audio }
                await MainActor.run {
                }
                let hasPlayableVideo = videoTracks.contains { $0.isPlayable && $0.isDecodable }
                let hasPlayableAudio = audioTracks.isEmpty || audioTracks.contains { $0.isPlayable && $0.isDecodable }

                await MainActor.run {
                    guard player?.currentItem === item else {
                        return
                    }

                    if !videoTracks.isEmpty, !hasPlayableVideo {
                        if allowsLocalFallback, !usesVLCFallback {
                            playbackErrorMessage = "视频轨道不受 iOS 原生播放器支持，正在切换到 VLC 内核..."
                            startVLCFallback(reason: "AVPlayer video track is not decodable")
                        } else {
                            playbackErrorMessage = "视频已打开，但视频轨道无法被 iOS 原生播放器解码。需要群晖转码或接入 VLC/FFmpeg 播放内核。"
                        }
                    } else if !hasPlayableAudio {
                        playbackErrorMessage = "视频已打开，但音频轨道无法被 iOS 原生播放器解码。画面可播时可能会无声，需要转码或更换播放器内核。"
                    }
                }
            } catch is CancellationError {
            } catch {
                // Track diagnostics are best-effort; playback itself remains the source of truth.
            }
        }
    }

    private func playNextRemoteURL() -> Bool {
        let urls = orderedPlaybackURLs
        let nextIndex = playbackURLIndex + 1
        guard urls.indices.contains(nextIndex) else {
            return false
        }

        playbackURLIndex = nextIndex
        playbackErrorMessage = "正在尝试另一种群晖下载链接..."
        startPlayback(from: urls[nextIndex], resumeFromSavedProgress: false, allowsURLFallback: true, allowsLocalFallback: true)
        if currentTime > 1, let player {
            seek(to: currentTime, player: player)
        }
        return true
    }

    private func playNextVLCURL(reason: String) -> Bool {
        let urls = orderedPlaybackURLs
        let nextIndex = playbackURLIndex + 1
        guard urls.indices.contains(nextIndex) else {
            playbackErrorMessage = "VLC 内核无法打开这个视频。请尝试转码，或检查该文件是否损坏。"
            isPlaying = false
            return false
        }

        playbackURLIndex = nextIndex
        startVLCPlayback(from: urls[nextIndex], reason: reason)
        return true
    }

    private func startVLCFallback(reason: String) {
        startVLCPlayback(from: currentPlaybackURL ?? orderedPlaybackURLs.first ?? url, reason: reason)
    }

    private func shouldPreferVLCFallback(for error: Error?) -> Bool {
        shouldAttemptVLCFallback(for: error)
    }

    private func shouldAttemptVLCFallback(for error: Error?) -> Bool {
        guard !usesVLCFallback else {
            return false
        }

        guard let avError = error as? AVError else {
            return true
        }

        switch avError.code {
        case .serverIncorrectlyConfigured, .failedToLoadMediaData, .contentIsUnavailable, .unknown:
            return true
        case AVError.Code(rawValue: -11829):
            return true
        default:
            return false
        }
    }

    private func playbackErrorDescription(for error: Error?) -> String {
        guard let error else {
            return "视频无法播放，可能是编码格式不受 iOS 原生播放器支持。"
        }

        if let avError = error as? AVError {
            switch avError.code {
            case .decoderNotFound, .decodeFailed, .formatUnsupported, .fileFormatNotRecognized, .undecodableMediaData, .incompatibleAsset:
                return "视频编码或封装不受 iOS 原生播放器支持。MP4 只是容器，里面如果是 AV1、部分 H.265/10-bit、特殊音轨等编码，AVPlayer 仍然可能无法播放。"
            case .serverIncorrectlyConfigured, .failedToLoadMediaData, .contentIsUnavailable:
                return "视频数据加载失败，请检查网络、群晖权限，或该文件是否支持 HTTP Range 播放。"
            default:
                return "视频无法播放：\(avError.localizedDescription)"
            }
        }

        return "视频无法播放：\(error.localizedDescription)"
    }

    private func observeNativePlaybackEnd() async {
        for await notification in NotificationCenter.default.notifications(
            named: .AVPlayerItemDidPlayToEndTime
        ) {
            guard !Task.isCancelled,
                  let endedItem = notification.object as? AVPlayerItem,
                  endedItem === player?.currentItem else {
                continue
            }

            completePlayback()
            return
        }
    }

    private func completePlayback() {
        guard !hasCompletedPlayback else {
            return
        }

        hasCompletedPlayback = true
        isPlaying = false
        clearPlaybackProgress()
        dismiss()
    }

    private func addProgressObserver(to player: AVPlayer) {
        let interval = CMTime(seconds: 1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            let seconds = time.seconds
            guard !hasCompletedPlayback, seconds.isFinite, seconds > 1 else {
                return
            }

            if !isSeeking {
                currentTime = seconds
            }
            acceptPlaybackDuration(player.currentItem?.duration.seconds ?? 0)
            isPlaying = player.timeControlStatus == .playing
            saveProgressIfNeeded(seconds)
        }
    }

    private func removeProgressObserver() {
        guard let timeObserverToken, let player else {
            return
        }

        player.removeTimeObserver(timeObserverToken)
        self.timeObserverToken = nil
    }

    private func saveProgressIfNeeded(_ progress: TimeInterval) {
        guard !hasCompletedPlayback, progress.isFinite, progress > 1 else {
            return
        }

        let duration = resolvedDuration()
        if duration > 0, progress >= max(duration - 20, 0) {
            clearPlaybackProgress()
            return
        }

        savePlaybackProgress(progress)
    }

    private func saveCurrentProgress() {
        if usesVLCFallback {
            guard currentTime.isFinite, currentTime > 1 else {
                return
            }

            saveProgressIfNeeded(currentTime)
            return
        }

        guard let player else {
            return
        }

        let seconds = player.currentTime().seconds
        guard seconds.isFinite, seconds > 1 else {
            return
        }

        saveProgressIfNeeded(seconds)
    }

    private func togglePlayback() {
        if usesVLCFallback {
            if isPlaying {
                vlcController.pause()
                isPlaying = false
                syncLocalPlaybackClock(to: currentTime)
                if pendingSeekTarget != nil {
                    pendingSeekTarget = currentTime
                    seekDisplayAnchorDate = Date()
                }
            } else {
                if isAtPlaybackEnd || vlcPlaybackState.rawState == VLCPlaybackStateRaw.ended {
                    currentTime = isAtPlaybackEnd ? 0 : currentTime
                    syncLocalPlaybackClock(to: currentTime)
                    beginSeekProtection(to: currentTime)
                    vlcController.restart(at: currentTime)
                } else {
                    vlcController.play()
                }
                isPlaying = true
                syncLocalPlaybackClock(to: currentTime)
                startLocalPlaybackClockIfNeeded()
                if pendingSeekTarget != nil {
                    pendingSeekTarget = currentTime
                    seekDisplayAnchorDate = Date()
                }
            }
            return
        }

        guard let player else {
            return
        }

        if player.timeControlStatus == .playing {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.18)) {
            showsControls.toggle()
        }
    }

    private func toggleAspectFill() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isAspectFill.toggle()
            panOffset = .zero
        }
    }

    private func updateViewportPan(_ offset: CGSize) {
        guard isAspectFill else {
            return
        }

        panOffset = offset
    }

    private func handleScrubChanged(_ translation: CGFloat) {
        guard isCurrentPlaybackSeekable else {
            showsControls = true
            cancelScrubbing()
            return
        }

        showsControls = true
        scrubPreview = seekPreview(from: translation)
        if let scrubPreview {
            applyScrubPreview(scrubPreview)
            seekDuringScrub(to: scrubPreview.targetTime)
        }
    }

    private func handleScrubEnded(_ translation: CGFloat) {
        guard isCurrentPlaybackSeekable else {
            cancelScrubbing()
            return
        }

        guard let preview = seekPreview(from: translation) else {
            cancelScrubbing()
            return
        }

        seek(to: preview.targetTime)
        finishScrubbing()
    }

    private func seek(to seconds: TimeInterval) {
        guard isCurrentPlaybackSeekable else {
            return
        }

        if usesVLCFallback {
            let targetTime = clampedSeekTime(seconds)
            currentTime = targetTime
            isSeeking = true
            beginSeekProtection(to: targetTime)
            syncLocalPlaybackClock(to: targetTime)
            if vlcPlaybackState.rawState == VLCPlaybackStateRaw.ended {
                vlcController.restart(at: targetTime)
                isPlaying = true
            } else {
                vlcController.seek(to: targetTime)
            }
            saveProgressIfNeeded(targetTime)
            isSeeking = false
            isDraggingControlBar = false
            return
        }

        guard let player else {
            return
        }

        seek(to: seconds, player: player)
    }

    private func seek(to seconds: TimeInterval, player: AVPlayer) {
        let targetTime = clampedSeekTime(seconds)
        let time = CMTime(seconds: targetTime, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        currentTime = targetTime
        isSeeking = true
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            Task { @MainActor in
                if finished {
                    currentTime = targetTime
                }
                isSeeking = false
            }
        }
        saveProgressIfNeeded(targetTime)
    }

    private func seekDuringScrub(to seconds: TimeInterval) {
        guard isCurrentPlaybackSeekable else {
            return
        }

        let targetTime = clampedSeekTime(seconds)
        if usesVLCFallback {
            currentTime = targetTime
            isSeeking = true
            return
        }

        guard let player else {
            return
        }

        let time = CMTime(seconds: targetTime, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func seekPreview(from horizontalTranslation: CGFloat) -> VideoScrubPreview? {
        let resolvedDuration = resolvedDuration()
        guard resolvedDuration > 0 else {
            return nil
        }

        if scrubStartTime == nil {
            scrubStartTime = currentTime
        }

        let secondsPerPoint = resolvedDuration / 600
        let startTime = scrubStartTime ?? currentTime
        let requestedTime = startTime + TimeInterval(horizontalTranslation) * secondsPerPoint
        let targetTime = clampedSeekTime(requestedTime)
        return VideoScrubPreview(
            startTime: startTime,
            targetTime: targetTime,
            duration: resolvedDuration
        )
    }

    private func applyScrubPreview(_ preview: VideoScrubPreview) {
        isSeeking = true
        currentTime = preview.targetTime
    }

    private func finishScrubbing() {
        scrubStartTime = nil
        scrubPreview = nil
        isDraggingControlBar = false
    }

    private func cancelScrubbing() {
        scrubStartTime = nil
        scrubPreview = nil
        isSeeking = false
        isDraggingControlBar = false
    }

    private func beginSeekProtection(to targetTime: TimeInterval) {
        pendingSeekTarget = targetTime
        seekDisplayAnchorDate = Date()
        startSeekDisplayTask()
    }

    private func clearSeekProtection() {
        pendingSeekTarget = nil
        seekDisplayAnchorDate = .distantPast
        seekDisplayTask?.cancel()
        seekDisplayTask = nil
    }

    private func startSeekDisplayTask() {
        seekDisplayTask?.cancel()
        seekDisplayTask = Task { @MainActor in
            while !Task.isCancelled {
                guard let pendingSeekTarget else {
                    break
                }

                currentTime = protectedDisplayTime(from: pendingSeekTarget)
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func displayPlaybackTime(from playbackTime: TimeInterval) -> TimeInterval? {
        guard !isSeeking, !isDraggingControlBar else {
            return nil
        }

        guard playbackTime.isFinite, playbackTime >= 0 else {
            return nil
        }

        if isTransportStreamFile, playbackTime <= 0, currentTime > 0 {
            return nil
        }

        guard let pendingSeekTarget else {
            return playbackTime
        }

        let expectedDisplayTime = protectedDisplayTime(from: pendingSeekTarget)
        if abs(playbackTime - expectedDisplayTime) <= 1.5 {
            clearSeekProtection()
            return playbackTime
        }

        return expectedDisplayTime
    }

    private func protectedDisplayTime(from targetTime: TimeInterval) -> TimeInterval {
        let elapsed = isPlaying ? Date().timeIntervalSince(seekDisplayAnchorDate) : 0
        return clampedPlaybackTime(targetTime + max(elapsed, 0))
    }

    private func resolvedDuration() -> TimeInterval {
        if duration.isFinite, duration > 0 {
            return duration
        }

        if usesVLCFallback, vlcPlaybackState.duration.isFinite, vlcPlaybackState.duration > 0 {
            return vlcPlaybackState.duration
        }

        let playerDuration = player?.currentItem?.duration.seconds ?? 0
        return playerDuration.isFinite ? playerDuration : 0
    }

    private var isAtPlaybackEnd: Bool {
        let duration = resolvedDuration()
        return duration > 0 && currentTime >= duration - 0.5
    }

    private func shouldAcceptDuration(_ candidate: TimeInterval, isTrusted: Bool) -> Bool {
        guard candidate.isFinite, candidate > 0 else {
            return false
        }

        if isTrusted {
            return duration <= 0 || abs(candidate - duration) > 1 || !hasTrustedDuration
        }

        if hasTrustedDuration {
            return false
        }

        guard duration.isFinite, duration > 60 else {
            return true
        }

        if candidate <= duration {
            return false
        }

        let maximumReasonableCorrection = duration * 1.75
        if candidate > maximumReasonableCorrection {
            return false
        }

        return true
    }

    private func acceptPlaybackDuration(_ candidate: TimeInterval, isTrusted: Bool = false) {
        guard shouldAcceptDuration(candidate, isTrusted: isTrusted) else {
            return
        }

        if candidate != duration {
        }
        hasTrustedDuration = hasTrustedDuration || isTrusted
        duration = candidate
        savePlaybackDuration(candidate)
    }

    private func constrainPlaybackDuration(to upperBound: TimeInterval) {
        guard upperBound.isFinite, upperBound > 0 else {
            return
        }

        guard duration <= 0 || upperBound < duration else {
            return
        }

        duration = upperBound
        if currentTime > upperBound {
            currentTime = max(upperBound - 0.5, 0)
        }
        savePlaybackDuration(upperBound)
    }

    private func startLocalPlaybackClockIfNeeded() {
        guard isTransportStreamFile else {
            return
        }

        syncLocalPlaybackClock(to: currentTime)
        localPlaybackClockTask?.cancel()
        localPlaybackClockTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard usesVLCFallback else {
                    break
                }

                guard isPlaying, !isSeeking, !isDraggingControlBar else {
                    syncLocalPlaybackClock(to: currentTime)
                    continue
                }

                let elapsed = Date().timeIntervalSince(localPlaybackClockAnchorDate)
                let displayTime = clampedPlaybackTime(localPlaybackClockAnchorTime + max(elapsed, 0))
                currentTime = displayTime
                if !hasCompletedPlayback, displayTime > 1 {
                    saveProgressIfNeeded(displayTime)
                }
            }
        }
    }

    private func syncLocalPlaybackClock(to time: TimeInterval) {
        guard isTransportStreamFile else {
            return
        }

        localPlaybackClockAnchorTime = max(time, 0)
        localPlaybackClockAnchorDate = Date()
    }

    private func stopLocalPlaybackClock() {
        localPlaybackClockTask?.cancel()
        localPlaybackClockTask = nil
        localPlaybackClockAnchorDate = .distantPast
        localPlaybackClockAnchorTime = 0
    }

    private func handleVLCPlaybackState(_ state: VLCPlaybackState) {
        if state.rawState == VLCPlaybackStateRaw.ended {
            clearSeekProtection()
            isSeeking = false
            isDraggingControlBar = false
            isPlaying = false
            syncLocalPlaybackClock(to: currentTime)
            completePlayback()
            return
        }

        if isTransportStreamFile {
            switch state.rawState {
            case VLCPlaybackStateRaw.playing:
                if !isPlaying {
                    isPlaying = true
                    syncLocalPlaybackClock(to: currentTime)
                    startLocalPlaybackClockIfNeeded()
                }
            case VLCPlaybackStateRaw.paused, VLCPlaybackStateRaw.ended:
                if isPlaying {
                    isPlaying = false
                    syncLocalPlaybackClock(to: currentTime)
                }
            default:
                break
            }
        }

        if state.rawState == VLCPlaybackStateRaw.error {
            if let currentPlaybackURL, failedVLCPlaybackURLs.contains(currentPlaybackURL) {
                return
            }
            if let currentPlaybackURL {
                failedVLCPlaybackURLs.insert(currentPlaybackURL)
            }
            _ = playNextVLCURL(reason: "VLC entered error state")
        }
    }

    private func startVLCStartupWatchdog(for playbackURL: URL) {
        vlcStartupWatchdogTask?.cancel()
        vlcStartupWatchdogTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled,
                  usesVLCFallback,
                  currentPlaybackURL == playbackURL,
                  currentTime < 1,
                  resolvedDuration() <= 0 else {
                return
            }

            _ = playNextVLCURL(reason: "VLC produced no playback progress after startup")
        }
    }

    private func startMediaDurationProbe(for playbackURL: URL) {
        let fileExtension = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        guard ["m2ts", "m4v", "mov", "mp4", "mts", "ts"].contains(fileExtension) else {
            return
        }

        mediaMetadataTask?.cancel()
        mediaMetadataTask = Task {
            do {
                let headChunk = try await loadMediaHeaderData(from: playbackURL)
                try Task.checkCancellation()
                if ["m2ts", "mts", "ts"].contains(fileExtension) {
                    let wideTailChunk = try await loadMediaWideTailData(from: playbackURL)
                    try Task.checkCancellation()
                    if let transportStreamDuration = TransportStreamDurationParser.duration(headData: headChunk.data, tailData: wideTailChunk.data) {
                        await MainActor.run {
                            acceptPlaybackDuration(transportStreamDuration, isTrusted: true)
                        }
                    } else {
                        await MainActor.run {
                        }
                    }
                    return
                }

                if let parsedDuration = MP4DurationParser.duration(from: headChunk.data) {
                    await MainActor.run {
                        acceptPlaybackDuration(parsedDuration, isTrusted: true)
                    }
                    return
                }

                let tailChunk = try await loadMediaTailData(from: playbackURL)
                try Task.checkCancellation()
                if let parsedDuration = MP4DurationParser.duration(from: tailChunk.data) {
                    await MainActor.run {
                        acceptPlaybackDuration(parsedDuration, isTrusted: true)
                    }
                    return
                }

                let wideTailChunk = try await loadMediaWideTailData(from: playbackURL)
                try Task.checkCancellation()
                if let parsedDuration = MP4DurationParser.duration(from: wideTailChunk.data) {
                    await MainActor.run {
                        acceptPlaybackDuration(parsedDuration, isTrusted: true)
                    }
                    return
                }

                if let transportStreamDuration = TransportStreamDurationParser.duration(headData: headChunk.data, tailData: wideTailChunk.data) {
                    await MainActor.run {
                        acceptPlaybackDuration(transportStreamDuration, isTrusted: true)
                    }
                    return
                }

                await MainActor.run {
                }
            } catch is CancellationError {
            } catch {
                await MainActor.run {
                }
            }
        }
    }

    private func loadMediaHeaderData(from playbackURL: URL) async throws -> MediaMetadataProbeChunk {
        let byteCount = 8 * 1024 * 1024
        if playbackURL.isFileURL {
            let fileHandle = try FileHandle(forReadingFrom: playbackURL)
            defer { try? fileHandle.close() }
            return MediaMetadataProbeChunk(data: try fileHandle.read(upToCount: byteCount) ?? Data(), responseDescription: "local=head")
        }

        var request = URLRequest(url: playbackURL)
        request.timeoutInterval = 15
        request.setValue("bytes=0-\(byteCount - 1)", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        return MediaMetadataProbeChunk(data: data, responseDescription: debugHTTPResponseDescription(response))
    }

    private func loadMediaTailData(from playbackURL: URL) async throws -> MediaMetadataProbeChunk {
        try await loadMediaTailData(from: playbackURL, byteCount: 8 * 1024 * 1024)
    }

    private func loadMediaWideTailData(from playbackURL: URL) async throws -> MediaMetadataProbeChunk {
        try await loadMediaTailData(from: playbackURL, byteCount: 128 * 1024 * 1024)
    }

    private func loadMediaTailData(from playbackURL: URL, byteCount: Int) async throws -> MediaMetadataProbeChunk {
        if playbackURL.isFileURL {
            let fileHandle = try FileHandle(forReadingFrom: playbackURL)
            defer { try? fileHandle.close() }
            let fileSize = try fileHandle.seekToEnd()
            let offset = fileSize > UInt64(byteCount) ? fileSize - UInt64(byteCount) : 0
            try fileHandle.seek(toOffset: offset)
            return MediaMetadataProbeChunk(data: try fileHandle.readToEnd() ?? Data(), responseDescription: "local=tail offset=\(offset)")
        }

        var request = URLRequest(url: playbackURL)
        request.timeoutInterval = 15
        request.setValue("bytes=-\(byteCount)", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        return MediaMetadataProbeChunk(data: data, responseDescription: debugHTTPResponseDescription(response))
    }

    private func debugHTTPResponseDescription(_ response: URLResponse) -> String {
        guard let httpResponse = response as? HTTPURLResponse else {
            return "response=non-http"
        }

        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "nil"
        let contentRange = httpResponse.value(forHTTPHeaderField: "Content-Range") ?? "nil"
        let contentLength = httpResponse.value(forHTTPHeaderField: "Content-Length") ?? "nil"
        return "status=\(httpResponse.statusCode), contentType=\(contentType), contentLength=\(contentLength), contentRange=\(contentRange)"
    }

    private func clampedPlaybackTime(_ seconds: TimeInterval) -> TimeInterval {
        let duration = resolvedDuration()
        guard duration > 0 else {
            return max(seconds, 0)
        }

        return min(max(seconds, 0), duration)
    }

    private func clampedSeekTime(_ seconds: TimeInterval) -> TimeInterval {
        let duration = resolvedDuration()
        guard duration > 0 else {
            return max(seconds, 0)
        }

        let endSeekSafetyInterval = min(2, duration * 0.1)
        let maximumSeekTime = max(duration - endSeekSafetyInterval, 0)
        return min(max(seconds, 0), maximumSeekTime)
    }
}

private struct VideoPlaybackErrorView: View {
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.orange)

            Text("无法播放此视频")
                .font(.headline)
                .foregroundStyle(.white)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
        }
        .padding(24)
    }
}

private struct VideoGestureCaptureLayer: UIViewRepresentable {
    let panOffset: CGSize
    let allowsViewportPan: Bool
    let setPanOffset: (CGSize) -> Void
    let singleTapAction: () -> Void
    let doubleTapAction: () -> Void
    let scrubChangedAction: (CGFloat) -> Void
    let scrubEndedAction: (CGFloat) -> Void
    let scrubCancelledAction: () -> Void

    func makeUIView(context: Context) -> VideoGestureCaptureUIView {
        let view = VideoGestureCaptureUIView()
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ uiView: VideoGestureCaptureUIView, context: Context) {
        uiView.panOffset = panOffset
        uiView.allowsViewportPan = allowsViewportPan
        uiView.setPanOffsetAction = setPanOffset
        uiView.singleTapAction = singleTapAction
        uiView.doubleTapAction = doubleTapAction
        uiView.scrubChangedAction = scrubChangedAction
        uiView.scrubEndedAction = scrubEndedAction
        uiView.scrubCancelledAction = scrubCancelledAction
    }
}

private final class VideoGestureCaptureUIView: UIView {
    var panOffset = CGSize.zero
    var allowsViewportPan = false
    var setPanOffsetAction: (CGSize) -> Void = { _ in }
    var singleTapAction: () -> Void = {}
    var doubleTapAction: () -> Void = {}
    var scrubChangedAction: (CGFloat) -> Void = { _ in }
    var scrubEndedAction: (CGFloat) -> Void = { _ in }
    var scrubCancelledAction: () -> Void = {}
    private lazy var gestureHandler = VideoPlaybackGestureHandler(
        panOffset: { [weak self] in self?.panOffset ?? .zero },
        allowsViewportPan: { [weak self] in self?.allowsViewportPan == true },
        setPanOffset: { [weak self] offset in
            self?.panOffset = offset
            self?.setPanOffsetAction(offset)
        },
        toggleControlsAction: { [weak self] in self?.singleTapAction() },
        toggleAspectFillAction: { [weak self] in self?.doubleTapAction() },
        scrubChangedAction: { [weak self] translation in self?.scrubChangedAction(translation) },
        scrubEndedAction: { [weak self] translation in self?.scrubEndedAction(translation) },
        scrubCancelledAction: { [weak self] in self?.scrubCancelledAction() }
    )

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        gestureHandler.install(on: self)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private struct VLCFallbackVideoPlayer: View {
    let fileName: String
    let url: URL
    let resumeTime: TimeInterval
    let knownDuration: TimeInterval
    let isAspectFill: Bool
    let panOffset: CGSize
    @Binding var playbackState: VLCPlaybackState
    let controller: VLCPlaybackController
    let toggleControlsAction: () -> Void
    let toggleAspectFillAction: () -> Void
    let scrubChangedAction: (CGFloat) -> Void
    let scrubEndedAction: (CGFloat) -> Void
    let scrubCancelledAction: () -> Void
    let viewportPanChangedAction: (CGSize) -> Void

    var body: some View {
        #if canImport(MobileVLCKit)
        VLCVideoPlayerSurface(
            url: url,
            resumeTime: resumeTime,
            knownDuration: knownDuration,
            isAspectFill: isAspectFill,
            panOffset: panOffset,
            playbackState: $playbackState,
            controller: controller,
            toggleControlsAction: toggleControlsAction,
            toggleAspectFillAction: toggleAspectFillAction,
            scrubChangedAction: scrubChangedAction,
            scrubEndedAction: scrubEndedAction,
            scrubCancelledAction: scrubCancelledAction,
            viewportPanChangedAction: viewportPanChangedAction
        )
        #else
        VStack(spacing: 14) {
            Image(systemName: "play.slash.fill")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.orange)

            Text("需要 VLC 播放内核")
                .font(.headline)
                .foregroundStyle(.white)

            Text("AVPlayer 无法打开这个视频。请给 target 添加 MobileVLCKit 后重试，应用不会再把视频下载到本机临时文件。")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        #endif
    }
}

private struct VLCPlaybackState: Equatable {
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var hasDurationUpperBound = false
    var isPlaying = false
    var isSeekable = false
    var rawState = VLCPlaybackStateRaw.unknown
}

private enum VLCPlaybackStateRaw {
    static let stopped = 0
    static let opening = 1
    static let buffering = 2
    static let ended = 3
    static let error = 4
    static let playing = 5
    static let paused = 6
    static let unknown = -1
}

private final class VLCPlaybackController {
    private var playAction: () -> Void = {}
    private var pauseAction: () -> Void = {}
    private var stopAction: () -> Void = {}
    private var seekAction: (TimeInterval) -> Void = { _ in }
    private var restartAction: (TimeInterval) -> Void = { _ in }

    func configure(
        playAction: @escaping () -> Void,
        pauseAction: @escaping () -> Void,
        stopAction: @escaping () -> Void,
        seekAction: @escaping (TimeInterval) -> Void,
        restartAction: @escaping (TimeInterval) -> Void
    ) {
        self.playAction = playAction
        self.pauseAction = pauseAction
        self.stopAction = stopAction
        self.seekAction = seekAction
        self.restartAction = restartAction
    }

    func play() {
        playAction()
    }

    func pause() {
        pauseAction()
    }

    func stop() {
        stopAction()
    }

    func seek(to seconds: TimeInterval) {
        seekAction(seconds)
    }

    func restart(at seconds: TimeInterval) {
        restartAction(seconds)
    }

    func reset() {
        playAction = {}
        pauseAction = {}
        stopAction = {}
        seekAction = { _ in }
        restartAction = { _ in }
    }
}

#if canImport(MobileVLCKit)
private struct VLCVideoPlayerSurface: UIViewRepresentable {
    let url: URL
    let resumeTime: TimeInterval
    let knownDuration: TimeInterval
    let isAspectFill: Bool
    let panOffset: CGSize
    @Binding var playbackState: VLCPlaybackState
    let controller: VLCPlaybackController
    let toggleControlsAction: () -> Void
    let toggleAspectFillAction: () -> Void
    let scrubChangedAction: (CGFloat) -> Void
    let scrubEndedAction: (CGFloat) -> Void
    let scrubCancelledAction: () -> Void
    let viewportPanChangedAction: (CGSize) -> Void

    func makeUIView(context: Context) -> VLCVideoPlayerUIView {
        let view = VLCVideoPlayerUIView()
        view.stateChanged = { state in
            playbackState = state
        }
        controller.configure(
            playAction: { [weak view] in
                view?.resumePlayback()
            },
            pauseAction: { [weak view] in
                view?.pausePlayback()
            },
            stopAction: { [weak view] in
                view?.stopPlayback()
            },
            seekAction: { [weak view] seconds in
                view?.seek(to: seconds)
            },
            restartAction: { [weak view] seconds in
                view?.restartPlayback(at: seconds)
            }
        )
        view.isAspectFill = isAspectFill
        view.knownDuration = knownDuration
        view.panOffset = panOffset
        view.allowsViewportPan = isAspectFill
        view.toggleControlsAction = toggleControlsAction
        view.toggleAspectFillAction = toggleAspectFillAction
        view.scrubChangedAction = scrubChangedAction
        view.scrubEndedAction = scrubEndedAction
        view.scrubCancelledAction = scrubCancelledAction
        view.viewportPanChangedAction = viewportPanChangedAction
        view.play(url, resumeTime: resumeTime)
        return view
    }

    func updateUIView(_ uiView: VLCVideoPlayerUIView, context: Context) {
        uiView.stateChanged = { state in
            playbackState = state
        }
        controller.configure(
            playAction: { [weak uiView] in
                uiView?.resumePlayback()
            },
            pauseAction: { [weak uiView] in
                uiView?.pausePlayback()
            },
            stopAction: { [weak uiView] in
                uiView?.stopPlayback()
            },
            seekAction: { [weak uiView] seconds in
                uiView?.seek(to: seconds)
            },
            restartAction: { [weak uiView] seconds in
                uiView?.restartPlayback(at: seconds)
            }
        )
        uiView.isAspectFill = isAspectFill
        uiView.knownDuration = knownDuration
        uiView.panOffset = panOffset
        uiView.allowsViewportPan = isAspectFill
        uiView.toggleControlsAction = toggleControlsAction
        uiView.toggleAspectFillAction = toggleAspectFillAction
        uiView.scrubChangedAction = scrubChangedAction
        uiView.scrubEndedAction = scrubEndedAction
        uiView.scrubCancelledAction = scrubCancelledAction
        uiView.viewportPanChangedAction = viewportPanChangedAction
        uiView.play(url, resumeTime: resumeTime)
    }

    static func dismantleUIView(_ uiView: VLCVideoPlayerUIView, coordinator: ()) {
        uiView.stopPlayback()
    }
}

private final class VLCVideoPlayerUIView: UIView, VLCMediaPlayerDelegate {
    private let mediaPlayer = VLCMediaPlayer()
    private let videoContainerView = UIView()
    private let videoView = UIView()
    private var currentURL: URL?
    private var cropGeometryPointer: UnsafeMutablePointer<CChar>?
    private var durationProbeWorkItem: DispatchWorkItem?
    private var seekRecoveryWorkItem: DispatchWorkItem?
    private var bestDuration: TimeInterval = 0
    private var durationUpperBound: TimeInterval?
    private var lastKnownVideoSize = CGSize.zero
    var stateChanged: ((VLCPlaybackState) -> Void)?
    var knownDuration: TimeInterval = 0 {
        didSet {
            if knownDuration.isFinite, knownDuration > bestDuration {
                bestDuration = knownDuration
                publishState()
            }
        }
    }
    var isAspectFill = false {
        didSet {
            guard oldValue != isAspectFill else {
                return
            }

            updateVideoCropGeometry()
            animateVideoLayout()
        }
    }

    var panOffset = CGSize.zero {
        didSet { layoutVideoView(animated: false) }
    }
    var allowsViewportPan = false
    var toggleControlsAction: () -> Void = {}
    var toggleAspectFillAction: () -> Void = {}
    var scrubChangedAction: (CGFloat) -> Void = { _ in }
    var scrubEndedAction: (CGFloat) -> Void = { _ in }
    var scrubCancelledAction: () -> Void = {}
    var viewportPanChangedAction: (CGSize) -> Void = { _ in }
    private lazy var gestureHandler = VideoPlaybackGestureHandler(
        panOffset: { [weak self] in self?.panOffset ?? .zero },
        allowsViewportPan: { [weak self] in self?.allowsViewportPan == true },
        setPanOffset: { [weak self] offset in
            self?.panOffset = offset
            self?.viewportPanChangedAction(offset)
        },
        toggleControlsAction: { [weak self] in self?.toggleControlsAction() },
        toggleAspectFillAction: { [weak self] in self?.toggleAspectFillAction() },
        scrubChangedAction: { [weak self] translation in self?.scrubChangedAction(translation) },
        scrubEndedAction: { [weak self] translation in self?.scrubEndedAction(translation) },
        scrubCancelledAction: { [weak self] in self?.scrubCancelledAction() }
    )

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .black
        videoContainerView.backgroundColor = .black
        videoContainerView.clipsToBounds = false
        videoView.backgroundColor = .black
        videoView.clipsToBounds = true
        videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(videoContainerView)
        videoContainerView.addSubview(videoView)
        mediaPlayer.drawable = videoView
        mediaPlayer.delegate = self
        gestureHandler.install(on: self)
        updateVideoCropGeometry()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopPlayback()
        clearVideoCropGeometry()
    }

    func play(_ url: URL, resumeTime: TimeInterval) {
        guard currentURL != url else {
            publishState()
            return
        }

        currentURL = url
        durationProbeWorkItem?.cancel()
        seekRecoveryWorkItem?.cancel()
        seekRecoveryWorkItem = nil
        bestDuration = knownDuration.isFinite && knownDuration > 0 ? knownDuration : 0
        durationUpperBound = nil
        lastKnownVideoSize = .zero
        panOffset = .zero
        layoutVideoView(animated: false)
        mediaPlayer.stop()
        configureMedia(for: url)
        mediaPlayer.play()
        if resumeTime > 1 {
            seek(to: resumeTime)
        }
        publishState()
    }

    func resumePlayback() {
        mediaPlayer.play()
        publishState()
    }

    func restartPlayback(at seconds: TimeInterval) {
        guard let currentURL else {
            resumePlayback()
            return
        }

        durationProbeWorkItem?.cancel()
        mediaPlayer.stop()
        configureMedia(for: currentURL)
        mediaPlayer.play()
        publishState(currentTime: seconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.seek(to: seconds)
            self?.mediaPlayer.play()
        }
    }

    func pausePlayback() {
        mediaPlayer.pause()
        publishState()
    }

    func stopPlayback() {
        durationProbeWorkItem?.cancel()
        durationProbeWorkItem = nil
        seekRecoveryWorkItem?.cancel()
        seekRecoveryWorkItem = nil
        mediaPlayer.stop()
        mediaPlayer.delegate = nil
        mediaPlayer.drawable = nil
        mediaPlayer.media = nil
        currentURL = nil
        publishState()
    }

    func seek(to seconds: TimeInterval) {
        guard seconds.isFinite, seconds >= 0 else {
            return
        }

        if isTerminalState, seconds < max(resolvedDuration() - 2, 0) {
            restartPlaybackPipelineAfterSeek(at: seconds)
            return
        }

        let shouldResumeAfterSeek = shouldResumePlaybackAfterSeek()
        let milliseconds = min(seconds * 1000, Double(Int32.max))
        mediaPlayer.time = VLCTime(int: Int32(milliseconds))
        publishState(currentTime: seconds)
        scheduleSeekRecovery(targetTime: seconds, shouldResume: shouldResumeAfterSeek)
    }

    private func configureMedia(for url: URL) {
        let media = VLCMedia(url: url)
        media.addOption(":avcodec-hw=none")
        media.addOption(":network-caching=1500")
        media.addOption(":file-caching=1500")
        mediaPlayer.media = media
        startDurationProbe(for: media)
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        if rememberVideoSizeIfAvailable(), isAspectFill {
            layoutVideoView(animated: true)
        }
        publishState()
    }

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        if rememberVideoSizeIfAvailable(), isAspectFill {
            layoutVideoView(animated: true)
        }
        publishState()
    }

    private func publishState(currentTime explicitCurrentTime: TimeInterval? = nil) {
        let currentTime = explicitCurrentTime ?? seconds(from: mediaPlayer.time)
        let duration = resolvedDuration(currentTime: currentTime)
        if durationUpperBound == nil, duration > bestDuration {
            bestDuration = duration
        }
        let state = VLCPlaybackState(
            currentTime: currentTime,
            duration: duration,
            hasDurationUpperBound: durationUpperBound != nil,
            isPlaying: mediaPlayer.isPlaying,
            isSeekable: mediaPlayer.isSeekable,
            rawState: mediaPlayer.state.rawValue
        )

        DispatchQueue.main.async { [stateChanged] in
            stateChanged?(state)
        }
    }

    private func seconds(from time: VLCTime?) -> TimeInterval {
        guard let milliseconds = time?.value?.doubleValue, milliseconds.isFinite, milliseconds > 0 else {
            return 0
        }

        return milliseconds / 1000
    }

    private func resolvedDuration(currentTime: TimeInterval? = nil) -> TimeInterval {
        let mediaDuration = mediaPlayer.media.map { seconds(from: $0.length) } ?? 0
        let measuredDuration = mediaDuration
        let uncappedDuration: TimeInterval
        if bestDuration > 0 || measuredDuration > 0 {
            uncappedDuration = max(bestDuration, measuredDuration)
        } else {
            let position = TimeInterval(mediaPlayer.position)
            let currentTime = currentTime ?? seconds(from: mediaPlayer.time)
            if position >= 0.01, currentTime > 0 {
                let inferredDuration = currentTime / position
                if inferredDuration.isFinite, inferredDuration > 0, isReasonableInferredDuration(inferredDuration, measuredDuration: measuredDuration) {
                    uncappedDuration = inferredDuration
                } else {
                    uncappedDuration = bestDuration
                }
            } else {
                uncappedDuration = bestDuration
            }
        }

        if let durationUpperBound {
            return min(uncappedDuration > 0 ? uncappedDuration : durationUpperBound, durationUpperBound)
        }

        return uncappedDuration
    }

    private func shouldResumePlaybackAfterSeek() -> Bool {
        if mediaPlayer.isPlaying {
            return true
        }

        switch mediaPlayer.state.rawValue {
        case VLCPlaybackStateRaw.opening, VLCPlaybackStateRaw.buffering, VLCPlaybackStateRaw.playing:
            return true
        default:
            return false
        }
    }

    private func scheduleSeekRecovery(targetTime: TimeInterval, shouldResume: Bool) {
        seekRecoveryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.recoverPlaybackAfterSeek(targetTime: targetTime, shouldResume: shouldResume)
        }
        seekRecoveryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }

    private func recoverPlaybackAfterSeek(targetTime: TimeInterval, shouldResume: Bool) {
        guard currentURL != nil else {
            return
        }

        let actualTime = seconds(from: mediaPlayer.time)
        let duration = resolvedDuration(currentTime: actualTime)
        if isTerminalStateAfterSeek(targetTime: targetTime, duration: duration) {
            constrainDurationAfterTerminalSeek(targetTime: targetTime, actualTime: actualTime)
            return
        }

        if shouldResume,
           !mediaPlayer.isPlaying,
           mediaPlayer.state.rawValue != VLCPlaybackStateRaw.ended,
           mediaPlayer.state.rawValue != VLCPlaybackStateRaw.error {
            mediaPlayer.play()
        }

        if duration > 0, targetTime > 0, abs(actualTime - targetTime) > 2 {
            mediaPlayer.position = Float(min(max(targetTime / duration, 0), 0.999))
        }

        publishState(currentTime: targetTime)

        let followUpWorkItem = DispatchWorkItem { [weak self] in
            guard let self, self.currentURL != nil else {
                return
            }

            let actualTime = self.seconds(from: self.mediaPlayer.time)
            let duration = self.resolvedDuration(currentTime: actualTime)
            if self.isTerminalStateAfterSeek(targetTime: targetTime, duration: duration) {
                self.constrainDurationAfterTerminalSeek(targetTime: targetTime, actualTime: actualTime)
                return
            }

            if shouldResume,
               !self.mediaPlayer.isPlaying,
               self.mediaPlayer.state.rawValue != VLCPlaybackStateRaw.ended,
               self.mediaPlayer.state.rawValue != VLCPlaybackStateRaw.error {
                self.mediaPlayer.play()
            }

            self.publishState()
        }
        seekRecoveryWorkItem = followUpWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: followUpWorkItem)
    }

    private var isTerminalState: Bool {
        switch mediaPlayer.state.rawValue {
        case VLCPlaybackStateRaw.stopped, VLCPlaybackStateRaw.ended:
            return true
        default:
            return false
        }
    }

    private func isTerminalStateAfterSeek(targetTime: TimeInterval, duration: TimeInterval) -> Bool {
        guard duration <= 0 || targetTime < duration - 2 else {
            return false
        }

        return isTerminalState
    }

    private func constrainDurationAfterTerminalSeek(targetTime: TimeInterval, actualTime: TimeInterval) {
        let upperBound: TimeInterval
        if actualTime > 1, actualTime <= targetTime + 2 {
            upperBound = actualTime
        } else {
            upperBound = targetTime
        }

        guard upperBound.isFinite, upperBound > 0 else {
            return
        }

        if durationUpperBound == nil || upperBound < (durationUpperBound ?? upperBound) {
            durationUpperBound = upperBound
            bestDuration = min(bestDuration > 0 ? bestDuration : upperBound, upperBound)
        }

        let displayTime = max(upperBound - 0.5, 0)
        publishState(currentTime: displayTime)
    }

    private func restartPlaybackPipelineAfterSeek(at targetTime: TimeInterval) {
        guard let currentURL else {
            return
        }

        durationProbeWorkItem?.cancel()
        mediaPlayer.stop()
        configureMedia(for: currentURL)
        mediaPlayer.play()
        publishState(currentTime: targetTime)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.currentURL != nil else {
                return
            }

            let milliseconds = min(targetTime * 1000, Double(Int32.max))
            self.mediaPlayer.time = VLCTime(int: Int32(milliseconds))
            self.mediaPlayer.play()
            self.publishState(currentTime: targetTime)
        }
    }

    private func isReasonableInferredDuration(_ inferredDuration: TimeInterval, measuredDuration: TimeInterval) -> Bool {
        guard inferredDuration <= 86_400 else {
            return false
        }

        guard measuredDuration > 60 else {
            return true
        }

        return inferredDuration <= measuredDuration * 2.5
    }

    private func startDurationProbe(for media: VLCMedia) {
        _ = media.parse(options: VLCMediaParsingOptions(rawValue: 1), timeout: 10_000)
        let workItem = DispatchWorkItem { [weak self, weak media] in
            guard let media else {
                return
            }

            let length = media.lengthWait(until: Date(timeIntervalSinceNow: 8))
            let duration = self?.seconds(from: length) ?? 0
            guard duration.isFinite, duration > 0 else {
                return
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.mediaPlayer.media === media else {
                    return
                }

                if duration > self.bestDuration {
                    self.bestDuration = duration
                    self.publishState(currentTime: self.seconds(from: self.mediaPlayer.time))
                }
            }
        }

        durationProbeWorkItem = workItem
        DispatchQueue.global(qos: .utility).async(execute: workItem)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutVideoView(animated: false)
    }

    private func layoutVideoView(animated: Bool) {
        guard bounds.width > 0, bounds.height > 0 else {
            videoContainerView.transform = .identity
            videoContainerView.frame = bounds
            videoView.frame = bounds
            return
        }

        let previousTransform = videoContainerView.transform
        videoContainerView.transform = .identity
        videoContainerView.frame = bounds
        videoView.frame = videoContainerView.bounds

        let targetScale = isAspectFill ? heightFillScale() : 1
        let scaledWidth = bounds.width * targetScale
        let maxXOffset = max((scaledWidth - bounds.width) / 2, 0)
        let clampedOffset = CGSize(
            width: min(max(panOffset.width, -maxXOffset), maxXOffset),
            height: 0
        )

        let targetTransform = CGAffineTransform(
            a: targetScale,
            b: 0,
            c: 0,
            d: targetScale,
            tx: clampedOffset.width,
            ty: clampedOffset.height
        )

        if animated {
            videoContainerView.transform = previousTransform
            UIView.animate(
                withDuration: 0.26,
                delay: 0,
                options: [.curveEaseInOut, .allowUserInteraction]
            ) {
                self.videoContainerView.transform = targetTransform
            }
        } else {
            videoContainerView.transform = targetTransform
        }

        if clampedOffset != panOffset {
            DispatchQueue.main.async { [weak self] in
                self?.viewportPanChangedAction(clampedOffset)
            }
        }
    }

    private func animateVideoLayout() {
        layoutVideoView(animated: true)
    }

    private func heightFillScale() -> CGFloat {
        guard let videoSize = currentVideoSize(),
              bounds.width > 0,
              bounds.height > 0 else {
            return 1
        }

        let aspectFitScale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let fittedVideoHeight = videoSize.height * aspectFitScale
        guard fittedVideoHeight > 0 else {
            return 1
        }

        return max(bounds.height / fittedVideoHeight, 1)
    }

    private func currentVideoSize() -> CGSize? {
        let videoSize = mediaPlayer.videoSize
        if videoSize.width > 0, videoSize.height > 0 {
            return videoSize
        }

        if lastKnownVideoSize.width > 0, lastKnownVideoSize.height > 0 {
            return lastKnownVideoSize
        }

        return nil
    }

    @discardableResult
    private func rememberVideoSizeIfAvailable() -> Bool {
        let videoSize = mediaPlayer.videoSize
        guard videoSize.width > 0, videoSize.height > 0 else {
            return false
        }

        guard videoSize != lastKnownVideoSize else {
            return false
        }

        lastKnownVideoSize = videoSize
        return true
    }

    private func updateVideoCropGeometry() {
        clearVideoCropGeometry()
        mediaPlayer.scaleFactor = 0
    }

    private func clearVideoCropGeometry() {
        mediaPlayer.videoCropGeometry = nil
        if let cropGeometryPointer {
            free(cropGeometryPointer)
            self.cropGeometryPointer = nil
        }
    }
}
#endif

private struct CustomVideoPlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    let isAspectFill: Bool
    let panOffset: CGSize
    let toggleControlsAction: () -> Void
    let toggleAspectFillAction: () -> Void
    let scrubChangedAction: (CGFloat) -> Void
    let scrubEndedAction: (CGFloat) -> Void
    let scrubCancelledAction: () -> Void
    let viewportPanChangedAction: (CGSize) -> Void

    func makeUIView(context: Context) -> PlayerSurfaceView {
        let view = PlayerSurfaceView()
        view.player = player
        view.isAspectFill = isAspectFill
        view.panOffset = panOffset
        view.allowsViewportPan = isAspectFill
        view.toggleControlsAction = toggleControlsAction
        view.toggleAspectFillAction = toggleAspectFillAction
        view.scrubChangedAction = scrubChangedAction
        view.scrubEndedAction = scrubEndedAction
        view.scrubCancelledAction = scrubCancelledAction
        view.viewportPanChangedAction = viewportPanChangedAction
        return view
    }

    func updateUIView(_ uiView: PlayerSurfaceView, context: Context) {
        uiView.player = player
        uiView.isAspectFill = isAspectFill
        uiView.panOffset = panOffset
        uiView.allowsViewportPan = isAspectFill
        uiView.toggleControlsAction = toggleControlsAction
        uiView.toggleAspectFillAction = toggleAspectFillAction
        uiView.scrubChangedAction = scrubChangedAction
        uiView.scrubEndedAction = scrubEndedAction
        uiView.scrubCancelledAction = scrubCancelledAction
        uiView.viewportPanChangedAction = viewportPanChangedAction
    }
}

private final class PlayerSurfaceView: UIView {
    private let playerLayer = AVPlayerLayer()

    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    var isAspectFill = false {
        didSet {
            guard oldValue != isAspectFill else {
                return
            }

            layoutPlayerLayer(animated: true)
        }
    }

    var panOffset = CGSize.zero {
        didSet { layoutPlayerLayer(animated: false) }
    }
    var allowsViewportPan = false
    var toggleControlsAction: () -> Void = {}
    var toggleAspectFillAction: () -> Void = {}
    var scrubChangedAction: (CGFloat) -> Void = { _ in }
    var scrubEndedAction: (CGFloat) -> Void = { _ in }
    var scrubCancelledAction: () -> Void = {}
    var viewportPanChangedAction: (CGSize) -> Void = { _ in }
    private lazy var gestureHandler = VideoPlaybackGestureHandler(
        panOffset: { [weak self] in self?.panOffset ?? .zero },
        allowsViewportPan: { [weak self] in self?.allowsViewportPan == true },
        setPanOffset: { [weak self] offset in
            self?.panOffset = offset
            self?.viewportPanChangedAction(offset)
        },
        toggleControlsAction: { [weak self] in self?.toggleControlsAction() },
        toggleAspectFillAction: { [weak self] in self?.toggleAspectFillAction() },
        scrubChangedAction: { [weak self] translation in self?.scrubChangedAction(translation) },
        scrubEndedAction: { [weak self] translation in self?.scrubEndedAction(translation) },
        scrubCancelledAction: { [weak self] in self?.scrubCancelledAction() }
    )

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .black
        layer.addSublayer(playerLayer)
        gestureHandler.install(on: self)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutPlayerLayer(animated: false)
    }

    private func layoutPlayerLayer(animated: Bool) {
        playerLayer.videoGravity = .resizeAspect

        guard isAspectFill,
              bounds.width > 0,
              bounds.height > 0 else {
            setPlayerLayerFrame(bounds, animated: animated)
            return
        }

        let fillSize: CGSize
        if let videoSize = playerLayer.player?.currentItem?.presentationSize,
           videoSize.width > 0,
           videoSize.height > 0 {
            let targetHeight = bounds.height
            let targetWidth = max(targetHeight * videoSize.width / videoSize.height, bounds.width)
            fillSize = CGSize(width: targetWidth, height: targetHeight)
        } else {
            fillSize = bounds.size
        }
        let maxXOffset = max((fillSize.width - bounds.width) / 2, 0)
        let maxYOffset = max((fillSize.height - bounds.height) / 2, 0)
        let clampedOffset = CGSize(
            width: min(max(panOffset.width, -maxXOffset), maxXOffset),
            height: min(max(panOffset.height, -maxYOffset), maxYOffset)
        )

        let targetFrame = CGRect(
            x: (bounds.width - fillSize.width) / 2 + clampedOffset.width,
            y: (bounds.height - fillSize.height) / 2 + clampedOffset.height,
            width: fillSize.width,
            height: fillSize.height
        )
        setPlayerLayerFrame(targetFrame, animated: animated)

        if clampedOffset != panOffset {
            DispatchQueue.main.async { [weak self] in
                self?.viewportPanChangedAction(clampedOffset)
            }
        }
    }

    private func setPlayerLayerFrame(_ frame: CGRect, animated: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.26 : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        CATransaction.setDisableActions(!animated)
        playerLayer.frame = frame
        CATransaction.commit()
    }
}

private final class VideoPlaybackGestureHandler: NSObject, UIGestureRecognizerDelegate {
    private let panOffset: () -> CGSize
    private let allowsViewportPan: () -> Bool
    private let setPanOffset: (CGSize) -> Void
    private let toggleControlsAction: () -> Void
    private let toggleAspectFillAction: () -> Void
    private let scrubChangedAction: (CGFloat) -> Void
    private let scrubEndedAction: (CGFloat) -> Void
    private let scrubCancelledAction: () -> Void
    private var startOffset = CGSize.zero
    private var isScrubbing = false
    private var pendingSingleTapWorkItem: DispatchWorkItem?

    init(
        panOffset: @escaping () -> CGSize,
        allowsViewportPan: @escaping () -> Bool,
        setPanOffset: @escaping (CGSize) -> Void,
        toggleControlsAction: @escaping () -> Void,
        toggleAspectFillAction: @escaping () -> Void,
        scrubChangedAction: @escaping (CGFloat) -> Void,
        scrubEndedAction: @escaping (CGFloat) -> Void,
        scrubCancelledAction: @escaping () -> Void
    ) {
        self.panOffset = panOffset
        self.allowsViewportPan = allowsViewportPan
        self.setPanOffset = setPanOffset
        self.toggleControlsAction = toggleControlsAction
        self.toggleAspectFillAction = toggleAspectFillAction
        self.scrubChangedAction = scrubChangedAction
        self.scrubEndedAction = scrubEndedAction
        self.scrubCancelledAction = scrubCancelledAction
    }

    func install(on view: UIView) {
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2

        let scrubPan = UIPanGestureRecognizer(target: self, action: #selector(handleScrubPan(_:)))
        scrubPan.minimumNumberOfTouches = 1
        scrubPan.maximumNumberOfTouches = 1
        scrubPan.delegate = self

        let cropPan = UIPanGestureRecognizer(target: self, action: #selector(handleCropPan(_:)))
        cropPan.minimumNumberOfTouches = 2
        cropPan.maximumNumberOfTouches = 2
        cropPan.delegate = self

        view.addGestureRecognizer(singleTap)
        view.addGestureRecognizer(doubleTap)
        view.addGestureRecognizer(scrubPan)
        view.addGestureRecognizer(cropPan)
    }

    @objc private func handleSingleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else {
            return
        }

        pendingSingleTapWorkItem?.cancel()
        let workItem = DispatchWorkItem { [toggleControlsAction] in
            toggleControlsAction()
        }
        pendingSingleTapWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: workItem)
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else {
            return
        }

        pendingSingleTapWorkItem?.cancel()
        pendingSingleTapWorkItem = nil
        toggleAspectFillAction()
    }

    @objc private func handleScrubPan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: recognizer.view)
        switch recognizer.state {
        case .began:
            isScrubbing = abs(translation.x) >= abs(translation.y)
            if !isScrubbing {
                scrubCancelledAction()
            }
        case .changed:
            guard isScrubbing else {
                return
            }
            scrubChangedAction(translation.x)
        case .ended:
            guard isScrubbing else {
                scrubCancelledAction()
                return
            }
            scrubEndedAction(translation.x)
            isScrubbing = false
        default:
            scrubCancelledAction()
            isScrubbing = false
        }
    }

    @objc private func handleCropPan(_ recognizer: UIPanGestureRecognizer) {
        guard allowsViewportPan() else {
            return
        }

        switch recognizer.state {
        case .began:
            startOffset = panOffset()
        case .changed:
            let translation = recognizer.translation(in: recognizer.view)
            setPanOffset(
                CGSize(
                    width: startOffset.width + translation.x,
                    height: startOffset.height + translation.y
                )
            )
        default:
            break
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let panGesture = gestureRecognizer as? UIPanGestureRecognizer else {
            return true
        }

        let velocity = panGesture.velocity(in: gestureRecognizer.view)
        if panGesture.numberOfTouches == 1 {
            return abs(velocity.x) >= abs(velocity.y)
        }

        return allowsViewportPan()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }
}

private struct VideoTrackDiagnostic {
    let mediaType: AVMediaType
    let isPlayable: Bool
    let isDecodable: Bool

    var debugDescription: String {
        "\(mediaType.rawValue): playable=\(isPlayable), decodable=\(isDecodable)"
    }
}

private struct VideoScrubPreview: Equatable {
    let startTime: TimeInterval
    let targetTime: TimeInterval
    let duration: TimeInterval
}

private struct VideoScrubOverlay: View {
    let preview: VideoScrubPreview

    var body: some View {
        VStack(spacing: 12) {
            Label(directionTitle, systemImage: directionIcon)
                .font(.headline)
                .foregroundStyle(.white)

            Text("\(formatted(preview.targetTime)) / \(formatted(preview.duration))")
                .font(.title2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            ProgressView(value: progress)
                .tint(.white)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 28)
    }

    private var progress: Double {
        guard preview.duration > 0 else {
            return 0
        }

        return min(max(preview.targetTime / preview.duration, 0), 1)
    }

    private var deltaSeconds: Int {
        Int((preview.targetTime - preview.startTime).rounded())
    }

    private var directionTitle: String {
        if deltaSeconds > 0 {
            return "快进 \(formattedDelta(deltaSeconds))"
        }

        if deltaSeconds < 0 {
            return "快退 \(formattedDelta(abs(deltaSeconds)))"
        }

        return "调整进度"
    }

    private var directionIcon: String {
        if deltaSeconds >= 0 {
            return "goforward"
        }

        return "gobackward"
    }

    private func formattedDelta(_ seconds: Int) -> String {
        if seconds >= 60 {
            return "\(seconds / 60)分\(seconds % 60)秒"
        }

        return "\(seconds)秒"
    }

    private func formatted(_ time: TimeInterval) -> String {
        guard time.isFinite, time > 0 else {
            return "00:00"
        }

        let totalSeconds = Int(time)
        let hours = totalSeconds / 3600
        let minutes = totalSeconds % 3600 / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private struct VideoControlsBar: View {
    let currentTime: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
    let isSeekable: Bool
    let playPauseAction: () -> Void
    let seekAction: (TimeInterval) -> Void
    let seekPreviewAction: (TimeInterval) -> Void
    let editingChangedAction: (Bool) -> Void
    @State private var sliderValue: TimeInterval = 0
    @State private var isDraggingSlider = false

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    playPauseAction()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())

                Slider(
                    value: Binding(
                        get: {
                            sliderValue
                        },
                        set: { newValue in
                            guard isSeekable else {
                                return
                            }

                            let safeValue = min(max(newValue, 0), maximumSeekTime)
                            sliderValue = safeValue
                            seekPreviewAction(safeValue)
                        }
                    ),
                    in: 0...max(duration, 1),
                    onEditingChanged: { isEditing in
                        isDraggingSlider = isEditing
                        if isEditing {
                            sliderValue = min(currentTime, maximumSeekTime)
                            editingChangedAction(true)
                        } else {
                            if isSeekable {
                                seekAction(sliderValue)
                            }
                            editingChangedAction(false)
                        }
                    }
                )
                .tint(.white)
                .disabled(!isSeekable)
                .onAppear {
                    sliderValue = clampedDisplayTime(currentTime)
                }
                .onChange(of: currentTime) {
                    if !isDraggingSlider {
                        sliderValue = clampedDisplayTime(currentTime)
                    }
                }
                .onChange(of: duration) {
                    if !isDraggingSlider {
                        sliderValue = clampedDisplayTime(currentTime)
                    }
                }

                Text(timeText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(minWidth: isSeekable ? 118 : 154, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 18)
        .background(
            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.72)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
    }

    private func clampedDisplayTime(_ time: TimeInterval) -> TimeInterval {
        min(max(time, 0), max(duration, 1))
    }

    private var maximumSeekTime: TimeInterval {
        guard duration > 0 else {
            return 0
        }

        let endSeekSafetyInterval = min(2, duration * 0.1)
        return max(duration - endSeekSafetyInterval, 0)
    }

    private var timeText: String {
        if !isSeekable, duration > 0 {
            return "\(formatted(currentTime)) / \(formatted(duration)) 不可拖动"
        }

        return "\(formatted(sliderValue)) / \(formatted(duration))"
    }

    private func formatted(_ time: TimeInterval) -> String {
        guard time.isFinite, time > 0 else {
            return "00:00"
        }

        let totalSeconds = Int(time)
        let hours = totalSeconds / 3600
        let minutes = totalSeconds % 3600 / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private enum MP4DurationParser {
    static func duration(from data: Data) -> TimeInterval? {
        if let moov = box(named: "moov", in: 0..<data.count, data: data),
           let mvhd = box(named: "mvhd", in: moov.payloadRange, data: data),
           let duration = movieHeaderDuration(in: mvhd.payloadRange, data: data) {
            return duration
        }

        return scannedMovieHeaderDuration(from: data)
    }

    private static func scannedMovieHeaderDuration(from data: Data) -> TimeInterval? {
        var searchRange = data.startIndex..<data.endIndex
        let signature = Data("mvhd".utf8)
        while let typeRange = data.range(of: signature, options: [], in: searchRange) {
            if typeRange.lowerBound >= 4 {
                let boxStart = typeRange.lowerBound - 4
                if let boxSize = data.uint32(at: boxStart),
               boxSize >= 16 {
                    let payloadStart = typeRange.upperBound
                    if let duration = movieHeaderDuration(in: payloadStart..<min(data.count, boxStart + Int(boxSize)), data: data) {
                        return duration
                    }
                }
            }

            searchRange = typeRange.upperBound..<data.endIndex
        }

        return nil
    }

    private static func movieHeaderDuration(in range: Range<Int>, data: Data) -> TimeInterval? {
        guard range.lowerBound < range.upperBound,
              let version = data.byte(at: range.lowerBound) else {
            return nil
        }

        let timescaleOffset: Int
        let durationOffset: Int
        let durationSize: Int
        if version == 1 {
            timescaleOffset = range.lowerBound + 20
            durationOffset = range.lowerBound + 24
            durationSize = 8
        } else {
            timescaleOffset = range.lowerBound + 12
            durationOffset = range.lowerBound + 16
            durationSize = 4
        }

        guard let timescale = data.uint32(at: timescaleOffset),
              timescale > 0 else {
            return nil
        }

        let rawDuration: UInt64?
        if durationSize == 8 {
            rawDuration = data.uint64(at: durationOffset)
        } else {
            rawDuration = data.uint32(at: durationOffset).map(UInt64.init)
        }

        guard let rawDuration, rawDuration > 0 else {
            return nil
        }

        let seconds = TimeInterval(rawDuration) / TimeInterval(timescale)
        guard seconds.isFinite, seconds > 0, seconds <= 86_400 else {
            return nil
        }

        return seconds
    }

    private static func box(named name: String, in range: Range<Int>, data: Data) -> MP4Box? {
        boxes(in: range, data: data).first { $0.type == name }
    }

    private static func boxes(in range: Range<Int>, data: Data) -> [MP4Box] {
        var boxes: [MP4Box] = []
        var offset = range.lowerBound
        while offset + 8 <= range.upperBound {
            guard let boxSize32 = data.uint32(at: offset),
                  let boxType = data.asciiString(at: offset + 4, count: 4) else {
                break
            }

            var headerSize = 8
            var boxSize = UInt64(boxSize32)
            if boxSize32 == 1 {
                guard let largeSize = data.uint64(at: offset + 8) else {
                    break
                }
                headerSize = 16
                boxSize = largeSize
            } else if boxSize32 == 0 {
                boxSize = UInt64(range.upperBound - offset)
            }

            guard boxSize >= UInt64(headerSize),
                  boxSize <= UInt64(Int.max) else {
                break
            }

            let nextOffset = offset + Int(boxSize)
            let availableEndOffset = min(nextOffset, range.upperBound)
            boxes.append(
                MP4Box(
                    type: boxType,
                    range: offset..<availableEndOffset,
                    payloadRange: (offset + headerSize)..<availableEndOffset
                )
            )
            guard nextOffset <= range.upperBound else {
                break
            }

            offset = nextOffset
        }

        return boxes
    }
}

private struct MP4Box {
    let type: String
    let range: Range<Int>
    let payloadRange: Range<Int>
}

private struct MediaMetadataProbeChunk {
    let data: Data
    let responseDescription: String
}

private enum TransportStreamDurationParser {
    static func isLikelyTransportStream(_ data: Data) -> Bool {
        !packetOffsets(in: data).isEmpty
    }

    static func duration(headData: Data, tailData: Data) -> TimeInterval? {
        guard let firstPCR = firstPCR(in: headData),
              let lastPCR = lastPCR(in: tailData) else {
            return nil
        }

        let timestampWrap = UInt64(1) << 33
        let tickDelta: UInt64
        if lastPCR >= firstPCR {
            tickDelta = lastPCR - firstPCR
        } else {
            tickDelta = timestampWrap - firstPCR + lastPCR
        }

        let seconds = TimeInterval(tickDelta) / 90_000
        guard seconds.isFinite, seconds > 0, seconds <= 86_400 else {
            return nil
        }

        return seconds
    }

    private static func firstPCR(in data: Data) -> UInt64? {
        packetOffsets(in: data).lazy.compactMap { pcr(in: data, packetOffset: $0) }.first
    }

    private static func lastPCR(in data: Data) -> UInt64? {
        packetOffsets(in: data).reversed().lazy.compactMap { pcr(in: data, packetOffset: $0) }.first
    }

    private static func packetOffsets(in data: Data) -> [Int] {
        for packetSize in [188, 192, 204] {
            if let alignmentOffset = alignmentOffset(in: data, packetSize: packetSize) {
                return stride(from: alignmentOffset, to: data.count - packetSize + 1, by: packetSize).map { $0 }
            }
        }

        return []
    }

    private static func alignmentOffset(in data: Data, packetSize: Int) -> Int? {
        guard data.count >= packetSize * 5 else {
            return nil
        }

        let scanLimit = min(packetSize, data.count)
        for offset in 0..<scanLimit {
            var syncCount = 0
            var packetOffset = offset
            while packetOffset < data.count, syncCount < 5 {
                guard data.byte(at: packetOffset) == 0x47 else {
                    break
                }

                syncCount += 1
                packetOffset += packetSize
            }

            if syncCount >= 5 {
                return offset
            }
        }

        return nil
    }

    private static func pcr(in data: Data, packetOffset: Int) -> UInt64? {
        guard packetOffset >= 0,
              packetOffset + 12 <= data.count,
              data.byte(at: packetOffset) == 0x47,
              let controlByte = data.byte(at: packetOffset + 3) else {
            return nil
        }

        let adaptationFieldControl = (controlByte >> 4) & 0x03
        guard adaptationFieldControl == 0x02 || adaptationFieldControl == 0x03,
              let adaptationLength = data.byte(at: packetOffset + 4),
              adaptationLength >= 7,
              packetOffset + 5 + Int(adaptationLength) <= data.count,
              let flags = data.byte(at: packetOffset + 5),
              flags & 0x10 != 0 else {
            return nil
        }

        guard let b0 = data.byte(at: packetOffset + 6),
              let b1 = data.byte(at: packetOffset + 7),
              let b2 = data.byte(at: packetOffset + 8),
              let b3 = data.byte(at: packetOffset + 9),
              let b4 = data.byte(at: packetOffset + 10) else {
            return nil
        }

        return UInt64(b0) << 25
            | UInt64(b1) << 17
            | UInt64(b2) << 9
            | UInt64(b3) << 1
            | UInt64(b4) >> 7
    }
}

private extension Data {
    func byte(at offset: Int) -> UInt8? {
        guard indices.contains(offset) else {
            return nil
        }

        return self[offset]
    }

    func uint32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else {
            return nil
        }

        return withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return UInt32(bytes[offset]) << 24
                | UInt32(bytes[offset + 1]) << 16
                | UInt32(bytes[offset + 2]) << 8
                | UInt32(bytes[offset + 3])
        }
    }

    func uint64(at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= count else {
            return nil
        }

        return withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return UInt64(bytes[offset]) << 56
                | UInt64(bytes[offset + 1]) << 48
                | UInt64(bytes[offset + 2]) << 40
                | UInt64(bytes[offset + 3]) << 32
                | UInt64(bytes[offset + 4]) << 24
                | UInt64(bytes[offset + 5]) << 16
                | UInt64(bytes[offset + 6]) << 8
                | UInt64(bytes[offset + 7])
        }
    }

    func asciiString(at offset: Int, count: Int) -> String? {
        guard offset >= 0, count > 0, offset + count <= self.count else {
            return nil
        }

        return String(bytes: self[offset..<(offset + count)], encoding: .ascii)
    }
}

private struct ImagePreview: View {
    let images: [SynologyImagePreviewItem]
    @Environment(\.dismiss) private var dismiss
    @State private var currentImage: SynologyImagePreviewItem
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset = CGSize.zero
    @State private var lastOffset = CGSize.zero

    init(initialImage: SynologyImagePreviewItem, images: [SynologyImagePreviewItem]) {
        self.images = images.isEmpty ? [initialImage] : images
        _currentImage = State(initialValue: initialImage)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
                .ignoresSafeArea()

            AsyncImage(url: currentImage.url, transaction: Transaction(animation: .default)) { phase in
                switch phase {
                case .empty:
                    ProgressView()
                        .tint(.white)
                case let .success(image):
                    GeometryReader { proxy in
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .scaleEffect(scale)
                            .offset(offset)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }
                    .ignoresSafeArea()
                case .failure:
                    ContentUnavailableView("图片加载失败", systemImage: "photo")
                        .foregroundStyle(.white)
                @unknown default:
                    ContentUnavailableView("图片加载失败", systemImage: "photo")
                        .foregroundStyle(.white)
                }
            }
            .id(currentImage.id)
            .animation(.easeInOut(duration: 0.2), value: currentImage.id)

            MediaPreviewCloseButton(fileName: currentImage.file.name) {
                dismiss()
            }
        }
        .simultaneousGesture(imageMagnifyGesture)
        .simultaneousGesture(imageDragGesture)
        .simultaneousGesture(imageDoubleTapGesture)
        .statusBarHidden()
    }

    private var imageMagnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(lastScale * value.magnification, 1), 5)
            }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1.01 {
                    resetZoom()
                }
            }
    }

    private var imageDragGesture: some Gesture {
        DragGesture(minimumDistance: 30)
            .onChanged { value in
                guard scale > 1 else {
                    return
                }

                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { value in
                if scale > 1 {
                    lastOffset = offset
                    return
                }

                guard abs(value.translation.width) > abs(value.translation.height),
                      abs(value.translation.width) > 70 else {
                    return
                }

                if value.translation.width < 0 {
                    showImage(offset: 1)
                } else {
                    showImage(offset: -1)
                }
            }
    }

    private var imageDoubleTapGesture: some Gesture {
        TapGesture(count: 2)
            .onEnded {
                withAnimation(.smooth(duration: 0.24)) {
                    if scale > 1 {
                        resetZoom()
                    } else {
                        scale = 2.5
                        lastScale = 2.5
                        offset = .zero
                        lastOffset = .zero
                    }
                }
            }
    }

    private func showImage(offset: Int) {
        guard let currentIndex = images.firstIndex(where: { $0.id == currentImage.id }) else {
            return
        }

        let nextIndex = currentIndex + offset
        guard images.indices.contains(nextIndex) else {
            return
        }

        withAnimation(.easeInOut(duration: 0.2)) {
            currentImage = images[nextIndex]
            resetZoom()
        }
    }

    private func resetZoom() {
        scale = 1
        lastScale = 1
        offset = .zero
        lastOffset = .zero
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

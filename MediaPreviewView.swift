import AVKit
import SwiftUI
import UIKit

struct MediaPreviewView: View {
    let item: SynologyFilePreviewItem
    let savePlaybackProgress: (TimeInterval) -> Void

    var body: some View {
        Group {
            if item.file.isVideo {
                VideoPreview(
                    fileName: item.file.name,
                    url: item.url,
                    resumeTime: item.resumeTime,
                    savePlaybackProgress: savePlaybackProgress
                )
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
    let resumeTime: TimeInterval
    let savePlaybackProgress: (TimeInterval) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var timeObserverToken: Any?
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    @State private var scrubStartTime: TimeInterval?
    @State private var scrubPreview: VideoScrubPreview?
    @State private var isAspectFill = false
    @State private var panOffset = CGSize.zero
    @State private var showsControls = true
    @State private var isPlaying = false
    @State private var isSeeking = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
                .ignoresSafeArea()

            if let player {
                CustomVideoPlayerSurface(
                    player: player,
                    isAspectFill: isAspectFill,
                    panOffset: panOffset
                )
                .overlay {
                    VideoGestureOverlay(
                        panOffset: $panOffset,
                        toggleControlsAction: {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                showsControls.toggle()
                            }
                        },
                        toggleAspectFillAction: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isAspectFill.toggle()
                                panOffset = .zero
                            }
                        },
                        scrubChangedAction: { translation in
                            scrubPreview = seekPreview(from: translation)
                        },
                        scrubEndedAction: { translation in
                            guard let preview = seekPreview(from: translation) else {
                                scrubStartTime = nil
                                scrubPreview = nil
                                return
                            }

                            seek(to: preview.targetTime, player: player)
                            scrubStartTime = nil
                            scrubPreview = nil
                        },
                        scrubCancelledAction: {
                            scrubStartTime = nil
                            scrubPreview = nil
                        }
                    )
                }
                .ignoresSafeArea()
            } else {
                ProgressView()
                    .tint(.white)
            }

            if let scrubPreview {
                VideoScrubOverlay(
                    preview: scrubPreview
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if showsControls {
                MediaPreviewCloseButton(fileName: fileName) {
                    dismiss()
                }
                .transition(.opacity)

                if let player {
                    VideoControlsBar(
                        currentTime: currentTime,
                        duration: durationFromPlayer(),
                        isPlaying: isPlaying,
                        playPauseAction: {
                            togglePlayback()
                        },
                        seekAction: { time in
                            seek(to: time, player: player)
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.opacity)
                }
            }
        }
        .statusBarHidden()
        .task {
            let player = AVPlayer(url: url)
            if resumeTime > 1 {
                let time = CMTime(seconds: resumeTime, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
                player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            }

            addProgressObserver(to: player)
            self.player = player
            player.play()
            isPlaying = true
        }
        .onDisappear {
            saveCurrentProgress()
            removeProgressObserver()
            player?.pause()
            player = nil
        }
    }

    private func addProgressObserver(to player: AVPlayer) {
        let interval = CMTime(seconds: 1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            let seconds = time.seconds
            guard seconds.isFinite, seconds > 1 else {
                return
            }

            if !isSeeking {
                currentTime = seconds
            }
            duration = player.currentItem?.duration.seconds ?? duration
            isPlaying = player.timeControlStatus == .playing
            savePlaybackProgress(seconds)
        }
    }

    private func removeProgressObserver() {
        guard let timeObserverToken, let player else {
            return
        }

        player.removeTimeObserver(timeObserverToken)
        self.timeObserverToken = nil
    }

    private func saveCurrentProgress() {
        guard let player else {
            return
        }

        let seconds = player.currentTime().seconds
        guard seconds.isFinite, seconds > 1 else {
            return
        }

        savePlaybackProgress(seconds)
    }

    private func togglePlayback() {
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

    private func seek(to seconds: TimeInterval, player: AVPlayer) {
        let targetTime = min(max(seconds, 0), durationFromPlayer())
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
        savePlaybackProgress(targetTime)
    }

    private func seekPreview(from horizontalTranslation: CGFloat) -> VideoScrubPreview? {
        let resolvedDuration = durationFromPlayer()
        guard resolvedDuration > 0 else {
            return nil
        }

        if scrubStartTime == nil {
            scrubStartTime = currentTime
        }

        let secondsPerPoint = resolvedDuration / 600
        let startTime = scrubStartTime ?? currentTime
        let targetTime = min(max(startTime + TimeInterval(horizontalTranslation) * secondsPerPoint, 0), resolvedDuration)
        return VideoScrubPreview(
            startTime: startTime,
            targetTime: targetTime,
            duration: resolvedDuration
        )
    }

    private func durationFromPlayer() -> TimeInterval {
        if duration.isFinite, duration > 0 {
            return duration
        }

        let playerDuration = player?.currentItem?.duration.seconds ?? 0
        return playerDuration.isFinite ? playerDuration : 0
    }
}

private struct CustomVideoPlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    let isAspectFill: Bool
    let panOffset: CGSize

    func makeUIView(context: Context) -> PlayerSurfaceView {
        let view = PlayerSurfaceView()
        view.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerSurfaceView, context: Context) {
        uiView.player = player
        uiView.isAspectFill = isAspectFill
        uiView.panOffset = panOffset
    }
}

private final class PlayerSurfaceView: UIView {
    private let playerLayer = AVPlayerLayer()

    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    var isAspectFill = false {
        didSet { setNeedsLayout() }
    }

    var panOffset = CGSize.zero {
        didSet { setNeedsLayout() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .black
        layer.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.videoGravity = .resizeAspect

        guard isAspectFill,
              let videoSize = playerLayer.player?.currentItem?.presentationSize,
              videoSize.width > 0,
              videoSize.height > 0,
              bounds.width > 0,
              bounds.height > 0 else {
            playerLayer.frame = bounds
            return
        }

        let scale = max(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let fillSize = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        let maxXOffset = max((fillSize.width - bounds.width) / 2, 0)
        let maxYOffset = max((fillSize.height - bounds.height) / 2, 0)
        let clampedOffset = CGSize(
            width: min(max(panOffset.width, -maxXOffset), maxXOffset),
            height: min(max(panOffset.height, -maxYOffset), maxYOffset)
        )

        playerLayer.frame = CGRect(
            x: (bounds.width - fillSize.width) / 2 + clampedOffset.width,
            y: (bounds.height - fillSize.height) / 2 + clampedOffset.height,
            width: fillSize.width,
            height: fillSize.height
        )
    }
}

private struct VideoGestureOverlay: UIViewRepresentable {
    @Binding var panOffset: CGSize
    let toggleControlsAction: () -> Void
    let toggleAspectFillAction: () -> Void
    let scrubChangedAction: (CGFloat) -> Void
    let scrubEndedAction: (CGFloat) -> Void
    let scrubCancelledAction: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear

        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        singleTap.require(toFail: doubleTap)

        let scrubPan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleScrubPan(_:)))
        scrubPan.minimumNumberOfTouches = 1
        scrubPan.maximumNumberOfTouches = 1
        scrubPan.delegate = context.coordinator

        let cropPan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleCropPan(_:)))
        cropPan.minimumNumberOfTouches = 2
        cropPan.maximumNumberOfTouches = 2
        cropPan.delegate = context.coordinator

        view.addGestureRecognizer(singleTap)
        view.addGestureRecognizer(doubleTap)
        view.addGestureRecognizer(scrubPan)
        view.addGestureRecognizer(cropPan)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.panOffset = $panOffset
        context.coordinator.toggleControlsAction = toggleControlsAction
        context.coordinator.toggleAspectFillAction = toggleAspectFillAction
        context.coordinator.scrubChangedAction = scrubChangedAction
        context.coordinator.scrubEndedAction = scrubEndedAction
        context.coordinator.scrubCancelledAction = scrubCancelledAction
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            panOffset: $panOffset,
            toggleControlsAction: toggleControlsAction,
            toggleAspectFillAction: toggleAspectFillAction,
            scrubChangedAction: scrubChangedAction,
            scrubEndedAction: scrubEndedAction,
            scrubCancelledAction: scrubCancelledAction
        )
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var panOffset: Binding<CGSize>
        var toggleControlsAction: () -> Void
        var toggleAspectFillAction: () -> Void
        var scrubChangedAction: (CGFloat) -> Void
        var scrubEndedAction: (CGFloat) -> Void
        var scrubCancelledAction: () -> Void
        private var startOffset = CGSize.zero
        private var isScrubbing = false

        init(
            panOffset: Binding<CGSize>,
            toggleControlsAction: @escaping () -> Void,
            toggleAspectFillAction: @escaping () -> Void,
            scrubChangedAction: @escaping (CGFloat) -> Void,
            scrubEndedAction: @escaping (CGFloat) -> Void,
            scrubCancelledAction: @escaping () -> Void
        ) {
            self.panOffset = panOffset
            self.toggleControlsAction = toggleControlsAction
            self.toggleAspectFillAction = toggleAspectFillAction
            self.scrubChangedAction = scrubChangedAction
            self.scrubEndedAction = scrubEndedAction
            self.scrubCancelledAction = scrubCancelledAction
        }

        @objc func handleSingleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else {
                return
            }

            toggleControlsAction()
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else {
                return
            }

            toggleAspectFillAction()
        }

        @objc func handleScrubPan(_ recognizer: UIPanGestureRecognizer) {
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

        @objc func handleCropPan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began:
                startOffset = panOffset.wrappedValue
            case .changed:
                let translation = recognizer.translation(in: recognizer.view)
                panOffset.wrappedValue = CGSize(
                    width: startOffset.width + translation.x,
                    height: startOffset.height + translation.y
                )
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let panGesture = gestureRecognizer as? UIPanGestureRecognizer else {
                return true
            }

            let translation = panGesture.translation(in: gestureRecognizer.view)
            if panGesture.numberOfTouches == 1 {
                return abs(translation.x) >= abs(translation.y)
            }

            return true
        }
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
    let playPauseAction: () -> Void
    let seekAction: (TimeInterval) -> Void
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
                        .contentShape(Rectangle())
                }

                Slider(
                    value: Binding(
                        get: {
                            isDraggingSlider ? sliderValue : currentTime
                        },
                        set: { newValue in
                            sliderValue = newValue
                        }
                    ),
                    in: 0...max(duration, 1),
                    onEditingChanged: { isEditing in
                        isDraggingSlider = isEditing
                        if !isEditing {
                            seekAction(sliderValue)
                        } else {
                            sliderValue = currentTime
                        }
                    }
                )
                .tint(.white)

                Text("\(formatted(isDraggingSlider ? sliderValue : currentTime)) / \(formatted(duration))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(minWidth: 92, alignment: .trailing)
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
                    GeometryReader { proxy in
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(width: proxy.size.width, height: proxy.size.height)
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

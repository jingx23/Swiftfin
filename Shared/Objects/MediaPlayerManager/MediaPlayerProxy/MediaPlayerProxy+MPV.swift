//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import Defaults
import Factory
import Foundation
import JellyfinAPI
import Libmpv
import SwiftUI

@MainActor
class MPVMediaPlayerProxy: VideoMediaPlayerProxy,
    MediaPlayerOffsetConfigurable,
    MediaPlayerSubtitleConfigurable
{

    let isBuffering: PublishedBox<Bool> = .init(initialValue: false)
    let videoSize: PublishedBox<CGSize> = .init(initialValue: .zero)

    private var mpvController: MPVController?
    private var managerItemObserver: AnyCancellable?
    private var managerStateObserver: AnyCancellable?

    weak var manager: MediaPlayerManager? {
        didSet {
            for var o in observers {
                o.manager = manager
            }

            if let manager {
                managerItemObserver = manager.$playbackItem
                    .sink { [weak self] playbackItem in
                        if let playbackItem {
                            self?.playNew(item: playbackItem)
                        }
                    }

                managerStateObserver = manager.$state
                    .sink { [weak self] state in
                        switch state {
                        case .stopped:
                            self?.playbackStopped()
                        default: break
                        }
                    }
            } else {
                managerItemObserver?.cancel()
                managerStateObserver?.cancel()
            }
        }
    }

    var observers: [any MediaPlayerObserver] = [
        NowPlayableObserver(),
    ]

    // MARK: - Playback Controls

    func play() {
        mpvController?.play()
    }

    func pause() {
        mpvController?.pause()
    }

    func stop() {
        mpvController?.stop()
    }

    func jumpForward(_ seconds: Duration) {
        guard let mpv = mpvController else { return }
        let current = mpv.getCurrentTime()
        mpv.seek(to: current + seconds.seconds)
    }

    func jumpBackward(_ seconds: Duration) {
        guard let mpv = mpvController else { return }
        let current = mpv.getCurrentTime()
        mpv.seek(to: max(0, current - seconds.seconds))
    }

    func setRate(_ rate: Float) {
        mpvController?.setRate(Double(rate))
    }

    func setSeconds(_ seconds: Duration) {
        mpvController?.seek(to: seconds.seconds)
    }

    func setAudioStream(_ stream: MediaStream) {
        guard let playbackItem = manager?.playbackItem else { return }
        let resolvedIndex = resolvedStreamIndex(
            for: stream,
            streamType: .audio,
            playbackItem: playbackItem
        )
        guard let resolvedIndex else { return }
        // mpv expects per-type 1-based IDs in the order tracks appear in the file.
        if let position = audioTrackPosition(for: resolvedIndex, mediaSource: playbackItem.mediaSource) {
            mpvController?.setAudioTrack(id: position + 1)
        }
    }

    func setSubtitleStream(_ stream: MediaStream) {
        guard let index = stream.index else { return }
        if index < 0 {
            mpvController?.setSubtitleTrack(id: nil)
        } else if let playbackItem = manager?.playbackItem {
            if let resolvedIndex = resolvedStreamIndex(
                for: stream,
                streamType: .subtitle,
                playbackItem: playbackItem
            ),
                let id = subtitleTrackID(for: resolvedIndex, mediaSource: playbackItem.mediaSource)
            {
                mpvController?.setSubtitleTrack(id: id)
            }
        }
    }

    func setAspectFill(_ aspectFill: Bool) {
        mpvController?.setAspectFill(aspectFill)
    }

    // MARK: - Offset Configuration

    func setAudioOffset(_ seconds: Duration) {
        mpvController?.setAudioDelay(seconds.seconds)
    }

    func setSubtitleOffset(_ seconds: Duration) {
        mpvController?.setSubtitleDelay(seconds.seconds)
    }

    // MARK: - Subtitle Configuration

    func setSubtitleColor(_ color: Color) {
        let uiColor = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        let hex = String(format: "#%02X%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255), Int(a * 255))
        mpvController?.setOption("sub-color", value: hex)
    }

    func setSubtitleFontName(_ fontName: String) {
        mpvController?.setOption("sub-font", value: fontName)
    }

    func setSubtitleFontSize(_ fontSize: Int) {
        mpvController?.setOption("sub-font-size", value: "\(fontSize)")
    }

    // MARK: - Video Player Body

    var videoPlayerBody: some View {
        MPVPlayerView(proxy: self)
    }

    // MARK: - Private

    private func playNew(item: MediaPlayerItem) {
        let baseItem = item.baseItem
        let mediaSource = item.mediaSource

        let startSeconds = max(
            .zero,
            (baseItem.startSeconds ?? .zero) - Duration.seconds(Defaults[.VideoPlayer.resumeOffset])
        )

        // mpv uses per-type 1-based track IDs (aid 1, 2, 3... / sid 1, 2, 3...)
        // based on the order tracks appear in the file.
        let mpvAudioTrackID: Int? = {
            guard !baseItem.isLiveStream else { return nil }
            let defaultIdx = item.selectedAudioStreamIndex ?? mediaSource.defaultAudioStreamIndex
            guard let defaultIdx, defaultIdx >= 0 else { return nil }
            let resolvedIndex = resolvedStreamIndex(
                forIndex: defaultIdx,
                streamType: .audio,
                playbackItem: item
            )
            if let resolvedIndex,
               let position = audioTrackPosition(for: resolvedIndex, mediaSource: mediaSource)
            {
                return position + 1
            }
            let fallbackStreams = mediaSource.mediaStreams?.filter { $0.type == .audio && !isExternalStream($0) } ?? []
            return fallbackStreams.isEmpty ? nil : 1
        }()

        let mpvSubtitleTrackID: Int? = {
            guard !baseItem.isLiveStream else { return nil }
            let defaultIdx = item.selectedSubtitleStreamIndex ?? mediaSource.defaultSubtitleStreamIndex
            guard let defaultIdx, defaultIdx >= 0 else { return nil }
            let resolvedIndex = resolvedStreamIndex(
                forIndex: defaultIdx,
                streamType: .subtitle,
                playbackItem: item
            )
            guard let resolvedIndex else { return nil }
            return subtitleTrackID(for: resolvedIndex, mediaSource: mediaSource)
        }()

        let configuration = MPVPlayerConfiguration(
            url: item.url,
            startSeconds: baseItem.isLiveStream ? nil : startSeconds,
            audioTrackID: mpvAudioTrackID,
            subtitleTrackID: mpvSubtitleTrackID,
            subtitleSize: 25 - Defaults[.VideoPlayer.Subtitle.subtitleSize],
            subtitleColor: Defaults[.VideoPlayer.Subtitle.subtitleColor],
            subtitleFontName: Defaults[.VideoPlayer.Subtitle.subtitleFontName],
            externalSubtitles: item.subtitleStreams
                .filter { $0.deliveryMethod == .external }
                .compactMap { stream -> (url: URL, title: String)? in
                    guard let deliveryURL = stream.deliveryURL,
                          let client = Container.shared.currentUserSession()?.client else { return nil }
                    let deliveryPath = deliveryURL.removingFirst(
                        if: client.configuration.url.absoluteString.last == "/"
                    )
                    guard let fullURL = client.fullURL(with: deliveryPath) else { return nil }
                    return (url: fullURL, title: stream.displayTitle ?? "")
                }
        )

        if let mpvController {
            mpvController.loadFile(configuration)
        } else {
            // Controller will be created by the view and load this config
            pendingConfiguration = configuration
        }
    }

    private func playbackStopped() {
        mpvController?.stop()
        mpvController?.cleanup()
        mpvController = nil
    }

    fileprivate var pendingConfiguration: MPVPlayerConfiguration?

    fileprivate func attachController(_ controller: MPVController) {
        mpvController = controller
        controller.delegate = self

        if let config = pendingConfiguration {
            pendingConfiguration = nil
            controller.loadFile(config)
        }
    }

    private func audioTrackPosition(for index: Int, mediaSource: MediaSourceInfo) -> Int? {
        let audioStreams = mediaSource.mediaStreams?
            .filter { $0.type == .audio && !isExternalStream($0) } ?? []
        return audioStreams.firstIndex(where: { $0.index == index })
    }

    private func subtitleTrackID(for index: Int, mediaSource: MediaSourceInfo) -> Int? {
        let subtitleStreams = mediaSource.mediaStreams?
            .filter { $0.type == .subtitle } ?? []
        let internalSubs = subtitleStreams.filter { !isExternalStream($0) }
        if let position = internalSubs.firstIndex(where: { $0.index == index }) {
            return position + 1
        }
        let externalSubs = subtitleStreams.filter { isExternalStream($0) }
        if let position = externalSubs.firstIndex(where: { $0.index == index }) {
            return internalSubs.count + position + 1
        }
        return nil
    }

    private func isExternalStream(_ stream: MediaStream) -> Bool {
        (stream.isExternal ?? false) || stream.deliveryMethod == .external
    }

    private func resolvedStreamIndex(
        for stream: MediaStream,
        streamType: MediaStreamType,
        playbackItem: MediaPlayerItem
    ) -> Int? {
        if let type = stream.type, type != streamType { return nil }
        if let index = stream.index,
           let direct = playbackItem.mediaSource.mediaStreams?
               .first(where: { $0.type == streamType && $0.index == index })
        {
            return direct.index
        }
        if let index = stream.index,
           let resolvedByPosition = resolvedStreamIndex(
               forIndex: index,
               streamType: streamType,
               playbackItem: playbackItem
           )
        {
            return resolvedByPosition
        }
        return originalStreamIndex(for: stream, mediaSource: playbackItem.mediaSource)
    }

    private func resolvedStreamIndex(
        forIndex index: Int,
        streamType: MediaStreamType,
        playbackItem: MediaPlayerItem
    ) -> Int? {
        if let direct = playbackItem.mediaSource.mediaStreams?
            .first(where: { $0.type == streamType && $0.index == index })
        {
            return direct.index
        }
        switch streamType {
        case .audio:
            guard let position = playbackItem.audioStreams.firstIndex(where: { $0.index == index }) else { return nil }
            let audioStreams = playbackItem.mediaSource.mediaStreams?
                .filter { $0.type == .audio && !isExternalStream($0) } ?? []
            guard position < audioStreams.count else { return nil }
            return audioStreams[position].index
        case .subtitle:
            guard let position = playbackItem.subtitleStreams.firstIndex(where: { $0.index == index }) else { return nil }
            let subtitleStreams = playbackItem.mediaSource.mediaStreams?
                .filter { $0.type == .subtitle } ?? []
            let internalSubs = subtitleStreams.filter { !isExternalStream($0) }
            let externalSubs = subtitleStreams.filter { isExternalStream($0) }
            if position < internalSubs.count {
                return internalSubs[position].index
            }
            let externalIndex = position - internalSubs.count
            guard externalIndex < externalSubs.count else { return nil }
            return externalSubs[externalIndex].index
        default:
            return nil
        }
    }

    private func originalStreamIndex(for stream: MediaStream, mediaSource: MediaSourceInfo) -> Int? {
        guard let streams = mediaSource.mediaStreams else { return nil }
        let isExternal = isExternalStream(stream)
        let candidates = streams.filter {
            $0.type == stream.type && isExternalStream($0) == isExternal
        }
        if let match = candidates.first(where: { matchesStream($0, stream) }) {
            return match.index
        }
        if let match = candidates.first(where: { $0.displayTitle == stream.displayTitle && $0.language == stream.language }) {
            return match.index
        }
        return nil
    }

    private func matchesStream(_ lhs: MediaStream, _ rhs: MediaStream) -> Bool {
        lhs.displayTitle == rhs.displayTitle &&
            lhs.language == rhs.language &&
            lhs.codec == rhs.codec &&
            lhs.channels == rhs.channels &&
            lhs.channelLayout == rhs.channelLayout &&
            lhs.bitRate == rhs.bitRate &&
            lhs.sampleRate == rhs.sampleRate &&
            lhs.isDefault == rhs.isDefault &&
            lhs.isForced == rhs.isForced
    }
}

// MARK: - MPVControllerDelegate

extension MPVMediaPlayerProxy: MPVControllerDelegate {

    nonisolated func mpvController(_ controller: MPVController, didUpdateSeconds seconds: Double, videoSize: CGSize) {
        Task { @MainActor in
            self.manager?.seconds = .seconds(seconds)
            self.videoSize.value = videoSize
        }
    }

    nonisolated func mpvController(_ controller: MPVController, didChangePlaybackState state: MPVPlaybackState) {
        Task { @MainActor in
            switch state {
            case .playing:
                self.isBuffering.value = false
                self.manager?.setPlaybackRequestStatus(status: .playing)
            case .paused:
                self.manager?.setPlaybackRequestStatus(status: .paused)
            case .buffering:
                self.isBuffering.value = true
            case .ended:
                guard let playbackItem = self.manager?.playbackItem,
                      !playbackItem.baseItem.isLiveStream else { return }
                self.isBuffering.value = false
                self.manager?.ended()
            case let .error(message):
                self.isBuffering.value = false
                self.manager?.error(ErrorMessage(message))
            case .idle:
                break
            }
        }
    }
}

// MARK: - MPV Player Configuration

struct MPVPlayerConfiguration {
    let url: URL
    let startSeconds: Duration?
    /// mpv 1-based audio track ID (aid)
    let audioTrackID: Int?
    /// mpv 1-based subtitle track ID (sid), nil to disable
    let subtitleTrackID: Int?
    let subtitleSize: Int
    let subtitleColor: Color
    let subtitleFontName: String
    let externalSubtitles: [(url: URL, title: String)]
}

// MARK: - MPV Playback State

enum MPVPlaybackState {
    case idle
    case playing
    case paused
    case buffering
    case ended
    case error(String)
}

// MARK: - MPVControllerDelegate Protocol

@MainActor
protocol MPVControllerDelegate: AnyObject {
    nonisolated func mpvController(_ controller: MPVController, didUpdateSeconds seconds: Double, videoSize: CGSize)
    nonisolated func mpvController(_ controller: MPVController, didChangePlaybackState state: MPVPlaybackState)
}

// MARK: - MPVController

class MPVController: @unchecked Sendable {

    private var mpv: OpaquePointer?
    private let queue = DispatchQueue(label: "mpv", qos: .userInitiated)

    nonisolated(unsafe) weak var delegate: (any MPVControllerDelegate)?

    let metalLayer = MetalLayer()

    init() {}

    func setupMpv() {
        mpv = mpv_create()
        guard mpv != nil else {
            print("MPV: Failed creating context")
            return
        }

        #if DEBUG
        checkError(mpv_request_log_messages(mpv, "warn"))
        #else
        checkError(mpv_request_log_messages(mpv, "no"))
        #endif

        var layerPtr = metalLayer
        checkError(mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &layerPtr))

        // Video output and rendering
        checkError(mpv_set_option_string(mpv, "vo", "gpu-next"))
        checkError(mpv_set_option_string(mpv, "gpu-api", "vulkan"))
        checkError(mpv_set_option_string(mpv, "hwdec", "videotoolbox"))

        // Video scaling and positioning
        checkError(mpv_set_option_string(mpv, "video-aspect-override", "no"))
        checkError(mpv_set_option_string(mpv, "video-unscaled", "no"))
        checkError(mpv_set_option_string(mpv, "keepaspect", "yes"))
        checkError(mpv_set_option_string(mpv, "keepaspect-window", "yes"))
        checkError(mpv_set_option_string(mpv, "panscan", "0.0"))
        checkError(mpv_set_option_string(mpv, "video-zoom", "0"))
        checkError(mpv_set_option_string(mpv, "video-pan-x", "0"))
        checkError(mpv_set_option_string(mpv, "video-pan-y", "0"))
        checkError(mpv_set_option_string(mpv, "video-align-x", "0"))
        checkError(mpv_set_option_string(mpv, "video-align-y", "0"))

        // Subtitles
        checkError(mpv_set_option_string(mpv, "subs-match-os-language", "yes"))
        checkError(mpv_set_option_string(mpv, "subs-fallback", "yes"))

        // Other options
        checkError(mpv_set_option_string(mpv, "video-rotate", "no"))
        checkError(mpv_set_option_string(mpv, "ytdl", "no"))

        // Buffering
        checkError(mpv_set_option_string(mpv, "cache", "yes"))
        checkError(mpv_set_option_string(mpv, "cache-secs", "60"))
        checkError(mpv_set_option_string(mpv, "demuxer-max-bytes", "200M"))
        checkError(mpv_set_option_string(mpv, "demuxer-readahead-secs", "30"))

        // Smooth playback
        checkError(mpv_set_option_string(mpv, "video-sync", "audio"))
        checkError(mpv_set_option_string(mpv, "interpolation", "no"))

        checkError(mpv_initialize(mpv))

        // Observe properties
        mpv_observe_property(mpv, 0, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 1, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 2, "video-params/w", MPV_FORMAT_INT64)
        mpv_observe_property(mpv, 3, "video-params/h", MPV_FORMAT_INT64)
        mpv_observe_property(mpv, 4, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 5, "eof-reached", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 6, "core-idle", MPV_FORMAT_FLAG)

        mpv_set_wakeup_callback(mpv, { ctx in
            guard let ctx else { return }
            let controller = Unmanaged<MPVController>.fromOpaque(ctx).takeUnretainedValue()
            controller.readEvents()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func loadFile(_ configuration: MPVPlayerConfiguration) {
        guard mpv != nil else { return }

        // Apply subtitle settings
        setOption("sub-font-size", value: "\(configuration.subtitleSize)")
        setOption("sub-font", value: configuration.subtitleFontName)

        let uiColor = UIColor(configuration.subtitleColor)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        let hex = String(format: "#%02X%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255), Int(a * 255))
        setOption("sub-color", value: hex)

        // Load the file
        command("loadfile", args: [configuration.url.absoluteString, "replace"])

        // Set start position
        if let startSeconds = configuration.startSeconds, startSeconds > .zero {
            // Use start option before loading for precise seeking
            setOption("start", value: "\(startSeconds.seconds)")
        }

        // Add external subtitles
        for subtitle in configuration.externalSubtitles {
            command("sub-add", args: [subtitle.url.absoluteString, "auto", subtitle.title])
        }

        // Set audio/subtitle tracks
        if let audioTrackID = configuration.audioTrackID, audioTrackID >= 0 {
            command("set", args: ["aid", "\(audioTrackID)"])
        }

        if let subtitleTrackID = configuration.subtitleTrackID {
            if subtitleTrackID >= 0 {
                command("set", args: ["sid", "\(subtitleTrackID)"])
            } else {
                command("set", args: ["sid", "no"])
            }
        }
    }

    // MARK: - Playback Controls

    func play() {
        setFlag("pause", false)
    }

    func pause() {
        setFlag("pause", true)
    }

    func stop() {
        command("stop", checkForErrors: false)
    }

    func seek(to position: Double) {
        command("seek", args: ["\(position)", "absolute"])
    }

    func getCurrentTime() -> Double {
        getDouble("time-pos")
    }

    func getDuration() -> Double {
        getDouble("duration")
    }

    func setRate(_ rate: Double) {
        guard mpv != nil else { return }
        var value = rate
        mpv_set_property(mpv, "speed", MPV_FORMAT_DOUBLE, &value)
    }

    func setAudioTrack(id: Int) {
        command("set", args: ["aid", "\(id)"])
    }

    func setSubtitleTrack(id: Int?) {
        if let id {
            command("set", args: ["sid", "\(id)"])
        } else {
            command("set", args: ["sid", "no"])
        }
    }

    func setAudioDelay(_ seconds: Double) {
        guard mpv != nil else { return }
        var value = seconds
        mpv_set_property(mpv, "audio-delay", MPV_FORMAT_DOUBLE, &value)
    }

    func setSubtitleDelay(_ seconds: Double) {
        guard mpv != nil else { return }
        var value = seconds
        mpv_set_property(mpv, "sub-delay", MPV_FORMAT_DOUBLE, &value)
    }

    func setAspectFill(_ fill: Bool) {
        setOption("panscan", value: fill ? "1.0" : "0.0")
    }

    func setOption(_ name: String, value: String) {
        guard mpv != nil else { return }
        mpv_set_property_string(mpv, name, value)
    }

    // MARK: - Private Helpers

    private var videoWidth: Int64 = 0
    private var videoHeight: Int64 = 0

    private func getDouble(_ name: String) -> Double {
        guard mpv != nil else { return 0.0 }
        var data = Double()
        mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &data)
        return data
    }

    private func getFlag(_ name: String) -> Bool {
        guard mpv != nil else { return false }
        var data = Int64()
        mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &data)
        return data > 0
    }

    private func setFlag(_ name: String, _ flag: Bool) {
        guard mpv != nil else { return }
        var data: Int = flag ? 1 : 0
        mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &data)
    }

    func command(_ command: String, args: [String?] = [], checkForErrors: Bool = true) {
        guard mpv != nil else { return }
        var cargs = makeCArgs(command, args).map { $0.flatMap { UnsafePointer<CChar>(strdup($0)) } }
        defer {
            for ptr in cargs where ptr != nil {
                free(UnsafeMutablePointer(mutating: ptr!))
            }
        }
        let returnValue = mpv_command(mpv, &cargs)
        if checkForErrors {
            checkError(returnValue)
        }
    }

    private func makeCArgs(_ command: String, _ args: [String?]) -> [String?] {
        if !args.isEmpty, args.last == nil {
            fatalError("Command do not need a nil suffix")
        }
        var strArgs = args
        strArgs.insert(command, at: 0)
        strArgs.append(nil)
        return strArgs
    }

    private func readEvents() {
        queue.async { [weak self] in
            guard let self, self.mpv != nil else { return }

            while self.mpv != nil {
                let event = mpv_wait_event(self.mpv, 0)
                guard let event, event.pointee.event_id != MPV_EVENT_NONE else { break }

                switch event.pointee.event_id {
                case MPV_EVENT_PROPERTY_CHANGE:
                    self.handlePropertyChange(event)
                case MPV_EVENT_SHUTDOWN:
                    self.mpv = nil
                    return
                case MPV_EVENT_END_FILE:
                    if let data = event.pointee.data {
                        let endFile = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                        if endFile.reason == MPV_END_FILE_REASON_EOF {
                            self.delegate?.mpvController(self, didChangePlaybackState: .ended)
                        } else if endFile.reason == MPV_END_FILE_REASON_ERROR {
                            let errorStr = String(cString: mpv_error_string(endFile.error))
                            self.delegate?.mpvController(self, didChangePlaybackState: .error("MPV playback error: \(errorStr)"))
                        }
                    }
                case MPV_EVENT_LOG_MESSAGE:
                    #if DEBUG
                    if let msg = UnsafeMutablePointer<mpv_event_log_message>(OpaquePointer(event.pointee.data)) {
                        print(
                            "MPV [\(String(cString: msg.pointee.prefix!))] \(String(cString: msg.pointee.level!)): \(String(cString: msg.pointee.text!))",
                            terminator: ""
                        )
                    }
                    #endif
                default:
                    break
                }
            }
        }
    }

    private func handlePropertyChange(_ event: UnsafePointer<mpv_event>) {
        guard let dataPtr = OpaquePointer(event.pointee.data) else { return }
        let property = UnsafePointer<mpv_event_property>(dataPtr).pointee
        let propertyName = String(cString: property.name)

        switch propertyName {
        case "time-pos":
            if property.format == MPV_FORMAT_DOUBLE, let data = property.data {
                let seconds = data.assumingMemoryBound(to: Double.self).pointee
                let size = CGSize(width: CGFloat(videoWidth), height: CGFloat(videoHeight))
                delegate?.mpvController(self, didUpdateSeconds: seconds, videoSize: size)
            }
        case "video-params/w":
            if property.format == MPV_FORMAT_INT64, let data = property.data {
                videoWidth = data.assumingMemoryBound(to: Int64.self).pointee
            }
        case "video-params/h":
            if property.format == MPV_FORMAT_INT64, let data = property.data {
                videoHeight = data.assumingMemoryBound(to: Int64.self).pointee
            }
        case "paused-for-cache":
            if property.format == MPV_FORMAT_FLAG, let data = property.data {
                let buffering = data.assumingMemoryBound(to: Int32.self).pointee != 0
                if buffering {
                    delegate?.mpvController(self, didChangePlaybackState: .buffering)
                }
            }
        case "pause":
            if property.format == MPV_FORMAT_FLAG, let data = property.data {
                let paused = data.assumingMemoryBound(to: Int32.self).pointee != 0
                delegate?.mpvController(self, didChangePlaybackState: paused ? .paused : .playing)
            }
        default:
            break
        }
    }

    private func checkError(_ status: CInt) {
        if status < 0 {
            print("MPV API error: \(String(cString: mpv_error_string(status)))")
        }
    }

    func cleanup() {
        guard mpv != nil else { return }

        mpv_set_wakeup_callback(mpv, nil, nil)
        command("stop", checkForErrors: false)

        if let device = metalLayer.device {
            device.makeCommandQueue()?.makeCommandBuffer()?.commit()
        }

        Thread.sleep(forTimeInterval: 0.1)

        mpv_terminate_destroy(mpv)
        mpv = nil
    }

    deinit {
        cleanup()
    }
}

// MARK: - MPVPlayerView

extension MPVMediaPlayerProxy {

    struct MPVPlayerView: UIViewControllerRepresentable {

        let proxy: MPVMediaPlayerProxy

        func makeUIViewController(context: Context) -> MPVMetalViewController {
            MPVMetalViewController(proxy: proxy)
        }

        func updateUIViewController(_ uiViewController: MPVMetalViewController, context: Context) {}
    }
}

// MARK: - MPVMetalViewController

final class MPVMetalViewController: UIViewController {

    private let proxy: MPVMediaPlayerProxy
    private let controller: MPVController

    init(proxy: MPVMediaPlayerProxy) {
        self.proxy = proxy
        self.controller = MPVController()
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let metalLayer = controller.metalLayer

        // Configure metal layer
        metalLayer.frame = view.bounds
        #if os(iOS)
        metalLayer.contentsScale = UIScreen.main.nativeScale
        #elseif os(tvOS)
        metalLayer.contentsScale = UIScreen.main.scale
        #endif
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.allowsNextDrawableTimeout = false

        view.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        view.layer.addSublayer(metalLayer)

        controller.setupMpv()
        proxy.attachController(controller)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        controller.metalLayer.frame = view.bounds
        CATransaction.commit()
    }

    deinit {
        controller.cleanup()
    }
}

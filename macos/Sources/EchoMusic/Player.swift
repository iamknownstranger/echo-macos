import AVFoundation
import MediaPlayer
import SwiftUI

@MainActor
final class Playhead: ObservableObject {
    @Published var seconds = 0.0
}

@MainActor
final class Player: ObservableObject {
    @Published private(set) var queue: [Track] = []
    @Published private(set) var index: Int?
    @Published private(set) var duration = 0.0
    @Published private(set) var wantsPlayback = false
    @Published private(set) var loading = false
    @Published private(set) var failure: String?
    @Published var roomPlaybackIssue: String?
    @Published var volume: Double = 0.8 { didSet { engine.volume = Float(volume) } }
    @Published var isVideoMode: Bool = false
    let head = Playhead()

    private let engine = AVPlayer()
    var playerEngine: AVPlayer { engine }

    private let offlineURL: (Track) -> URL?
    private let systemControls: Bool
    private var timeObserver: Any?
    private var rateObserver: NSKeyValueObservation?
    private var itemObserver: NSKeyValueObservation?
    private var itemNotifications: [NSObjectProtocol] = []
    private var request: Task<Void, Never>?
    private var generation = UUID()
    private var ended = false
    private var roomPlayback: RoomPlayback?
    private var roomSeek = UUID()
    private(set) var roomSeekInProgress = false

    var roomReady: Bool { engine.currentItem?.status == .readyToPlay && !loading && failure == nil }
    var roomPlaying: Bool { wantsPlayback && engine.timeControlStatus == .playing }
    var roomPosition: Double {
        let seconds = engine.currentTime().seconds
        return seconds.isFinite ? max(0, seconds) : head.seconds
    }
    var roomTrackGeneration: UUID { generation }

    func attachRoom(_ session: RoomSession) {
        roomPlayback = RoomPlayback(player: self, session: session)
    }

    private func roomAllows(_ track: Track? = nil) -> Bool {
        roomPlayback?.allowsLocalControl(track: track) != false
    }

    func setRoomQueue(_ tracks: [Track], at selected: Int?, reload: Bool = false) {
        queue = tracks
        if let selected, reload {
            start(selected, autoplay: false)
        } else {
            index = selected
            if selected == nil {
                request?.cancel()
                generation = UUID()
                roomSeek = UUID()
                roomSeekInProgress = false
                itemObserver = nil
                for token in itemNotifications { NotificationCenter.default.removeObserver(token) }
                itemNotifications.removeAll()
                engine.pause()
                engine.replaceCurrentItem(with: nil)
                wantsPlayback = false
                loading = false
                failure = nil
                duration = 0
                head.seconds = 0
            }
            updateSystemState()
        }
    }

    func applyRoomPosition(_ seconds: Double?, playing: Bool) {
        if !playing {
            wantsPlayback = false
            engine.pause()
            updateSystemState()
        }
        guard roomReady else { return }
        if seconds == nil, playing && roomSeekInProgress { return }
        let ticket = UUID()
        roomSeek = ticket
        roomSeekInProgress = seconds != nil
        engine.currentItem?.cancelPendingSeeks()
        if playing { wantsPlayback = true }
        if let seconds {
            let position = duration > 0 ? min(max(0, seconds), duration) : max(0, seconds)
            ended = false
            head.seconds = position
            engine.seek(to: CMTime(seconds: position, preferredTimescale: 1000),
                        toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                Task { @MainActor in
                    guard let self, self.roomSeek == ticket else { return }
                    self.roomSeekInProgress = false
                    if finished && self.wantsPlayback { self.engine.play() }
                    self.updateSystemState()
                    self.roomPlayback?.playerStatusChanged()
                }
            }
        } else if playing && !roomPlaying {
            engine.play()
        }
        updateSystemState()
    }

    func setRoomRate(_ rate: Float) {
        if roomPlaying { engine.rate = rate }
    }

    func disconnectRoomPlayback() {
        roomSeek = UUID()
        roomSeekInProgress = false
        engine.currentItem?.cancelPendingSeeks()
        if wantsPlayback && roomReady { engine.play() }
    }

    private var remoteTargets: [(MPRemoteCommand, Any)] = []

    var current: Track? { index.flatMap { queue.indices.contains($0) ? queue[$0] : nil } }
    private var nextIndex: Int? {
        guard let index else { return nil }
        let upcoming = queue.indices.dropFirst(index + 1)
        if roomPlayback?.expectsSharedTracks == true {
            return upcoming.first { queue[$0].roomTrackID != nil }
        }
        return upcoming.first
    }

    var hasNext: Bool { nextIndex != nil }

    init(systemControls: Bool = true, offlineURL: @escaping (Track) -> URL? = { _ in nil }) {
        self.offlineURL = offlineURL
        self.systemControls = systemControls
        engine.volume = Float(volume)
        timeObserver = engine.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.35, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.engine.currentItem != nil else { return }
                let time = self.engine.currentTime().seconds
                if time.isFinite {
                    let clamped = self.duration > 0 ? min(max(0, time), self.duration) : max(0, time)
                    self.head.seconds = clamped
                    if let track = self.current {
                        PlaybackTracker.shared.timeDidUpdate(to: clamped, track: track)
                    }
                }
            }
        }
        rateObserver = engine.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                self?.updateSystemState()
                self?.roomPlayback?.playerStatusChanged()
            }
        }
        if systemControls { registerCommands() }
    }

    deinit {
        request?.cancel()
        if let timeObserver { engine.removeTimeObserver(timeObserver) }
        for token in itemNotifications { NotificationCenter.default.removeObserver(token) }
        for (command, target) in remoteTargets { command.removeTarget(target) }
    }

    func play(_ tracks: [Track], at selected: Int = 0) {
        guard tracks.indices.contains(selected), roomAllows(tracks[selected]) else { return }
        queue = tracks
        start(selected)
    }

    func enqueue(_ track: Track, next: Bool = false) {
        guard roomAllows(track) else { return }
        guard let index else { play([track]); return }
        queue.insert(track, at: next ? index + 1 : queue.endIndex)
        updateSystemState()
        roomPlayback?.localQueueChanged()
    }

    func removeUpcoming(_ offset: Int) {
        guard let index, offset > index, queue.indices.contains(offset), roomAllows() else { return }
        queue.remove(at: offset)
        updateSystemState()
        roomPlayback?.localQueueChanged()
    }

    func start(_ selected: Int) {
        guard queue.indices.contains(selected), roomAllows(queue[selected]) else { return }
        start(selected, autoplay: true)
    }

    private func start(_ selected: Int, autoplay: Bool) {
        request?.cancel()
        let ticket = UUID()
        generation = ticket
        roomSeek = UUID()
        roomSeekInProgress = false
        itemObserver = nil
        for token in itemNotifications { NotificationCenter.default.removeObserver(token) }
        itemNotifications.removeAll()
        engine.pause()
        engine.replaceCurrentItem(with: nil)
        index = selected
        let track = queue[selected]
        PlaybackTracker.shared.trackDidChange(to: track)
        ended = false
        failure = nil
        wantsPlayback = autoplay
        loading = true
        head.seconds = 0
        duration = track.duration ?? 0
        updateSystemState()
        if autoplay { roomPlayback?.localTrackChanged() }

        request = Task {
            do {
                let url: URL
                var streamBytes: Int64? = nil
                let effectiveSource = track.playbackSource ?? track.source
                switch effectiveSource {
                case .file(let file):
                    guard FileManager.default.isReadableFile(atPath: file.path) else {
                        throw EchoError("The file could not be opened. If it moved, import it from its new location.")
                    }
                    url = file
                    if let d = track.duration, d > 0 { duration = d }
                case .youtube(let id):
                    if let file = offlineURL(track) {
                        url = file
                        break
                    }
                    if !isVideoMode, let cached = await AudioCache.shared.cachedURL(for: effectiveSource) {
                        url = cached
                        break
                    }
                    if isVideoMode {
                        let stream = try await Catalog.shared.videoStream(for: id, title: track.title, artist: track.artist)
                        try Task.checkCancellation()
                        guard generation == ticket else { return }
                        url = stream.url
                        if let index, queue.indices.contains(index) {
                            if queue[index].duration == nil { queue[index].duration = stream.track.duration }
                            if queue[index].artwork == nil { queue[index].artwork = stream.track.artwork }
                            if track.title == id { queue[index].title = stream.track.title }
                            if queue[index].artist.isEmpty { queue[index].artist = stream.track.artist }
                        }
                        let d = stream.track.duration ?? track.duration ?? 0
                        if d > 0 { duration = d }
                    } else {
                        let stream = try await Catalog.shared.stream(for: id)
                        try Task.checkCancellation()
                        guard generation == ticket else { return }
                        url = stream.url
                        streamBytes = stream.audioByteCount
                        if let index, queue.indices.contains(index) {
                            if queue[index].duration == nil { queue[index].duration = stream.track.duration }
                            if queue[index].artwork == nil { queue[index].artwork = stream.track.artwork }
                            if track.title == id { queue[index].title = stream.track.title }
                            if queue[index].artist.isEmpty { queue[index].artist = stream.track.artist }
                        }
                        let d = stream.track.duration ?? track.duration ?? 0
                        if d > 0 { duration = d }
                    }
                default:
                    let stream = try await Catalog.shared.stream(for: track)
                    try Task.checkCancellation()
                    guard generation == ticket else { return }
                    url = stream.url
                    streamBytes = stream.audioByteCount
                    if let index, queue.indices.contains(index) {
                        if queue[index].duration == nil { queue[index].duration = stream.track.duration }
                        if queue[index].artwork == nil { queue[index].artwork = stream.track.artwork }
                    }
                    let d = stream.track.duration ?? track.duration ?? 0
                    if d > 0 { duration = d }
                }
                guard generation == ticket, !Task.isCancelled else { return }
                let item = await createPlayerItem(for: url, track: track, streamAudioBytes: streamBytes)
                load(item, ticket: ticket)
            } catch {
                guard generation == ticket, !Task.isCancelled else { return }
                fail(error.localizedDescription)
            }
        }
    }

    private func createPlayerItem(for url: URL, track: Track, streamAudioBytes: Int64? = nil) async -> AVPlayerItem {
        if url.isFileURL || isVideoMode {
            return AVPlayerItem(url: url)
        }
        let effectiveSource = track.playbackSource ?? track.source
        if let cached = await AudioCache.shared.cachedURL(for: effectiveSource) {
            return AVPlayerItem(url: cached)
        }
        if let key = await AudioCache.shared.cacheKey(for: effectiveSource) {
            let customURL = AudioCacheURL.encode(streamURL: url, key: key)
            let asset = AVURLAsset(url: customURL)
            asset.resourceLoader.setDelegate(AudioCacheResourceLoader.shared, queue: AudioCacheResourceLoader.shared.queue)
            prefetchNextQueueItem()
            return AVPlayerItem(asset: asset)
        }
        return AVPlayerItem(url: url)
    }

    private func prefetchNextQueueItem() {
        guard let nextIndex, queue.indices.contains(nextIndex) else { return }
        let nextTrack = queue[nextIndex]
        Task {
            let nextSource = nextTrack.playbackSource ?? nextTrack.source
            guard let nextKey = await AudioCache.shared.cacheKey(for: nextSource),
                  await !AudioCache.shared.isCached(key: nextKey) else { return }
            if case .youtube(let nextID) = nextSource,
               let nextStream = try? await Catalog.shared.stream(for: nextID) {
                await AudioCache.shared.prefetch(key: nextKey, remoteURL: nextStream.url, expectedBytes: nextStream.audioByteCount)
            }
        }
    }

    private func load(_ item: AVPlayerItem, ticket: UUID) {
        Equalizer.shared.configureAudio(for: item)
        if duration > 0 {
            item.forwardPlaybackEndTime = CMTime(seconds: duration, preferredTimescale: 1000)
        }
        engine.replaceCurrentItem(with: item)
        itemObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.generation == ticket else { return }
                switch item.status {
                case .readyToPlay:
                    self.loading = false
                    let length = item.duration.seconds
                    if self.duration <= 0 {
                        if let url = (item.asset as? AVURLAsset)?.url,
                           let durParam = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "dur" })?.value,
                           let dur = Double(durParam), dur > 0 {
                            self.duration = dur
                        } else if length.isFinite && length > 0 {
                            self.duration = length
                        }
                    } else if length.isFinite && length > 0 {
                        // Protect against AVPlayerItem container timescale doubling bug on fragmented MP4 YouTube streams:
                        // Only adopt length if it is reasonably close to authoritative metadata duration (sub-second adjustment).
                        // Never overwrite if length is ~2x doubled or significantly diverges from authoritative metadata.
                        if abs(length - self.duration) <= 2.0 {
                            self.duration = length
                        }
                    }
                    if self.duration > 0 {
                        item.forwardPlaybackEndTime = CMTime(seconds: self.duration, preferredTimescale: 1000)
                    }
                    if let index = self.index, self.queue.indices.contains(index), self.queue[index].duration == nil {
                        self.queue[index].duration = self.duration
                    }
                    if self.wantsPlayback { self.engine.play() }
                    self.updateSystemState()
                    self.roomPlayback?.playerStatusChanged()
                case .failed: self.fail(item.error?.localizedDescription ?? "This audio could not be played.")
                default: break
                }
            }
        }
        let center = NotificationCenter.default
        itemNotifications.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == ticket else { return }
                if self.roomPlayback?.expectsRemoteTrackChanges == true {
                    self.ended = true
                    self.head.seconds = self.duration
                    self.wantsPlayback = false
                    self.updateSystemState()
                } else if let next = self.nextIndex {
                    self.start(next)
                } else {
                    self.ended = true
                    self.head.seconds = self.duration
                    self.pause()
                }
            }
        })
        itemNotifications.append(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
            let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
            Task { @MainActor in
                guard let self, self.generation == ticket else { return }
                self.fail(message ?? "The stream was interrupted. Try playing this song again.")
            }
        })
    }

    func switchPlaybackMode(toVideo: Bool) async {
        guard isVideoMode != toVideo else { return }
        isVideoMode = toVideo
        guard let current else { return }
        let savedTime = head.seconds
        let wasPlaying = wantsPlayback
        do {
            loading = true
            let streamObj: Catalog.Stream
            if toVideo {
                let videoID: String
                if case .youtube(let id) = current.playbackSource ?? current.source {
                    videoID = id
                } else {
                    let matched = try await MultiSourceResolver.shared.matchToYouTube(track: current)
                    guard case .youtube(let id) = matched.playbackSource ?? matched.source else {
                        throw EchoError("Could not resolve video stream for \(current.title)")
                    }
                    videoID = id
                }
                streamObj = try await Catalog.shared.videoStream(for: videoID, title: current.title, artist: current.artist)
            } else {
                streamObj = try await Catalog.shared.stream(for: current)
            }
            let item = await createPlayerItem(for: streamObj.url, track: current, streamAudioBytes: streamObj.audioByteCount)
            if let dur = streamObj.track.duration ?? current.duration, dur > 0 {
                duration = dur
            }
            load(item, ticket: generation)
            if savedTime > 0 {
                engine.seek(to: CMTime(seconds: savedTime, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    Task { @MainActor in
                        if wasPlaying { self?.engine.play() }
                    }
                }
            } else if wasPlaying {
                engine.play()
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    func currentTrackRemainingTime() -> Double? {
        guard duration > 0 else { return nil }
        return max(0, duration - head.seconds)
    }

    private func fail(_ message: String) {
        loading = false
        failure = message
        wantsPlayback = false
        engine.pause()
        updateSystemState()
        roomPlayback?.playerStatusChanged()
    }

    func toggle() { wantsPlayback ? pause() : resume() }

    func pause() {
        guard roomAllows() else { return }
        roomSeek = UUID()
        roomSeekInProgress = false
        wantsPlayback = false
        engine.pause()
        updateSystemState()
        roomPlayback?.localPlayStateChanged()
    }

    func resume() {
        guard let index, roomAllows(current) else { return }
        if failure != nil || ended { start(index); return }
        wantsPlayback = true
        if !loading { engine.play() }
        updateSystemState()
        roomPlayback?.localPlayStateChanged()
    }

    func previous() {
        guard let index else { return }
        if head.seconds > 3 || index == 0 { seek(0) } else { start(index - 1) }
    }

    func next() { if let nextIndex { start(nextIndex) } }

    func seek(_ seconds: Double) {
        guard roomAllows(), seconds.isFinite, duration > 0, roomReady else { return }
        roomSeek = UUID()
        roomSeekInProgress = false
        let position = min(max(0, seconds), duration)
        ended = false
        head.seconds = position
        engine.seek(to: CMTime(seconds: position, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
        updateSystemState()
        roomPlayback?.localSeeked(to: position)
    }

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()
        func bind(_ command: MPRemoteCommand, _ action: @escaping @MainActor (Player) -> Void) {
            let target = command.addTarget { [weak self] _ in
                Task { @MainActor in if let self { action(self) } }
                return .success
            }
            remoteTargets.append((command, target))
        }
        bind(center.playCommand) { $0.resume() }
        bind(center.pauseCommand) { $0.pause() }
        bind(center.togglePlayPauseCommand) { $0.toggle() }
        bind(center.previousTrackCommand) { $0.previous() }
        bind(center.nextTrackCommand) { $0.next() }
        let command = center.changePlaybackPositionCommand
        let target = command.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(event.positionTime) }
            return .success
        }
        remoteTargets.append((command, target))
        updateSystemState()
    }

    private func updateSystemState() {
        guard systemControls else { return }
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.isEnabled = current != nil && !wantsPlayback
        commands.pauseCommand.isEnabled = wantsPlayback
        commands.togglePlayPauseCommand.isEnabled = current != nil
        commands.previousTrackCommand.isEnabled = current != nil
        commands.nextTrackCommand.isEnabled = hasNext
        commands.changePlaybackPositionCommand.isEnabled = duration > 0 && !loading && failure == nil
        guard let current else {
            Task { await DiscordRPC.shared.clearActivity() }
            return
        }
        let info = MPNowPlayingInfoCenter.default()
        let playing = engine.timeControlStatus == .playing
        info.nowPlayingInfo = [
            MPMediaItemPropertyTitle: current.title, MPMediaItemPropertyArtist: current.artist,
            MPMediaItemPropertyPlaybackDuration: duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: head.seconds,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0
        ]
        info.playbackState = playing ? .playing : .paused

        Task {
            await DiscordRPC.shared.updateActivity(
                track: current,
                position: head.seconds,
                duration: duration,
                isPlaying: playing
            )
        }
    }
}

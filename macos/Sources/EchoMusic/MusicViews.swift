import AppKit
import SwiftUI

struct Cover: View {
    let url: URL?
    var body: some View {
        ZStack {
            Color.primary.opacity(0.065)
            Image(systemName: "waveform").foregroundStyle(.secondary).accessibilityHidden(true)
            if let url {
                AsyncImage(url: url) { image in image.resizable().aspectRatio(contentMode: .fill) } placeholder: { Color.clear }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityHidden(true)
    }
}

struct CoverCard: View {
    let title: String
    let subtitle: String
    let url: URL?

    // The catalog also serves these thumbnails at row size. Request artwork
    // large enough for the desktop shelf on a Retina display.
    private var coverURL: URL? {
        guard let url, url.host?.hasSuffix(".googleusercontent.com") == true,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let range = parts.percentEncodedPath.range(of: "=w[0-9]+-h[0-9]+", options: .regularExpression) else { return url }
        parts.percentEncodedPath.replaceSubrange(range, with: "=w500-h500")
        return parts.url ?? url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Cover(url: coverURL)
                .frame(width: 162, height: 162)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: 162, alignment: .leading)
        }
        .frame(width: 162, alignment: .topLeading)
        .contentShape(Rectangle())
        .threeDTilt()
    }
}

struct LoadingShelf: View {
    var body: some View {
        HStack(spacing: 12) {
            ForEach(0..<3) { _ in RoundedRectangle(cornerRadius: 7).fill(.quaternary).frame(maxWidth: 162).frame(height: 90) }
        }.accessibilityElement(children: .ignore).accessibilityLabel("Loading music")
    }
}

struct Notice: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: symbol).font(.title).foregroundStyle(.secondary).padding(.bottom, 5)
            Text(title).font(.title3.bold())
            Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 14)
    }
}

struct SongMenu: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var library: Library
    let track: Track
    var playlist: UUID?
    var localActions = false

    var body: some View {
        Button("Play next") { player.enqueue(track, next: true) }
        Button("Add to queue") { player.enqueue(track) }
        Button(library.likes(track) ? "Remove from liked songs" : "Like song") { library.toggleLike(track) }
        Menu("Add to playlist") {
            ForEach(library.data.playlists) { list in
                Button(list.name) { library.add(track, to: list.id) }.disabled(list.tracks.contains { $0.id == track.id })
            }
        }.disabled(library.data.playlists.isEmpty)
        if let playlist { Button("Remove from playlist") { library.remove(track, from: playlist) } }
        if let url = track.shareURL {
            Divider()
            if library.offlineURL(track) != nil {
                Button("Remove download") { library.removeDownload(track) }
            } else {
                Button(library.downloading.contains(track.id) ? "Downloading…" : "Download") {
                    Task { await library.download(track) }
                }.disabled(library.downloading.contains(track.id))
            }
            Button("Copy Echo song link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        }
        if localActions, case .file(let url) = track.source {
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Remove from library") { library.forgetFile(track) }
        }
    }
}

struct TrackRows: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var library: Library
    let tracks: [Track]
    var playlist: UUID?
    var localActions = false

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                HStack(spacing: 10) {
                    Button { player.play(tracks, at: index) } label: {
                        HStack(spacing: 10) {
                            Cover(url: track.artwork).frame(width: 37, height: 37)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(track.title).fontWeight(.medium).lineLimit(1)
                                    .foregroundStyle(player.current?.id == track.id ? Color.echoAccent : .primary)
                                Text(track.artist.isEmpty ? "Unknown artist" : track.artist)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Play \(track.title), \(track.artist)")
                    if let duration = track.duration { Text(clockText(duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    Button { library.toggleLike(track) } label: { Image(systemName: library.likes(track) ? "heart.fill" : "heart") }
                        .buttonStyle(.borderless).accessibilityLabel(library.likes(track) ? "Unlike \(track.title)" : "Like \(track.title)")
                    Menu {
                        SongMenu(track: track, playlist: playlist, localActions: localActions)
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Options for \(track.title)")
                }.padding(.vertical, 7)
                .contextMenu { SongMenu(track: track, playlist: playlist, localActions: localActions) }
                Divider()
            }
        }
    }
}

struct Transport: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var room: RoomSession
    @ObservedObject private var sleepTimer = SleepTimer.shared
    @ObservedObject private var equalizer = Equalizer.shared
    @Binding var inspector: Inspector?
    @ViewState private var equalizerSheetOpen = false

    var body: some View {
        VStack(spacing: 5) {
            if let failure = player.failure {
                HStack {
                    Image(systemName: "exclamationmark.circle")
                    Text(failure).lineLimit(2)
                    Spacer()
                    Button("Retry") { player.resume() }
                }.font(.callout).padding(.bottom, 4)
            }
            HStack(spacing: 12) {
                Cover(url: player.current?.artwork).frame(width: 45, height: 45)
                VStack(alignment: .leading, spacing: 3) {
                    Text(player.current?.title ?? "Nothing playing").lineLimit(1).font(.headline)
                    if let track = player.current {
                        Text(player.loading ? "Loading audio…" : track.artist).lineLimit(1).font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(minWidth: 70, idealWidth: 155, maxWidth: 190, alignment: .leading)
                if let track = player.current {
                    Button { library.toggleLike(track) } label: { Image(systemName: library.likes(track) ? "heart.fill" : "heart") }
                        .buttonStyle(.plain).accessibilityLabel("Toggle liked song")
                }
                Spacer(minLength: 3)
                Group {
                    Button { player.previous() } label: { Image(systemName: "backward.fill") }
                        .accessibilityLabel("Previous song").disabled(player.current == nil)
                    Button { player.toggle() } label: {
                        Image(systemName: player.wantsPlayback ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 33))
                    }.accessibilityLabel(player.wantsPlayback ? "Pause" : "Play").disabled(player.current == nil)
                    Button { player.next() } label: { Image(systemName: "forward.fill") }
                        .accessibilityLabel("Next song").disabled(!player.hasNext)
                    Scrubber(head: player.head).frame(minWidth: 80, maxWidth: .infinity).padding(.horizontal, 5)
                }.disabled(room.role == .guest && !room.canControlPlayback)

                Button {
                    Task { await player.switchPlaybackMode(toVideo: !player.isVideoMode) }
                } label: {
                    Image(systemName: player.isVideoMode ? "video.fill" : "video")
                        .foregroundStyle(player.isVideoMode ? Color.echoAccent : .primary)
                }
                .help(player.isVideoMode ? "Switch to Song mode" : "Switch to Video mode")
                .accessibilityLabel("Toggle Video mode")
                .disabled(player.current == nil)

                Menu {
                    Button("Off") { sleepTimer.start(mode: .off) }
                    Button("15 minutes") { sleepTimer.start(mode: .minutes(15)) }
                    Button("30 minutes") { sleepTimer.start(mode: .minutes(30)) }
                    Button("45 minutes") { sleepTimer.start(mode: .minutes(45)) }
                    Button("60 minutes") { sleepTimer.start(mode: .minutes(60)) }
                    Button("End of current track") { sleepTimer.start(mode: .endOfTrack) }
                } label: {
                    Image(systemName: sleepTimer.activeMode == .off ? "moon.zzz" : "moon.zzz.fill")
                        .foregroundStyle(sleepTimer.activeMode == .off ? .primary : Color.echoAccent)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 22)
                .help(sleepTimer.activeMode == .off ? "Sleep Timer" : "Sleep Timer: \(sleepTimer.activeMode.title)")

                Button {
                    equalizerSheetOpen = true
                } label: {
                    Image(systemName: "slider.vertical.3")
                        .foregroundStyle(equalizer.isEnabled ? Color.echoAccent : .primary)
                }
                .help("Equalizer & Loudness Normalization")
                .accessibilityLabel("Equalizer")

                Button {
                    AmbientWindowController.shared.toggle(player: player, library: library)
                } label: {
                    Image(systemName: "sparkles")
                }
                .help("Ambient Full-Screen Screensaver Player")
                .accessibilityLabel("Ambient Player")
                .disabled(player.current == nil)

                Image(systemName: "speaker.wave.2").foregroundStyle(.secondary).accessibilityHidden(true)
                Slider(value: $player.volume).frame(width: 58).accessibilityLabel("Volume")
                Divider().frame(height: 22)
                inspectorButton(.video, "tv", "Video & PiP")
                inspectorButton(.lyrics, "quote.bubble", "Lyrics")
                inspectorButton(.queue, "list.bullet", "Play queue")
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 17).padding(.vertical, 11).background(.regularMaterial)
        .sheet(isPresented: $equalizerSheetOpen) {
            EqualizerSheet(isPresented: $equalizerSheetOpen)
        }
    }

    private func inspectorButton(_ mode: Inspector, _ symbol: String, _ title: String) -> some View {
        Button { inspector = inspector == mode ? nil : mode } label: {
            Image(systemName: symbol).foregroundStyle(inspector == mode ? Color.echoAccent : .primary)
        }.help(title).accessibilityLabel(title)
    }
}

struct Scrubber: View {
    @EnvironmentObject private var player: Player
    @ObservedObject var head: Playhead
    @ViewState private var tentative: Double?
    @ViewState private var dragging = false
    var body: some View {
        VStack(spacing: 1) {
            Slider(value: Binding(get: { tentative ?? min(head.seconds, max(1, player.duration)) }, set: { position in
                if dragging { tentative = position } else { player.seek(position) }
            }),
                   in: 0...max(1, player.duration), onEditingChanged: { editing in
                dragging = editing
                if !editing, let position = tentative { player.seek(position); tentative = nil }
            })
            .disabled(player.duration <= 0 || player.loading || player.failure != nil)
            .accessibilityLabel("Playback position")
            .accessibilityValue(clockText(tentative ?? head.seconds))
            HStack {
                Text(clockText(tentative ?? head.seconds))
                Spacer()
                Text(clockText(player.duration))
            }.font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

struct InspectorView: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var library: Library
    let mode: Inspector
    let close: () -> Void
    @ViewState private var lyrics: Lyrics?
    @ViewState private var lyricsError: String?
    @ViewState private var retry = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(mode == .queue ? "Play queue" : (mode == .video ? "Video & PiP" : "Lyrics")).font(.title2.bold())
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Close panel")
            }
            if mode == .video {
                VStack(alignment: .leading, spacing: 12) {
                    ZStack {
                        VideoPlaybackView(player: player.playerEngine)
                            .aspectRatio(16/9, contentMode: .fit)
                            .cornerRadius(8)
                            .shadow(color: .black.opacity(0.2), radius: 6, x: 0, y: 3)
                        if player.loading {
                            ZStack {
                                Color.black.opacity(0.6)
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .controlSize(.regular)
                            }
                            .aspectRatio(16/9, contentMode: .fit)
                            .cornerRadius(8)
                        }
                    }
                    if let track = player.current {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(track.title).font(.headline).lineLimit(1)
                            Text(track.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Button {
                        Task { await player.switchPlaybackMode(toVideo: !player.isVideoMode) }
                    } label: {
                        Label(player.isVideoMode ? "Switch to Audio Only" : "Load High-Res Video", systemImage: player.isVideoMode ? "speaker.wave.2" : "video.fill")
                    }
                    .buttonStyle(.bordered)
                }
                .task {
                    if !player.isVideoMode && player.current != nil {
                        await player.switchPlaybackMode(toVideo: true)
                    }
                }
            } else if mode == .queue {
                if player.queue.isEmpty { Text("Play a song to start your queue.").foregroundStyle(.secondary) }
                ScrollView {
                    LazyVStack(alignment: .leading) {
                        ForEach(Array(player.queue.enumerated()), id: \.offset) { offset, track in
                            HStack {
                                Button { player.start(offset) } label: {
                                    HStack {
                                        if player.index == offset { Image(systemName: "waveform").foregroundStyle(Color.echoAccent) }
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(track.title).fontWeight(.medium).lineLimit(2)
                                            Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                if let current = player.index, offset > current {
                                    Button { player.removeUpcoming(offset) } label: { Image(systemName: "minus.circle") }
                                        .buttonStyle(.plain).accessibilityLabel("Remove \(track.title) from queue")
                                }
                            }.padding(.vertical, 5)
                        }
                    }
                }
            } else if player.current == nil { Text("Play a song to see its lyrics.").foregroundStyle(.secondary) }
            else if let lyricsError {
                Text(lyricsError).foregroundStyle(.secondary)
                Button("Try again") { retry += 1 }
            } else if let lyrics {
                switch lyrics {
                case .instrumental:
                    HStack(spacing: 8) {
                        Image(systemName: "guitars")
                            .font(.title2)
                        Text("Instrumental")
                            .font(.headline)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.top, 16)
                case .plain(let text):
                    ScrollView { Text(text).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                case .synced(let lines):
                    if let track = player.current {
                        let offset = library.lyricOffset(for: track.id)
                        HStack(spacing: 6) {
                            Text("Offset:")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Button("-0.5s") {
                                library.updateTrackOffset(id: track.id, offset: offset - 0.5)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            Text(String(format: "%+.1fs", offset))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(offset == 0 ? .secondary : .primary)
                            Button("+0.5s") {
                                library.updateTrackOffset(id: track.id, offset: offset + 0.5)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            if offset != 0 {
                                Button("Reset") {
                                    library.updateTrackOffset(id: track.id, offset: 0.0)
                                }
                                .buttonStyle(.borderless)
                                .controlSize(.mini)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.bottom, 6)
                        SyncedLyrics(lines: lines, head: player.head, offset: offset)
                    } else {
                        SyncedLyrics(lines: lines, head: player.head)
                    }
                case .notFound:
                    Text("No lyrics were found for this recording.").foregroundStyle(.secondary)
                }
            } else { ProgressView("Finding lyrics…").controlSize(.small) }
            Spacer(minLength: 0)
        }
        .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: Lookup(mode: mode, track: player.current, retry: retry)) {
            lyrics = nil
            lyricsError = nil
            guard mode == .lyrics, let track = player.current else { return }
            if case .youtube(let id) = track.source, track.title == id { return }
            do {
                let result = try await Lyrics.fetch(track)
                try Task.checkCancellation()
                lyrics = result
            } catch { if !Task.isCancelled { lyricsError = error.localizedDescription } }
        }
    }
    private struct Lookup: Equatable { let mode: Inspector; let track: Track?; let retry: Int }
}

struct SyncedLyrics: View {
    @EnvironmentObject private var player: Player
    let lines: [LyricLine]
    @ObservedObject var head: Playhead
    var offset: Double = 0.0

    var body: some View {
        let active = lines.lastIndex { $0.adjustedTimestamp(offset: offset) <= head.seconds }
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(lines.indices, id: \.self) { index in
                        let line = lines[index]
                        Button { player.seek(line.adjustedTimestamp(offset: offset)) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.text.isEmpty ? "♪" : line.text)
                                    .font(.body.weight(index == active ? .bold : .regular))
                                    .foregroundStyle(index == active ? .primary : .secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if let translation = line.translation, !translation.isEmpty {
                                    Text(translation)
                                        .font(.caption)
                                        .foregroundStyle(index == active ? Color.secondary : Color.secondary.opacity(0.7))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }.buttonStyle(.plain).id(index)
                    }
                }
            }
            .onChange(of: active, initial: true) { _, line in
                if let line { proxy.scrollTo(line, anchor: .center) }
            }
        }
    }
}

// MARK: - Artist Detail View

struct ArtistDetailView: View {
    let artist: Artist
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var browse: BrowseModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 20) {
                    if let thumb = artist.thumbnailURL {
                        AsyncImage(url: thumb) { phase in
                            if let image = phase.image {
                                image.resizable().aspectRatio(contentMode: .fill)
                            } else {
                                Color.gray.opacity(0.3)
                            }
                        }
                        .frame(width: 130, height: 130)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.2), radius: 6, x: 0, y: 3)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("ARTIST").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(artist.name).font(.system(size: 32, weight: .bold)).lineLimit(1)
                        if let bio = artist.bio {
                            Text(bio).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                }
                .padding(.top, 10)

                if !artist.singles.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Top Tracks").font(.title2.bold())
                        TrackRows(tracks: artist.singles)
                    }
                }

                if !artist.albums.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Albums & Releases").font(.title2.bold())
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                ForEach(artist.albums) { alb in
                                    Button {
                                        browse.showAlbum(id: alb.id)
                                    } label: {
                                        CoverCard(title: alb.title, subtitle: alb.year ?? "", url: alb.coverURL)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}

// MARK: - Album Detail View

struct AlbumDetailView: View {
    let album: Album
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var library: Library

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 20) {
                    Cover(url: album.coverURL)
                        .frame(width: 150, height: 150)
                        .cornerRadius(8)
                        .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
                        .threeDTilt()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("ALBUM").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(album.title).font(.system(size: 28, weight: .bold)).lineLimit(2)
                        Text(album.artist).font(.title3).foregroundStyle(.secondary)
                        if let year = album.year {
                            Text("\(year) · \(album.tracks.count) tracks").font(.caption).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 10) {
                            Button {
                                if !album.tracks.isEmpty { player.play(album.tracks, at: 0) }
                            } label: {
                                Label("Play Album", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(.top, 6)
                    }
                }
                .padding(.top, 10)

                Divider()
                TrackRows(tracks: album.tracks)
            }
            .padding(24)
        }
    }
}

// MARK: - Spotify Import Sheet

struct SpotifyImportSheet: View {
    @Binding var isPresented: Bool
    @ViewState private var urlString = ""
    @ViewState private var isBusy = false
    @ViewState private var statusMessage: String?
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: Player

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import from Spotify").font(.title2.bold())
            Text("Paste any public Spotify track link to stream it natively with zero user login.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("https://open.spotify.com/track/...", text: $urlString)
                .textFieldStyle(.roundedBorder)

            if let msg = statusMessage {
                Text(msg).font(.caption).foregroundStyle(msg.contains("Error") ? .red : .green)
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }.buttonStyle(.bordered)
                Button("Import & Play") {
                    guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
                    isBusy = true
                    statusMessage = "Resolving Spotify metadata & YouTube stream..."
                    Task {
                        do {
                            let track = try await MultiSourceResolver.shared.resolve(url: url)
                            library.toggleLike(track)
                            player.play([track], at: 0)
                            statusMessage = "Imported: \(track.title)"
                            isBusy = false
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                            isPresented = false
                        } catch {
                            statusMessage = "Error: \(error.localizedDescription)"
                            isBusy = false
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(urlString.isEmpty || isBusy)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

// MARK: - Equalizer Sheet

struct EqualizerSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject private var equalizer = Equalizer.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Equalizer & Normalization").font(.title2.bold())
                Spacer()
                Toggle("", isOn: $equalizer.isEnabled)
                    .toggleStyle(.switch)
                    .accessibilityLabel("Toggle Equalizer")
            }

            // Preset Selector
            HStack {
                Text("Preset:").font(.headline)
                Picker("", selection: $equalizer.currentPreset) {
                    ForEach(EQPreset.allPresets) { preset in
                        Text(preset.name).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!equalizer.isEnabled)
            }

            Divider()

            // 5-Band Slider Controls
            HStack(spacing: 24) {
                ForEach(Array(equalizer.bands.enumerated()), id: \.element.frequency) { index, band in
                    VStack(spacing: 8) {
                        Text(String(format: "%+.1fdB", band.gain))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)

                        Slider(
                            value: Binding(
                                get: { equalizer.bands[index].gain },
                                set: { equalizer.setBandGain(at: index, gain: $0) }
                            ),
                            in: -12.0...12.0,
                            step: 0.5
                        )
                        .frame(height: 140)
                        .rotationEffect(.degrees(-90))
                        .frame(width: 32)
                        .disabled(!equalizer.isEnabled)

                        Text(band.label)
                            .font(.caption.weight(.semibold))
                    }
                    .frame(width: 50)
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .center)

            Divider()

            // Loudness Normalization Toggle (ReplayGain leveling)
            Toggle(isOn: $equalizer.loudnessNormalizationEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Audio Loudness Normalization").font(.headline)
                    Text("Dynamically adjusts playback levels to prevent abrupt volume shifts between tracks.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)

            HStack {
                Spacer()
                Button("Done") {
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 480)
    }
}

// MARK: - History View

struct HistoryView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: Player

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Listening History").font(.system(size: 35, weight: .bold)).tracking(-1.4)
                    Text("\(library.data.history.count) plays tracked")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if !library.data.history.isEmpty {
                    Button(role: .destructive) {
                        library.clearHistory()
                    } label: {
                        Label("Clear History", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }
            }

            if library.data.history.isEmpty {
                Notice(
                    symbol: "clock.arrow.circlepath",
                    title: "No history yet",
                    detail: "Songs you listen to for more than 30 seconds or 50% of their length will appear here."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(library.data.history) { entry in
                            HStack(spacing: 12) {
                                Cover(url: entry.track.artwork).frame(width: 44, height: 44)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.track.title).font(.body.weight(.medium)).lineLimit(1)
                                    Text(entry.track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 3) {
                                    Text(entry.playedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2).foregroundStyle(.secondary)
                                    let count = library.playCount(for: entry.track)
                                    if count > 1 {
                                        Text("\(count) plays")
                                            .font(.caption2.weight(.bold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.echoAccent.opacity(0.15), in: Capsule())
                                            .foregroundStyle(Color.echoAccent)
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                player.play([entry.track])
                            }
                            .contextMenu { SongMenu(track: entry.track) }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Charts View

struct ChartsView: View {
    @EnvironmentObject private var browse: BrowseModel
    @EnvironmentObject private var player: Player

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Top Charts").font(.system(size: 35, weight: .bold)).tracking(-1.4)

            if browse.chartsBusy {
                LoadingShelf()
            } else if let error = browse.chartsError {
                Notice(symbol: "network.slash", title: "Couldn't load Charts", detail: error)
                Button("Try again") { Task { await browse.loadCharts() } }
            } else if browse.chartsShelves.isEmpty {
                Notice(symbol: "chart.line.uptrend.xyaxis", title: "Charts unavailable", detail: "Check network connection or try again later.")
            } else {
                ForEach(Array(browse.chartsShelves.enumerated()), id: \.offset) { _, shelf in
                    shelfView(shelf)
                }
            }
        }
        .task {
            if browse.chartsShelves.isEmpty {
                await browse.loadCharts()
            }
        }
    }

    private func shelfView(_ shelf: Shelf) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(shelf.title).font(.title2.bold()).tracking(-0.5)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(shelf.entries) { entry in
                        switch entry {
                        case .collection(let item):
                            Button { browse.show(item, autoPlay: true, player: player) } label: {
                                CoverCard(title: item.title, subtitle: item.subtitle, url: item.artwork)
                            }.buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    browse.show(item, autoPlay: true, player: player)
                                } label: {
                                    Label("Play Album", systemImage: "play.fill")
                                }
                                Button {
                                    browse.show(item, autoPlay: false)
                                } label: {
                                    Label("View Tracks", systemImage: "music.note.list")
                                }
                            }
                        case .track(let track):
                            Button {
                                let tracks = shelf.entries.compactMap { if case .track(let row) = $0 { return row }; return nil }
                                player.play(tracks, at: tracks.firstIndex(where: { $0.id == track.id }) ?? 0)
                            } label: { CoverCard(title: track.title, subtitle: track.artist, url: track.artwork) }
                            .buttonStyle(.plain).contextMenu { SongMenu(track: track) }
                        }
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 2)
            }
        }
    }
}

// MARK: - Moods & Genres View

struct MoodsAndGenresView: View {
    @EnvironmentObject private var browse: BrowseModel
    @EnvironmentObject private var player: Player

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Moods & Genres").font(.system(size: 35, weight: .bold)).tracking(-1.4)

            if browse.moodsBusy {
                LoadingShelf()
            } else if let error = browse.moodsError {
                Notice(symbol: "network.slash", title: "Couldn't load Moods & Genres", detail: error)
                Button("Try again") { Task { await browse.loadMoods() } }
            } else if browse.moodsShelves.isEmpty {
                Notice(symbol: "music.quarternote.3", title: "Moods unavailable", detail: "Check network connection or try again later.")
            } else {
                ForEach(Array(browse.moodsShelves.enumerated()), id: \.offset) { _, shelf in
                    shelfView(shelf)
                }
            }
        }
        .task {
            if browse.moodsShelves.isEmpty {
                await browse.loadMoods()
            }
        }
    }

    private func shelfView(_ shelf: Shelf) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(shelf.title).font(.title2.bold()).tracking(-0.5)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(shelf.entries) { entry in
                        switch entry {
                        case .collection(let item):
                            Button { browse.show(item, autoPlay: true, player: player) } label: {
                                CoverCard(title: item.title, subtitle: item.subtitle, url: item.artwork)
                            }.buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    browse.show(item, autoPlay: true, player: player)
                                } label: {
                                    Label("Play Album", systemImage: "play.fill")
                                }
                                Button {
                                    browse.show(item, autoPlay: false)
                                } label: {
                                    Label("View Tracks", systemImage: "music.note.list")
                                }
                            }
                        case .track(let track):
                            Button {
                                let tracks = shelf.entries.compactMap { if case .track(let row) = $0 { return row }; return nil }
                                player.play(tracks, at: tracks.firstIndex(where: { $0.id == track.id }) ?? 0)
                            } label: { CoverCard(title: track.title, subtitle: track.artist, url: track.artwork) }
                            .buttonStyle(.plain).contextMenu { SongMenu(track: track) }
                        }
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 2)
            }
        }
    }
}

// MARK: - New Releases View

struct NewReleasesView: View {
    @EnvironmentObject private var browse: BrowseModel
    @EnvironmentObject private var player: Player

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("New Releases").font(.system(size: 35, weight: .bold)).tracking(-1.4)

            if browse.newReleasesBusy {
                LoadingShelf()
            } else if let error = browse.newReleasesError {
                Notice(symbol: "network.slash", title: "Couldn't load New Releases", detail: error)
                Button("Try again") { Task { await browse.loadNewReleases() } }
            } else if browse.newReleasesShelves.isEmpty {
                Notice(symbol: "sparkles", title: "New releases unavailable", detail: "Check network connection or try again later.")
            } else {
                ForEach(Array(browse.newReleasesShelves.enumerated()), id: \.offset) { _, shelf in
                    shelfView(shelf)
                }
            }
        }
        .task {
            if browse.newReleasesShelves.isEmpty {
                await browse.loadNewReleases()
            }
        }
    }

    private func shelfView(_ shelf: Shelf) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(shelf.title).font(.title2.bold()).tracking(-0.5)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(shelf.entries) { entry in
                        switch entry {
                        case .collection(let item):
                            Button { browse.show(item, autoPlay: true, player: player) } label: {
                                CoverCard(title: item.title, subtitle: item.subtitle, url: item.artwork)
                            }.buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    browse.show(item, autoPlay: true, player: player)
                                } label: {
                                    Label("Play Album", systemImage: "play.fill")
                                }
                                Button {
                                    browse.show(item, autoPlay: false)
                                } label: {
                                    Label("View Tracks", systemImage: "music.note.list")
                                }
                            }
                        case .track(let track):
                            Button {
                                let tracks = shelf.entries.compactMap { if case .track(let row) = $0 { return row }; return nil }
                                player.play(tracks, at: tracks.firstIndex(where: { $0.id == track.id }) ?? 0)
                            } label: { CoverCard(title: track.title, subtitle: track.artist, url: track.artwork) }
                            .buttonStyle(.plain).contextMenu { SongMenu(track: track) }
                        }
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 2)
            }
        }
    }
}

import AppKit
import Foundation
import IOKit.pwr_mgt
import SwiftUI

class AmbientWindowController: NSWindowController {
    static let shared = AmbientWindowController()
    private var assertionID: IOPMAssertionID = 0
    private var isRunning = false

    func toggle(player: Player, library: Library) {
        if isRunning {
            stopAmbientMode()
        } else {
            startAmbientMode(player: player, library: library)
        }
    }

    func startAmbientMode(player: Player, library: Library) {
        guard !isRunning else { return }
        isRunning = true

        let screen = NSScreen.main ?? NSScreen.screens.first!
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.collectionBehavior = [.fullScreenPrimary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .black

        let ambientView = AmbientPlayerView(onDismiss: { [weak self] in
            self?.stopAmbientMode()
        })
        .environmentObject(player)
        .environmentObject(library)

        window.contentView = NSHostingView(rootView: ambientView.ignoresSafeArea())

        // Prevent Display Sleep
        IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Echo Music Ambient Mode" as CFString,
            &assertionID
        )

        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    func stopAmbientMode() {
        guard isRunning else { return }
        isRunning = false

        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }

        window?.close()
        window = nil
    }
}

struct AmbientPlayerView: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var library: Library
    @ViewState private var showControls = false
    @ViewState private var hideTask: Task<Void, Never>?
    @ViewState private var lyrics: Lyrics?
    @ViewState private var lyricsTask: Task<Void, Never>?
    let onDismiss: () -> Void

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }

    var body: some View {
        ZStack {
            // Ambient Backdrop: Animated Blurred Artwork
            GeometryReader { geo in
                if let artwork = player.current?.artwork {
                    AsyncImage(url: artwork) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .blur(radius: 65)
                            .scaleEffect(1.2)
                            .opacity(0.45)
                    } placeholder: {
                        Color.black
                    }
                } else {
                    LinearGradient(
                        colors: [Color.black, Color.echoAccent.opacity(0.2), Color.black],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            }
            .ignoresSafeArea()

            Color.black.opacity(0.3).ignoresSafeArea()

            // Main Content Area
            HStack(spacing: 60) {
                // Left Column: Large Hero Artwork & Track Info
                VStack(alignment: .leading, spacing: 28) {
                    if let artwork = player.current?.artwork {
                        AsyncImage(url: artwork) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        } placeholder: {
                            Rectangle().fill(.quaternary)
                        }
                        .frame(maxWidth: 380, maxHeight: 380)
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                        .shadow(color: .black.opacity(0.6), radius: 35, x: 0, y: 15)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text(player.current?.title ?? "Nothing playing")
                            .font(.system(size: 40, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(2)

                        Text(player.current?.artist ?? "")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)

                        if let album = player.current?.album, !album.isEmpty {
                            Text(album)
                                .font(.system(size: 18))
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(1)
                        }
                    }

                    // Scrubber Bar
                    VStack(spacing: 8) {
                        Scrubber(head: player.head)
                        HStack {
                            Text(clockText(player.head.seconds))
                            Spacer()
                            Text(clockText(player.duration))
                        }
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                    }
                    .frame(maxWidth: 380)
                }
                .frame(maxWidth: 440)

                // Right Column: Synchronized Floating Lyrics
                VStack(alignment: .leading, spacing: 16) {
                    Text("LYRICS")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.4))
                        .tracking(1.5)

                    if let lyrics {
                        switch lyrics {
                        case .synced(let lines):
                            SyncedLyrics(lines: lines, head: player.head)
                        case .plain(let text):
                            ScrollView {
                                Text(text)
                                    .font(.title3)
                                    .foregroundStyle(.white.opacity(0.85))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        case .instrumental:
                            Text("Instrumental")
                                .font(.title3)
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Finding lyrics…")
                                .font(.title3)
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        .frame(maxHeight: .infinity, alignment: .center)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(60)

            // Floating Transport & Exit Controls Overlay (Fades out when inactive)
            VStack {
                HStack {
                    Spacer()
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                    .help("Exit Ambient Mode (Esc)")
                }
                .padding(30)

                Spacer()

                HStack(spacing: 36) {
                    Button {
                        player.previous()
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 28))
                    }
                    .buttonStyle(.plain)
                    .disabled(player.current == nil)

                    Button {
                        player.toggle()
                    } label: {
                        Image(systemName: player.wantsPlayback ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 54))
                    }
                    .buttonStyle(.plain)
                    .disabled(player.current == nil)

                    Button {
                        player.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 28))
                    }
                    .buttonStyle(.plain)
                    .disabled(!player.hasNext)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 40)
                .padding(.vertical, 16)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 40)
                .opacity(showControls ? 1 : 0.05)
                .animation(.easeInOut(duration: 0.3), value: showControls)
            }
        }
        .onContinuousHover { _ in
            revealControls()
        }
        .task(id: player.current?.id) {
            loadLyrics()
        }
        .background {
            Button("Exit") { onDismiss() }
                .keyboardShortcut(.escape, modifiers: [])
                .hidden()
        }
    }

    private func revealControls() {
        showControls = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            showControls = false
        }
    }

    private func loadLyrics() {
        lyricsTask?.cancel()
        guard let track = player.current else { lyrics = nil; return }
        lyricsTask = Task {
            do {
                let fetched = try await Lyrics.fetch(track)
                guard !Task.isCancelled else { return }
                self.lyrics = fetched
            } catch {
                guard !Task.isCancelled else { return }
                self.lyrics = nil
            }
        }
    }
}

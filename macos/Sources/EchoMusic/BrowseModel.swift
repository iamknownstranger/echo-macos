import SwiftUI

enum SectionID: Hashable {
    case discover, charts, moods, newReleases, history, search, liked, files, downloads, listenTogether, playlist(UUID), collection(MusicCollection), artist(Artist), album(Album)
}

@MainActor
final class BrowseModel: ObservableObject {
    @Published var section = SectionID.discover
    @Published var query = ""
    @Published var submitted = ""
    @Published var listenTogetherInviteCode: String?
    @Published private(set) var shelves: [Shelf] = []
    @Published private(set) var discovering = false
    @Published private(set) var discoveryError: String?
    @Published private(set) var chartsShelves: [Shelf] = []
    @Published private(set) var chartsBusy = false
    @Published private(set) var chartsError: String?
    @Published private(set) var moodsShelves: [Shelf] = []
    @Published private(set) var moodsBusy = false
    @Published private(set) var moodsError: String?
    @Published private(set) var newReleasesShelves: [Shelf] = []
    @Published private(set) var newReleasesBusy = false
    @Published private(set) var newReleasesError: String?
    @Published private(set) var searchPage = TrackPage(tracks: [])
    @Published private(set) var searchBusy = false
    @Published private(set) var searchError: String?
    @Published private(set) var collectionPage = TrackPage(tracks: [])
    @Published private(set) var collectionBusy = false
    @Published private(set) var collectionError: String?
    @Published private(set) var activeArtist: Artist?
    @Published private(set) var activeAlbum: Album?
    @Published private(set) var detailBusy = false
    @Published private(set) var detailError: String?
    private var searchTask: Task<Void, Never>?
    private var collectionTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var chartsTask: Task<Void, Never>?
    private var moodsTask: Task<Void, Never>?
    private var newReleasesTask: Task<Void, Never>?

    func discover() async {
        guard !discovering else { return }
        discovering = true
        discoveryError = nil
        defer { discovering = false }
        do { shelves = try await Catalog.shared.home() }
        catch { if !Task.isCancelled { discoveryError = error.localizedDescription } }
    }

    func loadCharts() async {
        guard !chartsBusy else { return }
        chartsBusy = true
        chartsError = nil
        defer { chartsBusy = false }
        do { chartsShelves = try await Catalog.shared.charts() }
        catch { if !Task.isCancelled { chartsError = error.localizedDescription } }
    }

    func loadMoods() async {
        guard !moodsBusy else { return }
        moodsBusy = true
        moodsError = nil
        defer { moodsBusy = false }
        do { moodsShelves = try await Catalog.shared.moodsAndGenres() }
        catch { if !Task.isCancelled { moodsError = error.localizedDescription } }
    }

    func loadNewReleases() async {
        guard !newReleasesBusy else { return }
        newReleasesBusy = true
        newReleasesError = nil
        defer { newReleasesBusy = false }
        do { newReleasesShelves = try await Catalog.shared.newReleases() }
        catch { if !Task.isCancelled { newReleasesError = error.localizedDescription } }
    }

    func search(more: Bool = false) {
        let text = more ? submitted : query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        section = .search
        searchTask?.cancel()
        let token = more ? searchPage.continuation : nil
        if !more { searchPage = TrackPage(tracks: []); submitted = text }
        searchBusy = true
        searchError = nil
        searchTask = Task {
            do {
                let page = try await Catalog.shared.search(text, continuation: token)
                try Task.checkCancellation()
                searchPage.tracks += page.tracks
                searchPage.continuation = page.continuation == token ? nil : page.continuation
            } catch { if !Task.isCancelled { searchError = error.localizedDescription } }
            if !Task.isCancelled { searchBusy = false }
        }
    }

    func show(_ collection: MusicCollection, more: Bool = false) {
        collectionTask?.cancel()
        section = .collection(collection)
        let token = more ? collectionPage.continuation : nil
        if !more { collectionPage = TrackPage(tracks: []) }
        collectionError = nil
        collectionBusy = true
        collectionTask = Task {
            do {
                let page = try await Catalog.shared.collection(collection.id, continuation: token)
                try Task.checkCancellation()
                collectionPage.tracks += page.tracks.map { track in
                    var track = track
                    if track.artwork == nil { track.artwork = collection.artwork }
                    return track
                }
                collectionPage.continuation = page.continuation == token ? nil : page.continuation
            } catch { if !Task.isCancelled { collectionError = error.localizedDescription } }
            if !Task.isCancelled { collectionBusy = false }
        }
    }

    func showArtist(id: String) {
        detailTask?.cancel()
        detailBusy = true
        detailError = nil
        detailTask = Task {
            do {
                let artist = try await Catalog.shared.artist(id: id)
                try Task.checkCancellation()
                self.activeArtist = artist
                self.section = .artist(artist)
            } catch {
                if !Task.isCancelled { self.detailError = error.localizedDescription }
            }
            if !Task.isCancelled { self.detailBusy = false }
        }
    }

    func showAlbum(id: String) {
        detailTask?.cancel()
        detailBusy = true
        detailError = nil
        detailTask = Task {
            do {
                let album = try await Catalog.shared.album(id: id)
                try Task.checkCancellation()
                self.activeAlbum = album
                self.section = .album(album)
            } catch {
                if !Task.isCancelled { self.detailError = error.localizedDescription }
            }
            if !Task.isCancelled { self.detailBusy = false }
        }
    }
}

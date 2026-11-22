// Apple TV mode: the TV plays Apple Music itself through MusicKit, and the
// lyrics for whatever it plays come from LRCLIB. Feeds the same LyricsStore
// that the Mac stream feeds, so the lyric stage does not care which it is.
//
// Two players are watched: the app's own player (what BlueLyrics starts) and
// the system player (what the Apple TV's Music app is playing). Whichever has
// a current song drives the lyric stage, the app's own player first.

import Foundation
import MusicKit
import SwiftUI
import Combine

@MainActor
final class MusicPlayerStore: ObservableObject {
  enum Auth { case unknown, authorized, denied, restricted }
  @Published var auth: Auth = .unknown
  @Published var subscribed: Bool? = nil        // nil until MusicKit answers
  @Published var playlists: [Playlist] = []
  @Published var recentAlbums: [Album] = []
  @Published var charts: [Song] = []            // Apple Music top songs; used when the library is thin
  @Published var results: [Song] = []           // catalog search results
  @Published var songs: [Song] = []             // tracks of the opened playlist / album
  @Published var openedTitle: String? = nil
  @Published var loading = false
  @Published var error: String? = nil
  @Published var status = "Starting"            // one line the pane shows at all times
  @Published var log: [String] = []             // diagnostics, newest last
  @Published var nowTitle = ""
  @Published var nowArtist = ""
  @Published var isPlaying = false
  @Published var artwork: UIImage? = nil
  @Published var usingSystemPlayer = false

  let player = ApplicationMusicPlayer.shared
  let system = SystemMusicPlayer.shared
  private let fetcher = LyricsFetcher()
  private var store: LyricsStore?
  private var cancellables: Set<AnyCancellable> = []
  private var ticker: Timer?
  private var currentPid = ""
  private var lastStatus = ""

  func attach(_ store: LyricsStore) {
    self.store = store
    cancellables.removeAll()
    for object in [player.state.objectWillChange, player.queue.objectWillChange,
                   system.state.objectWillChange, system.queue.objectWillChange] {
      object.sink { [weak self] _ in
        DispatchQueue.main.async { self?.playerChanged() }
      }.store(in: &cancellables)
    }
    ticker?.invalidate()
    ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.tick() }
    }
    note("Attached. tvOS \(UIDevice.current.systemVersion), auth \(MusicAuthorization.currentStatus)")
    playerChanged()
  }

  func detach() {
    ticker?.invalidate(); ticker = nil
    cancellables.removeAll()
    store = nil
  }

  func note(_ line: String) {
    let stamp = Self.clock.string(from: Date())
    log.append("\(stamp) \(line)")
    if log.count > 60 { log.removeFirst(log.count - 60) }
  }

  private static let clock: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
  }()

  // MARK: authorization and library

  func authorize() async {
    status = "Asking for Apple Music access"
    let status = await MusicAuthorization.request()
    note("Authorization: \(status)")
    switch status {
    case .authorized:
      auth = .authorized
      await checkSubscription()
      await loadLibrary()
    case .denied:
      auth = .denied
      self.status = "Apple Music access is off for BlueLyrics"
    case .restricted:
      auth = .restricted
      self.status = "Apple Music is restricted on this Apple TV"
    default:
      auth = .unknown
      self.status = "Apple Music access not decided"
    }
  }

  func checkSubscription() async {
    do {
      let sub = try await MusicSubscription.current
      subscribed = sub.canPlayCatalogContent
      note("Subscription: catalog \(sub.canPlayCatalogContent), cloud library \(sub.hasCloudLibraryEnabled)")
      if !sub.canPlayCatalogContent {
        status = "No Apple Music subscription on this Apple TV's account"
      }
    } catch {
      note("Subscription check failed: \(error)")
      status = "Could not read the Apple Music subscription"
    }
  }

  func loadLibrary() async {
    loading = true; error = nil
    status = "Loading your library"
    defer { loading = false }
    do {
      var request = MusicLibraryRequest<Playlist>()
      request.limit = 60
      let response = try await request.response()
      playlists = Array(response.items)
      note("Playlists: \(playlists.count)")
    } catch {
      self.error = "Playlists: \(error.localizedDescription)"
      note("Playlists failed: \(error)")
    }
    do {
      var request = MusicRecentlyPlayedContainerRequest()
      request.limit = 20
      let response = try await request.response()
      recentAlbums = response.items.compactMap { if case .album(let a) = $0 { return a } else { return nil } }
      note("Recently played albums: \(recentAlbums.count)")
    } catch {
      note("Recently played failed: \(error)")
    }
    if subscribed != false { await loadCharts() }
    status = summary
  }

  func loadCharts() async {
    do {
      var request = MusicCatalogChartsRequest(types: [Song.self])
      request.limit = 40
      let response = try await request.response()
      charts = Array(response.songCharts.first?.items ?? [])
      note("Top songs: \(charts.count)")
    } catch {
      note("Charts failed: \(error)")
    }
  }

  func search(_ term: String) async {
    let term = term.trimmingCharacters(in: .whitespaces)
    guard !term.isEmpty else { results = []; return }
    loading = true; defer { loading = false }
    do {
      var request = MusicCatalogSearchRequest(term: term, types: [Song.self])
      request.limit = 25
      let response = try await request.response()
      results = Array(response.songs)
      openedTitle = "Results for \(term)"
      songs = results
      note("Search '\(term)': \(results.count) songs")
    } catch {
      self.error = "Search: \(error.localizedDescription)"
      note("Search failed: \(error)")
    }
  }

  private var summary: String {
    var parts: [String] = []
    parts.append("\(playlists.count) playlists")
    if !recentAlbums.isEmpty { parts.append("\(recentAlbums.count) recent albums") }
    if !charts.isEmpty { parts.append("top \(charts.count) songs") }
    if subscribed == false { parts.append("no subscription") }
    return parts.joined(separator: " · ")
  }

  func open(_ playlist: Playlist) async {
    loading = true; defer { loading = false }
    do {
      let detailed = try await playlist.with([.tracks])
      songs = (detailed.tracks ?? []).compactMap { if case .song(let s) = $0 { return s } else { return nil } }
      openedTitle = playlist.name
      note("Opened playlist \(playlist.name): \(songs.count) songs")
    } catch { self.error = "Playlist: \(error.localizedDescription)"; note("Open playlist failed: \(error)") }
  }

  func open(_ album: Album) async {
    loading = true; defer { loading = false }
    do {
      let detailed = try await album.with([.tracks])
      songs = (detailed.tracks ?? []).compactMap { if case .song(let s) = $0 { return s } else { return nil } }
      openedTitle = album.title
      note("Opened album \(album.title): \(songs.count) songs")
    } catch { self.error = "Album: \(error.localizedDescription)"; note("Open album failed: \(error)") }
  }

  func openCharts() {
    songs = charts
    openedTitle = "Top songs"
  }

  func closeList() { songs = []; openedTitle = nil; results = [] }

  // MARK: transport

  func play(_ playlist: Playlist) async { await start("playlist \(playlist.name)") { self.player.queue = [playlist] } }
  func play(_ album: Album) async { await start("album \(album.title)") { self.player.queue = [album] } }
  func play(_ song: Song, in list: [Song]) async {
    await start("song \(song.title)") { self.player.queue = ApplicationMusicPlayer.Queue(for: list, startingAt: song) }
  }

  private func start(_ what: String, _ setQueue: () -> Void) async {
    setQueue()
    error = nil
    status = "Starting \(what)"
    note("Play \(what)")
    do {
      try await player.play()
      status = "Playing"
    } catch {
      self.error = "Play: \(error.localizedDescription)"
      status = "Could not play"
      note("Play failed: \(error)")
    }
  }

  /// The player whose song is on the lyric stage: the app's own when it has
  /// something, otherwise the Apple TV's Music app.
  private var active: MusicPlayer {
    if player.queue.currentEntry != nil { return player }
    if system.queue.currentEntry != nil { return system }
    return player
  }
  private var activeEntry: MusicPlayer.Queue.Entry? {
    player.queue.currentEntry ?? system.queue.currentEntry
  }

  func togglePlayPause() {
    let p = active
    if p.state.playbackStatus == .playing { p.pause() }
    else { Task { do { try await p.play() } catch { note("Resume failed: \(error)") } } }
  }
  func next() { let p = active; Task { try? await p.skipToNextEntry() } }
  func previous() { let p = active; Task { try? await p.skipToPreviousEntry() } }

  // MARK: feeding the lyric stage

  private var statusString: String {
    let p = active
    switch p.state.playbackStatus {
    case .playing: return "playing"
    case .paused, .interrupted, .seekingForward, .seekingBackward: return "paused"
    case .stopped: return activeEntry == nil ? "off" : "stopped"
    @unknown default: return "paused"
    }
  }

  private func playerChanged() {
    guard let store else { return }
    let p = active
    usingSystemPlayer = (p === system)
    isPlaying = p.state.playbackStatus == .playing
    let entry = activeEntry
    var song: Song? = nil
    if case .song(let s)? = entry?.item { song = s }
    let pid = song.map { "apple:\($0.id.rawValue)" } ?? (entry.map { "apple:\($0.id)" } ?? "")
    let status = statusString
    if pid != currentPid {
      currentPid = pid
      nowTitle = entry?.title ?? ""
      nowArtist = entry?.subtitle ?? ""
      var track = Track()
      track.status = status
      track.pid = pid
      track.title = entry?.title ?? ""
      track.artist = entry?.subtitle ?? ""
      track.album = song?.albumTitle ?? ""
      track.duration = song?.duration ?? 0
      track.position = p.playbackTime
      track.lyricsSource = pid.isEmpty ? "none" : "loading"
      track.hasArt = entry?.artwork != nil
      artwork = nil
      store.setLocal(track: track, art: nil)
      if let art = entry?.artwork { loadArt(art, for: pid) }
      if !pid.isEmpty {
        note("Now \(usingSystemPlayer ? "(Music app)" : "(BlueLyrics)"): \(track.title) — \(track.artist)")
        fetchLyrics(for: track)
      }
      lastStatus = status
    } else if status != lastStatus {
      lastStatus = status
      store.applyPosition(Position(status: status, position: p.playbackTime, polledAt: 0, serverNow: nil))
    }
  }

  private func tick() {
    guard let store, !currentPid.isEmpty else { return }
    let status = statusString
    lastStatus = status
    store.applyPosition(Position(status: status, position: active.playbackTime, polledAt: 0, serverNow: nil))
  }

  private func loadArt(_ art: Artwork, for pid: String) {
    guard let url = art.url(width: 800, height: 800) else { return }
    Task { [weak self] in
      guard let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data) else { return }
      await MainActor.run {
        guard let self, self.currentPid == pid else { return }
        self.artwork = image
        self.store?.art = image
      }
    }
  }

  private func fetchLyrics(for track: Track) {
    let pid = track.pid
    Task { [weak self] in
      guard let self else { return }
      let result = await self.fetcher.lyrics(pid: pid, title: track.title, artist: track.artist, album: track.album, duration: track.duration)
      await MainActor.run {
        self.note("Lyrics for \(track.title): \(result.source), \(result.lines.count) lines, synced \(result.synced)")
        self.store?.setLocalLines(result.lines, source: result.source, synced: result.synced, for: pid)
      }
    }
  }
}

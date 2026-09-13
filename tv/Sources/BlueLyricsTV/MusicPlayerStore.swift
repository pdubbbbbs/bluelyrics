// Apple TV mode: the TV plays Apple Music itself through MusicKit, and the
// lyrics for whatever it plays come from LRCLIB. Feeds the same LyricsStore
// that the Mac stream feeds, so the lyric stage does not care which it is.

import Foundation
import MusicKit
import SwiftUI
import Combine

@MainActor
final class MusicPlayerStore: ObservableObject {
  enum Auth { case unknown, authorized, denied, restricted }
  @Published var auth: Auth = .unknown
  @Published var playlists: [Playlist] = []
  @Published var recentAlbums: [Album] = []
  @Published var songs: [Song] = []          // tracks of the opened playlist / album
  @Published var openedTitle: String? = nil
  @Published var loading = false
  @Published var error: String? = nil
  @Published var nowTitle = ""
  @Published var nowArtist = ""
  @Published var isPlaying = false
  @Published var artwork: UIImage? = nil

  let player = ApplicationMusicPlayer.shared
  private let fetcher = LyricsFetcher()
  private var store: LyricsStore?
  private var cancellables: Set<AnyCancellable> = []
  private var ticker: Timer?
  private var currentPid = ""
  private var lastStatus = ""

  func attach(_ store: LyricsStore) {
    self.store = store
    player.state.objectWillChange.sink { [weak self] _ in
      DispatchQueue.main.async { self?.playerChanged() }
    }.store(in: &cancellables)
    player.queue.objectWillChange.sink { [weak self] _ in
      DispatchQueue.main.async { self?.playerChanged() }
    }.store(in: &cancellables)
    ticker?.invalidate()
    ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.tick() }
    }
    playerChanged()
  }

  func detach() {
    ticker?.invalidate(); ticker = nil
    cancellables.removeAll()
    store = nil
  }

  // MARK: authorization and library

  func authorize() async {
    let status = await MusicAuthorization.request()
    switch status {
    case .authorized: auth = .authorized; await loadLibrary()
    case .denied: auth = .denied
    case .restricted: auth = .restricted
    default: auth = .unknown
    }
  }

  func loadLibrary() async {
    loading = true; error = nil
    defer { loading = false }
    do {
      var request = MusicLibraryRequest<Playlist>()
      request.limit = 60
      let response = try await request.response()
      playlists = Array(response.items)
    } catch {
      self.error = "Playlists: \(error.localizedDescription)"
    }
    do {
      var request = MusicRecentlyPlayedContainerRequest()
      request.limit = 20
      let response = try await request.response()
      recentAlbums = response.items.compactMap { if case .album(let a) = $0 { return a } else { return nil } }
    } catch {
      // Recently played is optional; an error here is not worth surfacing.
    }
  }

  func open(_ playlist: Playlist) async {
    loading = true; defer { loading = false }
    do {
      let detailed = try await playlist.with([.tracks])
      songs = (detailed.tracks ?? []).compactMap { if case .song(let s) = $0 { return s } else { return nil } }
      openedTitle = playlist.name
    } catch { self.error = "Playlist: \(error.localizedDescription)" }
  }

  func open(_ album: Album) async {
    loading = true; defer { loading = false }
    do {
      let detailed = try await album.with([.tracks])
      songs = (detailed.tracks ?? []).compactMap { if case .song(let s) = $0 { return s } else { return nil } }
      openedTitle = album.title
    } catch { self.error = "Album: \(error.localizedDescription)" }
  }

  func closeList() { songs = []; openedTitle = nil }

  // MARK: transport

  func play(_ playlist: Playlist) async { await start { self.player.queue = [playlist] } }
  func play(_ album: Album) async { await start { self.player.queue = [album] } }
  func play(_ song: Song, in list: [Song]) async {
    await start { self.player.queue = ApplicationMusicPlayer.Queue(for: list, startingAt: song) }
  }

  private func start(_ setQueue: () -> Void) async {
    setQueue()
    do { try await player.play() } catch { self.error = "Play: \(error.localizedDescription)" }
  }

  func togglePlayPause() {
    if player.state.playbackStatus == .playing { player.pause() }
    else { Task { try? await player.play() } }
  }
  func next() { Task { try? await player.skipToNextEntry() } }
  func previous() { Task { try? await player.skipToPreviousEntry() } }

  // MARK: feeding the lyric stage

  private var statusString: String {
    switch player.state.playbackStatus {
    case .playing: return "playing"
    case .paused, .interrupted, .seekingForward, .seekingBackward: return "paused"
    case .stopped: return player.queue.currentEntry == nil ? "off" : "stopped"
    @unknown default: return "paused"
    }
  }

  private func playerChanged() {
    guard let store else { return }
    isPlaying = player.state.playbackStatus == .playing
    let entry = player.queue.currentEntry
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
      track.position = player.playbackTime
      track.lyricsSource = pid.isEmpty ? "none" : "loading"
      track.hasArt = entry?.artwork != nil
      artwork = nil
      store.setLocal(track: track, art: nil)
      if let art = entry?.artwork { loadArt(art, for: pid) }
      if !pid.isEmpty { fetchLyrics(for: track) }
      lastStatus = status
    } else if status != lastStatus {
      lastStatus = status
      store.applyPosition(Position(status: status, position: player.playbackTime, polledAt: 0, serverNow: nil))
    }
  }

  private func tick() {
    guard let store, !currentPid.isEmpty else { return }
    let status = statusString
    lastStatus = status
    store.applyPosition(Position(status: status, position: player.playbackTime, polledAt: 0, serverNow: nil))
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
        self.store?.setLocalLines(result.lines, source: result.source, synced: result.synced, for: pid)
      }
    }
  }
}

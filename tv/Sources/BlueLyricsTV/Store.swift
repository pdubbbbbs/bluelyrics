// Connection to one BlueLyrics server plus everything the screen needs:
// the current track, an interpolated play position, theme and font.

import Foundation
import SwiftUI
import Network

@MainActor
final class LyricsStore: ObservableObject {
  @Published var track = Track()
  @Published var connected = false
  @Published var theme = Theme.named("blueguard")
  @Published var art: UIImage? = nil
  @Published var host: String = ""

  let fonts = FontLoader()

  private var base = 0.0            // position anchor (seconds into the track)
  private var baseAt = Date()       // when the anchor was taken
  private var playing = false
  private var sse: SSEClient?
  private var baseURL: URL?
  private var artVersion = -1

  static let hostKey = "bluelyrics.host"

  func connect(to host: String) {
    disconnect()
    self.host = host
    UserDefaults.standard.set(host, forKey: Self.hostKey)
    guard let base = URL(string: "http://\(host)/") else { return }
    baseURL = base
    sse = SSEClient(url: base.appendingPathComponent("events"),
                    onState: { [weak self] up in self?.connected = up },
                    handler: { [weak self] event, json in self?.handle(event, json) })
    sse?.start()
  }

  func disconnect() {
    sse?.stop(); sse = nil
    connected = false
    track = Track()
    art = nil
    artVersion = -1
  }

  /// Apple TV mode: the track comes from the TV's own player, not from a Mac.
  func setLocal(track: Track, art: UIImage?) {
    if sse != nil { sse?.stop(); sse = nil }
    connected = true
    self.track = track
    self.art = art
    applyPosition(Position(status: track.status, position: track.position, polledAt: 0, serverNow: nil))
  }

  func setLocalLines(_ lines: [LyricLine], source: String, synced: Bool, for pid: String) {
    guard track.pid == pid else { return }
    track.lines = lines
    track.lyricsSource = source
    track.synced = synced
  }

  private func handle(_ event: String, _ json: [String: Any]) {
    switch event {
    case "track":
      let t = Track.from(json)
      track = t
      applyPosition(Position(status: t.status, position: t.position, polledAt: t.polledAt, serverNow: nil))
      if t.hasArt {
        if t.artVersion != artVersion { artVersion = t.artVersion; fetchArt(version: t.artVersion) }
      } else { art = nil; artVersion = -1 }
    case "pos":
      applyPosition(Position.from(json))
    case "prefs":
      let prefs = json["prefs"] as? [String: Any] ?? [:]
      theme = Theme.named(prefs["theme"] as? String)
      if let baseURL { fonts.load(prefs: prefs, fonts: json["fonts"] as? [String: Any] ?? [:], base: baseURL) }
    default:
      break
    }
  }

  func applyPosition(_ p: Position) {
    playing = p.status == "playing"
    track.status = p.status
    // add the time the server spent between reading Music and sending this
    var lag = 0.0
    if let now = p.serverNow, p.polledAt > 0 { lag = max(0, min(1, now - p.polledAt)) }
    base = p.position + (playing ? lag : 0)
    baseAt = Date()
  }

  /// Where the song is right now, interpolated between server updates.
  func position(at date: Date = Date()) -> Double {
    base + (playing ? date.timeIntervalSince(baseAt) : 0)
  }

  var isPlaying: Bool { playing }

  func lineIndex(at pos: Double) -> Int {
    let lines = track.lines
    guard !lines.isEmpty else { return -1 }
    if track.synced {
      var idx = -1
      for (i, line) in lines.enumerated() {
        if let t = line.t, t <= pos { idx = i } else if line.t != nil { break }
      }
      return idx
    }
    guard track.duration > 0 else { return 0 }
    return min(lines.count - 1, Int(floor(pos / track.duration * Double(lines.count))))
  }

  private func fetchArt(version: Int) {
    guard let baseURL else { return }
    var comps = URLComponents(url: baseURL.appendingPathComponent("art"), resolvingAgainstBaseURL: false)
    comps?.queryItems = [URLQueryItem(name: "v", value: String(version))]
    guard let url = comps?.url else { return }
    Task { [weak self] in
      guard let (data, response) = try? await URLSession.shared.data(from: url),
            (response as? HTTPURLResponse)?.statusCode == 200, let image = UIImage(data: data) else { return }
      await MainActor.run { self?.art = image }
    }
  }
}

/// Finds BlueLyrics servers on the network. The macOS app advertises
/// _bluelyrics._tcp once it carries the matching change; before that the
/// address is typed in by hand.
@MainActor
final class Discovery: ObservableObject {
  struct Found: Identifiable, Equatable {
    let id: String
    let name: String
    let host: String
  }
  @Published var found: [Found] = []
  private var browser: NWBrowser?
  private var resolving: [String: NWConnection] = [:]

  func start() {
    stop()
    let params = NWParameters.tcp
    params.includePeerToPeer = false
    let browser = NWBrowser(for: .bonjour(type: "_bluelyrics._tcp", domain: nil), using: params)
    browser.browseResultsChangedHandler = { [weak self] results, _ in
      Task { @MainActor in self?.resolve(results) }
    }
    browser.start(queue: .main)
    self.browser = browser
  }

  func stop() { browser?.cancel(); browser = nil; resolving.values.forEach { $0.cancel() }; resolving = [:] }

  private func resolve(_ results: Set<NWBrowser.Result>) {
    let names = Set(results.compactMap { r -> String? in
      if case .service(let name, _, _, _) = r.endpoint { return name }
      return nil
    })
    found.removeAll { !names.contains($0.name) }
    for result in results {
      guard case .service(let name, _, _, _) = result.endpoint, resolving[name] == nil, !found.contains(where: { $0.name == name }) else { continue }
      let connection = NWConnection(to: result.endpoint, using: .tcp)
      resolving[name] = connection
      connection.stateUpdateHandler = { [weak self] state in
        guard case .ready = state, let path = connection.currentPath, let remote = path.remoteEndpoint else {
          if case .failed = state { Task { @MainActor in self?.resolving[name] = nil }; connection.cancel() }
          return
        }
        if case .hostPort(let host, let port) = remote {
          var text = "\(host)"
          if let cut = text.firstIndex(of: "%") { text = String(text[..<cut]) }   // drop the interface suffix
          if text.contains(":") { text = "[\(text)]" }
          let hostPort = "\(text):\(port.rawValue)"
          Task { @MainActor in
            self?.found.append(Found(id: name, name: name, host: hostPort))
            self?.resolving[name] = nil
          }
        }
        connection.cancel()
      }
      connection.start(queue: .main)
    }
  }
}

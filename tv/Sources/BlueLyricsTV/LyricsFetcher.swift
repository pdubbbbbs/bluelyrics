// Lyrics for a song the Apple TV is playing itself, from LRCLIB, with the
// same lookup order and LRC parsing as the Mac app.

import Foundation

struct FetchedLyrics { var source: String; var synced: Bool; var lines: [LyricLine] }

actor LyricsFetcher {
  private var cache: [String: FetchedLyrics] = [:]
  private static let lrcTime = try! NSRegularExpression(pattern: "\\[(\\d+):(\\d+(?:\\.\\d+)?)\\]")
  private static let titleNoise = try! NSRegularExpression(
    pattern: "\\s*[\\(\\[][^\\)\\]]*(feat\\.|ft\\.|featuring|remaster|remix|version|edit|mix|live|mono|stereo|deluxe|bonus)[^\\)\\]]*[\\)\\]]",
    options: .caseInsensitive)

  func lyrics(pid: String, title: String, artist: String, album: String, duration: Double) async -> FetchedLyrics {
    if let hit = cache[pid] { return hit }
    let result = await fetchLRCLIB(title: title, artist: artist, album: album, duration: duration)
    if !result.lines.isEmpty { cache[pid] = result }
    return result
  }

  private func get(_ url: URL) async -> Any? {
    var request = URLRequest(url: url, timeoutInterval: 10)
    request.setValue("BlueLyrics-tvOS/1.0 (github.com/pdubbbbbs/bluelyrics)", forHTTPHeaderField: "User-Agent")
    guard let (data, response) = try? await URLSession.shared.data(for: request),
          (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
    return try? JSONSerialization.jsonObject(with: data)
  }

  private func fetchLRCLIB(title: String, artist: String, album: String, duration: Double) async -> FetchedLyrics {
    let base = "https://lrclib.net/api"
    var titles = [title]; let cleaned = Self.cleanTitle(title)
    if cleaned != title { titles.append(cleaned) }
    func q(_ items: [String: String]) -> String {
      items.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }.joined(separator: "&")
    }
    var hits: [[String: Any]] = []
    for t in titles {
      if let url = URL(string: "\(base)/get?" + q(["artist_name": artist, "track_name": t, "album_name": album, "duration": String(Int(duration.rounded()))])),
         let hit = await get(url) as? [String: Any] { hits.append(hit); break }
    }
    if hits.isEmpty {
      for t in titles {
        if let url = URL(string: "\(base)/search?" + q(["track_name": t, "artist_name": artist])),
           let found = await get(url) as? [[String: Any]], !found.isEmpty { hits = found; break }
      }
    }
    if hits.isEmpty, let url = URL(string: "\(base)/search?" + q(["q": "\(artist) \(cleaned)"])),
       let found = await get(url) as? [[String: Any]] { hits = found }
    let usable = hits.filter { h in
      Self.artistMatches(h["artistName"] as? String ?? "", artist) &&
      ((h["syncedLyrics"] as? String)?.isEmpty == false || (h["plainLyrics"] as? String)?.isEmpty == false)
    }
    let ranked = usable.sorted { a, b in
      func rank(_ h: [String: Any]) -> (Int, Int, Double) {
        let gap = duration > 0 ? abs(((h["duration"] as? NSNumber)?.doubleValue ?? 0) - duration) : 0
        return ((h["syncedLyrics"] as? String)?.isEmpty == false ? 0 : 1, gap <= 6 ? 0 : 1, gap)
      }
      return rank(a) < rank(b)
    }
    guard let best = ranked.first else { return FetchedLyrics(source: "none", synced: false, lines: []) }
    if let synced = best["syncedLyrics"] as? String, !synced.isEmpty {
      return FetchedLyrics(source: "lrclib", synced: true, lines: Self.parseLRC(synced))
    }
    return FetchedLyrics(source: "lrclib", synced: false, lines: Self.parsePlain(best["plainLyrics"] as? String ?? ""))
  }

  static func parseLRC(_ text: String) -> [LyricLine] {
    var lines: [LyricLine] = []
    for raw in text.components(separatedBy: .newlines) {
      let ns = raw as NSString
      let matches = lrcTime.matches(in: raw, range: NSRange(location: 0, length: ns.length))
      guard !matches.isEmpty else { continue }
      let body = lrcTime.stringByReplacingMatches(in: raw, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        .trimmingCharacters(in: .whitespaces)
      for m in matches {
        let minutes = Double(ns.substring(with: m.range(at: 1))) ?? 0
        let seconds = Double(ns.substring(with: m.range(at: 2))) ?? 0
        lines.append(LyricLine(t: minutes * 60 + seconds, end: nil, text: body, words: nil))
      }
    }
    return lines.sorted { ($0.t ?? 0) < ($1.t ?? 0) }
  }

  static func parsePlain(_ text: String) -> [LyricLine] {
    var lines: [LyricLine] = []; var blank = false
    for raw in text.components(separatedBy: .newlines) {
      let body = raw.trimmingCharacters(in: .whitespaces)
      if body.isEmpty { blank = true; continue }
      if blank, !lines.isEmpty { lines.append(LyricLine(t: nil, end: nil, text: "", words: nil)) }
      blank = false
      lines.append(LyricLine(t: nil, end: nil, text: body, words: nil))
    }
    return lines
  }

  static func cleanTitle(_ title: String) -> String {
    let cleaned = titleNoise.stringByReplacingMatches(in: title, range: NSRange(title.startIndex..., in: title), withTemplate: "")
      .replacingOccurrences(of: "\\s+-\\s+(feat\\.|ft\\.).*$", with: "", options: [.regularExpression, .caseInsensitive])
      .trimmingCharacters(in: .whitespaces)
    return cleaned.isEmpty ? title : cleaned
  }

  static func artistMatches(_ candidate: String, _ wanted: String) -> Bool {
    let norm: (String) -> String = { $0.lowercased().replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression) }
    let a = norm(candidate), b = norm(wanted)
    if b.isEmpty { return true }
    if a.isEmpty { return false }
    return a.contains(b) || b.contains(a)
  }
}

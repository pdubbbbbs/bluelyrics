// Lyrics lookup: timed lyrics embedded in the track, then community sources
// (LRCLIB, NetEase) when the user allows them. Results are cached per track.

import Foundation

struct LyricsResult { var source: String; var synced: Bool; var lines: [LyricLine] }

final class LyricsResolver {
  private static let lrcTime = try! NSRegularExpression(pattern: "\\[(\\d+):(\\d+(?:\\.\\d+)?)\\]")
  private static let titleNoise = try! NSRegularExpression(
    pattern: "\\s*[\\(\\[][^\\)\\]]*(feat\\.|ft\\.|featuring|remaster|remix|version|edit|mix|live|mono|stereo|deluxe|bonus)[^\\)\\]]*[\\)\\]]",
    options: .caseInsensitive)
  private static let webNoise = try! NSRegularExpression(
    pattern: "\\s*[\\(\\[][^\\)\\]]*(official|video|audio|lyrics?|lyric video|visuali[sz]er|hd|hq|4k|mv|m/v|explicit|clean|live|remaster|prod\\.?)[^\\)\\]]*[\\)\\]]",
    options: .caseInsensitive)

  func resolve(pid: String, title: String, artist: String, album: String, duration: Double, embedded: String) -> LyricsResult {
    let cacheFile = Paths.cache.appendingPathComponent(pid.replacingOccurrences(of: "[^A-Za-z0-9]", with: "_", options: .regularExpression) + ".json")
    if let data = try? Data(contentsOf: cacheFile), let cached = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let lines = cached["lines"] as? [[String: Any]], (cached["community"] as? Bool) == Prefs.communityLyrics {
      return LyricsResult(source: cached["source"] as? String ?? "none", synced: cached["synced"] as? Bool ?? false,
                          lines: lines.map { Self.line(from: $0) })
    }
    var result = LyricsResult(source: "none", synced: false, lines: [])
    if !embedded.isEmpty, Self.lrcTime.firstMatch(in: embedded, range: NSRange(embedded.startIndex..., in: embedded)) != nil {
      result = LyricsResult(source: "music", synced: true, lines: Self.parseLRC(embedded))
    }
    if !result.synced, Prefs.communityLyrics {
      let lrclib = fetchLRCLIB(title: title, artist: artist, album: album, duration: duration)
      if lrclib.synced { result = lrclib }
      else {
        let netease = fetchNetEase(title: title, artist: artist, duration: duration)
        result = netease.synced ? netease : (lrclib.lines.isEmpty ? result : lrclib)
      }
    }
    if result.lines.isEmpty, !embedded.isEmpty { result = LyricsResult(source: "music", synced: false, lines: Self.parsePlain(embedded)) }
    if !result.lines.isEmpty {
      let payload: [String: Any] = ["source": result.source, "synced": result.synced, "community": Prefs.communityLyrics,
                                    "lines": result.lines.map { $0.json }]
      if let data = try? JSONSerialization.data(withJSONObject: payload) { try? data.write(to: cacheFile) }
    }
    return result
  }

  // MARK: parsing

  static func line(from d: [String: Any]) -> LyricLine {
    LyricLine(t: (d["t"] as? NSNumber)?.doubleValue, end: (d["end"] as? NSNumber)?.doubleValue,
              text: d["text"] as? String ?? "", words: nil)
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

  static func cleanWebMetadata(title: String, artist: String) -> (String, String) {
    var t = webNoise.stringByReplacingMatches(in: title, range: NSRange(title.startIndex..., in: title), withTemplate: "")
    t = t.replacingOccurrences(of: "\\s*\\|.*$", with: "", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: " -–|"))
    var a = artist.replacingOccurrences(of: "\\s*-\\s*Topic$", with: "", options: [.regularExpression, .caseInsensitive])
    a = a.replacingOccurrences(of: "VEVO$", with: "", options: [.regularExpression, .caseInsensitive]).trimmingCharacters(in: .whitespaces)
    if let range = t.range(of: " - ") {
      let left = String(t[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
      let right = String(t[range.upperBound...]).trimmingCharacters(in: .whitespaces)
      if !left.isEmpty, !right.isEmpty, a.isEmpty || left.lowercased().contains(a.lowercased()) || !t.lowercased().contains(a.lowercased()) {
        a = left; t = right
      }
    }
    return (t.trimmingCharacters(in: .whitespaces), a)
  }

  static func artistMatches(_ candidate: String, _ wanted: String) -> Bool {
    let norm: (String) -> String = { $0.lowercased().replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression) }
    let a = norm(candidate), b = norm(wanted)
    if b.isEmpty { return true }
    if a.isEmpty { return false }
    return a.contains(b) || b.contains(a)
  }

  // MARK: community sources

  private func get(_ url: URL, headers: [String: String] = [:]) -> Any? {
    var request = URLRequest(url: url, timeoutInterval: 10)
    request.setValue("BlueLyrics/0.3 (github.com/pdubbbbbs/bluelyrics)", forHTTPHeaderField: "User-Agent")
    headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
    let semaphore = DispatchSemaphore(value: 0)
    var result: Any?
    URLSession.shared.dataTask(with: request) { data, response, _ in
      if let data, (response as? HTTPURLResponse)?.statusCode == 200 { result = try? JSONSerialization.jsonObject(with: data) }
      semaphore.signal()
    }.resume()
    _ = semaphore.wait(timeout: .now() + 12)
    return result
  }

  private func fetchLRCLIB(title: String, artist: String, album: String, duration: Double) -> LyricsResult {
    let base = "https://lrclib.net/api"
    var titles = [title]; let cleaned = Self.cleanTitle(title)
    if cleaned != title { titles.append(cleaned) }
    var hits: [[String: Any]] = []
    func q(_ items: [String: String]) -> String {
      items.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }.joined(separator: "&")
    }
    for t in titles {
      if let url = URL(string: "\(base)/get?" + q(["artist_name": artist, "track_name": t, "album_name": album, "duration": String(Int(duration.rounded()))])),
         let hit = get(url) as? [String: Any] { hits.append(hit); break }
    }
    if hits.isEmpty {
      for t in titles {
        if let url = URL(string: "\(base)/search?" + q(["track_name": t, "artist_name": artist])),
           let found = get(url) as? [[String: Any]], !found.isEmpty { hits = found; break }
      }
    }
    if hits.isEmpty, let url = URL(string: "\(base)/search?" + q(["q": "\(artist) \(cleaned)"])),
       let found = get(url) as? [[String: Any]] { hits = found }
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
    guard let best = ranked.first else { return LyricsResult(source: "none", synced: false, lines: []) }
    if let synced = best["syncedLyrics"] as? String, !synced.isEmpty {
      return LyricsResult(source: "lrclib", synced: true, lines: Self.parseLRC(synced))
    }
    return LyricsResult(source: "lrclib", synced: false, lines: Self.parsePlain(best["plainLyrics"] as? String ?? ""))
  }

  private func fetchNetEase(title: String, artist: String, duration: Double) -> LyricsResult {
    let headers = ["User-Agent": "Mozilla/5.0", "Referer": "https://music.163.com"]
    let term = "\(artist) \(Self.cleanTitle(title))".addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    guard let url = URL(string: "https://music.163.com/api/search/get?s=\(term)&type=1&limit=8"),
          let json = get(url, headers: headers) as? [String: Any],
          let songs = (json["result"] as? [String: Any])?["songs"] as? [[String: Any]] else {
      return LyricsResult(source: "none", synced: false, lines: [])
    }
    var best: [LyricLine] = []
    for song in songs {
      let names = (song["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
      guard names.contains(where: { Self.artistMatches($0, artist) }) else { continue }
      let songDuration = ((song["duration"] as? NSNumber)?.doubleValue ?? 0) / 1000
      if duration > 0, abs(songDuration - duration) > 8 { continue }
      guard let id = song["id"], let lurl = URL(string: "https://music.163.com/api/song/lyric?id=\(id)&lv=1&kv=1&tv=-1"),
            let l = get(lurl, headers: headers) as? [String: Any],
            let lrc = (l["lrc"] as? [String: Any])?["lyric"] as? String else { continue }
      let lines = Self.parseLRC(lrc).filter { !$0.text.isEmpty && $0.text.range(of: "^(作词|作曲|编曲|制作人|lyrics? by|composed by)", options: [.regularExpression, .caseInsensitive]) == nil }
      if lines.count >= 8, lines.count > best.count { best = lines }
    }
    return best.isEmpty ? LyricsResult(source: "none", synced: false, lines: []) : LyricsResult(source: "netease", synced: true, lines: best)
  }
}

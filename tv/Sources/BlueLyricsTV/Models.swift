// What the Mac's BlueLyrics server sends: the current track, its lyric lines,
// and position updates. Mirrors TrackState.json in the macOS app.

import Foundation

struct LyricWord: Equatable {
  var t: Double
  var end: Double
  var text: String
}

struct LyricLine: Equatable {
  var t: Double?
  var end: Double?
  var text: String
  var words: [LyricWord]?
}

struct Track: Equatable {
  var status = "off"          // off | stopped | paused | playing
  var pid = ""
  var title = ""
  var artist = ""
  var album = ""
  var duration = 0.0
  var position = 0.0
  var lyricsSource = "none"
  var synced = false
  var lines: [LyricLine] = []
  var hasArt = false
  var artVersion = 0
  var polledAt = 0.0

  static func from(_ json: [String: Any]) -> Track {
    var t = Track()
    t.status = json["status"] as? String ?? "off"
    t.pid = json["pid"] as? String ?? ""
    t.title = json["title"] as? String ?? ""
    t.artist = json["artist"] as? String ?? ""
    t.album = json["album"] as? String ?? ""
    t.duration = (json["duration"] as? NSNumber)?.doubleValue ?? 0
    t.position = (json["position"] as? NSNumber)?.doubleValue ?? 0
    t.lyricsSource = json["lyrics_source"] as? String ?? "none"
    t.synced = json["synced"] as? Bool ?? false
    t.hasArt = json["has_art"] as? Bool ?? false
    t.artVersion = (json["art_version"] as? NSNumber)?.intValue ?? 0
    t.polledAt = (json["polled_at"] as? NSNumber)?.doubleValue ?? 0
    t.lines = (json["lines"] as? [[String: Any]] ?? []).map { line in
      var l = LyricLine(text: line["text"] as? String ?? "")
      l.t = (line["t"] as? NSNumber)?.doubleValue
      l.end = (line["end"] as? NSNumber)?.doubleValue
      if let words = line["words"] as? [[String: Any]] {
        l.words = words.compactMap { w in
          guard let t = (w["t"] as? NSNumber)?.doubleValue else { return nil }
          return LyricWord(t: t, end: (w["end"] as? NSNumber)?.doubleValue ?? t + 0.3, text: w["text"] as? String ?? "")
        }
      }
      return l
    }
    return t
  }

  var statusTag: String {
    switch status {
    case "off": return "music off"
    case "stopped": return "idle"
    default:
      if lyricsSource == "loading" { return "finding lyrics" }
      if lyricsSource == "none" { return "no lyrics" }
      if lyricsSource == "apple-words" { return "synced · word timing" }
      return synced ? "synced" : "no timing · estimated"
    }
  }
}

struct Position {
  var status: String
  var position: Double
  var polledAt: Double
  var serverNow: Double?

  static func from(_ json: [String: Any]) -> Position {
    Position(status: json["status"] as? String ?? "off",
             position: (json["position"] as? NSNumber)?.doubleValue ?? 0,
             polledAt: (json["polled_at"] as? NSNumber)?.doubleValue ?? 0,
             serverNow: (json["server_now"] as? NSNumber)?.doubleValue)
  }
}

/// A word on screen with the time window in which it is sung.
struct TimedWord: Identifiable {
  let id: Int
  let text: String
  let start: Double
  let end: Double
}

enum WordTiming {
  /// Same estimate the web page uses: LRCLIB gives line times only, so a line's
  /// span is shared out by syllable count, with a pause after punctuation.
  static func syllables(_ word: String) -> Int {
    let w = word.lowercased().filter { $0.isLetter || $0 == "'" }
    guard !w.isEmpty else { return 1 }
    var trimmed = w
    if trimmed.hasSuffix("e") { trimmed.removeLast() }
    var groups = 0
    var inVowel = false
    for ch in trimmed {
      let vowel = "aeiouy".contains(ch)
      if vowel && !inVowel { groups += 1 }
      inVowel = vowel
    }
    return max(1, groups)
  }

  static func estimate(text: String, start: Double, end: Double) -> [TimedWord] {
    guard end > start else { return [] }
    let tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard !tokens.isEmpty else { return [] }
    let weights: [Double] = tokens.map { tok in
      let punct = tok.last.map { ",.;:!?…".contains($0) } ?? false
      return Double(syllables(tok)) + (punct ? 0.6 : 0) + 0.15   // 0.15 stands in for the space slot
    }
    let total = weights.reduce(0, +)
    let usable = (end - start) * 0.92
    var cursor = start
    var out: [TimedWord] = []
    for (i, tok) in tokens.enumerated() {
      let slot = usable * weights[i] / total
      out.append(TimedWord(id: i, text: tok, start: cursor, end: cursor + slot))
      cursor += slot
    }
    return out
  }

  static func timed(_ words: [LyricWord]) -> [TimedWord] {
    words.enumerated().map { i, w in
      TimedWord(id: i, text: w.text, start: w.t, end: max(w.end, w.t + 0.12))
    }
  }

  /// Word windows for the current line, whichever timing the server gave.
  static func words(for lines: [LyricLine], at index: Int, duration: Double) -> [TimedWord] {
    guard index >= 0, index < lines.count else { return [] }
    let line = lines[index]
    if let words = line.words, !words.isEmpty { return timed(words) }
    guard let start = line.t, !line.text.isEmpty else { return [] }
    let next = lines[(index + 1)...].first { !$0.text.isEmpty }?.t
    var end = min(line.end ?? .infinity, next ?? start + 6, start + 12)
    if duration > 0 { end = min(end, duration) }
    return estimate(text: line.text, start: start, end: end)
  }
}

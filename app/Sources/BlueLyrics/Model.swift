// Shared state for what is playing and which lyrics go with it.

import Foundation

struct LyricLine {
  var t: Double?          // seconds; nil for untimed lines
  var end: Double?
  var text: String
  var words: [LyricWord]?
  var json: [String: Any] {
    var d: [String: Any] = ["t": t as Any, "text": text]
    if let end { d["end"] = end }
    if let words { d["words"] = words.map { ["t": $0.t, "end": $0.end, "text": $0.text] } }
    return d
  }
}

struct LyricWord { var t: Double; var end: Double; var text: String }

struct TrackState {
  var status = "off"          // off | stopped | paused | playing
  var source = "music"        // music | youtube | youtube-music | captions
  var pid = ""
  var title = ""
  var artist = ""
  var album = ""
  var duration = 0.0
  var position = 0.0
  var lyricsSource = "none"   // none | loading | music | lrclib | netease
  var synced = false
  var lines: [LyricLine] = []
  var hasArt = false
  var artVersion = 0
  var polledAt = Date().timeIntervalSince1970

  var json: [String: Any] {
    ["status": status, "source": source, "pid": pid, "title": title, "artist": artist, "album": album,
     "duration": duration, "position": position, "lyrics_source": lyricsSource, "synced": synced,
     "lines": lines.map { $0.json }, "has_art": hasArt, "art_version": artVersion, "polled_at": polledAt]
  }
}

/// A now-playing reading from one source, before it is folded into TrackState.
struct Reading {
  var source: String
  var status: String
  var pid = ""
  var title = ""
  var artist = ""
  var album = ""
  var duration = 0.0
  var position = 0.0
  var art = ""            // https URL for web sources
  var nativeLines: [String]? = nil   // lyrics the service itself displayed
  var timedLines: [LyricLine]? = nil // captions/lyrics with timing from the service
}

enum Paths {
  static let support: URL = {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("BlueLyrics", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
  }()
  static let cache: URL = {
    let url = support.appendingPathComponent("cache", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }()
  static let art = cache.appendingPathComponent("current-art.bin")
  static let prefs = support.appendingPathComponent("prefs.json")
  static let log = support.appendingPathComponent("bluelyrics.log")
}

enum Log {
  private static let queue = DispatchQueue(label: "bluelyrics.log")
  private static let formatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f }()
  static func info(_ message: String) {
    queue.async {
      let line = "\(formatter.string(from: Date())) \(message)\n"
      if let handle = try? FileHandle(forWritingTo: Paths.log) {
        handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
      } else {
        try? line.write(to: Paths.log, atomically: true, encoding: .utf8)
      }
      NSLog("%@", message)
    }
  }
}

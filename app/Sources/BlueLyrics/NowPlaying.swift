// Watches Music.app through Apple Events, accepts reports from the browser
// extension, picks whichever source started playing most recently, and
// resolves lyrics and artwork for the current track.

import Foundation

final class NowPlaying {
  private(set) var state = TrackState()
  private let lock = NSLock()
  private var listeners: [(TrackState, Bool) -> Void] = []   // (state, trackChanged)
  private var external: Reading?
  private var externalAt = 0.0
  private var externalPlayingSince = 0.0
  private var musicPlayingSince = 0.0
  private var musicLastStatus = ""
  private var musicLastPID = ""
  private var failures = 0
  private var timer: DispatchSourceTimer?
  private let queue = DispatchQueue(label: "bluelyrics.nowplaying")
  private let lyrics = LyricsResolver()

  func onChange(_ listener: @escaping (TrackState, Bool) -> Void) {
    lock.lock(); listeners.append(listener); lock.unlock()
  }

  func snapshot() -> TrackState { lock.lock(); defer { lock.unlock() }; return state }

  func start() {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: 0.3)
    timer.setEventHandler { [weak self] in self?.poll() }
    timer.resume()
    self.timer = timer
  }

  // MARK: sources

  /// Browser extension report (YouTube / YouTube Music).
  func report(_ payload: [String: Any]) {
    let status = (payload["status"] as? String) == "playing" ? "playing" : "paused"
    let source = payload["source"] as? String ?? "youtube"
    var reading = Reading(
      source: source, status: status,
      pid: "\(source):\(payload["id"] as? String ?? "")",
      title: (payload["title"] as? String ?? "").trimmingCharacters(in: .whitespaces),
      artist: (payload["artist"] as? String ?? "").trimmingCharacters(in: .whitespaces),
      album: payload["album"] as? String ?? "",
      duration: (payload["duration"] as? NSNumber)?.doubleValue ?? 0,
      position: (payload["position"] as? NSNumber)?.doubleValue ?? 0,
      art: payload["art"] as? String ?? "",
      nativeLines: (payload["lines"] as? [String]).flatMap { $0.count >= 4 ? $0 : nil },
      timedLines: (payload["timedLines"] as? [[String: Any]]).flatMap { arr in
        let lines = arr.compactMap { d -> LyricLine? in
          guard let t = (d["t"] as? NSNumber)?.doubleValue, let text = d["text"] as? String, !text.isEmpty else { return nil }
          return LyricLine(t: t, end: (d["end"] as? NSNumber)?.doubleValue, text: text, words: nil)
        }
        return lines.count >= 3 ? lines : nil
      })
    lock.lock()
    if let prev = external, prev.pid == reading.pid {
      if reading.nativeLines == nil { reading.nativeLines = prev.nativeLines }
      if reading.timedLines == nil { reading.timedLines = prev.timedLines }
    }
    let started = external == nil || external?.status != "playing" || external?.pid != reading.pid
    external = reading
    externalAt = Date().timeIntervalSince1970
    if status == "playing" && started { externalPlayingSince = externalAt }
    lock.unlock()
  }

  private func readMusic() -> Reading? {
    let script = """
    if application "Music" is not running then return "off"
    tell application "Music"
      set pstate to (player state as text)
      if pstate is "stopped" then return "stopped"
      set t to current track
      return (persistent ID of t) & tab & (name of t) & tab & (artist of t) & tab & (album of t) & tab & (duration of t) & tab & (player position) & tab & pstate
    end tell
    """
    guard let raw = AppleScript.run(script) else {
      failures += 1
      if failures < 8 { return nil }
      return Reading(source: "music", status: "off")
    }
    failures = 0
    if raw == "off" || raw == "stopped" { return Reading(source: "music", status: raw) }
    let parts = raw.components(separatedBy: "\t")
    guard parts.count == 7 else { Log.info("unexpected Music reply: \(raw)"); return nil }
    let status = parts[6]
    if status == "playing" && (musicLastStatus != "playing" || musicLastPID != parts[0]) {
      musicPlayingSince = Date().timeIntervalSince1970
    }
    musicLastStatus = status; musicLastPID = parts[0]
    return Reading(source: "music", status: status, pid: parts[0], title: parts[1], artist: parts[2], album: parts[3],
                   duration: Double(parts[4]) ?? 0, position: Double(parts[5]) ?? 0)
  }

  private func choose(music: Reading?) -> Reading? {
    lock.lock()
    var ext = external
    let extAt = externalAt, extSince = externalPlayingSince
    lock.unlock()
    let now = Date().timeIntervalSince1970
    let fresh = ext != nil && now - extAt < 4
    if fresh, ext?.status == "playing" { ext?.position += now - extAt }
    let musicPlaying = music?.status == "playing"
    if musicPlaying { return music }                       // Music is exact; it always wins while playing
    if fresh, let e = ext, e.status == "playing" { return e }
    if let m = music, m.status == "paused" {
      if fresh, extSince > musicPlayingSince, let e = ext { return e }
      return m
    }
    if var e = ext, now - extAt < 30 {
      if e.status == "playing" { e.status = "paused" }      // reporter went quiet (tab closed, browser gone): stop the glow
      return e
    }
    return music
  }

  private func poll() {
    let music = readMusic()
    if music == nil && external == nil { return }
    apply(choose(music: music))
  }

  private func apply(_ reading: Reading?) {
    guard let reading else { return }
    let now = Date().timeIntervalSince1970
    lock.lock()
    if reading.status == "off" || reading.status == "stopped" {
      let changed = state.status != reading.status
      state = TrackState(status: reading.status, polledAt: now)
      let snap = state
      lock.unlock()
      if changed { notify(snap, trackChanged: true) }
      return
    }
    let trackChanged = reading.pid != state.pid
    let nativeArrived = !trackChanged && ((reading.timedLines != nil && state.lyricsSource != "captions") || (reading.nativeLines != nil && state.lyricsSource == "none"))
    state.status = reading.status
    state.position = reading.position
    state.polledAt = now
    if trackChanged {
      state.source = reading.source; state.pid = reading.pid; state.title = reading.title
      state.artist = reading.artist; state.album = reading.album; state.duration = reading.duration
      state.lyricsSource = "loading"; state.synced = false; state.lines = []; state.hasArt = false
    }
    let snap = state
    lock.unlock()
    notify(snap, trackChanged: trackChanged)
    if trackChanged {
      Log.info("now playing (\(reading.source)): \(reading.artist) - \(reading.title)")
      loadTrack(reading)
    } else if nativeArrived {
      Log.info("native lyrics arrived for \(reading.title)")
      loadTrack(reading)
    }
  }

  private func loadTrack(_ reading: Reading) {
    let pid = reading.pid
    var artOK = false
    if reading.source == "music" {
      artOK = AppleScript.run("""
      tell application "Music"
        set t to current track
        if (persistent ID of t) is not "\(pid)" then return "mismatch"
        if (count of artworks of t) is 0 then return "none"
        set d to raw data of artwork 1 of t
        set f to open for access POSIX file "\(Paths.art.path)" with write permission
        set eof f to 0
        write d to f
        close access f
        return "ok"
      end tell
      """) == "ok"
    } else if reading.art.hasPrefix("https://"), let url = URL(string: reading.art),
              let data = try? Data(contentsOf: url) {
      try? data.write(to: Paths.art); artOK = true
    }
    var title = reading.title, artist = reading.artist
    if reading.source != "music" { (title, artist) = LyricsResolver.cleanWebMetadata(title: title, artist: artist) }
    let embedded = reading.source == "music" ? (AppleScript.run("""
      tell application "Music"
        set t to current track
        if (persistent ID of t) is not "\(pid)" then return ""
        return lyrics of t
      end tell
      """) ?? "") : ""
    let result: LyricsResult
    if let timed = reading.timedLines {
      result = LyricsResult(source: "captions", synced: true, lines: timed)
    } else if let native = reading.nativeLines {
      result = LyricsResult(source: "native", synced: false, lines: native.map { LyricLine(t: nil, end: nil, text: $0, words: nil) })
    } else {
      result = lyrics.resolve(pid: pid, title: title, artist: artist, album: reading.album,
                              duration: reading.duration, embedded: embedded)
    }
    lock.lock()
    guard state.pid == pid else { lock.unlock(); return }
    state.hasArt = artOK; state.artVersion += 1
    state.title = title; state.artist = artist
    state.lyricsSource = result.source; state.synced = result.synced; state.lines = result.lines
    let snap = state
    lock.unlock()
    notify(snap, trackChanged: true)
  }

  private func notify(_ snap: TrackState, trackChanged: Bool) {
    lock.lock(); let ls = listeners; lock.unlock()
    ls.forEach { $0(snap, trackChanged) }
  }
}

enum AppleScript {
  /// NSAppleScript is main-thread only; run there synchronously and log failures to the app log.
  private static var loggedErrors = 0
  static func run(_ source: String) -> String? {
    var output: String?
    let work = {
      var error: NSDictionary?
      guard let script = NSAppleScript(source: source) else { return }
      let result = script.executeAndReturnError(&error)
      if let error {
        if loggedErrors < 20 { loggedErrors += 1; Log.info("AppleScript error: \(error[NSAppleScript.errorNumber] ?? "?") \(error[NSAppleScript.errorMessage] ?? "")") }
        return
      }
      output = result.stringValue
    }
    if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
    return output
  }
}

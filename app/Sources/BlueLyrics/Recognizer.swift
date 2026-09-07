// Turns captured speaker audio into (a) song matches through ShazamKit and
// (b) live captions through Apple's on-device speech recognition.

import Foundation
import ShazamKit
import Speech
import AVFoundation

final class SongMatcher: NSObject, SHSessionDelegate {
  private let session = SHSession()
  var onMatch: ((_ title: String, _ artist: String, _ offset: Double, _ artworkURL: String, _ shazamID: String) -> Void)?
  var onNoMatch: (() -> Void)?
  private var lastMatchAt = 0.0
  private var lastShazamID = ""

  override init() { super.init(); session.delegate = self }

  func feed(_ buffer: AVAudioPCMBuffer) { session.matchStreamingBuffer(buffer, at: nil) }

  func session(_ session: SHSession, didFind match: SHMatch) {
    guard let item = match.mediaItems.first else { return }
    lastMatchAt = Date().timeIntervalSince1970
    let id = item.shazamID ?? ""
    if id != lastShazamID { Log.info("shazam: \(item.artist ?? "?") - \(item.title ?? "?") at \(Int(item.predictedCurrentMatchOffset))s") }
    lastShazamID = id
    onMatch?(item.title ?? "", item.artist ?? "", item.predictedCurrentMatchOffset, item.artworkURL?.absoluteString ?? "", id)
  }

  func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
    if let error { Log.info("shazam no match: \(error.localizedDescription)") }
    onNoMatch?()
  }
}

/// Continuous on-device captions. Apple limits a request to about a minute,
/// so the request is rotated; final text of each segment is pushed out.
final class Captioner {
  private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var segmentStart = 0.0
  private var authorized = false
  var onCaption: ((_ text: String, _ final: Bool) -> Void)?

  func start() {
    SFSpeechRecognizer.requestAuthorization { [weak self] status in
      guard let self else { return }
      self.authorized = status == .authorized
      Log.info("speech authorization: \(status.rawValue) (3 = authorized)")
      if self.authorized { DispatchQueue.main.async { self.rotate() } }
    }
  }

  func stop() { task?.cancel(); task = nil; request?.endAudio(); request = nil }

  func feed(_ buffer: AVAudioPCMBuffer) {
    guard authorized, let request else { return }
    request.append(buffer)
    if Date().timeIntervalSince1970 - segmentStart > 50 { DispatchQueue.main.async { self.rotate() } }
  }

  private func rotate() {
    guard let recognizer, recognizer.isAvailable else { Log.info("speech recognizer unavailable"); return }
    task?.finish()
    let req = SFSpeechAudioBufferRecognitionRequest()
    req.shouldReportPartialResults = true
    req.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
    req.taskHint = .dictation
    request = req; segmentStart = Date().timeIntervalSince1970
    task = recognizer.recognitionTask(with: req) { [weak self] result, error in
      if let result { self?.onCaption?(result.bestTranscription.formattedString, result.isFinal) }
      if let error, (error as NSError).code != 216 { Log.info("speech: \(error.localizedDescription)") }
    }
  }
}

/// Ties capture, matcher and captioner together; reports into NowPlaying.
final class Listener {
  let capture = AudioCapture()               // ScreenCaptureKit fallback (macOS 13)
  private var analyzerCaptioner: Any? = { if #available(macOS 26.0, *) { return AnalyzerCaptioner() } else { return nil } }()
  private var tap: Any? = { if #available(macOS 14.2, *) { return AudioTapCapture() } else { return nil } }()
  let matcher = SongMatcher()
  let captioner = Captioner()
  private(set) var on = false
  var onCaption: ((String, Bool) -> Void)?
  var onStatus: ((String) -> Void)?
  weak var nowPlaying: NowPlaying?
  private var current: (title: String, artist: String, art: String, id: String, offset: Double, at: Double)?
  private var reportTimer: DispatchSourceTimer?

  /// Listening but hearing only zeros: the System Audio Recording permission is missing.
  var needsPermission: Bool {
    if #available(macOS 14.2, *), let t = tap as? AudioTapCapture { return t.silentDespiteAudio }
    return false
  }
  var lastError: String? {
    if #available(macOS 14.2, *), let t = tap as? AudioTapCapture { return t.lastError ?? capture.lastError }
    return capture.lastError
  }

  init() {
    var buffers = 0
    var loudest: Float = 0
    var lastLog = 0.0
    let sink: (AVAudioPCMBuffer, Double) -> Void = { [weak self] buffer, _ in
      buffers += 1
      if let data = buffer.floatChannelData?[0] {
        var peak: Float = 0
        for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[i])) }
        loudest = max(loudest, peak)
      }
      let now = Date().timeIntervalSince1970
      if now - lastLog > 5 {
        lastLog = now
        Log.info("audio: \(buffers) buffers, last \(buffer.frameLength) frames @\(Int(buffer.format.sampleRate)) Hz, peak \(String(format: "%.3f", loudest))")
        loudest = 0
      }
      if #available(macOS 26.0, *), let a = self?.analyzerCaptioner as? AnalyzerCaptioner, a.ready { a.feed(buffer) }
      else { self?.captioner.feed(buffer) }
    }
    capture.onAudio(sink)
    if #available(macOS 14.2, *), let t = tap as? AudioTapCapture { t.onAudio(sink) }
    matcher.onMatch = { [weak self] title, artist, offset, art, id in
      guard let self else { return }
      self.current = (title, artist, art, id, offset, Date().timeIntervalSince1970)
      self.report()
    }
    captioner.onCaption = { [weak self] text, final in self?.onCaption?(text, final) }
    if #available(macOS 26.0, *), let a = analyzerCaptioner as? AnalyzerCaptioner { a.onCaption = { [weak self] text, final in self?.onCaption?(text, final) } }
  }

  func setOn(_ value: Bool, completion: @escaping (Bool, String?) -> Void) {
    if value == on { completion(true, nil); return }
    if value {
      if #available(macOS 14.2, *), let t = tap as? AudioTapCapture {
        let ok = t.start()
        if ok { on = true; startCaptioning(); startReporting() }
        completion(ok, ok ? nil : t.lastError); onStatus?(ok ? "listening" : "off")
        return
      }
      capture.start { [weak self] ok in
        guard let self else { return }
        if ok { self.on = true; self.startCaptioning(); self.startReporting() }
        completion(ok, ok ? nil : self.capture.lastError)
        self.onStatus?(ok ? "listening" : "off")
      }
    } else {
      if #available(macOS 14.2, *), let t = tap as? AudioTapCapture, t.running { t.stop() } else { capture.stop() }
      captioner.stop()
      if #available(macOS 26.0, *), let a = analyzerCaptioner as? AnalyzerCaptioner { a.stop() }
      reportTimer?.cancel(); reportTimer = nil; on = false; current = nil
      completion(true, nil); onStatus?("off")
    }
  }

  /// Diagnostic: run a local audio file through the caption engine (no tap, no permission needed).
  func transcribeFile(_ url: URL) -> String? {
    guard let file = try? AVAudioFile(forReading: url) else { return "cannot open \(url.lastPathComponent)" }
    startCaptioning()
    DispatchQueue.global().async { [weak self] in
      guard let self else { return }
      let format = file.processingFormat
      let chunk = AVAudioFrameCount(format.sampleRate / 10)     // 100 ms
      var fed = 0
      while file.framePosition < file.length {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk), (try? file.read(into: buffer, frameCount: chunk)) != nil, buffer.frameLength > 0 else { break }
        if #available(macOS 26.0, *), let a = self.analyzerCaptioner as? AnalyzerCaptioner {
          var waited = 0
          while !a.ready && waited < 300 { Thread.sleep(forTimeInterval: 0.1); waited += 1 }
          a.feed(buffer)
        } else { self.captioner.feed(buffer) }
        fed += Int(buffer.frameLength)
        Thread.sleep(forTimeInterval: 0.1)            // real time, like a speaker
      }
      Log.info("transcribeFile fed \(fed) frames from \(url.lastPathComponent)")
    }
    return nil
  }

  private func startCaptioning() {
    if #available(macOS 26.0, *), let a = analyzerCaptioner as? AnalyzerCaptioner { a.start() } else { captioner.start() }
  }

  private func startReporting() {
    let timer = DispatchSource.makeTimerSource(queue: .global())
    timer.schedule(deadline: .now(), repeating: 0.5)
    timer.setEventHandler { [weak self] in self?.report() }
    timer.resume(); reportTimer = timer
  }

  /// Push the matched song as a "speaker" reading, position advanced from the match offset.
  private func report() {
    guard on, let c = current, let nowPlaying else { return }
    let elapsed = Date().timeIntervalSince1970 - c.at
    guard elapsed < 20 else { return }         // match went stale: song ended or changed
    nowPlaying.report(["source": "speaker", "id": c.id, "title": c.title, "artist": c.artist, "album": "",
                       "duration": 0, "position": c.offset + elapsed, "status": "playing", "art": c.art])
  }
}

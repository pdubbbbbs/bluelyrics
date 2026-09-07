// On-device transcription of whatever the Mac is playing, using Apple's
// SpeechAnalyzer (macOS 26+), the same class of model as Whisper but built in.

import Foundation
import Speech
import AVFoundation

@available(macOS 26.0, *)
final class AnalyzerCaptioner {
  private var analyzer: SpeechAnalyzer?
  private var transcriber: SpeechTranscriber?
  private var input: AsyncStream<AnalyzerInput>.Continuation?
  private var inputFormat: AVAudioFormat?
  private var converter: AVAudioConverter?
  private var resultsTask: Task<Void, Never>?
  private(set) var ready = false
  var onCaption: ((String, Bool) -> Void)?

  func start() {
    Task { await self.boot() }
  }

  private func boot() async {
    do {
      let locale = Locale(identifier: "en-US")
      let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
      self.transcriber = transcriber
      if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        Log.info("speech model download needed, installing…")
        try await request.downloadAndInstall()
        Log.info("speech model installed")
      }
      let analyzer = SpeechAnalyzer(modules: [transcriber])
      self.analyzer = analyzer
      inputFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
      let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
      input = continuation
      try await analyzer.start(inputSequence: stream)
      ready = true
      Log.info("SpeechAnalyzer running, input format \(inputFormat.map { "\(Int($0.sampleRate)) Hz \($0.channelCount) ch" } ?? "?")")
      resultsTask = Task { [weak self] in
        guard let transcriber = self?.transcriber else { return }
        do {
          for try await result in transcriber.results {
            let text = String(result.text.characters)
            self?.onCaption?(text, result.isFinal)
          }
        } catch { Log.info("SpeechAnalyzer results ended: \(error.localizedDescription)") }
      }
    } catch {
      Log.info("SpeechAnalyzer failed: \(error.localizedDescription)")
    }
  }

  func feed(_ buffer: AVAudioPCMBuffer) {
    guard ready, let input else { return }
    var out = buffer
    if let target = inputFormat, target != buffer.format {
      if converter == nil || converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: target) }
      guard let converter, let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 16) else { return }
      var consumed = false; var error: NSError?
      converter.convert(to: converted, error: &error) { _, status in
        if consumed { status.pointee = .noDataNow; return nil }
        consumed = true; status.pointee = .haveData; return buffer
      }
      guard error == nil else { return }
      out = converted
    }
    input.yield(AnalyzerInput(buffer: out))
  }

  func stop() {
    input?.finish(); input = nil
    resultsTask?.cancel(); resultsTask = nil
    let analyzer = self.analyzer
    Task { try? await analyzer?.finalizeAndFinishThroughEndOfInput() }
    ready = false
  }
}

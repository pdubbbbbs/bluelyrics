// Captures whatever the Mac is playing through its speakers (system audio)
// with ScreenCaptureKit, audio only, and hands PCM buffers to listeners.

import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
  private var stream: SCStream?
  private let queue = DispatchQueue(label: "bluelyrics.audio")
  private var listeners: [(AVAudioPCMBuffer, Double) -> Void] = []   // (buffer, hostTimeSeconds)
  private(set) var running = false
  private(set) var lastError: String?
  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!

  func onAudio(_ listener: @escaping (AVAudioPCMBuffer, Double) -> Void) { listeners.append(listener) }

  func start(completion: @escaping (Bool) -> Void) {
    guard !running else { completion(true); return }
    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, error in
      guard let self else { return }
      if let error { self.lastError = "screen content: \(error.localizedDescription)"; Log.info(self.lastError!); completion(false); return }
      guard let display = content?.displays.first else { self.lastError = "no display"; completion(false); return }
      // exclude our own app so the window never feeds back; capture audio only
      let me = content?.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier } ?? []
      let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
      let config = SCStreamConfiguration()
      config.capturesAudio = true
      config.excludesCurrentProcessAudio = true
      config.sampleRate = 48000
      config.channelCount = 1
      config.width = 2; config.height = 2                 // minimal video, we ignore it
      config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
      config.showsCursor = false
      let stream = SCStream(filter: filter, configuration: config, delegate: self)
      do {
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.queue)
        stream.startCapture { error in
          if let error { self.lastError = "start: \(error.localizedDescription)"; Log.info(self.lastError!); completion(false); return }
          self.stream = stream; self.running = true; self.lastError = nil
          Log.info("audio capture started"); completion(true)
        }
      } catch { self.lastError = "setup: \(error.localizedDescription)"; Log.info(self.lastError!); completion(false) }
    }
  }

  func stop() {
    guard let stream else { return }
    stream.stopCapture { _ in }
    self.stream = nil; running = false
    Log.info("audio capture stopped")
  }

  func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .audio, sampleBuffer.isValid, let pcm = Self.pcmBuffer(from: sampleBuffer, format: format) else { return }
    let hostTime = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    listeners.forEach { $0(pcm, hostTime) }
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    lastError = "stopped: \(error.localizedDescription)"; Log.info(lastError!); running = false; self.stream = nil
  }

  /// CMSampleBuffer (audio) -> mono Float32 AVAudioPCMBuffer at the stream's rate.
  static func pcmBuffer(from sample: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
    guard let desc = CMSampleBufferGetFormatDescription(sample), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee else { return nil }
    let frames = CMSampleBufferGetNumSamples(sample)
    guard frames > 0, let inFormat = AVAudioFormat(streamDescription: withUnsafePointer(to: asbd) { $0 }) else { return nil }
    guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
    inBuffer.frameLength = AVAudioFrameCount(frames)
    let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: inBuffer.mutableAudioBufferList)
    guard status == noErr else { return nil }
    if inFormat.sampleRate == format.sampleRate, inFormat.channelCount == format.channelCount, inFormat.commonFormat == format.commonFormat { return inBuffer }
    guard let converter = AVAudioConverter(from: inFormat, to: format),
          let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(frames) * format.sampleRate / inFormat.sampleRate) + 16) else { return nil }
    var consumed = false
    var error: NSError?
    converter.convert(to: out, error: &error) { _, status in
      if consumed { status.pointee = .noDataNow; return nil }
      consumed = true; status.pointee = .haveData; return inBuffer
    }
    return error == nil ? out : nil
  }
}

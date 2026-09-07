// Audio-only capture of everything the Mac plays, through a Core Audio
// process tap (macOS 14.2+). Asks only for the "System Audio Recording"
// permission, never screen recording.

import Foundation
import CoreAudio
import AVFoundation

@available(macOS 14.2, *)
final class AudioTapCapture {
  private var tapID = AudioObjectID(kAudioObjectUnknown)
  private var aggregateID = AudioObjectID(kAudioObjectUnknown)
  private var procID: AudioDeviceIOProcID?
  private var tapFormat: AVAudioFormat?
  private let queue = DispatchQueue(label: "bluelyrics.audiotap")
  private var listeners: [(AVAudioPCMBuffer, Double) -> Void] = []
  private(set) var running = false
  private(set) var lastError: String?
  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
  private var converter: AVAudioConverter?

  func onAudio(_ listener: @escaping (AVAudioPCMBuffer, Double) -> Void) { listeners.append(listener) }

  private func fail(_ message: String) -> Bool { lastError = message; Log.info("audio tap: \(message)"); return false }

  private func getProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> OSStatus {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
  }
  private func getPropertyQualified<Q, T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, qualifier: inout Q, _ value: inout T) -> OSStatus {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    return withUnsafePointer(to: &qualifier) { q in AudioObjectGetPropertyData(object, &address, UInt32(MemoryLayout<Q>.size), q, &size, &value) }
  }

  func start() -> Bool {
    if running { return true }
    // our own process object, so the tap never hears the app itself
    var pid = pid_t(ProcessInfo.processInfo.processIdentifier)
    var ownObject = AudioObjectID(kAudioObjectUnknown)
    _ = getPropertyQualified(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyTranslatePIDToProcessObject, qualifier: &pid, &ownObject)
    let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])   // the app plays no audio itself
    description.name = "BlueLyrics listener"
    description.isPrivate = true
    description.muteBehavior = .unmuted
    var tap = AudioObjectID(kAudioObjectUnknown)
    var status = AudioHardwareCreateProcessTap(description, &tap)
    guard status == noErr else { return fail("create tap failed (\(status)); System Audio Recording permission may be missing") }
    tapID = tap
    // default output device UID for the aggregate
    var outputDevice = AudioObjectID(kAudioObjectUnknown)
    status = getProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, &outputDevice)
    guard status == noErr else { return fail("no default output device (\(status))") }
    var uidRef: Unmanaged<CFString>?
    status = getProperty(outputDevice, kAudioDevicePropertyDeviceUID, &uidRef)
    guard status == noErr, let outputUID = uidRef?.takeRetainedValue() as String? else { return fail("output UID (\(status))") }
    let aggregate: [String: Any] = [
      kAudioAggregateDeviceNameKey as String: "BlueLyrics Tap",
      kAudioAggregateDeviceUIDKey as String: "com.blueguard.bluelyrics.tap",
      kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
      kAudioAggregateDeviceIsPrivateKey as String: true,
      kAudioAggregateDeviceIsStackedKey as String: false,
      kAudioAggregateDeviceTapAutoStartKey as String: true,
      kAudioAggregateDeviceSubDeviceListKey as String: [[kAudioSubDeviceUIDKey as String: outputUID]],
      kAudioAggregateDeviceTapListKey as String: [[kAudioSubTapDriftCompensationKey as String: true, kAudioSubTapUIDKey as String: description.uuid.uuidString]],
    ]
    var agg = AudioObjectID(kAudioObjectUnknown)
    status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg)
    guard status == noErr else { return fail("aggregate device failed (\(status))") }
    aggregateID = agg
    var asbd = AudioStreamBasicDescription()
    status = getProperty(tapID, kAudioTapPropertyFormat, &asbd)
    guard status == noErr, let inFormat = AVAudioFormat(streamDescription: &asbd) else { return fail("tap format (\(status))") }
    tapFormat = inFormat
    converter = AVAudioConverter(from: inFormat, to: format)
    var proc: AudioDeviceIOProcID?
    status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, queue) { [weak self] _, inputData, inputTime, _, _ in
      self?.handle(inputData, at: inputTime)
    }
    guard status == noErr, let proc else { return fail("io proc (\(status))") }
    procID = proc
    status = AudioDeviceStart(aggregateID, proc)
    guard status == noErr else { return fail("start (\(status))") }
    running = true; lastError = nil; firstCallbackAt = 0; lastSoundAt = 0
    Log.info("audio tap started: \(Int(inFormat.sampleRate)) Hz, \(inFormat.channelCount) ch, output \(outputUID)")
    return true
  }

  func stop() {
    if let procID { AudioDeviceStop(aggregateID, procID); AudioDeviceDestroyIOProcID(aggregateID, procID) }
    procID = nil
    if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = AudioObjectID(kAudioObjectUnknown) }
    if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = AudioObjectID(kAudioObjectUnknown) }
    running = false
    Log.info("audio tap stopped")
  }

  private var rawCalls = 0
  private var rawPeak: Float = 0
  private var rawLogAt = 0.0
  private var lastSoundAt = 0.0
  private var firstCallbackAt = 0.0
  /// True when audio callbacks arrive but every sample is zero: macOS is withholding the audio (permission).
  var silentDespiteAudio: Bool {
    guard running, firstCallbackAt > 0 else { return false }
    let now = Date().timeIntervalSince1970
    return now - firstCallbackAt > 8 && now - lastSoundAt > 8
  }
  private func handle(_ list: UnsafePointer<AudioBufferList>, at time: UnsafePointer<AudioTimeStamp>) {
    rawCalls += 1
    let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
    for buf in abl {
      guard let data = buf.mData else { continue }
      let f = data.assumingMemoryBound(to: Float.self)
      for i in 0..<Int(buf.mDataByteSize) / 4 { let v = abs(f[i]); if v > rawPeak { rawPeak = v } }
    }
    let now = Date().timeIntervalSince1970
    if firstCallbackAt == 0 { firstCallbackAt = now; lastSoundAt = 0 }
    if rawPeak > 0.001 { lastSoundAt = now }
    if now - rawLogAt > 5 { rawLogAt = now; Log.info("tap raw: \(rawCalls) callbacks, \(abl.count) buffers, first \(abl.first?.mDataByteSize ?? 0) bytes, raw peak \(String(format: "%.3f", rawPeak))"); rawPeak = 0 }
    guard let tapFormat, let converter else { return }
    let frames = AVAudioFrameCount(list.pointee.mBuffers.mDataByteSize) / tapFormat.streamDescription.pointee.mBytesPerFrame
    guard frames > 0, let inBuffer = AVAudioPCMBuffer(pcmFormat: tapFormat, bufferListNoCopy: list, deallocator: nil) else { return }
    inBuffer.frameLength = frames
    guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(frames) * format.sampleRate / tapFormat.sampleRate) + 16) else { return }
    var consumed = false; var error: NSError?
    converter.convert(to: out, error: &error) { _, status in
      if consumed { status.pointee = .noDataNow; return nil }
      consumed = true; status.pointee = .haveData; return inBuffer
    }
    guard error == nil, out.frameLength > 0 else { return }
    let seconds = time.pointee.mHostTime > 0 ? Double(time.pointee.mHostTime) / 1e9 : Date().timeIntervalSince1970
    listeners.forEach { $0(out, seconds) }
  }
}

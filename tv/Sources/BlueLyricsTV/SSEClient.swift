// Server-sent events over URLSession: reads "event:" / "data:" frames from the
// Mac's /events stream and hands each one to a callback. Reconnects on its own.

import Foundation
import UIKit

final class SSEClient {
  typealias Handler = (String, [String: Any]) -> Void

  private let url: URL
  private let handler: Handler
  private let onState: (Bool) -> Void
  private var task: Task<Void, Never>?

  init(url: URL, onState: @escaping (Bool) -> Void, handler: @escaping Handler) {
    self.url = url
    self.onState = onState
    self.handler = handler
  }

  func start() {
    task?.cancel()
    task = Task { [url, handler, onState] in
      var delay: UInt64 = 1
      while !Task.isCancelled {
        do {
          var request = URLRequest(url: url)
          request.timeoutInterval = 60 * 60 * 24
          request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
          request.setValue("appletv", forHTTPHeaderField: "X-BlueLyrics-Client")
          request.setValue(await MainActor.run { UIDevice.current.name }, forHTTPHeaderField: "X-BlueLyrics-Name")
          let (bytes, response) = try await URLSession.shared.bytes(for: request)
          guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
          await MainActor.run { onState(true) }
          delay = 1
          var event = "message"
          var data = ""
          var line = Data()
          for try await byte in bytes {
            if Task.isCancelled { break }
            if byte != 0x0A { if byte != 0x0D { line.append(byte) }; continue }
            let text = String(decoding: line, as: UTF8.self)
            line.removeAll(keepingCapacity: true)
            if text.isEmpty {
              if !data.isEmpty, let json = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] {
                let name = event
                await MainActor.run { handler(name, json) }
              }
              event = "message"; data = ""
            } else if text.hasPrefix("event:") {
              event = text.dropFirst(6).trimmingCharacters(in: .whitespaces)
            } else if text.hasPrefix("data:") {
              data += text.dropFirst(5).trimmingCharacters(in: .whitespaces)
            }
          }
        } catch {
          // fall through to reconnect
        }
        await MainActor.run { onState(false) }
        if Task.isCancelled { break }
        try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
        delay = min(delay * 2, 8)
      }
    }
  }

  func stop() { task?.cancel(); task = nil }
}

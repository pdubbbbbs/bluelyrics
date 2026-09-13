// Fetches the display font the Mac is using from its /fonts/ route and
// registers it, so the TV shows the same face as the Mac window.

import Foundation
import CoreText
import SwiftUI

@MainActor
final class FontLoader: ObservableObject {
  @Published var family: String? = nil
  private var registered: Set<String> = []

  func load(prefs: [String: Any], fonts: [String: Any], base: URL) {
    let key = (prefs["font"] as? String).flatMap { fonts[$0] != nil ? $0 : nil } ?? "cinzel"
    guard let font = fonts[key] as? [String: Any], let name = font["name"] as? String else { return }
    let files = (font["files"] as? [String: String] ?? [:]).values.sorted()
    if registered.contains(name) { family = name; return }
    Task {
      var ok = false
      for file in files {
        guard let remote = URL(string: "fonts/" + (file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file), relativeTo: base) else { continue }
        let local = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(file)
        if !FileManager.default.fileExists(atPath: local.path) {
          guard let (data, response) = try? await URLSession.shared.data(from: remote),
                (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
          try? data.write(to: local)
        }
        if CTFontManagerRegisterFontsForURL(local as CFURL, .process, nil) { ok = true }
        else if fontIsRegistered(local) { ok = true }
      }
      if ok { registered.insert(name); family = name }
    }
  }

  private func fontIsRegistered(_ url: URL) -> Bool {
    guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else { return false }
    for d in descriptors {
      if let name = CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute) as? String, UIFont(name: name, size: 12) != nil { return true }
    }
    return false
  }
}

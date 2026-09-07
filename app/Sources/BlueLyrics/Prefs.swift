// Display preferences shared with every cast client (font choice, sources).

import Foundation

enum Prefs {
  static let fonts: [String: [String: Any]] = [
    "cinzel": ["name": "Cinzel", "files": ["400 900": "Cinzel[wght].ttf"]],
    "alegreya-sans-sc": ["name": "Alegreya Sans SC", "files": ["400": "AlegreyaSansSC-Regular.ttf", "700": "AlegreyaSansSC-Bold.ttf"]],
    "carrois-gothic-sc": ["name": "Carrois Gothic SC", "files": ["400": "CarroisGothicSC-Regular.ttf"]],
    "marcellus-sc": ["name": "Marcellus SC", "files": ["400": "MarcellusSC-Regular.ttf"]],
    "playfair-display-sc": ["name": "Playfair Display SC", "files": ["400": "PlayfairDisplaySC-Regular.ttf", "700": "PlayfairDisplaySC-Bold.ttf"]],
    "vollkorn-sc": ["name": "Vollkorn SC", "files": ["400": "VollkornSC-Regular.ttf", "700": "VollkornSC-Bold.ttf"]],
    "bona-nova-sc": ["name": "Bona Nova SC", "files": ["400": "BonaNovaSC-Regular.ttf", "700": "BonaNovaSC-Bold.ttf"]],
    "alegreya-sc": ["name": "Alegreya SC", "files": ["400": "AlegreyaSC-Regular.ttf", "700": "AlegreyaSC-Bold.ttf"]],
    "cormorant-sc": ["name": "Cormorant SC", "files": ["400": "CormorantSC-Regular.ttf", "700": "CormorantSC-Bold.ttf"]],
    "overlock-sc": ["name": "Overlock SC", "files": ["400": "OverlockSC-Regular.ttf"]],
    "mate-sc": ["name": "Mate SC", "files": ["400": "MateSC-Regular.ttf"]],
    "diplomata-sc": ["name": "Diplomata SC", "files": ["400": "DiplomataSC-Regular.ttf"]],
  ]
  private static let queue = DispatchQueue(label: "bluelyrics.prefs")
  private static var cached: [String: Any]?

  static func load() -> [String: Any] {
    queue.sync {
      if let cached { return cached }
      let data = (try? Data(contentsOf: Paths.prefs)) ?? Data()
      let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
      cached = parsed
      return parsed
    }
  }

  @discardableResult
  static func save(_ update: [String: Any]) -> [String: Any] {
    queue.sync {
      var prefs = cached ?? [:]
      if let font = update["font"] as? String, fonts[font] != nil { prefs["font"] = font }
      if let community = update["communityLyrics"] as? Bool { prefs["communityLyrics"] = community }
      if let captions = update["captions"] as? Bool { prefs["captions"] = captions }
      if let listen = update["listen"] as? Bool { prefs["listen"] = listen }
      if let theme = update["theme"] as? String, ["blueguard", "ember", "violet", "emerald", "rose", "mono"].contains(theme) { prefs["theme"] = theme }
      cached = prefs
      if let data = try? JSONSerialization.data(withJSONObject: prefs) { try? data.write(to: Paths.prefs) }
      return prefs
    }
  }

  static var communityLyrics: Bool { (load()["communityLyrics"] as? Bool) ?? true }
  static var listen: Bool { (load()["listen"] as? Bool) ?? false }
}

// BlueLyrics for Apple TV: follows the word-synced lyrics that the Mac's
// BlueLyrics app is showing, over the same local server the Cast page uses.

import SwiftUI

@main
struct BlueLyricsTVApp: App {
  @StateObject private var store = LyricsStore()
  @StateObject private var discovery = Discovery()
  @StateObject private var music = MusicPlayerStore()

  var body: some Scene {
    WindowGroup {
      RootView()
        .environmentObject(store)
        .environmentObject(discovery)
        .environmentObject(music)
        .preferredColorScheme(.dark)
    }
  }
}

enum Mode: String { case connect, mac, appleTV }

struct RootView: View {
  @EnvironmentObject var store: LyricsStore
  @EnvironmentObject var music: MusicPlayerStore
  @State private var mode: Mode = .connect
  static let modeKey = "bluelyrics.mode"

  var body: some View {
    ZStack {
      switch mode {
      case .connect:
        ConnectView(onConnected: { enter(.mac) }, onAppleTV: { enter(.appleTV) })
      case .mac:
        LyricsView(onDisconnect: { store.disconnect(); enter(.connect) })
      case .appleTV:
        LyricsView(onDisconnect: { music.detach(); store.disconnect(); enter(.connect) }, showMusicPanel: true)
      }
    }
    .onAppear {
      let saved = Mode(rawValue: UserDefaults.standard.string(forKey: Self.modeKey) ?? "") ?? .connect
      if saved == .appleTV {
        enter(.appleTV)
      } else if saved == .mac, let host = UserDefaults.standard.string(forKey: LyricsStore.hostKey), !host.isEmpty {
        store.connect(to: host)
        enter(.mac)
      }
    }
  }

  private func enter(_ new: Mode) {
    mode = new
    UserDefaults.standard.set(new.rawValue, forKey: Self.modeKey)
    if new == .appleTV {
      music.attach(store)
      Task { await music.authorize() }
    }
  }
}

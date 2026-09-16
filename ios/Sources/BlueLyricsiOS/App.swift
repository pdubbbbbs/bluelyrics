// BlueLyrics for iPhone and iPad: plays Apple Music on the device with
// word-synced lyrics, or follows the lyrics a Mac running BlueLyrics is showing.

import SwiftUI
import UIKit

@main
struct BlueLyricsiOSApp: App {
  @StateObject private var store = LyricsStore()
  @StateObject private var discovery = Discovery()
  @StateObject private var music = MusicPlayerStore()

  init() {
    SSEClient.clientTag = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
    LyricsFetcher.userAgent = "BlueLyrics-iOS/1.0 (github.com/pdubbbbbs/bluelyrics)"
  }

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

enum Mode: String { case connect, mac, device }

struct RootView: View {
  @EnvironmentObject var store: LyricsStore
  @EnvironmentObject var music: MusicPlayerStore
  @State private var mode: Mode = .connect
  @Environment(\.scenePhase) private var scenePhase
  static let modeKey = "bluelyrics.mode"

  var body: some View {
    ZStack {
      switch mode {
      case .connect:
        ConnectView(onConnected: { enter(.mac) }, onDevice: { enter(.device) })
          .transition(.opacity)
      case .mac:
        LyricsView(onLeave: { store.disconnect(); enter(.connect) })
          .transition(.opacity)
      case .device:
        LyricsView(onLeave: { music.detach(); store.disconnect(); enter(.connect) }, showMusicPanel: true)
          .transition(.opacity)
      }
    }
    .animation(.easeInOut(duration: 0.25), value: mode)
    .onAppear {
      let saved = Mode(rawValue: UserDefaults.standard.string(forKey: Self.modeKey) ?? "") ?? .connect
      if saved == .device {
        enter(.device)
      } else if saved == .mac, let host = UserDefaults.standard.string(forKey: LyricsStore.hostKey), !host.isEmpty {
        store.connect(to: host)
        enter(.mac)
      }
    }
    .onChange(of: mode) { _, new in
      // The lyric stage is meant to be watched, so the screen stays on while it is up.
      UIApplication.shared.isIdleTimerDisabled = new != .connect
    }
    .onChange(of: scenePhase) { _, phase in
      // iOS suspends the event stream in the background; pick it up again on return.
      guard mode == .mac, !store.host.isEmpty else { return }
      if phase == .active { store.connect(to: store.host) }
      else if phase == .background { store.disconnect() }
    }
  }

  private func enter(_ new: Mode) {
    mode = new
    UserDefaults.standard.set(new.rawValue, forKey: Self.modeKey)
    if new == .device {
      music.attach(store)
      Task { await music.authorize() }
    }
  }
}

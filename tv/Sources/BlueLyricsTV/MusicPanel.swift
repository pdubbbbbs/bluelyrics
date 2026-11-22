// The Apple Music pane: what is playing, transport, a status line, and the
// music to pick from: your library, a catalog search, or the top songs.
// A Diagnostics button shows the store's log on screen, so a failure on a
// real Apple TV can be read without a Mac.

import SwiftUI
import MusicKit

struct MusicPanel: View {
  @EnvironmentObject var music: MusicPlayerStore
  @EnvironmentObject var store: LyricsStore
  @Namespace private var panelNamespace
  @State private var query = ""
  @State private var showLog = false

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      nowPlaying
      statusLine
      Divider().overlay(Color.white.opacity(0.15))
      if showLog {
        diagnostics
      } else {
        switch music.auth {
        case .authorized: library
        case .denied: message("Apple Music access is off for BlueLyrics. Turn it on in Settings, Apps, BlueLyrics.")
        case .restricted: message("Apple Music is restricted on this Apple TV.")
        case .unknown:
          VStack(alignment: .leading, spacing: 16) {
            message("BlueLyrics needs access to Apple Music to play your library here.")
            Button("Allow Apple Music") { Task { await music.authorize() } }
          }
        }
      }
      Spacer(minLength: 0)
      Button(showLog ? "Back to music" : "Diagnostics") { showLog.toggle() }
        .font(.system(size: 20))
    }
    .padding(28)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color.black.opacity(0.35))
  }

  private func message(_ text: String) -> some View {
    Text(text).font(.system(size: 24)).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
  }

  private var statusLine: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(music.status).font(.system(size: 20)).foregroundStyle(store.theme.glow1.opacity(0.85)).lineLimit(2)
      if music.usingSystemPlayer {
        Text("Following the Music app").font(.system(size: 18)).foregroundStyle(.white.opacity(0.5))
      }
      if let error = music.error {
        Text(error).font(.system(size: 20)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var nowPlaying: some View {
    VStack(alignment: .leading, spacing: 14) {
      ZStack {
        RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.08))
        if let art = music.artwork {
          Image(uiImage: art).resizable().scaledToFill()
        } else {
          Image(systemName: "music.note").font(.system(size: 60)).foregroundStyle(.white.opacity(0.4))
        }
      }
      .frame(width: 220, height: 220)
      .clipShape(RoundedRectangle(cornerRadius: 14))
      .shadow(color: store.theme.glow3.opacity(0.5), radius: 24)
      Text(music.nowTitle.isEmpty ? "Nothing playing" : music.nowTitle)
        .font(.system(size: 26, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
      if !music.nowArtist.isEmpty {
        Text(music.nowArtist).font(.system(size: 22)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
      }
      HStack(spacing: 18) {
        Button { music.previous() } label: { Image(systemName: "backward.fill") }
        Button { music.togglePlayPause() } label: { Image(systemName: music.isPlaying ? "pause.fill" : "play.fill") }
          .prefersDefaultFocus(in: panelNamespace)
        Button { music.next() } label: { Image(systemName: "forward.fill") }
      }
      .font(.system(size: 26))
      .focusScope(panelNamespace)
    }
  }

  private var diagnostics: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 4) {
        Text("Diagnostics").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
        Text("Build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?") · tvOS \(UIDevice.current.systemVersion)")
          .font(.system(size: 18)).foregroundStyle(.white.opacity(0.5))
        ForEach(Array(music.log.enumerated()), id: \.offset) { _, line in
          Text(line).font(.system(size: 17, design: .monospaced)).foregroundStyle(.white.opacity(0.8))
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func songRow(_ song: Song, in list: [Song]) -> some View {
    Button { Task { await music.play(song, in: list) } } label: {
      VStack(alignment: .leading, spacing: 2) {
        Text(song.title).font(.system(size: 22)).lineLimit(1)
        Text(song.artistName).font(.system(size: 18)).foregroundStyle(.secondary).lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  @ViewBuilder
  private var library: some View {
    if let opened = music.openedTitle {
      HStack {
        Button { music.closeList() } label: { Image(systemName: "chevron.left") }
        Text(opened).font(.system(size: 24, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
      }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 6) {
          if music.songs.isEmpty && !music.loading { message("Nothing here.") }
          ForEach(music.songs, id: \.id) { song in songRow(song, in: music.songs) }
        }
      }
    } else {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 10) {
          TextField("Search Apple Music", text: $query)
            .font(.system(size: 22))
            .onSubmit { Task { await music.search(query) } }
          if music.loading { ProgressView().tint(.white) }
          if !music.charts.isEmpty {
            Button { music.openCharts() } label: {
              Text("Top songs on Apple Music").font(.system(size: 22)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          if !music.recentAlbums.isEmpty {
            Text("Recently played").font(.system(size: 20)).foregroundStyle(.white.opacity(0.5)).padding(.top, 8)
            ForEach(music.recentAlbums, id: \.id) { album in
              Button { Task { await music.open(album) } } label: {
                VStack(alignment: .leading, spacing: 2) {
                  Text(album.title).font(.system(size: 22)).lineLimit(1)
                  Text(album.artistName).font(.system(size: 18)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
              }
            }
          }
          Text("Playlists").font(.system(size: 20)).foregroundStyle(.white.opacity(0.5)).padding(.top, 8)
          if music.playlists.isEmpty && !music.loading {
            message("No playlists in your library.")
          }
          ForEach(music.playlists, id: \.id) { playlist in
            Button { Task { await music.open(playlist) } } label: {
              Text(playlist.name).font(.system(size: 22)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        }
      }
    }
  }
}

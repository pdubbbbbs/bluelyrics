// The Apple Music pane: what is playing, transport, and the library to pick from.

import SwiftUI
import MusicKit

struct MusicPanel: View {
  @EnvironmentObject var music: MusicPlayerStore
  @EnvironmentObject var store: LyricsStore
  @Namespace private var panelNamespace

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      nowPlaying
      Divider().overlay(Color.white.opacity(0.15))
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
      Spacer(minLength: 0)
    }
    .padding(28)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color.black.opacity(0.35))
  }

  private func message(_ text: String) -> some View {
    Text(text).font(.system(size: 24)).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
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

  @ViewBuilder
  private var library: some View {
    if let opened = music.openedTitle {
      HStack {
        Button { music.closeList() } label: { Image(systemName: "chevron.left") }
        Text(opened).font(.system(size: 24, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
      }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 6) {
          ForEach(music.songs, id: \.id) { song in
            Button { Task { await music.play(song, in: music.songs) } } label: {
              VStack(alignment: .leading, spacing: 2) {
                Text(song.title).font(.system(size: 22)).lineLimit(1)
                Text(song.artistName).font(.system(size: 18)).foregroundStyle(.secondary).lineLimit(1)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        }
      }
    } else {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 10) {
          if music.loading { ProgressView().tint(.white) }
          if let error = music.error { message(error) }
          if !music.recentAlbums.isEmpty {
            Text("Recently played").font(.system(size: 20)).foregroundStyle(.white.opacity(0.5))
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

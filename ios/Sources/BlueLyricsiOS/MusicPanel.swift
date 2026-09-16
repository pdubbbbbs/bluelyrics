// Apple Music on the device: a compact bar for portrait phones, a side pane
// for landscape and iPad, and a sheet with the library to pick from.

import SwiftUI
import MusicKit

/// Portrait phone: what is playing, transport, and a button to open the library.
struct MusicBar: View {
  @EnvironmentObject var music: MusicPlayerStore
  @EnvironmentObject var store: LyricsStore
  let openLibrary: () -> Void

  var body: some View {
    VStack(spacing: 8) {
      if music.auth != .authorized { AuthPrompt() }
      HStack(spacing: 12) {
        Button(action: openLibrary) {
          HStack(spacing: 10) {
            ArtThumb(size: 44)
            VStack(alignment: .leading, spacing: 2) {
              Text(music.nowTitle.isEmpty ? "Choose music" : music.nowTitle)
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
              Text(music.nowArtist.isEmpty ? "Playlists and recently played" : music.nowArtist)
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Spacer(minLength: 0)
          }
        }
        .buttonStyle(.plain)
        Transport(size: 20)
      }
      .padding(10)
      .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
      .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08)))
    }
  }
}

/// Landscape and iPad: the pane beside the lyrics with the library inline.
struct MusicPanel: View {
  @EnvironmentObject var music: MusicPlayerStore
  @EnvironmentObject var store: LyricsStore

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 12) {
        ArtThumb(size: 72)
        VStack(alignment: .leading, spacing: 3) {
          Text(music.nowTitle.isEmpty ? "Nothing playing" : music.nowTitle)
            .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
          if !music.nowArtist.isEmpty {
            Text(music.nowArtist).font(.system(size: 13)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
          }
          Transport(size: 18)
        }
      }
      Divider().overlay(Color.white.opacity(0.15))
      if music.auth == .authorized { LibraryList() } else { AuthPrompt() }
      Spacer(minLength: 0)
    }
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color.black.opacity(0.35))
  }
}

/// The library as a bottom sheet on portrait phones.
struct LibrarySheet: View {
  @EnvironmentObject var music: MusicPlayerStore
  @EnvironmentObject var store: LyricsStore
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ZStack {
        LinearGradient(colors: [store.theme.bg1, store.theme.bg0], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
        VStack(alignment: .leading, spacing: 12) {
          if music.auth == .authorized { LibraryList() } else { AuthPrompt() }
        }
        .padding(16)
      }
      .navigationTitle(music.openedTitle ?? "Apple Music")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        if music.openedTitle != nil {
          ToolbarItem(placement: .topBarLeading) {
            Button { music.closeList() } label: { Label("Back", systemImage: "chevron.left") }
          }
        }
        ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
      }
    }
  }
}

private struct ArtThumb: View {
  @EnvironmentObject var music: MusicPlayerStore
  @EnvironmentObject var store: LyricsStore
  let size: CGFloat
  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: size * 0.18).fill(Color.white.opacity(0.08))
      if let art = music.artwork {
        Image(uiImage: art).resizable().scaledToFill()
      } else {
        Image(systemName: "music.note").font(.system(size: size * 0.4)).foregroundStyle(.white.opacity(0.4))
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: size * 0.18))
    .shadow(color: store.theme.glow3.opacity(0.5), radius: 8)
  }
}

private struct Transport: View {
  @EnvironmentObject var music: MusicPlayerStore
  let size: CGFloat
  var body: some View {
    HStack(spacing: size * 0.9) {
      Button { music.previous() } label: { Image(systemName: "backward.fill") }
      Button { music.togglePlayPause() } label: { Image(systemName: music.isPlaying ? "pause.fill" : "play.fill") }
        .font(.system(size: size * 1.3))
      Button { music.next() } label: { Image(systemName: "forward.fill") }
    }
    .font(.system(size: size))
    .foregroundStyle(.white)
    .buttonStyle(.plain)
  }
}

private struct AuthPrompt: View {
  @EnvironmentObject var music: MusicPlayerStore
  var body: some View {
    switch music.auth {
    case .authorized: EmptyView()
    case .denied: message("Apple Music access is off for BlueLyrics. Turn it on in Settings, Apps, BlueLyrics.")
    case .restricted: message("Apple Music is restricted on this device.")
    case .unknown:
      VStack(alignment: .leading, spacing: 10) {
        message("BlueLyrics needs access to Apple Music to play your library here.")
        Button("Allow Apple Music") { Task { await music.authorize() } }
          .buttonStyle(.borderedProminent)
      }
    }
  }
  private func message(_ text: String) -> some View {
    Text(text).font(.system(size: 14)).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
  }
}

/// Playlists, recently played albums, and the songs of whichever is open.
private struct LibraryList: View {
  @EnvironmentObject var music: MusicPlayerStore

  var body: some View {
    if let opened = music.openedTitle {
      HStack(spacing: 8) {
        Button { music.closeList() } label: { Image(systemName: "chevron.left") }.foregroundStyle(.white)
        Text(opened).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
      }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 2) {
          ForEach(music.songs, id: \.id) { song in
            Button { Task { await music.play(song, in: music.songs) } } label: {
              VStack(alignment: .leading, spacing: 1) {
                Text(song.title).font(.system(size: 15)).foregroundStyle(.white).lineLimit(1)
                Text(song.artistName).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.vertical, 8).padding(.horizontal, 6)
            }
            .buttonStyle(.plain)
          }
        }
      }
    } else {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 4) {
          if music.loading { ProgressView().tint(.white) }
          if let error = music.error {
            Text(error).font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
          }
          if !music.recentAlbums.isEmpty {
            Text("Recently played").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.5)).padding(.top, 4)
            ForEach(music.recentAlbums, id: \.id) { album in
              Button { Task { await music.open(album) } } label: {
                VStack(alignment: .leading, spacing: 1) {
                  Text(album.title).font(.system(size: 15)).foregroundStyle(.white).lineLimit(1)
                  Text(album.artistName).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8).padding(.horizontal, 6)
              }
              .buttonStyle(.plain)
            }
          }
          Text("Playlists").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.5)).padding(.top, 8)
          if music.playlists.isEmpty && !music.loading {
            Text("No playlists in your library.").font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
          }
          ForEach(music.playlists, id: \.id) { playlist in
            Button { Task { await music.open(playlist) } } label: {
              Text(playlist.name).font(.system(size: 15)).foregroundStyle(.white).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8).padding(.horizontal, 6)
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
  }
}

// The lyric stage on a phone or tablet: the current line large with each word
// lighting up as it is sung and trailing a comet glow, neighbouring lines dimmed.
// Portrait puts the Apple Music controls in a bar along the bottom; landscape
// and iPad widths put them in a pane beside the lyrics, as on Apple TV.

import SwiftUI

struct LyricsView: View {
  @EnvironmentObject var store: LyricsStore
  @EnvironmentObject var music: MusicPlayerStore
  let onLeave: () -> Void
  var showMusicPanel = false
  @State private var lastIndex = -1
  @State private var pulse = false
  @State private var libraryShown = false

  private let context = 2   // lines shown above and below the current one
  private let trail = 3.0   // seconds a sung word keeps glowing

  var body: some View {
    GeometryReader { geo in
      let wide = showMusicPanel && geo.size.width > geo.size.height && geo.size.width >= 700
      let scale = min(1.0, max(0.6, geo.size.width / 430))
      TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
        let pos = store.position(at: timeline.date)
        let idx = store.lineIndex(at: pos)
        ZStack {
          background
          HStack(spacing: 0) {
            VStack(spacing: 0) {
              header
              Spacer(minLength: 12)
              stage(pos: pos, idx: idx, scale: scale)
                .frame(maxHeight: .infinity)
              Spacer(minLength: 12)
              footer(pos: pos)
              if showMusicPanel && !wide {
                MusicBar(openLibrary: { libraryShown = true })
                  .padding(.top, 10)
              }
            }
            .padding(.horizontal, wide ? 24 : 18)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .frame(width: wide ? geo.size.width * 0.68 : geo.size.width, height: geo.size.height)
            if wide {
              MusicPanel().frame(width: geo.size.width * 0.32, height: geo.size.height)
            }
          }
        }
        .onChange(of: idx) { _, new in
          if new != lastIndex {
            lastIndex = new
            withAnimation(.easeOut(duration: 0.25)) { pulse = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { withAnimation(.easeIn(duration: 0.3)) { pulse = false } }
          }
        }
      }
    }
    .sheet(isPresented: $libraryShown) {
      LibrarySheet()
        .environmentObject(music)
        .environmentObject(store)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }
  }

  private var theme: Theme { store.theme }

  private func contextFont(_ scale: CGFloat) -> Font {
    let size = 20 * scale
    if let family = store.fonts.family { return .custom(family, size: size) }
    return .system(size: size, weight: .medium, design: .serif)
  }
  private func displayFont(_ scale: CGFloat) -> Font {
    let size = 36 * scale
    if let family = store.fonts.family { return .custom(family, size: size) }
    return .system(size: size, weight: .semibold, design: .serif)
  }

  private var background: some View {
    ZStack {
      RadialGradient(colors: [theme.bg1, theme.bg0], center: .top, startRadius: 0, endRadius: 900).ignoresSafeArea()
      if let art = store.art {
        Image(uiImage: art)
          .resizable()
          .scaledToFill()
          .blur(radius: 40)
          .opacity(0.35)
          .ignoresSafeArea()
        Rectangle().fill(theme.bg0.opacity(0.45)).ignoresSafeArea()
      }
    }
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 10) {
      Button(action: onLeave) {
        Image(systemName: "chevron.left")
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(.white.opacity(0.8))
          .frame(width: 36, height: 36)
          .background(Color.white.opacity(0.08), in: Circle())
      }
      .accessibilityLabel(showMusicPanel ? "Leave" : "Change Mac")
      Circle()
        .fill(store.isPlaying ? theme.glow2 : store.track.status == "paused" ? Color.yellow : Color.gray)
        .frame(width: 10, height: 10)
        .shadow(color: store.isPlaying ? theme.glow2 : .clear, radius: 6)
      VStack(alignment: .leading, spacing: 1) {
        Text(store.track.title.isEmpty ? "BlueLyrics" : store.track.title)
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(.white)
          .lineLimit(1)
        Text(store.track.artist.isEmpty ? (store.connected || showMusicPanel ? store.track.statusTag : "reconnecting to \(store.host)") : store.track.artist)
          .font(.system(size: 13))
          .foregroundStyle(.white.opacity(0.6))
          .lineLimit(1)
      }
      Spacer()
      Text(store.connected || showMusicPanel ? store.track.statusTag : "reconnecting")
        .font(.system(size: 12))
        .foregroundStyle(store.connected || showMusicPanel ? theme.glow1.opacity(0.8) : Color.orange)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
  }

  @ViewBuilder
  private func stage(pos: Double, idx: Int, scale: CGFloat) -> some View {
    let track = store.track
    VStack(spacing: 16 * scale) {
      if track.status == "off" || track.status == "stopped" {
        idleLine(showMusicPanel ? "Pick something to play" : "Music is idle")
      } else if track.lines.isEmpty {
        Text(track.title).font(displayFont(scale)).foregroundStyle(.white).multilineTextAlignment(.center)
        idleLine(track.lyricsSource == "loading" ? "finding lyrics…" : "no lyrics found")
      } else {
        let from = max(0, idx - context)
        let to = min(track.lines.count - 1, max(idx, 0) + context)
        if idx < 0 { nowLine(text: "♪", words: [], pos: pos, scale: scale) }
        ForEach(from...to, id: \.self) { i in
          let line = track.lines[i]
          if i == idx {
            let words = track.synced && !line.text.isEmpty ? WordTiming.words(for: track.lines, at: i, duration: track.duration) : []
            nowLine(text: line.text.isEmpty ? "♪" : line.text, words: words, pos: pos, scale: scale)
          } else {
            Text(line.text.isEmpty ? "♪" : line.text)
              .font(contextFont(scale))
              .foregroundStyle(.white.opacity(abs(i - idx) > 1 ? 0.22 : 0.45))
              .multilineTextAlignment(.center)
              .lineLimit(2)
              .transition(.opacity)
          }
        }
      }
    }
    .frame(maxWidth: .infinity)
    .scaleEffect(pulse ? 1.015 : 1.0)
    .animation(.easeInOut(duration: 0.25), value: idx)
  }

  private func idleLine(_ text: String) -> some View {
    Text(text).font(.system(size: 22, weight: .light)).foregroundStyle(.white.opacity(0.5))
  }

  @ViewBuilder
  private func nowLine(text: String, words: [TimedWord], pos: Double, scale: CGFloat) -> some View {
    if words.isEmpty {
      Text(text)
        .font(displayFont(scale))
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .shadow(color: theme.glow2.opacity(0.85), radius: 10)
        .shadow(color: theme.glow3.opacity(0.7), radius: 26)
    } else {
      FlowLayout(spacing: 10 * scale, lineSpacing: 6 * scale) {
        ForEach(words) { w in
          wordView(w, pos: pos, scale: scale)
        }
      }
      .frame(maxWidth: .infinity)
    }
  }

  private struct WordStyle {
    var white: Double
    var a1: Double, r1: CGFloat
    var a2: Double, r2: CGFloat
    var a3: Double, r3: CGFloat, x3: CGFloat
    var a4: Double, r4: CGFloat
    var scale: CGFloat
    var singing: Bool
  }

  /// Comet trail: a sung word starts at full brightness and decays over `trail`
  /// seconds, with a streak smeared back toward the words before it.
  private func wordStyle(_ w: TimedWord, pos: Double) -> WordStyle {
    let sung: Bool = pos >= w.end
    let singing: Bool = !sung && pos >= w.start
    if singing {
      return WordStyle(white: 1.0, a1: 1.0, r1: 10, a2: 1.0, r2: 24, a3: 0.45, r3: 14, x3: -10, a4: 0.8, r4: 56, scale: 1.04, singing: true)
    }
    if !sung {
      return WordStyle(white: 0.6, a1: 0, r1: 0, a2: 0, r2: 0, a3: 0, r3: 0, x3: 0, a4: 0, r4: 0, scale: 1.0, singing: false)
    }
    let age: Double = pos - w.end
    let g: Double = max(0, 1 - age / trail)
    let e: Double = g * g
    let white: Double = 0.45 + 0.55 * e
    return WordStyle(white: white,
                     a1: 0.9 * e + 0.1, r1: CGFloat(6 + 8 * e),
                     a2: 0.8 * e, r2: CGFloat(10 + 18 * e),
                     a3: 0.45 * e, r3: CGFloat(8 + 12 * e), x3: CGFloat(-(0.3 + 0.5 * e) * 20),
                     a4: 0.5 * e, r4: CGFloat(28 + 28 * e),
                     scale: 1.0, singing: false)
  }

  private func wordView(_ w: TimedWord, pos: Double, scale: CGFloat) -> some View {
    let st = wordStyle(w, pos: pos)
    let base = Text(w.text).font(displayFont(scale)).foregroundStyle(Color.white.opacity(st.white))
    let glow1 = base.shadow(color: theme.glow1.opacity(st.a1), radius: st.r1)
    let glow2 = glow1.shadow(color: theme.glow2.opacity(st.a2), radius: st.r2)
    let streak = glow2.shadow(color: theme.glow2.opacity(st.a3), radius: st.r3, x: st.x3, y: 0)
    let glow3 = streak.shadow(color: theme.glow3.opacity(st.a4), radius: st.r4)
    return glow3
      .scaleEffect(st.scale)
      .animation(.easeOut(duration: 0.12), value: st.singing)
  }

  private func footer(pos: Double) -> some View {
    let duration = store.track.duration
    let fraction = duration > 0 ? min(1, max(0, pos / duration)) : 0
    return VStack(spacing: 6) {
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          Capsule().fill(Color.white.opacity(0.12)).frame(height: 4)
          Capsule().fill(theme.glow2).frame(width: geo.size.width * fraction, height: 4)
            .shadow(color: theme.glow2.opacity(0.8), radius: 5)
        }
      }
      .frame(height: 4)
      HStack {
        Text(Self.fmt(pos)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
        Spacer()
        Text(Self.fmt(duration)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
      }
    }
  }

  static func fmt(_ s: Double) -> String {
    let v = max(0, Int(s))
    return String(format: "%d:%02d", v / 60, v % 60)
  }
}

/// Lays words out left to right, wrapping to new rows, each row centred.
struct FlowLayout: Layout {
  var spacing: CGFloat = 20
  var lineSpacing: CGFloat = 10

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = arrange(proposal: proposal, subviews: subviews)
    let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
    let width = rows.map(\.width).max() ?? 0
    return CGSize(width: proposal.width ?? width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let rows = arrange(proposal: proposal, subviews: subviews)
    var y = bounds.minY
    for row in rows {
      var x = bounds.minX + (bounds.width - row.width) / 2
      for item in row.items {
        let size = subviews[item].sizeThatFits(.unspecified)
        subviews[item].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
        x += size.width + spacing
      }
      y += row.height + lineSpacing
    }
  }

  private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

  private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
    let maxWidth = proposal.width ?? .infinity
    var rows: [Row] = [Row()]
    for (i, view) in subviews.enumerated() {
      let size = view.sizeThatFits(.unspecified)
      var row = rows[rows.count - 1]
      let extra = row.items.isEmpty ? 0 : spacing
      if !row.items.isEmpty && row.width + extra + size.width > maxWidth {
        rows.append(Row(items: [i], width: size.width, height: size.height))
      } else {
        row.items.append(i); row.width += extra + size.width; row.height = max(row.height, size.height)
        rows[rows.count - 1] = row
      }
    }
    return rows
  }
}

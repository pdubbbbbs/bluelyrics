// The lyric stage: the current line large with each word lighting up as it is
// sung and trailing a comet glow, neighbouring lines dimmed above and below.

import SwiftUI

struct LyricsView: View {
  @EnvironmentObject var store: LyricsStore
  @EnvironmentObject var music: MusicPlayerStore
  let onDisconnect: () -> Void
  var showMusicPanel = false
  @State private var lastIndex = -1
  @State private var pulse = false
  @FocusState private var focused: Bool

  private let context = 2   // lines shown above and below the current one
  private let trail = 3.0   // seconds a sung word keeps glowing

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
      let pos = store.position(at: timeline.date)
      let idx = store.lineIndex(at: pos)
      ZStack {
        background
        GeometryReader { geo in
          HStack(spacing: 0) {
            VStack(spacing: 0) {
              header
              Spacer(minLength: 20)
              stage(pos: pos, idx: idx)
              Spacer(minLength: 20)
              footer(pos: pos)
            }
            .padding(.horizontal, showMusicPanel ? 60 : 90)
            .padding(.vertical, 60)
            .frame(width: showMusicPanel ? geo.size.width * 0.75 : geo.size.width, height: geo.size.height)
            if showMusicPanel {
              MusicPanel().frame(width: geo.size.width * 0.25, height: geo.size.height)
            }
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
    .ignoresSafeArea()
    // In Mac mode nothing on screen takes focus, so the stage itself does, which lets Menu work.
    // In Apple TV mode the music pane's buttons own focus; making the whole screen focusable
    // would light every control at once when Select is pressed.
    .focusable(!showMusicPanel)
    .focused($focused)
    .onAppear { if !showMusicPanel { focused = true } }
    .onExitCommand { onDisconnect() }
    .onPlayPauseCommand { if showMusicPanel { music.togglePlayPause() } }
  }

  private var theme: Theme { store.theme }
  private var contextFont: Font {
    if let family = store.fonts.family { return .custom(family, size: 48) }
    return .system(size: 48, weight: .medium, design: .serif)
  }
  private var displayFont: Font {
    if let family = store.fonts.family { return .custom(family, size: showMusicPanel ? 76 : 96) }
    return .system(size: showMusicPanel ? 76 : 96, weight: .semibold, design: .serif)
  }
  private var stageFontSize: CGFloat { showMusicPanel ? 76 : 96 }

  private var background: some View {
    ZStack {
      RadialGradient(colors: [theme.bg1, theme.bg0], center: .top, startRadius: 0, endRadius: 1400).ignoresSafeArea()
      if let art = store.art {
        Image(uiImage: art)
          .resizable()
          .scaledToFill()
          .blur(radius: 60)
          .opacity(0.35)
          .ignoresSafeArea()
        Rectangle().fill(theme.bg0.opacity(0.45)).ignoresSafeArea()
      }
    }
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 18) {
      Circle()
        .fill(store.isPlaying ? theme.glow2 : store.track.status == "paused" ? Color.yellow : Color.gray)
        .frame(width: 18, height: 18)
        .shadow(color: store.isPlaying ? theme.glow2 : .clear, radius: 10)
      Text(store.track.title.isEmpty ? "BlueLyrics" : store.track.title)
        .font(.system(size: 34, weight: .semibold))
        .foregroundStyle(.white)
        .lineLimit(1)
      if !store.track.artist.isEmpty {
        Text("· " + store.track.artist).font(.system(size: 30)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
      }
      Spacer()
      Text(store.connected || showMusicPanel ? store.track.statusTag : "reconnecting to \(store.host)")
        .font(.system(size: 24))
        .foregroundStyle(store.connected || showMusicPanel ? theme.glow1.opacity(0.8) : Color.orange)
    }
  }

  @ViewBuilder
  private func stage(pos: Double, idx: Int) -> some View {
    let track = store.track
    VStack(spacing: 28) {
      if track.status == "off" || track.status == "stopped" {
        idleLine("Music is idle")
      } else if track.lines.isEmpty {
        Text(track.title).font(displayFont).foregroundStyle(.white).multilineTextAlignment(.center)
        idleLine(track.lyricsSource == "loading" ? "finding lyrics…" : "no lyrics found")
      } else {
        let from = max(0, idx - context)
        let to = min(track.lines.count - 1, max(idx, 0) + context)
        if idx < 0 { nowLine(text: "♪", words: [], pos: pos) }
        ForEach(from...to, id: \.self) { i in
          let line = track.lines[i]
          if i == idx {
            let words = track.synced && !line.text.isEmpty ? WordTiming.words(for: track.lines, at: i, duration: track.duration) : []
            nowLine(text: line.text.isEmpty ? "♪" : line.text, words: words, pos: pos)
          } else {
            Text(line.text.isEmpty ? "♪" : line.text)
              .font(contextFont)
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
    Text(text).font(.system(size: 44, weight: .light)).foregroundStyle(.white.opacity(0.5))
  }

  @ViewBuilder
  private func nowLine(text: String, words: [TimedWord], pos: Double) -> some View {
    if words.isEmpty {
      Text(text)
        .font(displayFont)
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .shadow(color: theme.glow2.opacity(0.85), radius: 18)
        .shadow(color: theme.glow3.opacity(0.7), radius: 46)
    } else {
      FlowLayout(spacing: 26, lineSpacing: 12) {
        ForEach(words) { w in
          wordView(w, pos: pos)
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
      return WordStyle(white: 1.0, a1: 1.0, r1: 22, a2: 1.0, r2: 50, a3: 0.45, r3: 30, x3: -20, a4: 0.8, r4: 120, scale: 1.04, singing: true)
    }
    if !sung {
      return WordStyle(white: 0.6, a1: 0, r1: 0, a2: 0, r2: 0, a3: 0, r3: 0, x3: 0, a4: 0, r4: 0, scale: 1.0, singing: false)
    }
    let age: Double = pos - w.end
    let g: Double = max(0, 1 - age / trail)
    let e: Double = g * g
    let white: Double = 0.45 + 0.55 * e
    return WordStyle(white: white,
                     a1: 0.9 * e + 0.1, r1: CGFloat(14 + 16 * e),
                     a2: 0.8 * e, r2: CGFloat(20 + 40 * e),
                     a3: 0.45 * e, r3: CGFloat(18 + 24 * e), x3: CGFloat(-(0.3 + 0.5 * e) * 40),
                     a4: 0.5 * e, r4: CGFloat(60 + 60 * e),
                     scale: 1.0, singing: false)
  }

  private func wordView(_ w: TimedWord, pos: Double) -> some View {
    let st = wordStyle(w, pos: pos)
    let base = Text(w.text).font(displayFont).foregroundStyle(Color.white.opacity(st.white))
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
    return VStack(spacing: 10) {
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          Capsule().fill(Color.white.opacity(0.12)).frame(height: 6)
          Capsule().fill(theme.glow2).frame(width: geo.size.width * fraction, height: 6)
            .shadow(color: theme.glow2.opacity(0.8), radius: 8)
        }
      }
      .frame(height: 6)
      HStack {
        Text(Self.fmt(pos)).font(.system(size: 24, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
        Spacer()
        Text(showMusicPanel ? "Menu to leave" : "Menu to change Mac").font(.system(size: 22)).foregroundStyle(.white.opacity(0.35))
        Spacer()
        Text(Self.fmt(duration)).font(.system(size: 24, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
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

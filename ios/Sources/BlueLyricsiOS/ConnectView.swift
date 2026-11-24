// First screen: play Apple Music on this device, or follow a Mac running BlueLyrics.

import SwiftUI

struct ConnectView: View {
  @EnvironmentObject var store: LyricsStore
  @EnvironmentObject var discovery: Discovery
  @State private var address = UserDefaults.standard.string(forKey: LyricsStore.hostKey) ?? ""
  @FocusState private var addressFocused: Bool
  let onConnected: () -> Void
  let onDevice: () -> Void

  private var deviceName: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }

  var body: some View {
    ZStack {
      LinearGradient(colors: [store.theme.bg1, store.theme.bg0], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
      ScrollView {
        VStack(spacing: 28) {
          VStack(spacing: 8) {
            Text("BlueLyrics")
              .font(.system(size: 44, weight: .bold, design: .serif))
              .foregroundStyle(.white)
              .shadow(color: store.theme.glow2.opacity(0.85), radius: 12)
              .shadow(color: store.theme.glow3.opacity(0.7), radius: 30)
            Text("Word-synced lyrics for what you play.")
              .font(.subheadline)
              .foregroundStyle(.white.opacity(0.7))
          }
          .padding(.top, 36)

          card {
            Text("Play on this \(deviceName)").font(.headline).foregroundStyle(.white.opacity(0.7))
            Button(action: onDevice) {
              HStack(spacing: 12) {
                Image(systemName: "music.note")
                Text("Apple Music here, lyrics on screen")
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.4))
              }
            }
            .buttonStyle(RowButtonStyle(tint: store.theme.glow2))
            Text("Plays your Apple Music library on this \(deviceName), with each word lighting up as it is sung.")
              .font(.footnote).foregroundStyle(.white.opacity(0.5))
          }

          card {
            Text("Follow a Mac running BlueLyrics").font(.headline).foregroundStyle(.white.opacity(0.7))
            if !discovery.found.isEmpty {
              ForEach(discovery.found) { mac in
                Button { connect(mac.host) } label: {
                  HStack(spacing: 12) {
                    Image(systemName: "desktopcomputer")
                    Text(mac.name).lineLimit(1)
                    Spacer()
                    Text(mac.host).font(.footnote).foregroundStyle(.white.opacity(0.5))
                  }
                }
                .buttonStyle(RowButtonStyle(tint: store.theme.glow2))
              }
            } else {
              HStack(spacing: 10) {
                ProgressView().tint(.white.opacity(0.6))
                Text("Looking for Macs on your network…").font(.footnote).foregroundStyle(.white.opacity(0.5))
              }
            }
            Text(discovery.found.isEmpty ? "Or type the Mac's address. It is shown by the ♪ menu on the Mac under Open in browser, for example 192.168.1.50:7331." : "Or type the address.")
              .font(.footnote).foregroundStyle(.white.opacity(0.5))
            HStack(spacing: 10) {
              TextField("192.168.1.50:7331", text: $address)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($addressFocused)
                .submitLabel(.go)
                .onSubmit { connect(address) }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.white)
              Button("Connect") { connect(address) }
                .buttonStyle(.borderedProminent)
                .tint(store.theme.glow3)
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
          }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 40)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
      }
      .scrollDismissesKeyboard(.interactively)
    }
    .onAppear { discovery.start() }
    .onDisappear { discovery.stop() }
  }

  @ViewBuilder
  private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 12, content: content)
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
      .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08)))
  }

  private func connect(_ raw: String) {
    var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    host = host.replacingOccurrences(of: "http://", with: "").replacingOccurrences(of: "https://", with: "")
    while host.hasSuffix("/") { host.removeLast() }
    guard !host.isEmpty else { return }
    if !host.contains(":") || (host.hasPrefix("[") && !host.contains("]:")) { host += ":7331" }
    addressFocused = false
    store.connect(to: host)
    onConnected()
  }
}

/// A full-width row that dims when pressed, tinted with the current theme.
struct RowButtonStyle: ButtonStyle {
  var tint: Color
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.body.weight(.medium))
      .foregroundStyle(.white)
      .padding(.horizontal, 14).padding(.vertical, 12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(tint.opacity(configuration.isPressed ? 0.35 : 0.18), in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.35)))
  }
}

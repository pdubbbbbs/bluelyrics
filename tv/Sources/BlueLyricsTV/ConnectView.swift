// Pick the Mac to follow: one found on the network, or an address typed in.

import SwiftUI

struct ConnectView: View {
  @EnvironmentObject var store: LyricsStore
  @EnvironmentObject var discovery: Discovery
  @State private var address = UserDefaults.standard.string(forKey: LyricsStore.hostKey) ?? ""
  let onConnected: () -> Void
  let onAppleTV: () -> Void

  var body: some View {
    ZStack {
      LinearGradient(colors: [store.theme.bg1, store.theme.bg0], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
      VStack(spacing: 40) {
        VStack(spacing: 12) {
          Text("BlueLyrics")
            .font(.system(size: 76, weight: .bold, design: .serif))
            .foregroundStyle(.white)
            .shadow(color: store.theme.glow2.opacity(0.85), radius: 18)
            .shadow(color: store.theme.glow3.opacity(0.7), radius: 46)
          Text("Word-synced lyrics for what you play.")
            .font(.title3)
            .foregroundStyle(.white.opacity(0.7))
        }

        VStack(alignment: .leading, spacing: 16) {
          Text("Play on this Apple TV").font(.headline).foregroundStyle(.white.opacity(0.6))
          Button { onAppleTV() } label: {
            HStack {
              Image(systemName: "appletv.fill")
              Text("Apple Music here, lyrics beside it")
              Spacer()
            }
            .frame(maxWidth: 900)
          }
          Text("Plays your Apple Music library on the TV, with the lyrics filling three quarters of the screen.")
            .font(.callout).foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: 1100)

        Text("Or follow a Mac running BlueLyrics").font(.headline).foregroundStyle(.white.opacity(0.6)).frame(maxWidth: 1100, alignment: .leading)

        if !discovery.found.isEmpty {
          VStack(alignment: .leading, spacing: 16) {
            Text("On your network").font(.headline).foregroundStyle(.white.opacity(0.6))
            ForEach(discovery.found) { mac in
              Button {
                connect(mac.host)
              } label: {
                HStack {
                  Image(systemName: "desktopcomputer")
                  Text(mac.name)
                  Spacer()
                  Text(mac.host).foregroundStyle(.secondary).font(.callout)
                }
                .frame(maxWidth: 900)
              }
            }
          }
        }

        VStack(alignment: .leading, spacing: 16) {
          Text(discovery.found.isEmpty ? "Address of the Mac running BlueLyrics" : "Or type the address").font(.headline).foregroundStyle(.white.opacity(0.6))
          Text("It is printed by the ♪ menu on the Mac under Open in browser, for example 10.10.10.169:7331.")
            .font(.callout).foregroundStyle(.white.opacity(0.5))
          HStack(spacing: 24) {
            TextField("10.10.10.169:7331", text: $address)
              .keyboardType(.numbersAndPunctuation)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .frame(maxWidth: 700)
              .onSubmit { connect(address) }
            Button("Connect") { connect(address) }
              .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
          }
        }
        .frame(maxWidth: 1100)
      }
      .padding(80)
    }
    .onAppear { discovery.start() }
    .onDisappear { discovery.stop() }
  }

  private func connect(_ raw: String) {
    var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    host = host.replacingOccurrences(of: "http://", with: "").replacingOccurrences(of: "https://", with: "")
    while host.hasSuffix("/") { host.removeLast() }
    guard !host.isEmpty else { return }
    if !host.contains(":") || (host.hasPrefix("[") && !host.contains("]:")) { host += ":7331" }
    store.connect(to: host)
    onConnected()
  }
}

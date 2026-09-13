# BlueLyrics for Apple TV

Two modes, chosen on the first screen.

**Play on this Apple TV** (split screen, lyrics 75 percent, Apple Music pane 25 percent): the TV plays
the user's Apple Music library itself through MusicKit (`MusicPlayerStore.swift`, `MusicPanel.swift`),
looks up lyrics for each song on LRCLIB (`LyricsFetcher.swift`, same lookup order and LRC parser as the
Mac app) and feeds the same lyric stage. tvOS cannot embed or overlay the real Music app, so the pane is
BlueLyrics' own: artwork, title, previous/play/next, recently played albums and playlists, and the
tracks of whichever one is opened. Needs an Apple Music subscription on the Apple TV, and the App ID
`com.blueguard.bluelyrics.tv` must have the MusicKit app service enabled in the developer portal
before playback works on a real device. The simulator has no Apple Music account, so only the layout
and the permission prompt were verified there.

**Follow a Mac**: a native client for the BlueLyrics server the Mac app runs on port 7331.
Apple TV has no web view, so instead of loading the Cast page it reads the same
`/events` stream (track, pos, prefs), fetches `/art` and the display font from `/fonts/`,
and renders the word-synced lyrics itself with the same per-word timing estimate
and comet glow as the Mac page. Verified end to end in the simulator against a dev copy of the Mac server.

- `project.yml` — xcodegen definition. Run `xcodegen generate` to (re)create `BlueLyricsTV.xcodeproj`.
- `Sources/BlueLyricsTV/` — SwiftUI app: `Store.swift` (connection, position interpolation,
  Bonjour discovery), `SSEClient.swift`, `LyricsView.swift`, `ConnectView.swift`, `Models.swift`.
- Discovery uses `_bluelyrics._tcp`; the Mac server advertises it from the `HTTPServer.start()`
  change in `app/Sources/BlueLyrics/HTTPServer.swift`. Until a Mac build carrying that change is
  running, type the address shown by the Mac's ♪ menu (for example `10.10.10.169:7331`).
- Menu button on the remote returns to the connect screen.

Build for the simulator without signing:

```
DEVELOPER_DIR=/Volumes/cloud/dubsf3/Applications/Xcode.app/Contents/Developer \
  $DEVELOPER_DIR/usr/bin/xcodebuild -project BlueLyricsTV.xcodeproj -scheme BlueLyricsTV \
  -sdk appletvsimulator -destination 'generic/platform=tvOS Simulator' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

Not done yet: a tvOS layered app icon (Assets.xcassets has none), and a test on real Apple TV hardware.

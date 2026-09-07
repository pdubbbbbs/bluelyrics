# LyricGlow

A floating, glowing lyrics window for Music.app (and YouTube / YouTube Music
through a small Brave extension), styled after bluetoothdefense.com. Lyrics
are synced per line from LRCLIB and lit per word inside each line. The same
page can be opened by any browser on the LAN, so it goes wherever you cast.

## Start / stop

    ./lyricglow.sh start          # server + one window, left half of the main display
    ./lyricglow.sh start --all    # a window on every display
    ./lyricglow.sh stop
    ./lyricglow.sh status         # what is running, plus the cast addresses
    ./lyricglow.sh server         # server only (cast-only use, no window)

The menu-bar ♪ item lists every display; pick one to open or close a window
there, or "Show on every display". Quit from that menu.

## In the window

Normal macOS window buttons, drag by the top edge, resize from the corners.
The control bar has: text size, context lines, sync later/sooner, fill this
screen (Esc undoes it), next display, all displays, on top, glass, cast
(shows the LAN address in big type), hide, close. Keyboard: + and - size,
[ and ] sync, l lines, f fill, h hide bar, c cast.

## Casting to other screens, and the guest address

The lyrics page is served on the local network. Guests on the house Wi-Fi
open this address in any browser, on a phone, tablet, laptop or TV browser:

    http://10.10.10.169:7331/

(That is the Mac's wired address. On Wi-Fi the Mac also answers at
http://10.10.31.123:7331/. `./lyricglow.sh url` prints whatever is current,
and the Cast button in the window shows it in large type for the room.)

Double-click the page for full screen. Text size, sync offset and line count
are remembered per browser. To put it on a Chromecast or AirPlay screen, open
the address in a Brave or Chrome tab and cast that tab. Nothing leaves the
LAN; there is no account and no login.

## YouTube and YouTube Music

Load the `extension` folder once in Brave: brave://extensions, turn on
Developer mode, "Load unpacked", choose `extension/`. It reports the playing
video (title, artist, position from the video element itself) to the server.
The server follows whichever source started playing most recently, so
pressing play on YouTube takes over from Music and vice versa. YouTube titles
are cleaned ("Artist - Song (Official Video)" becomes artist + song) before
the lyric lookup.

## Apple Music word timing (best source)

With the extension loaded, open https://music.apple.com in Brave while
signed in. The extension reads the session tokens the site already uses and
hands them to the server (stored with owner-only permissions in
~/Library/Application Support/LyricGlow/apple-tokens.json). From then on
lyrics come from Apple first, with real per-word timing where Apple has it;
the badge reads "synced · word timing". If the token expires, the log says
so; reopen music.apple.com once.

## Lyrics

Order: timed lyrics embedded in the Music track, Apple Music (word-timed,
then line-timed), LRCLIB synced, NetEase synced, LRCLIB plain, embedded plain.
Titles are cleaned of "(feat. …)", "[Remastered]" and similar before lookup.
Results are cached under `cache/`. Without Apple, word timing is estimated from syllables inside each synced
line. Sung words fade out over two seconds (the comet trail).
Tracks with no lyrics anywhere (live intros, instrumentals) show the title.

## Files

- `server.py` — Python 3 stdlib server on port 7331: Music.app polling via
  AppleScript, LRCLIB lookup, `/events` stream, `/state`, `/art`, `/info`,
  `POST /report` for the extension, `--demo FILE` to replay a cached lyric file.
- `static/index.html` — the page.
- `LyricGlow.swift` + `Info.plist` — native floating window app (built by
  `lyricglow.sh build`). `LyricGlow.v1-fullscreen-default.swift` is the first
  version, kept for reference; `server.v1-music-only.py` likewise.
- `extension/` — Brave/Chrome MV3 reporter for YouTube and YouTube Music.

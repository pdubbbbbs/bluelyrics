#!/usr/bin/env python3
"""LyricGlow server: streams the Music.app now-playing state and lyrics.

Polls Music.app through AppleScript, resolves lyrics (embedded first, then
LRCLIB synced/plain), caches them on disk, and serves a glowing lyrics page
plus a Server-Sent Events feed that any browser on the LAN can open.

Endpoints:
  /            the lyrics page (static/index.html)
  /events      SSE stream: "track" on change, "pos" every poll
  /state       current state as JSON (polling fallback)
  /art         current track artwork (JPEG/PNG) or 404
  /health      plain "ok"
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import re
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import asdict, dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent
STATIC = ROOT / "static"
CACHE = Path(os.environ.get("LYRICGLOW_CACHE", ROOT / "cache"))
ART_PATH = CACHE / "current-art.bin"
LRCLIB = "https://lrclib.net/api"
USER_AGENT = "LyricGlow/0.1 (github.com/pdubbbbbs)"
POLL_SECONDS = 0.3

log = logging.getLogger("lyricglow")

POLL_SCRIPT = """
if application "Music" is not running then return "off"
tell application "Music"
  set pstate to (player state as text)
  if pstate is "stopped" then return "stopped"
  set t to current track
  return (persistent ID of t) & tab & (name of t) & tab & (artist of t) & tab & (album of t) & tab & (duration of t) & tab & (player position) & tab & pstate
end tell
"""

LYRICS_SCRIPT = """
tell application "Music"
  set t to current track
  if (persistent ID of t) is not "{pid}" then return ""
  return lyrics of t
end tell
"""

ART_SCRIPT = """
tell application "Music"
  set t to current track
  if (persistent ID of t) is not "{pid}" then return "mismatch"
  if (count of artworks of t) is 0 then return "none"
  set d to raw data of artwork 1 of t
  set f to open for access POSIX file "{path}" with write permission
  set eof f to 0
  write d to f
  close access f
  return "ok"
end tell
"""


@dataclass
class TrackState:
  """Everything a client needs to render the current moment."""

  status: str = "off"  # off | stopped | paused | playing
  source: str = "music"  # music | youtube | demo
  pid: str = ""
  title: str = ""
  artist: str = ""
  album: str = ""
  duration: float = 0.0
  position: float = 0.0
  lyrics_source: str = "none"  # none | music | lrclib
  synced: bool = False
  lines: list[dict] = field(default_factory=list)
  has_art: bool = False
  art_version: int = 0
  polled_at: float = 0.0


def run_osascript(script: str, timeout: float = 8.0) -> str:
  """Run an AppleScript and return stdout, empty string on failure."""
  try:
    result = subprocess.run(
      ["osascript", "-e", script],
      capture_output=True,
      text=True,
      timeout=timeout,
      check=False,
    )
  except subprocess.TimeoutExpired:
    log.warning("osascript timed out")
    return ""
  if result.returncode != 0:
    log.debug("osascript error: %s", result.stderr.strip())
    return ""
  return result.stdout.rstrip("\n")


LRC_TIME = re.compile(r"\[(\d+):(\d+(?:\.\d+)?)\]")


def parse_lrc(text: str) -> list[dict]:
  """Turn LRC text into [{t: seconds, text: str}] sorted by time."""
  lines: list[dict] = []
  for raw in text.splitlines():
    stamps = LRC_TIME.findall(raw)
    if not stamps:
      continue
    body = LRC_TIME.sub("", raw).strip()
    for minutes, seconds in stamps:
      lines.append({"t": int(minutes) * 60 + float(seconds), "text": body})
  lines.sort(key=lambda item: item["t"])
  return lines


def parse_plain(text: str) -> list[dict]:
  """Turn plain lyrics into untimed lines, collapsing blank runs."""
  lines: list[dict] = []
  blank = False
  for raw in text.splitlines():
    body = raw.strip()
    if not body:
      blank = True
      continue
    if blank and lines:
      lines.append({"t": None, "text": ""})
    blank = False
    lines.append({"t": None, "text": body})
  return lines


def lrclib_get(params: dict) -> dict | None:
  """Call one LRCLIB endpoint, returning parsed JSON or None."""
  url = f"{LRCLIB}/{params.pop('_endpoint')}?{urllib.parse.urlencode(params)}"
  request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
  try:
    with urllib.request.urlopen(request, timeout=10) as response:
      return json.load(response)
  except (urllib.error.URLError, json.JSONDecodeError, TimeoutError) as exc:
    log.info("lrclib miss for %s: %s", url, exc)
    return None


TITLE_NOISE = re.compile(
  r"\s*[\(\[][^\)\]]*(feat\.|ft\.|featuring|remaster|remix|version|edit|mix|live|mono|stereo|deluxe|bonus)[^\)\]]*[\)\]]",
  re.IGNORECASE,
)


def clean_title(title: str) -> str:
  """Strip '(feat. X)', '[Remastered]' style suffixes that defeat lookups."""
  cleaned = TITLE_NOISE.sub("", title)
  cleaned = re.sub(r"\s+-\s+(feat\.|ft\.).*$", "", cleaned, flags=re.IGNORECASE)
  return cleaned.strip() or title


def best_candidate(hits: list[dict], duration: float) -> dict | None:
  """Prefer synced lyrics whose duration is closest to the playing track."""
  usable = [h for h in hits if isinstance(h, dict) and (h.get("syncedLyrics") or h.get("plainLyrics"))]
  if not usable:
    return None

  def rank(hit: dict) -> tuple:
    gap = abs(float(hit.get("duration") or 0) - duration) if duration else 0
    return (0 if hit.get("syncedLyrics") else 1, 0 if gap <= 6 else 1, gap)

  return sorted(usable, key=rank)[0]


def fetch_lrclib(state: TrackState) -> tuple[str, bool, list[dict]]:
  """Resolve lyrics from LRCLIB: exact match, then cleaned title, then search."""
  titles = [state.title]
  cleaned = clean_title(state.title)
  if cleaned != state.title:
    titles.append(cleaned)
  hits: list[dict] = []
  for title in titles:
    exact = lrclib_get({
      "_endpoint": "get",
      "artist_name": state.artist,
      "track_name": title,
      "album_name": state.album,
      "duration": int(round(state.duration)),
    })
    if isinstance(exact, dict):
      hits.append(exact)
      break
  if not hits:
    for title in titles:
      found = lrclib_get({"_endpoint": "search", "track_name": title, "artist_name": state.artist})
      if isinstance(found, list) and found:
        hits.extend(found)
        break
  if not hits:
    found = lrclib_get({"_endpoint": "search", "q": f"{state.artist} {cleaned}"})
    if isinstance(found, list):
      hits.extend(found)
  hit = best_candidate(hits, state.duration)
  if hit is None:
    return "none", False, []
  if hit.get("syncedLyrics"):
    return "lrclib", True, parse_lrc(hit["syncedLyrics"])
  return "lrclib", False, parse_plain(hit["plainLyrics"])


WEB_NOISE = re.compile(
  r"\s*[\(\[][^\)\]]*(official|video|audio|lyrics?|lyric video|visuali[sz]er|hd|hq|4k|mv|m/v|"
  r"explicit|clean|live|remaster|prod\.?)[^\)\]]*[\)\]]",
  re.IGNORECASE,
)


def clean_web_metadata(title: str, artist: str) -> tuple[str, str]:
  """Normalise YouTube-style titles: strip '(Official Video)', split 'Artist - Song'."""
  title = WEB_NOISE.sub("", title)
  title = re.sub(r"\s*\|.*$", "", title).strip(" -–|")
  artist = re.sub(r"\s*-\s*Topic$", "", artist, flags=re.IGNORECASE)
  artist = re.sub(r"VEVO$", "", artist, flags=re.IGNORECASE).strip()
  if " - " in title:
    left, right = [part.strip() for part in title.split(" - ", 1)]
    if left and right and (not artist or artist.lower() in left.lower() or artist.lower() not in title.lower()):
      artist, title = left, right
  return title.strip(), artist.strip()


def download_art(url: str) -> bool:
  """Save a web thumbnail to ART_PATH; returns True on success."""
  if not url.startswith("https://"):
    return False
  request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
  try:
    with urllib.request.urlopen(request, timeout=10) as response:
      ART_PATH.write_bytes(response.read())
    return True
  except (urllib.error.URLError, TimeoutError, OSError) as exc:
    log.info("art download failed: %s", exc)
    return False


def lan_addresses() -> list[str]:
  """Return this Mac's non-loopback IPv4 addresses (for cast URLs)."""
  try:
    output = subprocess.run(["ifconfig"], capture_output=True, text=True, timeout=5, check=False).stdout
  except (OSError, subprocess.TimeoutExpired):
    return []
  found = re.findall(r"inet (\d+\.\d+\.\d+\.\d+)", output)
  return [ip for ip in found if not ip.startswith("127.")]


class Monitor(threading.Thread):
  """Background poller that owns the TrackState and notifies listeners."""

  def __init__(self) -> None:
    super().__init__(daemon=True, name="music-monitor")
    self.state = TrackState()
    self.lock = threading.Lock()
    self.listeners: set[threading.Event] = set()
    self.version = 0
    self.failures = 0
    self.external: dict | None = None
    self.external_playing_since = 0.0
    self.music_playing_since = 0.0
    self.music_last_status = ""
    self.music_last_pid = ""
    CACHE.mkdir(parents=True, exist_ok=True)

  def subscribe(self) -> threading.Event:
    event = threading.Event()
    with self.lock:
      self.listeners.add(event)
    return event

  def unsubscribe(self, event: threading.Event) -> None:
    with self.lock:
      self.listeners.discard(event)

  def snapshot(self) -> dict:
    with self.lock:
      return asdict(self.state)

  def _notify(self) -> None:
    with self.lock:
      self.version += 1
      for event in self.listeners:
        event.set()

  demo: dict | None = None  # {"lines", "synced", "duration", "started"} when replaying

  def run(self) -> None:
    while True:
      try:
        self._demo_tick() if self.demo else self._poll_once()
      except Exception:  # noqa: BLE001 - keep the poller alive, log everything
        log.exception("poll failed")
      time.sleep(POLL_SECONDS)

  def _demo_tick(self) -> None:
    """Replay a cached lyrics file on a loop, no Music.app needed."""
    demo = self.demo or {}
    position = (time.time() - demo["started"]) % demo["duration"]
    with self.lock:
      first = not self.state.pid
      self.state.status = "playing"
      self.state.pid = "demo"
      self.state.title = demo.get("title", "Demo track")
      self.state.artist = demo.get("artist", "LyricGlow demo")
      self.state.duration = demo["duration"]
      self.state.position = position
      self.state.lyrics_source = "demo"
      self.state.synced = demo["synced"]
      self.state.lines = demo["lines"]
      self.state.polled_at = time.time()
    self._notify()

  # ---- external sources (browser extension reports) ----

  def report(self, payload: dict) -> None:
    """Accept a now-playing report from the browser extension."""
    status = payload.get("status", "paused")
    with self.lock:
      previous = self.external
      self.external = {
        "source": str(payload.get("source", "youtube")),
        "pid": f"{payload.get('source', 'youtube')}:{payload.get('id', '')}",
        "title": str(payload.get("title", "")).strip(),
        "artist": str(payload.get("artist", "")).strip(),
        "album": str(payload.get("album", "")).strip(),
        "duration": float(payload.get("duration") or 0),
        "position": float(payload.get("position") or 0),
        "status": status if status in ("playing", "paused") else "paused",
        "art": str(payload.get("art", "")),
        "at": time.time(),
      }
      started = previous is None or previous["status"] != "playing" or previous["pid"] != self.external["pid"]
      if self.external["status"] == "playing" and started:
        self.external_playing_since = time.time()

  def _read_music(self) -> dict | None:
    """Poll Music.app. Returns a reading dict, or None if Music is busy."""
    raw = run_osascript(POLL_SCRIPT, timeout=4)
    if raw == "":
      # Music is busy (modal dialog, launch, sync). Keep the last known state
      # instead of flapping to "off"; give up only after ~10 s of silence.
      self.failures += 1
      if self.failures < 8:
        return None
      raw = "off"
    else:
      self.failures = 0
    if raw in ("off", "stopped"):
      return {"source": "music", "status": raw}
    parts = raw.split("\t")
    if len(parts) != 7:
      log.warning("unexpected poll output: %r", raw)
      return None
    pid, title, artist, album, duration, position, status = parts
    reading = {"source": "music", "pid": pid, "title": title, "artist": artist, "album": album,
               "duration": float(duration or 0), "position": float(position or 0), "status": status}
    if status == "playing" and (self.music_last_status != "playing" or self.music_last_pid != pid):
      self.music_playing_since = time.time()
    self.music_last_status, self.music_last_pid = status, pid
    return reading

  def _choose(self, music: dict | None) -> dict | None:
    """Pick the source that started playing most recently; Music wins ties."""
    with self.lock:
      external = dict(self.external) if self.external else None
    fresh = external is not None and time.time() - external["at"] < 4
    if fresh and external["status"] == "playing":
      external["position"] += time.time() - external["at"]
    music_playing = music is not None and music.get("status") == "playing"
    if fresh and external["status"] == "playing":
      if not music_playing or self.external_playing_since > self.music_playing_since:
        return external
    if music_playing:
      return music
    if music is not None and music.get("status") == "paused":
      if fresh and self.external_playing_since > self.music_playing_since:
        return external
      return music
    if external is not None and time.time() - external["at"] < 30:
      return external
    return music

  def _poll_once(self) -> None:
    music = self._read_music()
    if music is None and self.external is None:
      return
    self._apply(self._choose(music))

  def _apply(self, reading: dict | None) -> None:
    """Fold one reading into the shared TrackState and notify clients."""
    if reading is None:
      return
    now = time.time()
    if reading["status"] in ("off", "stopped"):
      with self.lock:
        changed = self.state.status != reading["status"]
        self.state = TrackState(status=reading["status"], polled_at=now)
      if changed:
        self._notify()
      return
    pid = reading["pid"]
    with self.lock:
      track_changed = pid != self.state.pid
      self.state.status = reading["status"]
      self.state.position = reading["position"]
      self.state.polled_at = now
      if track_changed:
        self.state.source = reading["source"]
        self.state.pid = pid
        self.state.title = reading["title"]
        self.state.artist = reading["artist"]
        self.state.album = reading["album"]
        self.state.duration = reading["duration"]
        self.state.lyrics_source = "loading"
        self.state.synced = False
        self.state.lines = []
        self.state.has_art = False
    if track_changed:
      log.info("now playing (%s): %s - %s", reading["source"], reading["artist"], reading["title"])
      self._notify()
      self._load_track(pid, reading)
    else:
      self._notify()

  def _load_track(self, pid: str, reading: dict) -> None:
    """Fetch artwork and lyrics for the track identified by pid."""
    with self.lock:
      state = TrackState(**asdict(self.state))
    if reading["source"] == "music":
      art_ok = run_osascript(ART_SCRIPT.format(pid=pid, path=ART_PATH)) == "ok"
    else:
      art_ok = download_art(reading.get("art", ""))
      state.title, state.artist = clean_web_metadata(state.title, state.artist)
      with self.lock:
        if self.state.pid == pid:
          self.state.title, self.state.artist = state.title, state.artist
    source, synced, lines = self._resolve_lyrics(state, pid, embedded=reading["source"] == "music")
    with self.lock:
      if self.state.pid != pid:
        return
      self.state.has_art = art_ok
      self.state.art_version += 1
      self.state.lyrics_source = source
      self.state.synced = synced
      self.state.lines = lines
    self._notify()

  def _resolve_lyrics(self, state: TrackState, pid: str, embedded: bool = True) -> tuple[str, bool, list[dict]]:
    cache_file = CACHE / f"{re.sub(r'[^A-Za-z0-9]', '_', pid)}.json"
    if cache_file.exists():
      try:
        cached = json.loads(cache_file.read_text())
        return cached["source"], cached["synced"], cached["lines"]
      except (json.JSONDecodeError, KeyError):
        log.warning("bad cache file %s, refetching", cache_file)
    text = run_osascript(LYRICS_SCRIPT.format(pid=pid)).strip() if embedded else ""
    if text:
      lines = parse_lrc(text) if LRC_TIME.search(text) else parse_plain(text)
      result = ("music", bool(lines and lines[0]["t"] is not None), lines)
    else:
      result = fetch_lrclib(state)
    if result[2]:
      cache_file.write_text(json.dumps(
        {"source": result[0], "synced": result[1], "lines": result[2]}))
    return result


class Handler(BaseHTTPRequestHandler):
  monitor: Monitor

  def log_message(self, fmt: str, *args) -> None:  # quieter default logging
    log.debug("%s " + fmt, self.address_string(), *args)

  def _send(self, status: int, body: bytes, content_type: str) -> None:
    self.send_response(status)
    self.send_header("Content-Type", content_type)
    self.send_header("Content-Length", str(len(body)))
    self.send_header("Cache-Control", "no-store")
    self.send_header("Access-Control-Allow-Origin", "*")
    self.end_headers()
    self.wfile.write(body)

  def do_GET(self) -> None:  # noqa: N802 - http.server API
    path = urllib.parse.urlsplit(self.path).path
    if path in ("/", "/index.html"):
      self._send(200, (STATIC / "index.html").read_bytes(), "text/html; charset=utf-8")
    elif path == "/health":
      self._send(200, b"ok", "text/plain")
    elif path == "/info":
      urls = [f"http://{ip}:{self.server.server_address[1]}/" for ip in lan_addresses()]
      self._send(200, json.dumps({"urls": urls}).encode(), "application/json")
    elif path == "/state":
      self._send(200, json.dumps(self.monitor.snapshot()).encode(), "application/json")
    elif path == "/art":
      self._serve_art()
    elif path == "/events":
      self._serve_events()
    else:
      self._send(404, b"not found", "text/plain")

  def do_OPTIONS(self) -> None:  # noqa: N802 - CORS preflight from the extension
    self.send_response(204)
    self.send_header("Access-Control-Allow-Origin", "*")
    self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
    self.send_header("Access-Control-Allow-Headers", "Content-Type")
    self.end_headers()

  def do_POST(self) -> None:  # noqa: N802 - http.server API
    path = urllib.parse.urlsplit(self.path).path
    if path != "/report":
      self._send(404, b"not found", "text/plain")
      return
    length = int(self.headers.get("Content-Length") or 0)
    if length > 64_000:
      self._send(413, b"too large", "text/plain")
      return
    try:
      payload = json.loads(self.rfile.read(length) or b"{}")
    except json.JSONDecodeError:
      self._send(400, b"bad json", "text/plain")
      return
    if not isinstance(payload, dict) or not payload.get("title"):
      self._send(400, b"need title", "text/plain")
      return
    self.monitor.report(payload)
    self._send(200, b"ok", "text/plain")

  def _serve_art(self) -> None:
    if not self.monitor.snapshot()["has_art"] or not ART_PATH.exists():
      self._send(404, b"no art", "text/plain")
      return
    data = ART_PATH.read_bytes()
    kind = "image/png" if data.startswith(b"\x89PNG") else "image/jpeg"
    self._send(200, data, kind)

  def _serve_events(self) -> None:
    self.send_response(200)
    self.send_header("Content-Type", "text/event-stream")
    self.send_header("Cache-Control", "no-store")
    self.send_header("Access-Control-Allow-Origin", "*")
    self.send_header("X-Accel-Buffering", "no")
    self.end_headers()
    event = self.monitor.subscribe()
    last_track = None
    try:
      while True:
        snap = self.monitor.snapshot()
        track_key = (snap["pid"], snap["lyrics_source"], snap["art_version"], snap["status"] == "off")
        if track_key != last_track:
          last_track = track_key
          self._emit("track", snap)
        else:
          self._emit("pos", {
            "status": snap["status"],
            "position": snap["position"],
            "polled_at": snap["polled_at"],
            "server_now": time.time(),
          })
        event.clear()
        event.wait(timeout=15)
    except (BrokenPipeError, ConnectionResetError, OSError):
      pass
    finally:
      self.monitor.unsubscribe(event)

  def _emit(self, name: str, payload: dict) -> None:
    self.wfile.write(f"event: {name}\ndata: {json.dumps(payload)}\n\n".encode())
    self.wfile.flush()


def main() -> None:
  parser = argparse.ArgumentParser(description="LyricGlow now-playing lyrics server")
  parser.add_argument("--host", default="0.0.0.0", help="bind address (default all interfaces)")
  parser.add_argument("--port", type=int, default=7331)
  parser.add_argument("--verbose", action="store_true")
  parser.add_argument("--demo", metavar="LYRICS_JSON",
                      help="replay a cached lyrics file instead of watching Music.app")
  args = parser.parse_args()
  logging.basicConfig(
    level=logging.DEBUG if args.verbose else logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
  )
  monitor = Monitor()
  if args.demo:
    cached = json.loads(Path(args.demo).read_text())
    last = max((line["t"] or 0) for line in cached["lines"]) if cached["lines"] else 60
    monitor.demo = {"lines": cached["lines"], "synced": cached["synced"],
                    "duration": float(last + 8), "started": time.time(),
                    "title": cached.get("title", "Demo track"), "artist": cached.get("artist", "LyricGlow demo")}
    log.info("demo mode: replaying %s", args.demo)
  monitor.start()
  Handler.monitor = monitor
  server = ThreadingHTTPServer((args.host, args.port), Handler)
  server.daemon_threads = True
  log.info("LyricGlow listening on http://%s:%d", args.host, args.port)
  try:
    server.serve_forever()
  except KeyboardInterrupt:
    log.info("shutting down")


if __name__ == "__main__":
  main()

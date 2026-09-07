#!/usr/bin/env bash
# LyricGlow launcher: server + floating lyrics window for Music.app.
#
# Usage:
#   lyricglow.sh start [--all] [--fill] [--scale N]   start server and open the window
#   lyricglow.sh stop                                 stop the window and the server
#   lyricglow.sh status                               what is running, plus cast URLs
#   lyricglow.sh url                                  print the addresses to open elsewhere
#   lyricglow.sh build                                recompile the native window app
#   lyricglow.sh bundle                               build LyricGlow.app here (self-contained, starts its own server)
#   lyricglow.sh install                              bundle, copy to /Applications, pin to the Dock
#   lyricglow.sh server                               run only the server (for cast-only use)
#
# Defaults: one floating window on the main display, window buttons visible,
# on-screen control bar. --all opens on every display; --fill fills them.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${LYRICGLOW_PORT:-7331}"
URL="http://127.0.0.1:${PORT}"
LOG_DIR="${HERE}/cache"
SERVER_PID="${LOG_DIR}/server.pid"
APP_PID="${LOG_DIR}/app.pid"

usage() { sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

alive() { [[ -f "$1" ]] && kill -0 "$(cat "$1")" 2>/dev/null; }

build() {
  if [[ ! -x "${HERE}/LyricGlow" || "${HERE}/LyricGlow.swift" -nt "${HERE}/LyricGlow" ]]; then
    echo "building LyricGlow…"
    swiftc -O "${HERE}/LyricGlow.swift" -o "${HERE}/LyricGlow" -framework Cocoa -framework WebKit \
      -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "${HERE}/Info.plist"
  fi
}

start_server() {
  mkdir -p "${LOG_DIR}"
  if alive "${SERVER_PID}"; then return; fi
  nohup python3 "${HERE}/server.py" --port "${PORT}" >> "${LOG_DIR}/server.log" 2>&1 &
  echo $! > "${SERVER_PID}"
  for _ in $(seq 1 30); do
    curl -fs -m 1 "${URL}/health" >/dev/null 2>&1 && return
    sleep 0.3
  done
  echo "server did not answer on ${URL}; see ${LOG_DIR}/server.log" >&2
  exit 1
}

start_app() {
  build
  if alive "${APP_PID}"; then echo "window already open (menu-bar ♪ to add displays)"; return; fi
  nohup "${HERE}/LyricGlow" --url "${URL}" "$@" >> "${LOG_DIR}/app.log" 2>&1 &
  echo $! > "${APP_PID}"
}

stop_pid() {
  if alive "$1"; then kill "$(cat "$1")" 2>/dev/null || true; fi
  rm -f "$1"
}

bundle() {
  build
  local app="${HERE}/LyricGlow.app"
  rm -rf "${app}.building"
  mkdir -p "${app}.building/Contents/MacOS" "${app}.building/Contents/Resources/static"
  cp "${HERE}/LyricGlow" "${app}.building/Contents/MacOS/LyricGlow"
  cp "${HERE}/Info-bundle.plist" "${app}.building/Contents/Info.plist"
  cp "${HERE}/assets/AppIcon.icns" "${app}.building/Contents/Resources/AppIcon.icns"
  cp "${HERE}/server.py" "${app}.building/Contents/Resources/server.py"
  cp "${HERE}/static/index.html" "${HERE}/static/fonts.html" "${app}.building/Contents/Resources/static/"
  cp -R "${HERE}/static/fonts" "${app}.building/Contents/Resources/static/fonts"
  codesign --force --sign - "${app}.building" >/dev/null 2>&1 || true
  if [[ -d "${app}" ]]; then mv "${app}" "${app}.previous-$(date +%Y%m%d-%H%M%S)"; fi
  mv "${app}.building" "${app}"
  echo "bundled ${app}"
}

install_app() {
  bundle
  local target="/Applications/LyricGlow.app"
  if [[ -d "${target}" ]]; then mv "${target}" "/Applications/LyricGlow.previous-$(date +%Y%m%d-%H%M%S).app"; fi
  cp -R "${HERE}/LyricGlow.app" "${target}"
  if command -v dockutil >/dev/null; then
    dockutil --find "${target}" >/dev/null 2>&1 || dockutil --add "${target}" --no-restart >/dev/null
    killall Dock
  fi
  echo "installed ${target} and pinned to the Dock"
}

print_urls() {
  if curl -fs -m 2 "${URL}/info" >/dev/null 2>&1; then
    curl -fs -m 2 "${URL}/info" | python3 -c 'import json,sys; [print(u) for u in json.load(sys.stdin)["urls"]]'
  else
    echo "server is not running; start it with: $0 start"
  fi
}

case "${1:-}" in
  start) shift; start_server; start_app "$@"; echo "LyricGlow window open on the main display. Cast address:"; print_urls ;;
  server) start_server; echo "server on ${URL}"; print_urls ;;
  stop) stop_pid "${APP_PID}"; stop_pid "${SERVER_PID}"; echo "stopped" ;;
  status)
    alive "${SERVER_PID}" && echo "server: running (${URL})" || echo "server: stopped"
    alive "${APP_PID}" && echo "window app: running" || echo "window app: not running"
    print_urls ;;
  url) print_urls ;;
  build) rm -f "${HERE}/LyricGlow"; build; echo "built" ;;
  bundle) bundle ;;
  install) install_app ;;
  -h|--help|help|"") usage ;;
  *) echo "unknown command: $1" >&2; usage; exit 2 ;;
esac

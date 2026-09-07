// BlueLyrics: floating, glowing, per-word synced lyrics for whatever is playing.
// App entry point: the in-app HTTP server, the floating lyric windows, and the
// menu-bar controls.

import Cocoa
import WebKit

let SERVER_PORT: UInt16 = 7331

/// A normal window that participates in Mission Control and Cmd-Tab like any app window.
final class GlowPanel: NSWindow {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}

final class GlowWebView: WKWebView {
  override var mouseDownCanMoveWindow: Bool { true }
}

final class DragStrip: NSView {
  override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
  override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
}

final class LyricWindow: NSObject, WKScriptMessageHandler, NSWindowDelegate {
  let panel: GlowPanel
  let webView: WKWebView
  let strip = DragStrip()
  weak var app: AppDelegate?
  var screenIndex: Int
  var fill = false
  var pinned = false
  var glass = false
  var floatingFrame: NSRect

  init(app: AppDelegate, screenIndex: Int, fill: Bool) {
    self.app = app; self.screenIndex = screenIndex; self.fill = fill
    let screen = NSScreen.screens[min(screenIndex, NSScreen.screens.count - 1)]
    floatingFrame = LyricWindow.floatingRect(on: screen)
    panel = GlowPanel(contentRect: fill ? screen.visibleFrame : floatingFrame,
                      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                      backing: .buffered, defer: false)
    let content = WKUserContentController()
    let configuration = WKWebViewConfiguration()
    configuration.userContentController = content
    webView = GlowWebView(frame: panel.contentView!.bounds, configuration: configuration)
    super.init()
    content.add(self, name: "bluelyrics")
    configure(); load()
  }

  static func floatingRect(on screen: NSScreen) -> NSRect {
    let v = screen.visibleFrame
    return NSRect(x: v.minX, y: v.minY, width: v.width / 2, height: v.height)
  }

  func configure() {
    panel.title = "BlueLyrics"; panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
    panel.isMovableByWindowBackground = true; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
    applyBehavior()
    panel.minSize = NSSize(width: 480, height: 280)
    panel.delegate = self
    applyLevel(); applyGlass()
    webView.autoresizingMask = [.width, .height]
    panel.contentView?.addSubview(webView)
    strip.frame = NSRect(x: 0, y: panel.contentView!.bounds.height - 30, width: panel.contentView!.bounds.width, height: 30)
    strip.autoresizingMask = [.width, .minYMargin]
    panel.contentView?.addSubview(strip)
    panel.makeKeyAndOrderFront(nil)
  }

  func load() {
    var query = ["chrome=1", "scale=\(app?.scale ?? 1)", "screen=\(screenIndex)"]
    if glass { query += ["transparent=1", "float=1", "w=100", "h=100"] }
    webView.load(URLRequest(url: URL(string: "http://127.0.0.1:\(SERVER_PORT)/?" + query.joined(separator: "&"))!))
  }

  func applyLevel() {
    panel.level = pinned ? .floating : .normal
    applyBehavior()
    panel.orderFront(nil)
  }

  /// Pinned: follow you to every Space and sit over full-screen apps. Unpinned: behave like any window.
  func applyBehavior() {
    panel.collectionBehavior = pinned ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.managed, .participatesInCycle]
  }

  func applyGlass() {
    let navy = NSColor(red: 0.016, green: 0.05, blue: 0.1, alpha: 1)
    panel.isOpaque = !glass; panel.hasShadow = !glass
    panel.backgroundColor = glass ? .clear : navy
    webView.setValue(!glass, forKey: "drawsBackground")
    if #available(macOS 12.0, *) { webView.underPageBackgroundColor = glass ? .clear : navy }
  }

  func setFill(_ on: Bool) {
    guard let screen = panel.screen ?? NSScreen.main else { return }
    if on && !fill { floatingFrame = panel.frame }
    fill = on
    panel.setFrame(on ? screen.visibleFrame : floatingFrame, display: true, animate: true)
    pushButtonState()
  }

  func move(to index: Int) {
    guard NSScreen.screens.indices.contains(index) else { return }
    screenIndex = index
    let screen = NSScreen.screens[index]
    floatingFrame = LyricWindow.floatingRect(on: screen)
    panel.setFrame(fill ? screen.visibleFrame : floatingFrame, display: true, animate: true)
  }

  func pushButtonState() {
    webView.evaluateJavaScript("window.bluelyrics && window.bluelyrics.markButtons({fullscreen: \(fill), pin: \(pinned), glass: \(glass)})")
  }

  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else { return }
    switch cmd {
    case "fill": setFill(!fill)
    case "unfill": if fill { setFill(false) }
    case "nextScreen": move(to: (screenIndex + 1) % NSScreen.screens.count)
    case "allScreens": app?.showOnAllScreens()
    case "pin": pinned.toggle(); applyLevel(); pushButtonState()
    case "glass": glass.toggle(); applyGlass(); load()
    case "close": panel.close()
    case "quit": NSApp.terminate(nil)
    default: break
    }
  }

  func windowWillClose(_ notification: Notification) { app?.forget(self) }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  var windows: [LyricWindow] = []
  var statusItem: NSStatusItem?
  var scale = 1.0
  let nowPlaying = NowPlaying()
  let listener = Listener()
  let server = HTTPServer(port: SERVER_PORT)
  var sseClients: [SSEClient] = []
  let sseLock = NSLock()
  var prefsVersion = 0

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    buildMainMenu(); buildStatusItem()
    configureRoutes()
    startServer(attempt: 1)
    requestMusicAutomation()
    listener.nowPlaying = nowPlaying
    listener.onCaption = { [weak self] text, final in self?.sendAll(event: "caption", data: ["text": text, "final": final, "at": Date().timeIntervalSince1970]) }
    listener.onStatus = { [weak self] status in self?.sendAll(event: "listen", data: ["state": status]) }
    nowPlaying.onChange { [weak self] state, trackChanged in self?.broadcast(state, trackChanged: trackChanged) }
    nowPlaying.start()
    open(on: mainScreenIndex())
    if Prefs.listen {
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
        self?.listener.setOn(true) { ok, error in Log.info("auto-listen on launch: \(ok ? "on" : "failed: \(error ?? "?")")") }
      }
    }
  }

  /// Start the LAN server; if the port is still held by a previous instance, retry for ~30 s.
  func startServer(attempt: Int) {
    server.onFailure = { [weak self] in
      guard attempt < 15 else { Log.info("server gave up: port \(SERVER_PORT) stays busy"); return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.startServer(attempt: attempt + 1) }
    }
    do { try server.start(); Log.info("BlueLyrics listening on port \(SERVER_PORT) (attempt \(attempt))") }
    catch { Log.info("server failed to start: \(error)"); server.onFailure?() }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if windows.isEmpty { open(on: mainScreenIndex()) } else { windows.forEach { $0.panel.orderFrontRegardless() } }
    return false
  }

  /// Ask macOS, once, for permission to control Music (the Automation prompt).
  func requestMusicAutomation() {
    var target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.Music").aeDesc!.pointee
    let status = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, true)
    Log.info("Music automation permission status: \(status) (0 = granted, -1744 = asked, -1743 = denied)")
  }

  // MARK: HTTP routes

  var resources: URL { Bundle.main.resourceURL ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent() }

  func page(_ name: String) -> HTTPResponse {
    guard let data = try? Data(contentsOf: resources.appendingPathComponent(name)) else { return .notFound }
    return .file(data, type: "text/html; charset=utf-8")
  }

  func configureRoutes() {
    server.route("GET", "/") { [weak self] _ in self?.page("index.html") ?? .notFound }
    server.route("GET", "/index.html") { [weak self] _ in self?.page("index.html") ?? .notFound }
    server.route("GET", "/fonts.html") { [weak self] _ in self?.page("fonts.html") ?? .notFound }
    server.route("GET", "/icon.html") { [weak self] _ in self?.page("icon.html") ?? .notFound }
    server.route("GET", "/health") { _ in .text("ok") }
    server.route("GET", "/state") { [weak self] _ in .json(self?.nowPlaying.snapshot().json ?? [:]) }
    server.route("GET", "/info") { _ in .json(["urls": LAN.urls(port: SERVER_PORT), "apple": false]) }
    server.route("GET", "/prefs") { _ in .json(["prefs": Prefs.load(), "fonts": Prefs.fonts]) }
    server.route("GET", "/art") { [weak self] _ in
      guard self?.nowPlaying.snapshot().hasArt == true, let data = try? Data(contentsOf: Paths.art) else { return .notFound }
      let png = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
      return .file(data, type: png ? "image/png" : "image/jpeg")
    }
    server.route("GET", "/fonts/", prefix: true) { [weak self] request in
      guard let self else { return .notFound }
      let name = (request.path as NSString).lastPathComponent
      let url = self.resources.appendingPathComponent("fonts").appendingPathComponent(name)
      guard ["ttf", "otf", "woff2"].contains(url.pathExtension), let data = try? Data(contentsOf: url) else { return .notFound }
      return .file(data, type: url.pathExtension == "woff2" ? "font/woff2" : "font/ttf")
    }
    server.route("GET", "/icons/", prefix: true) { [weak self] request in
      guard let self else { return .notFound }
      let url = self.resources.appendingPathComponent("icons").appendingPathComponent((request.path as NSString).lastPathComponent)
      guard url.pathExtension == "png", let data = try? Data(contentsOf: url) else { return .notFound }
      return .file(data, type: "image/png")
    }
    server.route("POST", "/report") { [weak self] request in
      guard let payload = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
            let title = payload["title"] as? String, !title.isEmpty else { return .text("need title", status: 400) }
      self?.nowPlaying.report(payload); return .text("ok")
    }
    server.route("POST", "/transcribe-file") { [weak self] request in
      guard let payload = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any], let path = payload["path"] as? String else { return .text("need path", status: 400) }
      let err = self?.listener.transcribeFile(URL(fileURLWithPath: path))
      return .json(["ok": err == nil, "error": err as Any])
    }
    server.route("POST", "/caption") { [weak self] request in
      guard let payload = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
            let text = payload["text"] as? String, !text.isEmpty else { return .text("need text", status: 400) }
      self?.sendAll(event: "caption", data: ["text": text, "final": true, "source": payload["source"] as? String ?? "page", "at": Date().timeIntervalSince1970])
      return .text("ok")
    }
    server.route("POST", "/prefs") { [weak self] request in
      let payload = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]) ?? [:]
      let prefs = Prefs.save(payload)
      self?.prefsVersion += 1
      self?.sendAll(event: "prefs", data: ["prefs": prefs, "fonts": Prefs.fonts])
      return .json(prefs)
    }
    server.route("GET", "/listen") { [weak self] _ in .json(["state": self?.listener.on == true ? "listening" : "off", "error": self?.listener.lastError as Any, "needsPermission": self?.listener.needsPermission ?? false]) }
    server.route("POST", "/open-audio-permission") { _ in
      DispatchQueue.main.async { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!) }
      return .text("ok")
    }
    server.route("POST", "/listen") { [weak self] request in
      guard let self else { return .notFound }
      let payload = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]) ?? [:]
      let wanted = (payload["on"] as? Bool) ?? !self.listener.on
      let semaphore = DispatchSemaphore(value: 0)
      var ok = false; var err: String?
      DispatchQueue.main.async { self.listener.setOn(wanted) { success, error in ok = success; err = error; semaphore.signal() } }
      _ = semaphore.wait(timeout: .now() + 15)
      if ok { Prefs.save(["listen": wanted]) }
      return .json(["state": self.listener.on ? "listening" : "off", "ok": ok, "error": err as Any])
    }
    server.route("POST", "/log") { request in
      Log.info("page: " + (String(data: request.body.prefix(8000), encoding: .utf8) ?? "")); return .text("ok")
    }
    server.sse("/events") { [weak self] _, client in
      guard let self else { return }
      self.sseLock.lock(); self.sseClients.append(client); self.sseLock.unlock()
      client.send(event: "prefs", data: ["prefs": Prefs.load(), "fonts": Prefs.fonts])
      client.send(event: "track", data: self.nowPlaying.snapshot().json)
      client.send(event: "listen", data: ["state": self.listener.on ? "listening" : "off"])
    }
  }

  func sendAll(event: String, data: Any) {
    sseLock.lock(); sseClients.removeAll { !$0.alive }; let clients = sseClients; sseLock.unlock()
    clients.forEach { $0.send(event: event, data: data) }
  }

  func broadcast(_ state: TrackState, trackChanged: Bool) {
    if trackChanged {
      sendAll(event: "track", data: state.json)
    } else {
      sendAll(event: "pos", data: ["status": state.status, "position": state.position, "polled_at": state.polledAt,
                                   "server_now": Date().timeIntervalSince1970])
    }
  }

  // MARK: windows

  func mainScreenIndex() -> Int { NSScreen.screens.firstIndex(where: { $0 == NSScreen.main }) ?? 0 }

  @discardableResult
  func open(on index: Int) -> LyricWindow {
    if let existing = windows.first(where: { $0.screenIndex == index }) { existing.panel.orderFrontRegardless(); return existing }
    let window = LyricWindow(app: self, screenIndex: index, fill: false)
    windows.append(window); return window
  }
  func showOnAllScreens() { NSScreen.screens.indices.forEach { open(on: $0) } }
  func forget(_ window: LyricWindow) { windows.removeAll { $0 === window } }

  // MARK: menus

  func buildMainMenu() {
    let main = NSMenu(); let appItem = NSMenuItem(); main.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Show controls", action: #selector(showControls), keyEquivalent: "h").target = self
    appMenu.addItem(withTitle: "Show on every display", action: #selector(showAll), keyEquivalent: "a").target = self
    appMenu.addItem(withTitle: "Close all windows", action: #selector(closeAll), keyEquivalent: "w").target = self
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit BlueLyrics", action: #selector(quit), keyEquivalent: "q").target = self
    appItem.submenu = appMenu; NSApp.mainMenu = main
  }

  func buildStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.button?.title = "♪"; item.button?.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
    let menu = NSMenu(); menu.delegate = self; item.menu = menu; statusItem = item
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    menu.addItem(withTitle: "BlueLyrics", action: nil, keyEquivalent: "")
    menu.addItem(.separator())
    for (index, screen) in NSScreen.screens.enumerated() {
      let name = "Display \(index + 1)\(screen == NSScreen.main ? " (main)" : "")  \(Int(screen.frame.width))×\(Int(screen.frame.height))"
      let entry = NSMenuItem(title: name, action: #selector(toggleScreen(_:)), keyEquivalent: "\(index + 1)")
      entry.tag = index; entry.target = self
      entry.state = windows.contains { $0.screenIndex == index } ? .on : .off
      menu.addItem(entry)
    }
    menu.addItem(withTitle: "Show on every display", action: #selector(showAll), keyEquivalent: "a").target = self
    menu.addItem(withTitle: "Show controls", action: #selector(showControls), keyEquivalent: "h").target = self
    menu.addItem(withTitle: "Close all windows", action: #selector(closeAll), keyEquivalent: "w").target = self
    menu.addItem(.separator())
    menu.addItem(withTitle: "Open in browser (for casting)", action: #selector(openBrowser), keyEquivalent: "b").target = self
    menu.addItem(withTitle: "Reload", action: #selector(reload), keyEquivalent: "r").target = self
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit BlueLyrics", action: #selector(quit), keyEquivalent: "q").target = self
  }

  @objc func toggleScreen(_ sender: NSMenuItem) {
    if let existing = windows.first(where: { $0.screenIndex == sender.tag }) { existing.panel.close() } else { open(on: sender.tag) }
  }
  @objc func showAll() { showOnAllScreens() }
  @objc func showControls() { windows.forEach { $0.webView.evaluateJavaScript("window.bluelyrics && window.bluelyrics.reveal()") } }
  @objc func closeAll() { windows.forEach { $0.panel.close() } }
  @objc func openBrowser() { NSWorkspace.shared.open(URL(string: "http://127.0.0.1:\(SERVER_PORT)/")!) }
  @objc func reload() { windows.forEach { $0.webView.reload() } }
  @objc func quit() { NSApp.terminate(nil) }
}

enum LAN {
  static func urls(port: UInt16) -> [String] {
    var result: [String] = []
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return result }
    defer { freeifaddrs(ifaddr) }
    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
      let iface = ptr.pointee
      guard iface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      if getnameinfo(iface.ifa_addr, socklen_t(iface.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
        let ip = String(cString: host)
        if !ip.hasPrefix("127.") { result.append("http://\(ip):\(port)/") }
      }
    }
    return result
  }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

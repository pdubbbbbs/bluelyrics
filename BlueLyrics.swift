// BlueLyrics: a floating, glowing lyrics window for Music.app.
// Opens ONE floating window on the main display by default. The page's own
// control bar and the menu-bar item add windows to other displays, fill a
// screen, pin on top, or close. Nothing goes full screen unless asked.
//
// Run: ./BlueLyrics --url http://127.0.0.1:7331 [--all] [--fill] [--scale 1.2]

import Cocoa
import WebKit

struct Options {
  var url = "http://127.0.0.1:7331"
  var allScreens = false
  var fill = false
  var scale = 1.0

  static func parse(_ args: [String]) -> Options {
    var options = Options()
    var iterator = args.dropFirst().makeIterator()
    while let arg = iterator.next() {
      switch arg {
      case "--url": options.url = iterator.next() ?? options.url
      case "--all": options.allScreens = true
      case "--fill": options.fill = true
      case "--scale": options.scale = Double(iterator.next() ?? "1") ?? 1.0
      default: break
      }
    }
    return options
  }
}

/// Floating panel that still accepts keyboard focus when clicked.
final class GlowPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

/// Web view that lets a drag anywhere on the page move the window.
final class GlowWebView: WKWebView {
  override var mouseDownCanMoveWindow: Bool { true }
}

/// Transparent strip along the top edge that drags the window.
final class DragStrip: NSView {
  override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
  override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
}

final class LyricWindow: NSObject, WKScriptMessageHandler, NSWindowDelegate {
  let panel: GlowPanel
  let webView: WKWebView
  let strip = DragStrip()
  weak var app: BlueLyricsApp?
  var screenIndex: Int
  var fill = false
  var pinned = true
  var glass = false
  var floatingFrame: NSRect

  init(app: BlueLyricsApp, screenIndex: Int, fill: Bool) {
    self.app = app
    self.screenIndex = screenIndex
    self.fill = fill
    let screen = NSScreen.screens[min(screenIndex, NSScreen.screens.count - 1)]
    floatingFrame = LyricWindow.floatingRect(on: screen)
    panel = GlowPanel(
      contentRect: fill ? screen.visibleFrame : floatingFrame,
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .nonactivatingPanel],
      backing: .buffered, defer: false)
    let content = WKUserContentController()
    let configuration = WKWebViewConfiguration()
    configuration.userContentController = content
    webView = GlowWebView(frame: panel.contentView!.bounds, configuration: configuration)
    super.init()
    content.add(self, name: "bluelyrics")
    configure()
    load()
  }

  /// Default placement: the left half of the display, top to bottom.
  static func floatingRect(on screen: NSScreen) -> NSRect {
    let visible = screen.visibleFrame
    return NSRect(x: visible.minX, y: visible.minY, width: visible.width / 2, height: visible.height)
  }

  func configure() {
    panel.title = "BlueLyrics"
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.isMovableByWindowBackground = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.minSize = NSSize(width: 480, height: 280)
    panel.backgroundColor = NSColor(red: 0.016, green: 0.05, blue: 0.1, alpha: 1)
    panel.delegate = self
    applyLevel()
    applyGlass()
    webView.autoresizingMask = [.width, .height]
    panel.contentView?.addSubview(webView)
    strip.frame = NSRect(x: 0, y: panel.contentView!.bounds.height - 30, width: panel.contentView!.bounds.width, height: 30)
    strip.autoresizingMask = [.width, .minYMargin]
    panel.contentView?.addSubview(strip)
    panel.orderFrontRegardless()
  }

  func load() {
    var query = ["chrome=1", "scale=\(app?.options.scale ?? 1)", "screen=\(screenIndex)"]
    if glass { query.append("transparent=1"); query.append("float=1"); query.append("w=100"); query.append("h=100") }
    webView.load(URLRequest(url: URL(string: (app?.options.url ?? "") + "/?" + query.joined(separator: "&"))!))
  }

  func applyLevel() { panel.level = pinned ? .floating : .normal }

  func applyGlass() {
    panel.isOpaque = !glass
    panel.hasShadow = !glass
    panel.backgroundColor = glass ? .clear : NSColor(red: 0.016, green: 0.05, blue: 0.1, alpha: 1)
    webView.setValue(!glass, forKey: "drawsBackground")
    if #available(macOS 12.0, *) { webView.underPageBackgroundColor = glass ? .clear : NSColor(red: 0.016, green: 0.05, blue: 0.1, alpha: 1) }
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
    let js = "window.bluelyrics && window.bluelyrics.markButtons({fullscreen: \(fill), pin: \(pinned), glass: \(glass)})"
    webView.evaluateJavaScript(js)
  }

  // MARK: bridge from the page

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

final class BlueLyricsApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
  var options: Options
  var windows: [LyricWindow] = []
  var statusItem: NSStatusItem?

  init(options: Options) { self.options = options; super.init() }

  var serverProcess: Process?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)   // shows in the Dock with the app icon
    buildMainMenu()
    buildStatusItem()
    ensureServer { [weak self] in
      guard let self else { return }
      if self.options.allScreens { self.showOnAllScreens() } else { self.open(on: self.mainScreenIndex()) }
    }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if windows.isEmpty { open(on: mainScreenIndex()) } else { windows.forEach { $0.panel.orderFrontRegardless() } }
    return false
  }

  func applicationWillTerminate(_ notification: Notification) {
    if let process = serverProcess, process.isRunning { process.terminate() }
  }

  /// Start server.py from the bundle if nothing answers on the port yet.
  func ensureServer(then ready: @escaping () -> Void) {
    let health = URL(string: options.url + "/health")!
    URLSession.shared.dataTask(with: health) { [weak self] _, response, _ in
      let up = (response as? HTTPURLResponse)?.statusCode == 200
      DispatchQueue.main.async {
        if up { ready(); return }
        self?.launchServer()
        self?.waitForServer(attempts: 40, then: ready)
      }
    }.resume()
  }

  func launchServer() {
    let resources = Bundle.main.resourceURL ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    let script = resources.appendingPathComponent("server.py").path
    let pythons = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
    guard let python = pythons.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("BlueLyrics", isDirectory: true)
    try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: python)
    process.arguments = [script, "--port", String(URL(string: options.url)?.port ?? 7331)]
    process.environment = ProcessInfo.processInfo.environment.merging(
      ["BLUELYRICS_CACHE": support.appendingPathComponent("cache").path]) { $1 }
    let handle = try? FileHandle(forWritingTo: logFile(in: support))
    handle?.seekToEndOfFile()
    process.standardOutput = handle
    process.standardError = process.standardOutput
    do { try process.run(); serverProcess = process } catch { NSLog("BlueLyrics: could not start server: \(error)") }
  }

  func logFile(in dir: URL) -> URL {
    let url = dir.appendingPathComponent("server.log")
    if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
    return url
  }

  func waitForServer(attempts: Int, then ready: @escaping () -> Void) {
    guard attempts > 0 else { ready(); return }
    URLSession.shared.dataTask(with: URL(string: options.url + "/health")!) { [weak self] _, response, _ in
      DispatchQueue.main.async {
        if (response as? HTTPURLResponse)?.statusCode == 200 { ready() }
        else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.waitForServer(attempts: attempts - 1, then: ready) } }
      }
    }.resume()
  }

  func buildMainMenu() {
    let main = NSMenu()
    let appItem = NSMenuItem(); main.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Show controls", action: #selector(showControls), keyEquivalent: "h").target = self
    appMenu.addItem(withTitle: "Show on every display", action: #selector(showAll), keyEquivalent: "a").target = self
    appMenu.addItem(withTitle: "Close all windows", action: #selector(closeAll), keyEquivalent: "w").target = self
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit BlueLyrics", action: #selector(quit), keyEquivalent: "q").target = self
    appItem.submenu = appMenu
    NSApp.mainMenu = main
  }

  func mainScreenIndex() -> Int {
    NSScreen.screens.firstIndex(where: { $0 == NSScreen.main }) ?? 0
  }

  @discardableResult
  func open(on index: Int) -> LyricWindow {
    if let existing = windows.first(where: { $0.screenIndex == index }) {
      existing.panel.orderFrontRegardless()
      return existing
    }
    let window = LyricWindow(app: self, screenIndex: index, fill: options.fill)
    windows.append(window)
    return window
  }

  func showOnAllScreens() { NSScreen.screens.indices.forEach { open(on: $0) } }
  func forget(_ window: LyricWindow) { windows.removeAll { $0 === window } }

  // MARK: menu bar

  func buildStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.button?.title = "♪"
    item.button?.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
    let menu = NSMenu()
    menu.delegate = self
    item.menu = menu
    statusItem = item
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    menu.addItem(withTitle: "BlueLyrics", action: nil, keyEquivalent: "")
    menu.addItem(.separator())
    for (index, screen) in NSScreen.screens.enumerated() {
      let name = "Display \(index + 1)\(screen == NSScreen.main ? " (main)" : "")  \(Int(screen.frame.width))×\(Int(screen.frame.height))"
      let entry = NSMenuItem(title: name, action: #selector(toggleScreen(_:)), keyEquivalent: "\(index + 1)")
      entry.tag = index
      entry.target = self
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
    if let existing = windows.first(where: { $0.screenIndex == sender.tag }) { existing.panel.close() }
    else { open(on: sender.tag) }
  }
  @objc func showAll() { showOnAllScreens() }
  @objc func showControls() {
    windows.forEach { $0.webView.evaluateJavaScript("window.bluelyrics && window.bluelyrics.reveal()") }
  }
  @objc func closeAll() { windows.forEach { $0.panel.close() } }
  @objc func openBrowser() { NSWorkspace.shared.open(URL(string: options.url)!) }
  @objc func reload() { windows.forEach { $0.webView.reload() } }
  @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = BlueLyricsApp(options: Options.parse(CommandLine.arguments))
app.delegate = delegate
app.run()

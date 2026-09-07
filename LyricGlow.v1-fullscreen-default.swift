// LyricGlow: always-on-top glowing lyric panels, one per attached screen.
// Loads the local LyricGlow server page into a transparent floating NSPanel
// on every display. Controlled from a menu-bar item (no Dock icon).
//
// Build: see lyricglow.sh build
// Run:   ./LyricGlow --url http://127.0.0.1:7331 [--float] [--glass] [--top]

import Cocoa
import WebKit

struct Options {
  var url = "http://127.0.0.1:7331"
  var fill = true        // fill each screen vs a floating card in the middle
  var glass = false      // transparent page body so the desktop shows through
  var top = false        // status-bar level (above nearly everything)
  var scale = 1.0

  static func parse(_ args: [String]) -> Options {
    var options = Options()
    var iterator = args.dropFirst().makeIterator()
    while let arg = iterator.next() {
      switch arg {
      case "--url": options.url = iterator.next() ?? options.url
      case "--float": options.fill = false
      case "--glass": options.glass = true
      case "--top": options.top = true
      case "--scale": options.scale = Double(iterator.next() ?? "1") ?? 1.0
      default: break
      }
    }
    return options
  }
}

final class LyricGlowApp: NSObject, NSApplicationDelegate {
  var options: Options
  var panels: [NSPanel] = []
  var webViews: [WKWebView] = []
  var clickThrough = false
  var statusItem: NSStatusItem?

  init(options: Options) {
    self.options = options
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    buildStatusItem()
    buildPanels()
    NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil, queue: .main) { [weak self] _ in self?.buildPanels() }
  }

  // MARK: panels

  func pageURL(screenIndex: Int) -> URL {
    var query = ["screen=\(screenIndex)", "scale=\(options.scale)"]
    if options.glass { query.append("transparent=1") }
    if !options.fill { query.append("float=1"); query.append("w=100"); query.append("h=100") }
    return URL(string: options.url + "/?" + query.joined(separator: "&"))!
  }

  func frame(for screen: NSScreen) -> NSRect {
    let visible = screen.visibleFrame
    if options.fill { return visible }
    let width = visible.width * 0.72
    let height = visible.height * 0.62
    return NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height)
  }

  func buildPanels() {
    panels.forEach { $0.orderOut(nil) }
    panels.removeAll()
    webViews.removeAll()
    for (index, screen) in NSScreen.screens.enumerated() {
      let panel = NSPanel(
        contentRect: frame(for: screen),
        styleMask: [.borderless, .nonactivatingPanel, .resizable],
        backing: .buffered, defer: false)
      panel.level = options.top ? .statusBar : .floating
      panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.hasShadow = false
      panel.hidesOnDeactivate = false
      panel.isMovableByWindowBackground = true
      panel.ignoresMouseEvents = clickThrough
      panel.isReleasedWhenClosed = false

      let configuration = WKWebViewConfiguration()
      configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
      let webView = WKWebView(frame: panel.contentView!.bounds, configuration: configuration)
      webView.autoresizingMask = [.width, .height]
      webView.setValue(false, forKey: "drawsBackground")
      if #available(macOS 12.0, *) { webView.underPageBackgroundColor = .clear }
      webView.load(URLRequest(url: pageURL(screenIndex: index)))
      panel.contentView?.addSubview(webView)
      panel.orderFrontRegardless()
      panels.append(panel)
      webViews.append(webView)
    }
  }

  // MARK: menu bar

  func buildStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.button?.title = "♪"
    item.button?.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
    let menu = NSMenu()
    menu.addItem(withTitle: "LyricGlow", action: nil, keyEquivalent: "")
    menu.addItem(.separator())
    menu.addItem(withTitle: "Fill every screen", action: #selector(setFill), keyEquivalent: "1")
    menu.addItem(withTitle: "Floating cards", action: #selector(setFloat), keyEquivalent: "2")
    menu.addItem(withTitle: "Glass (see-through)", action: #selector(toggleGlass), keyEquivalent: "g")
    menu.addItem(withTitle: "Click-through", action: #selector(toggleClickThrough), keyEquivalent: "c")
    menu.addItem(withTitle: "Above everything", action: #selector(toggleTop), keyEquivalent: "t")
    menu.addItem(.separator())
    menu.addItem(withTitle: "Bigger text", action: #selector(bigger), keyEquivalent: "+")
    menu.addItem(withTitle: "Smaller text", action: #selector(smaller), keyEquivalent: "-")
    menu.addItem(withTitle: "Reload", action: #selector(reload), keyEquivalent: "r")
    menu.addItem(withTitle: "Open in browser (for casting)", action: #selector(openBrowser), keyEquivalent: "b")
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit LyricGlow", action: #selector(quit), keyEquivalent: "q")
    menu.items.forEach { $0.target = self }
    menu.delegate = self
    item.menu = menu
    statusItem = item
  }

  @objc func setFill() { options.fill = true; buildPanels() }
  @objc func setFloat() { options.fill = false; buildPanels() }
  @objc func toggleGlass() { options.glass.toggle(); buildPanels() }
  @objc func toggleTop() { options.top.toggle(); buildPanels() }
  @objc func toggleClickThrough() {
    clickThrough.toggle()
    panels.forEach { $0.ignoresMouseEvents = clickThrough }
  }
  @objc func bigger() { options.scale = min(3.0, options.scale + 0.1); buildPanels() }
  @objc func smaller() { options.scale = max(0.4, options.scale - 0.1); buildPanels() }
  @objc func reload() { webViews.forEach { $0.reload() } }
  @objc func openBrowser() { NSWorkspace.shared.open(URL(string: options.url)!) }
  @objc func quit() { NSApp.terminate(nil) }
}

extension LyricGlowApp: NSMenuDelegate {
  func menuNeedsUpdate(_ menu: NSMenu) {
    for item in menu.items {
      switch item.title {
      case "Fill every screen": item.state = options.fill ? .on : .off
      case "Floating cards": item.state = options.fill ? .off : .on
      case "Glass (see-through)": item.state = options.glass ? .on : .off
      case "Click-through": item.state = clickThrough ? .on : .off
      case "Above everything": item.state = options.top ? .on : .off
      default: break
      }
    }
  }
}

let app = NSApplication.shared
let delegate = LyricGlowApp(options: Options.parse(CommandLine.arguments))
app.delegate = delegate
app.run()

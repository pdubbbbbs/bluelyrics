// The six display themes from the macOS page, as glow colours and backgrounds.

import SwiftUI

struct Theme {
  let name: String
  let glow1: Color
  let glow2: Color
  let glow3: Color
  let bg0: Color
  let bg1: Color

  static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r / 255, green: g / 255, blue: b / 255) }
  static func hex(_ v: UInt32) -> Color { rgb(Double((v >> 16) & 0xff), Double((v >> 8) & 0xff), Double(v & 0xff)) }

  static let all: [String: Theme] = [
    "blueguard": Theme(name: "blueguard", glow1: rgb(128, 229, 255), glow2: rgb(0, 212, 255), glow3: rgb(33, 150, 243), bg0: hex(0x040d1a), bg1: hex(0x0a1628)),
    "ember":     Theme(name: "ember",     glow1: rgb(255, 214, 150), glow2: rgb(255, 140, 40),  glow3: rgb(220, 60, 20),   bg0: hex(0x1a0a04), bg1: hex(0x2a1208)),
    "violet":    Theme(name: "violet",    glow1: rgb(230, 190, 255), glow2: rgb(190, 110, 255), glow3: rgb(120, 40, 220),  bg0: hex(0x0b0416), bg1: hex(0x170a2a)),
    "emerald":   Theme(name: "emerald",   glow1: rgb(190, 255, 220), glow2: rgb(60, 230, 160),  glow3: rgb(0, 160, 110),   bg0: hex(0x03120c), bg1: hex(0x072318)),
    "rose":      Theme(name: "rose",      glow1: rgb(255, 200, 220), glow2: rgb(255, 110, 160), glow3: rgb(200, 30, 90),   bg0: hex(0x160408), bg1: hex(0x260a12)),
    "mono":      Theme(name: "mono",      glow1: rgb(255, 255, 255), glow2: rgb(220, 220, 220), glow3: rgb(150, 150, 150), bg0: hex(0x050505), bg1: hex(0x121212)),
  ]
  static let order = ["blueguard", "ember", "violet", "emerald", "rose", "mono"]
  static func named(_ name: String?) -> Theme { all[name ?? ""] ?? all["blueguard"]! }
}

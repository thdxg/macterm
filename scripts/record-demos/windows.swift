// Print the on-screen windows, front to back, one per line:
//
//   <owner>|<layer>|<x>|<y>|<width>|<height>|<title>
//
// in points, top-left origin — the coordinates System Events and CGEvent use.
// The recorder uses it for what AppleScript can't see: whether anything but
// wallpaper and widgets sits inside a capture region (demos 8 and 9 record
// the desktop), and whether the password bubble — an NSPopover, a window of
// its own — is up (demo 10). Compiled once into the work directory.
import CoreGraphics
import Foundation

let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
    as? [[String: Any]] ?? []
for window in windows {
    let owner = window[kCGWindowOwnerName as String] as? String ?? ""
    let layer = window[kCGWindowLayer as String] as? Int ?? 0
    let title = window[kCGWindowName as String] as? String ?? ""
    guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
          let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
    else { continue }
    print("\(owner)|\(layer)|\(Int(rect.minX))|\(Int(rect.minY))|\(Int(rect.width))|\(Int(rect.height))|\(title)")
}

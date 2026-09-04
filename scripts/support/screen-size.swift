// The main display's size in points, for `screencapture -R`.
//
// `system_profiler` reports pixels, which on a Retina Mac is twice the number
// `screencapture` wants and produces a region that misses the display entirely.
import AppKit

if let screen = NSScreen.main {
  print("\(Int(screen.frame.width)) \(Int(screen.frame.height))")
} else {
  print("1440 900")
}

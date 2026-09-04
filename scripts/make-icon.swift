#!/usr/bin/env swift
import ImageIO
// Draws the Rant application icon and writes the .icns.
//
// Generated rather than checked in as a binary blob so the mark has one definition:
// change the palette in Theme.swift, change the numbers here, and the icon follows.
// Run: swift scripts/make-icon.swift

import AppKit
import CoreGraphics
import Foundation

// The palette, matching Theme.swift.
let paper = CGColor(red: 0.984, green: 0.973, blue: 0.953, alpha: 1)   // #FBF8F3
let clay = CGColor(red: 0.761, green: 0.333, blue: 0.227, alpha: 1)    // #C2553A
let clayDeep = CGColor(red: 0.639, green: 0.259, blue: 0.169, alpha: 1)
let ink = CGColor(red: 0.118, green: 0.106, blue: 0.141, alpha: 1)     // #1E1B24

func drawIcon(size: CGFloat) -> CGImage? {
  guard
    let context = CGContext(
      data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  else { return nil }

  context.setShouldAntialias(true)
  context.interpolationQuality = .high

  // macOS icons sit inside a rounded square with a margin. The first attempt used a
  // 10% margin and a 22% corner radius, which reads as a slab: too much plate, not
  // enough mark. Apple's own proportions are closer to a 6% margin and a corner just
  // under a quarter of the width, and the mark wants to be considerably larger than
  // feels right in isolation — at 32 points in a Dock it is the only thing visible.
  let margin = size * 0.06
  let plate = CGRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
  let radius = plate.width * 0.2337

  let plateShape = CGPath(
    roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)

  // A clay plate rather than an ink one. The mark was clay-on-near-black, which went
  // muddy at Dock size because two dark browns sat next to each other; the contrast
  // now comes from light strokes on a saturated ground, which survives being 32
  // points tall on any wallpaper.
  context.saveGState()
  context.addPath(plateShape)
  context.clip()
  if let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
      CGColor(red: 0.847, green: 0.404, blue: 0.259, alpha: 1),   // warm top
      CGColor(red: 0.639, green: 0.239, blue: 0.161, alpha: 1),   // deeper base
    ] as CFArray,
    locations: [0, 1])
  {
    context.drawLinearGradient(
      gradient, start: CGPoint(x: plate.midX, y: plate.maxY),
      end: CGPoint(x: plate.midX, y: plate.minY), options: [])
  }
  context.restoreGState()

  // A hairline highlight along the top edge, which is what stops a flat fill looking
  // like a placeholder.
  context.saveGState()
  context.addPath(plateShape)
  context.clip()
  context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.22))
  context.setLineWidth(size * 0.012)
  context.addPath(plateShape)
  context.strokePath()
  context.restoreGState()

  // The mark: three strokes, low–high–mid. Thinner and further apart than before —
  // the earlier version had them almost touching, which read as a solid block rather
  // than as separate strokes.
  let scales: [CGFloat] = [0.30, 0.56, 0.42]
  let strokeWidth = plate.width * 0.088
  let gap = plate.width * 0.098
  let totalWidth = strokeWidth * 3 + gap * 2
  // Optically centred: the group is centred on the plate, then nudged so the visual
  // weight — which sits low, because the strokes rise from a common baseline — lands
  // on the middle rather than below it.
  let baseline = plate.minY + plate.height * 0.275
  var x = plate.midX - totalWidth / 2

  for scale in scales {
    let height = plate.height * scale
    let bar = CGRect(x: x, y: baseline, width: strokeWidth, height: height)
    context.addPath(
      CGPath(
        roundedRect: bar, cornerWidth: strokeWidth / 2, cornerHeight: strokeWidth / 2,
        transform: nil))
    context.setFillColor(CGColor(red: 1, green: 0.976, blue: 0.965, alpha: 1))
    context.fillPath()
    x += strokeWidth + gap
  }

  return context.makeImage()
}

let iconset = "build/Rant.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

// The sizes macOS actually asks for.
let variants: [(name: String, pixels: CGFloat)] = [
  ("icon_16x16", 16), ("icon_16x16@2x", 32),
  ("icon_32x32", 32), ("icon_32x32@2x", 64),
  ("icon_128x128", 128), ("icon_128x128@2x", 256),
  ("icon_256x256", 256), ("icon_256x256@2x", 512),
  ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
  guard let image = drawIcon(size: variant.pixels) else {
    FileHandle.standardError.write(Data("could not render \(variant.name)\n".utf8))
    exit(1)
  }
  let url = URL(fileURLWithPath: "\(iconset)/\(variant.name).png")
  guard
    let destination = CGImageDestinationCreateWithURL(
      url as CFURL, "public.png" as CFString, 1, nil)
  else { exit(1) }
  CGImageDestinationAddImage(destination, image, nil)
  CGImageDestinationFinalize(destination)
}

// A standalone PNG for the README.
if let image = drawIcon(size: 512) {
  let url = URL(fileURLWithPath: "docs/assets/icon.png")
  try? FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  if let destination = CGImageDestinationCreateWithURL(
    url as CFURL, "public.png" as CFString, 1, nil)
  {
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
  }
}

print("wrote \(iconset) and docs/assets/icon.png")

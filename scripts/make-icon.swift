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

  // macOS icons sit inside a rounded square with a margin; matching the system
  // proportions is what stops it looking like a sticker in the Dock.
  let margin = size * 0.10
  let plate = CGRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
  let radius = plate.width * 0.225

  // Ink plate, so the clay mark has something to sit on in both light and dark Docks.
  let path = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)
  context.addPath(path)
  context.setFillColor(ink)
  context.fillPath()

  // A soft warm wash from the bottom, so the plate is not a flat rectangle.
  context.saveGState()
  context.addPath(path)
  context.clip()
  if let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
      CGColor(red: 0.761, green: 0.333, blue: 0.227, alpha: 0.30),
      CGColor(red: 0.118, green: 0.106, blue: 0.141, alpha: 0),
    ] as CFArray,
    locations: [0, 1])
  {
    context.drawLinearGradient(
      gradient, start: CGPoint(x: plate.midX, y: plate.minY),
      end: CGPoint(x: plate.midX, y: plate.maxY), options: [])
  }
  context.restoreGState()

  // The mark: three rising strokes, the same shape the sidebar draws.
  let scales: [CGFloat] = [0.42, 0.76, 0.58]
  let strokeWidth = plate.width * 0.115
  let gap = plate.width * 0.085
  let totalWidth = strokeWidth * 3 + gap * 2
  let baseline = plate.minY + plate.height * 0.24
  var x = plate.midX - totalWidth / 2

  for (index, scale) in scales.enumerated() {
    let height = plate.height * scale
    let bar = CGRect(x: x, y: baseline, width: strokeWidth, height: height)
    let barPath = CGPath(
      roundedRect: bar, cornerWidth: strokeWidth / 2, cornerHeight: strokeWidth / 2,
      transform: nil)
    context.addPath(barPath)
    // The tallest stroke is the brightest: the eye should land on the middle.
    context.setFillColor(index == 1 ? clay : clayDeep)
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

#!/usr/bin/env swift
import AppKit
import Foundation

enum GenerationTarget: String {
  case watchOS
}

struct IconOutput {
  let filename: String
  let pixelSize: Int
}

enum IconGenerationError: LocalizedError {
  case invalidArguments
  case unsupportedTarget(String)
  case failedToLoadSVG(URL)
  case failedToCreateBitmap(Int)
  case failedToEncodePNG(String)

  var errorDescription: String? {
    switch self {
    case .invalidArguments:
      return "Usage: generate_app_icons.swift <watchOS> <source.svg> <appiconset-directory>"
    case .unsupportedTarget(let value):
      return "Unsupported icon target: \(value)"
    case .failedToLoadSVG(let url):
      return "Failed to load SVG at \(url.path)"
    case .failedToCreateBitmap(let size):
      return "Failed to create a \(size)x\(size) bitmap"
    case .failedToEncodePNG(let filename):
      return "Failed to encode PNG for \(filename)"
    }
  }
}

func iconOutputs(for target: GenerationTarget) -> [IconOutput] {
  switch target {
  case .watchOS:
    return [
      IconOutput(filename: "AppIcon.png", pixelSize: 1024)
    ]
  }
}

func needsUpdate(sourceURL: URL, outputURL: URL) -> Bool {
  let fileManager = FileManager.default

  guard fileManager.fileExists(atPath: outputURL.path) else {
    return true
  }

  guard
    let sourceDate = modificationDate(for: sourceURL),
    let outputDate = modificationDate(for: outputURL)
  else {
    return true
  }

  return outputDate < sourceDate
}

func modificationDate(for url: URL) -> Date? {
  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
  return values?.contentModificationDate
}

func renderPNG(from sourceImage: NSImage, pixelSize: Int) throws -> Data {
  guard
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: pixelSize,
      pixelsHigh: pixelSize,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bitmapFormat: [],
      bytesPerRow: 0,
      bitsPerPixel: 0
    )
  else {
    throw IconGenerationError.failedToCreateBitmap(pixelSize)
  }

  bitmap.size = NSSize(width: pixelSize, height: pixelSize)

  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
  NSGraphicsContext.current?.imageInterpolation = .high
  sourceImage.draw(
    in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
    from: .zero,
    operation: .copy,
    fraction: 1
  )
  NSGraphicsContext.restoreGraphicsState()

  guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
    throw IconGenerationError.failedToEncodePNG("\(pixelSize)x\(pixelSize)")
  }

  return pngData
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 3 else {
  throw IconGenerationError.invalidArguments
}

guard let target = GenerationTarget(rawValue: arguments[0]) else {
  throw IconGenerationError.unsupportedTarget(arguments[0])
}

let sourceURL = URL(fileURLWithPath: arguments[1])
let appIconSetURL = URL(fileURLWithPath: arguments[2], isDirectory: true)

let fileManager = FileManager.default
try fileManager.createDirectory(at: appIconSetURL, withIntermediateDirectories: true)

guard let sourceImage = NSImage(contentsOf: sourceURL) else {
  throw IconGenerationError.failedToLoadSVG(sourceURL)
}

let outputs = iconOutputs(for: target)
if outputs.allSatisfy({
  !needsUpdate(sourceURL: sourceURL, outputURL: appIconSetURL.appendingPathComponent($0.filename))
}) {
  exit(0)
}

for output in outputs {
  let outputURL = appIconSetURL.appendingPathComponent(output.filename)
  let pngData = try renderPNG(from: sourceImage, pixelSize: output.pixelSize)
  try pngData.write(to: outputURL, options: .atomic)
}

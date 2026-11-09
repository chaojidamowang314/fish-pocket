#!/usr/bin/env swift
// The QR code on the share poster (ShareAppPage) is a fixed picture: the link it points at
// never changes at runtime. Run this again after changing `AppLinks.site`:
//
//   swift scripts/make-share-qr.swift https://fish-pocket.deepseek1024.com
//
// Writes app/DshIOS/Assets.xcassets/ShareQRCode.imageset/share-qr.png: black modules on
// transparent, no quiet zone (the poster leaves its own margin), level M, 16 px a module.
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2, let link = CommandLine.arguments.last, URL(string: link) != nil else {
    FileHandle.standardError.write(Data("usage: make-share-qr.swift <url>\n".utf8))
    exit(64)
}

let filter = CIFilter.qrCodeGenerator()
filter.message = Data(link.utf8)
filter.correctionLevel = "M"
guard let code = filter.outputImage else { fatalError("no QR code") }

// The generator pads one module on each side; cut it, then scale without smoothing.
let modules = code.extent.insetBy(dx: 1, dy: 1)
let scale: CGFloat = 16
let mask = code.cropped(to: modules)
    .transformed(by: CGAffineTransform(translationX: -modules.minX, y: -modules.minY))
    .samplingNearest()
    .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
// Dark modules opaque, light ones clear.
let black = CIImage(color: .black).cropped(to: mask.extent)
let clear = CIImage(color: .clear).cropped(to: mask.extent)
let alpha = mask.applyingFilter("CIColorInvert").applyingFilter("CIMaskToAlpha")
let image = black.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: alpha])

let context = CIContext()
guard let cgImage = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
    fatalError("render failed")
}
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let folder = root.appending(path: "app/DshIOS/Assets.xcassets/ShareQRCode.imageset")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let output = folder.appending(path: "share-qr.png")
guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else { fatalError("no destination") }
CGImageDestinationAddImage(destination, cgImage, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("write failed") }
let contents = """
{
  "images" : [
    {
      "filename" : "share-qr.png",
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
try Data(contents.utf8).write(to: folder.appending(path: "Contents.json"))
print("\(output.path): \(cgImage.width)×\(cgImage.height) for \(link)")

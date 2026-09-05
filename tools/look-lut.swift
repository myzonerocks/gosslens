// Writes the lut.pass strip fs_lut_pass.sc samples (512x512, 8x8 tiles of 64, blue picks the
// tile) for a look, run through the app's own Core Image chain, so the engine's colour is Core
// Image's by construction. usage: swift tools/look-lut.swift out.png op:value ... with ops
// sepia, saturation, contrast (deltas from 1), brightness (multiplier), hue (degrees).

import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: look-lut.swift out.png op:value ...\n".data(using: .utf8)!)
    exit(2)
}
let outPath = args[0]
let grid = 8
let tile = 64
let side = grid * tile

// The identity strip: every texel holds the colour that addresses it.
var identity = [UInt8](repeating: 255, count: side * side * 4)
for b in 0 ..< (tile) {
    let tileX = b % grid
    let tileY = b / grid
    for g in 0 ..< tile {
        for r in 0 ..< tile {
            let x = tileX * tile + r
            let y = tileY * tile + g
            let i = (y * side + x) * 4
            identity[i] = UInt8(r * 255 / (tile - 1))
            identity[i + 1] = UInt8(g * 255 / (tile - 1))
            identity[i + 2] = UInt8(b * 255 / (tile - 1))
        }
    }
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let data = Data(identity)
var image = CIImage(
    bitmapData: data, bytesPerRow: side * 4, size: CGSize(width: side, height: side),
    format: .RGBA8, colorSpace: space,
)

// The app's own chain, op for op and in the order given.
for spec in args.dropFirst() {
    let parts = spec.split(separator: ":")
    guard parts.count == 2, let value = Float(parts[1]) else { continue }
    switch parts[0] {
    case "sepia":
        let f = CIFilter.sepiaTone(); f.inputImage = image; f.intensity = value
        image = f.outputImage ?? image
    case "saturation":
        let f = CIFilter.colorControls(); f.inputImage = image; f.saturation = max(0, 1 + value)
        image = f.outputImage ?? image
    case "contrast":
        let f = CIFilter.colorControls(); f.inputImage = image; f.contrast = 1 + value
        image = f.outputImage ?? image
    case "brightness":
        let m = CIFilter.colorMatrix(); m.inputImage = image
        let s = CGFloat(value)
        m.rVector = CIVector(x: s, y: 0, z: 0, w: 0)
        m.gVector = CIVector(x: 0, y: s, z: 0, w: 0)
        m.bVector = CIVector(x: 0, y: 0, z: s, w: 0)
        image = m.outputImage ?? image
    case "hue":
        let f = CIFilter.hueAdjust(); f.inputImage = image; f.angle = value * .pi / 180
        image = f.outputImage ?? image
    default:
        FileHandle.standardError.write("unknown op \(parts[0])\n".data(using: .utf8)!)
        exit(2)
    }
}

// The app's own context, defaults and all: Core Image grades in its working space, and a LUT
// baked under a different one is a different look. Output is sRGB, so the texel is the colour.
let context = CIContext()
guard let png = context.pngRepresentation(
    of: image.cropped(to: CGRect(x: 0, y: 0, width: side, height: side)),
    format: .RGBA8, colorSpace: space,
) else {
    FileHandle.standardError.write("could not render the strip\n".data(using: .utf8)!)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) \(side)x\(side)")

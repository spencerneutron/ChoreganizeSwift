// Wash lab: renders Choreganize/ChoreWash.metal frames to PNG without building the app.
//
//   wash-lab <metallib> <out-dir> [--dark] [--look N] [--motion 0|1] [--seed S] [--size WxH] [--scale K]
//            [--duration D] [--no-cards] (--times t1,t2,… | --fps N)
//
// --times writes one PNG per time (seconds); --fps writes every frame of the effect as
// frame-0000.png … for ffmpeg. Colours are the App Store creative's (amber #ffc233, lavender
// #aeb4ff, honey #ffd978) over the iOS grouped background.
import Foundation
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct LabParams {
    var size: SIMD2<Float>
    var scale: Float
    var time: Float
    var duration: Float
    var seed: Float
    var dark: Float
    var look: Float
    var motion: Float
    var cards: Float
    var base: SIMD4<Float>
    var colorA: SIMD4<Float>
    var colorB: SIMD4<Float>
    var glow: SIMD4<Float>
    var card: SIMD4<Float>
    var ink: SIMD4<Float>
}

func rgb(_ hex: UInt32) -> SIMD4<Float> {
    SIMD4(Float((hex >> 16) & 0xFF) / 255, Float((hex >> 8) & 0xFF) / 255, Float(hex & 0xFF) / 255, 1)
}

var args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: wash-lab <metallib> <out-dir> [options]\n".data(using: .utf8)!)
    exit(2)
}
let libURL = URL(fileURLWithPath: args.removeFirst())
let outDir = URL(fileURLWithPath: args.removeFirst())
var dark = false, look: Float = 1, motion: Float = 1, seed: Float = 3.7, scale: Float = 2, duration: Float = 8
var size = SIMD2<Float>(402, 874), cards = true, times: [Float] = [], fps: Float = 0
while !args.isEmpty {
    let flag = args.removeFirst()
    switch flag {
    case "--dark": dark = true
    case "--no-cards": cards = false
    case "--look": look = Float(args.removeFirst())!
    case "--motion": motion = Float(args.removeFirst())!
    case "--seed": seed = Float(args.removeFirst())!
    case "--scale": scale = Float(args.removeFirst())!
    case "--duration": duration = Float(args.removeFirst())!
    case "--fps": fps = Float(args.removeFirst())!
    case "--size":
        let parts = args.removeFirst().split(separator: "x").compactMap { Float($0) }
        size = SIMD2(parts[0], parts[1])
    case "--times": times = args.removeFirst().split(separator: ",").compactMap { Float($0) }
    default: fatalError("unknown flag \(flag)")
    }
}
if fps > 0 { times = stride(from: Float(0), through: duration, by: 1 / fps).map { $0 } }

let device = MTLCreateSystemDefaultDevice()!
let library = try device.makeLibrary(URL: libURL)
let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "lab")!)
let queue = device.makeCommandQueue()!
let width = Int(size.x * scale), height = Int(size.y * scale)
let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width,
                                                          height: height, mipmapped: false)
descriptor.usage = [.shaderWrite, .shaderRead]
descriptor.storageMode = .shared
let texture = device.makeTexture(descriptor: descriptor)!
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

var params = LabParams(
    size: size, scale: scale, time: 0, duration: duration, seed: seed,
    dark: dark ? 1 : 0, look: look, motion: motion, cards: cards ? 1 : 0,
    base: dark ? rgb(0x000000) : rgb(0xF2F2F7),
    colorA: rgb(0xFFC233), colorB: rgb(0xAEB4FF), glow: rgb(0xFFD978),
    card: dark ? rgb(0x1C1C1E) : rgb(0xFFFFFF),
    ink: dark ? rgb(0xE5E5EA) : rgb(0x1C1C1E))

var gpuTotal: Double = 0
for (index, t) in times.enumerated() {
    params.time = t
    let buffer = queue.makeCommandBuffer()!
    let encoder = buffer.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(pipeline)
    encoder.setTexture(texture, index: 0)
    encoder.setBytes(&params, length: MemoryLayout<LabParams>.stride, index: 0)
    let group = MTLSize(width: 16, height: 16, depth: 1)
    encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: group)
    encoder.endEncoding()
    buffer.commit()
    buffer.waitUntilCompleted()
    gpuTotal += buffer.gpuEndTime - buffer.gpuStartTime

    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let name = fps > 0 ? String(format: "frame-%04d.png", index) : String(format: "t%.2f.png", t)
    let dest = CGImageDestinationCreateWithURL(outDir.appendingPathComponent(name) as CFURL,
                                               UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}
let average = gpuTotal / Double(max(times.count, 1)) * 1000
print(String(format: "%d frame(s) %dx%d px, GPU %.2f ms/frame avg (%@)", times.count, width, height,
             average, device.name))

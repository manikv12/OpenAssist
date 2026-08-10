import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ShortVideoError: Error, CustomStringConvertible {
    case invalidArguments(String)
    case noFrames
    case unreadableFrame(String)
    case writer(String)

    var description: String {
        switch self {
        case .invalidArguments(let message): return message
        case .noFrames: return "No PNG frames were found."
        case .unreadableFrame(let path): return "Could not read frame: \(path)"
        case .writer(let message): return message
        }
    }
}

func argumentValue(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func loadImage(_ url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw ShortVideoError.unreadableFrame(url.path)
    }
    return image
}

func frameURLs(in directory: URL) throws -> [URL] {
    let urls = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    ).filter { $0.pathExtension.lowercased() == "png" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    if urls.isEmpty { throw ShortVideoError.noFrames }
    return urls
}

func writeGIF(frames: [URL], output: URL, fps: Int) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        output as CFURL,
        UTType.gif.identifier as CFString,
        frames.count,
        nil
    ) else {
        throw ShortVideoError.writer("Could not create the GIF destination.")
    }
    let fileProperties = [
        kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
    ] as CFDictionary
    CGImageDestinationSetProperties(destination, fileProperties)
    let delay = 1.0 / Double(max(1, fps))
    let frameProperties = [
        kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]
    ] as CFDictionary
    for frameURL in frames {
        CGImageDestinationAddImage(destination, try loadImage(frameURL), frameProperties)
    }
    guard CGImageDestinationFinalize(destination) else {
        throw ShortVideoError.writer("Could not finish the GIF file.")
    }
}

func makePixelBuffer(width: Int, height: Int, pool: CVPixelBufferPool?) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    if let pool {
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
    } else {
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixelBuffer)
    }
    guard let pixelBuffer else {
        throw ShortVideoError.writer("Could not allocate a video frame.")
    }
    return pixelBuffer
}

func draw(_ image: CGImage, into pixelBuffer: CVPixelBuffer, width: Int, height: Int) throws {
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
          let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
          ) else {
        throw ShortVideoError.writer("Could not draw a video frame.")
    }
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
}

func writeMP4(frames: [URL], output: URL, fps: Int) throws {
    let first = try loadImage(frames[0])
    let width = first.width
    let height = first.height
    let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
    let settings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: max(2_000_000, width * height * 5),
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
        ]
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
    )
    guard writer.canAdd(input) else {
        throw ShortVideoError.writer("The video writer rejected its input settings.")
    }
    writer.add(input)
    guard writer.startWriting() else {
        throw ShortVideoError.writer(writer.error?.localizedDescription ?? "Could not start the video writer.")
    }
    writer.startSession(atSourceTime: .zero)

    for (index, frameURL) in frames.enumerated() {
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed {
                throw ShortVideoError.writer(writer.error?.localizedDescription ?? "Video encoding failed.")
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
        let pixelBuffer = try makePixelBuffer(width: width, height: height, pool: adaptor.pixelBufferPool)
        try draw(try loadImage(frameURL), into: pixelBuffer, width: width, height: height)
        let time = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(max(1, fps)))
        guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
            throw ShortVideoError.writer(writer.error?.localizedDescription ?? "Could not append a video frame.")
        }
    }

    input.markAsFinished()
    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting { semaphore.signal() }
    semaphore.wait()
    guard writer.status == .completed else {
        throw ShortVideoError.writer(writer.error?.localizedDescription ?? "Could not finish the MP4 file.")
    }
}

func emitJSON(_ object: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: object),
       let text = String(data: data, encoding: .utf8) {
        print(text)
    }
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let framesPath = argumentValue("--frames-dir", in: arguments),
          let outputPath = argumentValue("--output", in: arguments) else {
        throw ShortVideoError.invalidArguments("Usage: short-video-helper --frames-dir DIR --output FILE --fps 12 --format mp4|gif")
    }
    let fps = max(1, Int(argumentValue("--fps", in: arguments) ?? "12") ?? 12)
    let format = (argumentValue("--format", in: arguments) ?? "mp4").lowercased()
    let frames = try frameURLs(in: URL(fileURLWithPath: framesPath))
    let output = URL(fileURLWithPath: outputPath)
    try? FileManager.default.removeItem(at: output)
    if format == "gif" {
        try writeGIF(frames: frames, output: output, fps: fps)
    } else {
        try writeMP4(frames: frames, output: output, fps: fps)
    }
    emitJSON(["ok": true, "path": output.path, "frames": frames.count, "format": format])
} catch {
    emitJSON(["ok": false, "error": String(describing: error)])
    fputs("short-video-helper: \(error)\n", stderr)
    exit(1)
}

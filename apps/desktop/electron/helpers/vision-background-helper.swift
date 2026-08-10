import Foundation
import CoreImage
import Vision

enum BackgroundRemovalError: LocalizedError {
    case usage
    case unsupportedSystem
    case unreadableImage
    case noForeground

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: vision-background-helper INPUT_IMAGE OUTPUT_PNG"
        case .unsupportedSystem:
            return "Transparent background removal requires macOS 14 or newer."
        case .unreadableImage:
            return "macOS Vision could not read the generated image."
        case .noForeground:
            return "macOS Vision could not identify a foreground subject."
        }
    }
}

func run() throws {
    guard CommandLine.arguments.count == 3 else {
        throw BackgroundRemovalError.usage
    }
    guard #available(macOS 14.0, *) else {
        throw BackgroundRemovalError.unsupportedSystem
    }

    let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
    guard let inputImage = CIImage(contentsOf: inputURL) else {
        throw BackgroundRemovalError.unreadableImage
    }

    let handler = VNImageRequestHandler(ciImage: inputImage)
    let request = VNGenerateForegroundInstanceMaskRequest()
    try handler.perform([request])
    guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
        throw BackgroundRemovalError.noForeground
    }

    let maskBuffer = try observation.generateScaledMaskForImage(
        forInstances: observation.allInstances,
        from: handler
    )
    let maskImage = CIImage(cvPixelBuffer: maskBuffer)
    let transparentBackground = CIImage.empty()
    let outputImage = inputImage.applyingFilter("CIBlendWithMask", parameters: [
        kCIInputBackgroundImageKey: transparentBackground,
        kCIInputMaskImageKey: maskImage
    ])

    let context = CIContext(options: [.cacheIntermediates: false])
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    try context.writePNGRepresentation(
        of: outputImage,
        to: outputURL,
        format: .RGBA8,
        colorSpace: colorSpace
    )
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum OutputKind: Equatable, Sendable { case gif, mp4 }

struct ExportOptions: Sendable {
    let photos: [URL]
    let fps: Int
    let maximumDimension: Int
    let quality: Int
    let pingPong: Bool
    var repetitions = 1
    var format: CanvasFormat = .original
    var framing: ImageFraming = .fit
}

enum FotoExporter {
    static func write(options: ExportOptions, kind: OutputKind, to destination: URL,
                      progress: @Sendable (Double) -> Void = { _ in }) throws {
        guard let first = options.photos.first, let original = PhotoImages.dimensions(of: first) else {
            throw ExportError.invalidImage(options.photos.first?.lastPathComponent ?? "")
        }
        guard [4, 6, 8, 10, 12, 15, 20, 24, 30].contains(options.fps),
              (1...20).contains(options.repetitions), (1...3).contains(options.quality),
              [720, 1080, 1920].contains(options.maximumDimension) else { throw ExportError.renderFailed }
        guard let executable = ffmpegURL() else { throw ExportError.ffmpegMissing }
        let canvas = AnimationSequence.dimensions(ratio: options.format.ratio(original: original.width / original.height),
                                                   maximum: options.maximumDimension, original: original)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("FotoLoop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        // Encode beside the destination, then replace atomically; failures preserve any existing file.
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".FotoLoop-\(UUID().uuidString).\(kind == .gif ? "gif" : "mp4")")
        defer {
            try? FileManager.default.removeItem(at: temporary)
            try? FileManager.default.removeItem(at: staging)
        }
        for (index, url) in options.photos.enumerated() {
            try autoreleasepool {
                guard let size = PhotoImages.dimensions(of: url) else { throw ExportError.invalidImage(url.lastPathComponent) }
                let rect = AnimationSequence.drawRect(image: size, canvas: canvas, framing: options.framing)
                let needed = Int(ceil(max(rect.width, rect.height)))
                guard let image = PhotoImages.load(url, maximum: needed) else { throw ExportError.invalidImage(url.lastPathComponent) }
                guard let context = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height),
                                              bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ExportError.renderFailed }
                context.interpolationQuality = .high
                context.setFillColor(CGColor(gray: 0, alpha: 1))
                context.fill(CGRect(origin: .zero, size: canvas))
                // Use original proportions to avoid thumbnail rounding changing the crop.
                context.draw(image, in: rect)
                guard let rendered = context.makeImage() else { throw ExportError.renderFailed }
                let file = temporary.appendingPathComponent(String(format: "%06d.jpg", index))
                guard let output = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw ExportError.renderFailed }
                CGImageDestinationAddImage(output, rendered, [kCGImageDestinationLossyCompressionQuality: 0.96] as CFDictionary)
                guard CGImageDestinationFinalize(output) else { throw ExportError.renderFailed }
            }
            progress(Double(index + 1) / Double(options.photos.count) * 0.8)
        }
        let order = AnimationSequence.indices(count: options.photos.count, pingPong: options.pingPong)
        // Hard links reuse the already rendered images on the return path.
        for index in options.photos.count..<order.count {
            try FileManager.default.linkItem(at: temporary.appendingPathComponent(String(format: "%06d.jpg", order[index])),
                                            to: temporary.appendingPathComponent(String(format: "%06d.jpg", index)))
        }
        try runFFmpeg(executable: executable, options: options, kind: kind, input: temporary, output: staging)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        } else { try FileManager.default.moveItem(at: staging, to: destination) }
        progress(1)
    }

    static func ffmpegURL() -> URL? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    private static func runFFmpeg(executable: URL, options: ExportOptions, kind: OutputKind, input: URL, output: URL) throws {
        let process = Process()
        process.executableURL = executable
        // Repeat the input cycle, not the JPEG preparation; GIF's infinite playback remains independent.
        var args = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-stream_loop", String(options.repetitions - 1),
                    "-framerate", String(options.fps), "-i", input.appendingPathComponent("%06d.jpg").path]
        switch kind {
        case .gif:
            let colors = [64, 128, 256][options.quality - 1]
            args += ["-filter_complex", "[0:v]split[a][b];[a]palettegen=max_colors=\(colors)[p];[b][p]paletteuse=dither=sierra2_4a", "-loop", "0", output.path]
        case .mp4:
            let crf = [30, 23, 18][options.quality - 1]
            args += ["-vf", "fps=30,scale=in_range=full:out_range=tv", "-c:v", "libx264", "-preset", "medium", "-crf", String(crf),
                     "-pix_fmt", "yuv420p", "-color_range", "tv", "-movflags", "+faststart", "-r", "30", output.path]
        }
        process.arguments = args
        // A file avoids pipe backpressure. Read only a bounded tail for a failed process.
        let log = input.appendingPathComponent("ffmpeg.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let errors = try FileHandle(forWritingTo: log)
        defer { try? errors.close() }
        process.standardError = errors
        do { try process.run() } catch { throw ExportError.ffmpegFailed(error.localizedDescription) }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let reader = try FileHandle(forReadingFrom: log)
            defer { try? reader.close() }
            let length = try reader.seekToEnd()
            try reader.seek(toOffset: length > 2048 ? length - 2048 : 0)
            let detail = String(data: try reader.readToEnd() ?? Data(), encoding: .utf8) ?? ""
            throw ExportError.ffmpegFailed(detail.isEmpty ? "Código \(process.terminationStatus)." : detail)
        }
        guard FileManager.default.fileExists(atPath: output.path) else { throw ExportError.ffmpegFailed("O arquivo não foi criado.") }
    }
}

enum ExportError: LocalizedError {
    case ffmpegMissing, invalidImage(String), renderFailed, ffmpegFailed(String)
    var errorDescription: String? {
        switch self {
        case .ffmpegMissing: return "FFmpeg não foi encontrado. Instale com: brew install ffmpeg"
        case .invalidImage(let name): return "Não foi possível abrir a foto \(name)."
        case .renderFailed: return "Não foi possível preparar uma das fotos para exportação."
        case .ffmpegFailed(let detail): return "Falha ao exportar: \(detail)"
        }
    }
}

import Foundation
import CoreGraphics

struct VideoInfo: Sendable {
    let url: URL
    let duration: Double
    let size: CGSize
}

struct VideoClip: Sendable {
    let info: VideoInfo
    let start: Double
    let duration: Double
}

enum VideoPipeline {
    static let maximumClipDuration = 30.0
    static let supportedExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm"]

    static func accepts(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    static func probe(_ url: URL) throws -> VideoInfo {
        guard accepts(url), (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw VideoError.invalidVideo
        }
        guard let ffmpeg = FotoExporter.ffmpegURL() else { throw ExportError.ffmpegMissing }
        let ffprobe = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
        guard FileManager.default.isExecutableFile(atPath: ffprobe.path) else { throw VideoError.ffprobeMissing }
        let process = Process()
        let output = Pipe()
        process.executableURL = ffprobe
        process.arguments = ["-v", "error", "-select_streams", "v:0", "-show_entries",
                             "stream=width,height:format=duration", "-of", "json", url.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stream = (json["streams"] as? [[String: Any]])?.first,
              let width = stream["width"] as? Int, let height = stream["height"] as? Int,
              let format = json["format"] as? [String: Any],
              let durationText = format["duration"] as? String,
              let duration = Double(durationText), duration.isFinite, duration > 0,
              width > 0, height > 0 else { throw VideoError.invalidVideo }
        return VideoInfo(url: url.standardizedFileURL, duration: duration,
                         size: CGSize(width: width, height: height))
    }

    static func extract(_ clip: VideoClip, fps: Int, into directory: URL) async throws -> [URL] {
        guard FotoLoopModel.frameRates.contains(fps), clip.start >= 0, clip.duration > 0,
              clip.duration <= maximumClipDuration,
              clip.start + clip.duration <= clip.info.duration + 0.01 else { throw VideoError.invalidClip }
        guard let ffmpeg = FotoExporter.ffmpegURL() else { throw ExportError.ffmpegMissing }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = ffmpeg
        let size = AnimationSequence.dimensions(ratio: clip.info.size.width / clip.info.size.height,
                                                maximum: 1920, original: clip.info.size)
        let filter = "fps=\(fps),scale=\(Int(size.width)):\(Int(size.height)):force_original_aspect_ratio=decrease:force_divisible_by=2"
        process.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                             "-ss", String(clip.start), "-i", clip.info.url.path,
                             "-t", String(clip.duration), "-an", "-sn", "-dn",
                             "-vf", filter, "-q:v", "3", "-start_number", "0",
                             directory.appendingPathComponent("%06d.jpg").path]
        let log = directory.appendingPathComponent("ffmpeg.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let errors = try FileHandle(forWritingTo: log)
        defer { try? errors.close() }
        process.standardError = errors
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try process.run()
            if Task.isCancelled { process.terminate() }
            process.waitUntilExit()
            try Task.checkCancellation()
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        guard process.terminationStatus == 0 else {
            let detail = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            throw VideoError.extractionFailed(String(detail.suffix(2048)))
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { throw VideoError.noFrames }
        return files
    }
}

enum VideoError: LocalizedError {
    case invalidVideo, ffprobeMissing, invalidClip, noFrames, extractionFailed(String)
    var errorDescription: String? {
        switch self {
        case .invalidVideo: return "Could not read this video. Try an MP4 or MOV file."
        case .ffprobeMissing: return "FFprobe was not found beside FFmpeg. Install FFmpeg with Homebrew."
        case .invalidClip: return "Choose a video segment up to 30 seconds long."
        case .noFrames: return "No frames could be extracted from this segment."
        case .extractionFailed(let detail): return "Could not extract video frames. \(detail)"
        }
    }
}

import AppKit
import SwiftUI

@MainActor
final class FotoLoopModel: ObservableObject {
    nonisolated static let frameRates = [4, 6, 8, 10, 12, 15, 20, 24, 30]
    @Published private(set) var photos: [URL] = []
    @Published var selected: URL?
    @Published var fps = 10
    @Published var maximumDimension = 1080
    @Published var quality = 2
    @Published var direction: PlaybackDirection = .forward
    @Published var repetitions = 1
    @Published var format: CanvasFormat = .original
    @Published var framing: ImageFraming = .fit
    @Published var holdFrames = 1
    @Published private(set) var videoClip: VideoClip?
    @Published private(set) var originalSize = CGSize(width: 5, height: 4)
    @Published private(set) var images = PreviewImageStore()
    @Published private(set) var sessionID = UUID()
    @Published private(set) var status = "Add photos to get started."
    @Published private(set) var isImporting = false
    @Published private(set) var isExporting = false
    @Published private(set) var exportProgress = 0.0
    private var exportID = UUID()
    private var importTask: Task<Void, Never>?
    private var videoDirectory: URL?

    deinit {
        importTask?.cancel()
        if let videoDirectory { try? FileManager.default.removeItem(at: videoDirectory) }
    }

    var busy: Bool { isImporting || isExporting }
    var ratio: Double { format.ratio(original: originalSize.width / originalSize.height) }
    var canvas: CGSize { AnimationSequence.dimensions(ratio: ratio, maximum: maximumDimension, original: originalSize) }
    var duration: Double { AnimationSequence.duration(count: photos.count, direction: direction, repetitions: repetitions,
                                                      fps: fps, hold: videoClip == nil ? 1 : holdFrames) }

    func setFPS(_ value: Int) {
        guard Self.frameRates.contains(value), !busy, value != fps else { return }
        if let videoClip { importVideo(videoClip, fps: value) }
        else { fps = value }
    }

    func importVideo(_ clip: VideoClip, fps requestedFPS: Int) {
        guard !busy else { return }
        let previousFPS = fps
        fps = requestedFPS
        isImporting = true
        status = "Extracting video frames…"
        let session = sessionID
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FotoLoop-Video-\(UUID().uuidString)", isDirectory: true)
        importTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let files = try await VideoPipeline.extract(clip, fps: requestedFPS, into: directory)
                try Task.checkCancellation()
                if let self {
                    await self.finishVideoImport(clip, fps: requestedFPS, files: files,
                                                 directory: directory, session: session)
                } else { try? FileManager.default.removeItem(at: directory) }
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: directory)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                await self?.failVideoImport(error, previousFPS: previousFPS, session: session)
            }
        }
    }

    private func failVideoImport(_ error: Error, previousFPS: Int, session: UUID) {
        guard session == sessionID else { return }
        fps = previousFPS
        failImport(error, session: session)
    }

    private func finishVideoImport(_ clip: VideoClip, fps: Int, files: [URL],
                                   directory: URL, session: UUID) {
        guard session == sessionID else {
            try? FileManager.default.removeItem(at: directory)
            return
        }
        let previousDirectory = videoDirectory
        let previousImages = images
        sessionID = UUID()
        images = PreviewImageStore()
        photos = files
        selected = files.first
        originalSize = PhotoImages.dimensions(of: files[0]) ?? clip.info.size
        videoClip = clip
        videoDirectory = directory
        self.fps = fps
        isImporting = false
        importTask = nil
        status = "\(files.count) frames from \(clip.info.url.lastPathComponent)."
        Task { await previousImages.removeAll() }
        if let previousDirectory { try? FileManager.default.removeItem(at: previousDirectory) }
    }

    func importPhotos(_ urls: [URL]) {
        guard !busy else { return }
        let replacingVideo = videoClip != nil
        isImporting = true
        status = "Importing photos…"
        let existing = replacingVideo ? [] : photos, session = sessionID
        importTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let imported = try PhotoImport.collect(urls, existing: existing)
                let size = imported.first.flatMap { PhotoImages.dimensions(of: $0) }
                try Task.checkCancellation()
                await self?.finishImport(imported, size: size, replacingVideo: replacingVideo, session: session)
            } catch is CancellationError { } catch {
                await self?.failImport(error, session: session)
            }
        }
    }
    private func finishImport(_ imported: [URL], size: CGSize?, replacingVideo: Bool, session: UUID) {
        guard session == sessionID else { return }
        let added = replacingVideo ? imported.count : imported.count - photos.count
        if replacingVideo && imported.isEmpty {
            isImporting = false
            importTask = nil
            status = "No photos found (JPG, PNG or HEIC). Video session kept."
            return
        }
        if replacingVideo && !imported.isEmpty {
            let previousImages = images
            let previousDirectory = videoDirectory
            sessionID = UUID()
            images = PreviewImageStore()
            videoClip = nil
            videoDirectory = nil
            holdFrames = 1
            fps = 10
            selected = nil
            Task { await previousImages.removeAll() }
            if let previousDirectory { try? FileManager.default.removeItem(at: previousDirectory) }
        }
        photos = imported
        selected = selected ?? photos.first
        if let size { originalSize = size }
        isImporting = false
        importTask = nil
        status = added == 0 ? "No new photos found (JPG, PNG or HEIC)." : "\(photos.count) photos loaded."
    }
    private func failImport(_ error: Error, session: UUID) {
        guard session == sessionID else { return }
        isImporting = false
        importTask = nil
        status = error.localizedDescription
    }
    func clearSession() {
        guard !isExporting else { return }
        importTask?.cancel()
        importTask = nil
        let previousDirectory = videoDirectory
        videoDirectory = nil
        videoClip = nil
        sessionID = UUID()
        photos = []
        selected = nil
        isImporting = false
        let old = images
        images = PreviewImageStore()
        Task { await old.removeAll() }
        fps = 10; maximumDimension = 1080; quality = 2
        direction = .forward; repetitions = 1; format = .original; framing = .fit; holdFrames = 1
        originalSize = CGSize(width: 5, height: 4)
        exportProgress = 0
        status = "Add photos to get started."
        if let previousDirectory { try? FileManager.default.removeItem(at: previousDirectory) }
    }
    func move(from source: IndexSet, to destination: Int) {
        guard !busy else { return }
        photos.move(fromOffsets: source, toOffset: destination)
        updateOriginalSize()
    }
    func moveSelected(_ offset: Int) {
        guard let selected, let index = photos.firstIndex(of: selected), photos.indices.contains(index + offset), !busy else { return }
        photos.swapAt(index, index + offset)
        updateOriginalSize()
    }
    func removeSelected() {
        guard let selected, let index = photos.firstIndex(of: selected), !busy else { return }
        photos.remove(at: index)
        self.selected = photos.isEmpty ? nil : photos[min(index, photos.count - 1)]
        updateOriginalSize()
        status = photos.isEmpty ? "Add photos to get started." : "\(photos.count) photos loaded."
        if photos.isEmpty { clearSession() }
    }
    private func updateOriginalSize() {
        // Metadata only, off the interface thread; stale results cannot update a new sequence.
        let first = photos.first, session = sessionID
        Task { [weak self] in
            let size = await Task.detached { first.flatMap { PhotoImages.dimensions(of: $0) } }.value
            guard let self, self.sessionID == session, self.photos.first == first, let size else { return }
            self.originalSize = size
        }
    }
    func export(_ kind: OutputKind, to destination: URL) {
        guard !photos.isEmpty, !busy else { return }
        let options = ExportOptions(photos: photos, fps: fps, maximumDimension: maximumDimension, quality: quality,
                                    direction: direction, repetitions: repetitions, format: format, framing: framing,
                                    holdFrames: videoClip == nil ? 1 : holdFrames)
        isExporting = true
        exportProgress = 0
        status = "Preparing export…"
        let operation = UUID()
        exportID = operation
        let report: @Sendable (Double) -> Void = { [weak self] value in
            guard let model = self else { return }
            Task { @MainActor in
                guard model.isExporting, model.exportID == operation else { return }
                model.exportProgress = value
                if value >= 0.8 { model.status = "Encoding animation…" }
            }
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try FotoExporter.write(options: options, kind: kind, to: destination, progress: report)
                await self?.finishExport("Saved: \(destination.lastPathComponent)", operation: operation)
            } catch { await self?.finishExport(error.localizedDescription, operation: operation) }
        }
    }
    private func finishExport(_ message: String, operation: UUID) {
        guard exportID == operation else { return }
        isExporting = false
        status = message
    }
}

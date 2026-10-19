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
    @Published var pingPong = false
    @Published var repetitions = 1
    @Published var format: CanvasFormat = .original
    @Published var framing: ImageFraming = .fit
    @Published private(set) var originalSize = CGSize(width: 5, height: 4)
    @Published private(set) var images = PreviewImageStore()
    @Published private(set) var sessionID = UUID()
    @Published private(set) var status = "Adicione fotos para começar."
    @Published private(set) var isImporting = false
    @Published private(set) var isExporting = false
    @Published private(set) var exportProgress = 0.0
    private var exportID = UUID()
    private var importTask: Task<Void, Never>?

    var busy: Bool { isImporting || isExporting }
    var ratio: Double { format.ratio(original: originalSize.width / originalSize.height) }
    var canvas: CGSize { AnimationSequence.dimensions(ratio: ratio, maximum: maximumDimension, original: originalSize) }
    var duration: Double { AnimationSequence.duration(count: photos.count, pingPong: pingPong, repetitions: repetitions, fps: fps) }

    func importPhotos(_ urls: [URL]) {
        guard !busy else { return }
        isImporting = true
        status = "Importando fotos…"
        let existing = photos, session = sessionID
        importTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let imported = try PhotoImport.collect(urls, existing: existing)
                let size = imported.first.flatMap { PhotoImages.dimensions(of: $0) }
                try Task.checkCancellation()
                await self?.finishImport(imported, size: size, session: session)
            } catch is CancellationError { } catch {
                await self?.failImport(error, session: session)
            }
        }
    }
    private func finishImport(_ imported: [URL], size: CGSize?, session: UUID) {
        guard session == sessionID else { return }
        let added = imported.count - photos.count
        photos = imported
        selected = selected ?? photos.first
        if let size { originalSize = size }
        isImporting = false
        importTask = nil
        status = added == 0 ? "Nenhuma foto nova encontrada (JPG, PNG ou HEIC)." : "\(photos.count) fotos carregadas."
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
        sessionID = UUID()
        photos = []
        selected = nil
        isImporting = false
        let old = images
        images = PreviewImageStore()
        Task { await old.removeAll() }
        fps = 10; maximumDimension = 1080; quality = 2
        pingPong = false; repetitions = 1; format = .original; framing = .fit
        originalSize = CGSize(width: 5, height: 4)
        exportProgress = 0
        status = "Adicione fotos para começar."
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
        status = photos.isEmpty ? "Adicione fotos para começar." : "\(photos.count) fotos carregadas."
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
                                    pingPong: pingPong, repetitions: repetitions, format: format, framing: framing)
        isExporting = true
        exportProgress = 0
        status = "Preparando exportação…"
        let operation = UUID()
        exportID = operation
        let report: @Sendable (Double) -> Void = { [weak self] value in
            guard let model = self else { return }
            Task { @MainActor in
                guard model.isExporting, model.exportID == operation else { return }
                model.exportProgress = value
                if value >= 0.8 { model.status = "Codificando animação…" }
            }
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try FotoExporter.write(options: options, kind: kind, to: destination, progress: report)
                await self?.finishExport("Arquivo salvo: \(destination.lastPathComponent)", operation: operation)
            } catch { await self?.finishExport(error.localizedDescription, operation: operation) }
        }
    }
    private func finishExport(_ message: String, operation: UUID) {
        guard exportID == operation else { return }
        isExporting = false
        status = message
    }
}

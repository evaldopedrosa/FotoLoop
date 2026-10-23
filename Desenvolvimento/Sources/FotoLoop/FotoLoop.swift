import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers

// Disambiguate the macOS 13 property wrapper from the SDK 27 macro of the same name.
private typealias ViewState<Value> = SwiftUI.State<Value>

enum AppAppearance: String, CaseIterable, Identifiable {
    case automatic, light, dark
    var id: Self { self }
    var title: String {
        switch self { case .automatic: return "Automatic"; case .light: return "Light"; case .dark: return "Dark" }
    }
    var colorScheme: ColorScheme? {
        switch self { case .automatic: return nil; case .light: return .light; case .dark: return .dark }
    }
}

private enum InspectorPage: Hashable {
    case sequence, export
}

@main
struct FotoLoopApp: App {
    @AppStorage("appearance") private var appearance: AppAppearance = .automatic
    var body: some Scene {
        WindowGroup("FotoLoop") {
            ContentView()
                .frame(minWidth: 960, minHeight: 720)
                .preferredColorScheme(appearance.colorScheme)
        }
        .defaultSize(width: 1120, height: 800)
        .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    @StateObject private var model = FotoLoopModel()
    @AppStorage("appearance") private var appearance: AppAppearance = .automatic
    @ViewState private var infoSheet: InfoSheet?
    @ViewState private var inspectorPage: InspectorPage = .sequence
    @ViewState private var isDropTargeted = false
    @ViewState private var isImportTargeted = false
    @ViewState private var isLoadingDrop = false
    @ViewState private var videoSelection: VideoSelection?
    @ViewState private var stagedFPS: Int?

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.4.0"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    header
                    importActions
                    Rectangle().fill(FLDesign.line).frame(height: 1)
                    controls
                }
                .frame(width: 336)
                .background(FLDesign.sidebar)
                Rectangle().fill(FLDesign.line).frame(width: 1)
                VStack(spacing: 0) {
                    workspaceHeader
                AnimationPreview(photos: model.photos, selected: model.selected, fps: model.fps,
                                 direction: model.direction, repetitions: model.repetitions,
                                 holdFrames: model.videoClip == nil ? 1 : model.holdFrames,
                                 canvas: model.canvas, framing: model.framing,
                                 active: !model.busy, store: model.images, session: model.sessionID,
                                 onSelect: { model.selected = $0 })
                    .id(model.sessionID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(18)
                    .overlay {
                        if isDropTargeted && !model.busy {
                            RoundedRectangle(cornerRadius: 18)
                                .fill(FLDesign.accent.opacity(0.12))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 18)
                                        .strokeBorder(FLDesign.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                                }
                                .overlay {
                                    Label("Drop photos, a folder or a video", systemImage: "square.and.arrow.down")
                                        .font(.headline)
                                        .padding(16)
                                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                                }
                                .padding(18)
                                .allowsHitTesting(false)
                        }
                    }
                    .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: importDropped)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(FLDesign.canvas)
            }
            .frame(maxHeight: .infinity)
            Rectangle().fill(FLDesign.line).frame(height: 1)
            footer
        }
        .background(FLDesign.canvas)
        .tint(FLDesign.accent)
        .sheet(item: $infoSheet) { sheet in
            AppInfoSheet(sheet: sheet, version: appVersion)
        }
        .sheet(item: $videoSelection) { selection in
            VideoClipSheet(selection: selection) { clip in model.importVideo(clip, fps: model.fps) }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let icon = Bundle.main.url(forResource: "FotoLoop", withExtension: "icns")
                .flatMap({ NSImage(contentsOf: $0) }) {
                Image(nsImage: icon).resizable().interpolation(.high)
                    .frame(width: 46, height: 46)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "photo.stack.fill")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 46, height: 46)
                    .accessibilityHidden(true)
            }
            Text("fotoloop").font(.system(size: 27, weight: .semibold, design: .rounded))
            Spacer(minLength: 0)
            appearanceMenu
        }
        .padding(.horizontal, FLDesign.padding)
        .padding(.top, 20).padding(.bottom, 14)
    }

    private var importActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Import media")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { model.clearSession() } label: {
                    Label("Clear session", systemImage: "xmark.circle")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(FLDesign.muted)
                .disabled(model.isExporting)
                .help("Remove this session's frames. Original files are preserved.")
            }
            HStack(spacing: 8) {
                ImportTile(title: "Photos", symbol: "photo.on.rectangle.angled") {
                    choosePhotos(folder: false)
                }
                .keyboardShortcut("o", modifiers: .command)
                ImportTile(title: "Folder", symbol: "folder") {
                    choosePhotos(folder: true)
                }
                ImportTile(title: "Video", symbol: "film") { chooseVideo() }
            }
            .disabled(model.busy)
            Text("Or drop files onto the preview")
                .font(.caption)
                .foregroundStyle(FLDesign.muted)
        }
        .padding(.horizontal, FLDesign.padding)
        .padding(.bottom, 16)
        .background(isImportTargeted ? FLDesign.accent.opacity(0.08) : Color.clear)
        .onDrop(of: [.fileURL], isTargeted: $isImportTargeted, perform: importDropped)
    }

    private var workspaceHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Preview").font(.system(size: 23, weight: .semibold))
                Text(model.photos.isEmpty ? "Photos and video, frame by frame" : "\(model.photos.count) frames · ≈ \(String(format: "%.2f", model.duration)) s")
                    .font(.callout).foregroundStyle(FLDesign.muted)
            }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 4)
    }

    private var appearanceMenu: some View {
        Menu {
                ForEach(AppAppearance.allCases) { choice in
                    Button { appearance = choice } label: {
                        if choice == appearance { Label(choice.title, systemImage: "checkmark") }
                        else { Text(choice.title) }
                    }
                }
        } label: {
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 31, height: 31)
                .background(FLDesign.inset, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(FLDesign.line))
        }
        .menuStyle(.borderlessButton).fixedSize()
        .accessibilityLabel("Appearance").help("Appearance: \(appearance.title)")
    }

    private var controls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 20) {
                inspectorTab("Sequence", page: .sequence)
                inspectorTab("Export", page: .export)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, FLDesign.padding).padding(.vertical, 10)
            Rectangle().fill(FLDesign.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if inspectorPage == .sequence {
                if let clip = model.videoClip {
                    InspectorCard(title: "Video source", symbol: "film") {
                        Text(clip.info.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Text(String(format: "%.1f–%.1f s of %.1f s", clip.start,
                                    clip.start + clip.duration, clip.info.duration))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Button("Edit segment…") {
                            videoSelection = VideoSelection(url: clip.info.url, existing: clip)
                        }
                        .disabled(model.busy)
                    }
                }
                InspectorCard(title: "Animation", symbol: "play.rectangle.on.rectangle") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Speed")
                            Spacer()
                            Text("\(stagedFPS ?? model.fps) FPS")
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                        }
                        Slider(value: Binding(
                            get: { Double(FotoLoopModel.frameRates.firstIndex(of: stagedFPS ?? model.fps) ?? 3) },
                            set: {
                                let value = FotoLoopModel.frameRates[max(0, min(Int($0.rounded()), FotoLoopModel.frameRates.count - 1))]
                                if model.videoClip == nil { model.setFPS(value) }
                                else { stagedFPS = value }
                            }
                        ), in: 0...Double(FotoLoopModel.frameRates.count - 1), step: 1,
                               onEditingChanged: { editing in
                            if !editing, let stagedFPS {
                                model.setFPS(stagedFPS)
                                self.stagedFPS = nil
                            }
                        })
                        .accessibilityLabel("Speed")
                        .accessibilityValue("\(stagedFPS ?? model.fps) frames per second")
                        HStack {
                            Text("Slower")
                            Spacer()
                            Text("Faster")
                        }
                        .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .help("Source frames per second. GIF timing is rounded to 0.01 s; MP4 uses a 30 FPS stream.")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Direction").font(.subheadline).foregroundStyle(.secondary)
                        FLChoiceRow(title: "Direction", selection: $model.direction,
                                    choices: PlaybackDirection.allCases.map { ($0, $0.title) })
                    }
                    FLNumberRow(title: "Repeats", value: $model.repetitions, range: 1...20)
                    if model.videoClip != nil {
                        FLNumberRow(title: "Hold each frame", value: $model.holdFrames, range: 1...4)
                        .help("Hold sampled frames longer. This increases the exported duration without changing the video sample rate.")
                        Text("Changing FPS or the segment resets frame order. Holding frames changes playback duration.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("\(model.photos.count) frames · ≈ \(String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), model.duration)) s")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .disabled(model.busy)

                InspectorCard(title: "Frame order", symbol: "square.stack.3d.up") {
                    if model.photos.isEmpty {
                        Text("Frames appear here after import")
                            .font(.caption)
                            .foregroundStyle(FLDesign.muted)
                    } else {
                        Text("Drag to reorder · Select to preview")
                            .font(.caption).foregroundStyle(.secondary)
                        NativePhotoList(model: model)
                            .frame(height: 230)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9)
                                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.4)))
                            .disabled(model.busy)
                        HStack {
                            Button { model.moveSelected(-1) } label: { Image(systemName: "arrow.up") }
                                .accessibilityLabel("Move frame up").help("Move selected frame up")
                                .disabled(selectedIndex == nil || selectedIndex == 0)
                            Button { model.moveSelected(1) } label: { Image(systemName: "arrow.down") }
                                .accessibilityLabel("Move frame down").help("Move selected frame down")
                                .disabled(selectedIndex == nil || selectedIndex == model.photos.count - 1)
                            Spacer()
                            Text("\(model.photos.count) frames")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Button { model.removeSelected() } label: { Image(systemName: "trash") }
                                .accessibilityLabel("Remove frame").help("Remove selected frame from this session")
                                .disabled(model.selected == nil)
                        }
                        .disabled(model.busy)
                    }
                }
                    } else {
                        exportSettings
                    }
                }
                .padding(.horizontal, FLDesign.padding)
                .padding(.vertical, 16)
            }
        }
    }

    private func inspectorTab(_ title: String, page: InspectorPage) -> some View {
        let selected = inspectorPage == page
        return Button { inspectorPage = page } label: {
            VStack(spacing: 7) {
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Color.primary : FLDesign.muted)
                Capsule()
                    .fill(selected ? FLDesign.accent : Color.clear)
                    .frame(height: 2)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }

    private var exportSettings: some View {
        InspectorCard(title: "Export settings", symbol: "square.and.arrow.up") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Aspect ratio").font(.subheadline).foregroundStyle(.secondary)
                AspectRatioGrid(selection: $model.format,
                                originalRatio: model.originalSize.width / model.originalSize.height)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Framing").font(.subheadline).foregroundStyle(.secondary)
                FLChoiceRow(title: "Framing", selection: $model.framing,
                            choices: ImageFraming.allCases.map { ($0, $0.title) })
            }
            .help("Fit shows the entire photo with margins. Fill crops the center without stretching.")
            VStack(alignment: .leading, spacing: 6) {
                Text("Max resolution").font(.subheadline).foregroundStyle(.secondary)
                FLChoiceRow(title: "Max resolution", selection: $model.maximumDimension,
                            choices: [(720, "720"), (1080, "1080"), (1920, "1920")])
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Quality").font(.subheadline).foregroundStyle(.secondary)
                FLChoiceRow(title: "Quality", selection: $model.quality,
                            choices: [(1, "Small"), (2, "Balanced"), (3, "High")])
            }
        }
        .disabled(model.busy)
    }

    private var selectedIndex: Int? { model.selected.flatMap { model.photos.firstIndex(of: $0) } }

    private var footer: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if model.isExporting {
                    if model.exportProgress < 0.8 {
                        ProgressView(value: model.exportProgress / 0.8).frame(width: 70)
                            .accessibilityLabel("Preparing photos")
                    } else { ProgressView().controlSize(.small) }
                } else if model.isImporting { ProgressView().controlSize(.small) }
                Text(model.status).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    .textSelection(.enabled)
                Spacer(minLength: 10)
                Button("Export GIF…") { chooseDestination(.gif) }
                    .buttonStyle(FLActionButtonStyle(prominent: true))
                    .disabled(model.photos.isEmpty || model.busy)
                Button("Export MP4…") { chooseDestination(.mp4) }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .buttonStyle(FLActionButtonStyle(prominent: false))
                    .disabled(model.photos.isEmpty || model.busy)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            HStack(spacing: 16) {
                Text("v\(appVersion)").monospacedDigit()
                Text("Open source")
                Button("MIT License") { infoSheet = .license }
                Button("Help") { infoSheet = .help }
                Spacer()
                Text("Made by ") + Text("Evakdo").fontWeight(.semibold)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)
            .padding(.horizontal, 20).padding(.vertical, 8)
        }
        .background(FLDesign.sidebar)
    }

    private func choosePhotos(folder: Bool) {
        let panel = NSOpenPanel()
        panel.title = folder ? "Choose a folder of photos" : "Choose photos for the sequence"
        panel.canChooseFiles = !folder
        panel.canChooseDirectories = folder
        panel.allowsMultipleSelection = !folder
        if !folder { panel.allowedContentTypes = [.jpeg, .png, .heic] }
        panel.begin { response in
            guard response == .OK else { return }
            model.importPhotos(panel.urls)
        }
    }

    private func chooseVideo() {
        let panel = NSOpenPanel()
        panel.title = "Choose a video"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            videoSelection = VideoSelection(url: url, existing: nil)
        }
    }

    private func importDropped(_ providers: [NSItemProvider]) -> Bool {
        guard !model.busy, !isLoadingDrop else { return false }
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        isLoadingDrop = true
        Task { @MainActor in
            var urls: [URL] = []
            for provider in fileProviders {
                if let url = await droppedFileURL(from: provider) { urls.append(url) }
            }
            isLoadingDrop = false
            if urls.count == 1, let url = urls.first, VideoPipeline.accepts(url) {
                videoSelection = VideoSelection(url: url, existing: nil)
            } else if !urls.isEmpty { model.importPhotos(urls) }
        }
        return true
    }

    private func droppedFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: NSURL.self) { item, _ in
                let url = (item as? NSURL).map { $0 as URL }
                continuation.resume(returning: url?.isFileURL == true ? url : nil)
            }
        }
    }

    private func chooseDestination(_ kind: OutputKind) {
        let panel = NSSavePanel()
        panel.title = kind == .gif ? "Export GIF animation" : "Export MP4 video"
        panel.nameFieldStringValue = kind == .gif ? "FotoLoop.gif" : "FotoLoop.mp4"
        panel.allowedContentTypes = [kind == .gif ? .gif : .mpeg4Movie]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            model.export(kind, to: url)
        }
    }
}

private struct ImportTile: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @ViewState private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .regular))
                    .frame(height: 22)
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isHovered && isEnabled ? FLDesign.accent : Color.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 58)
        }
        .buttonStyle(ImportTileStyle(hovered: isHovered && isEnabled))
        .onHover { isHovered = $0 }
        .accessibilityLabel("Add \(title.lowercased())")
    }
}

private struct ImportTileStyle: ButtonStyle {
    let hovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(hovered || configuration.isPressed ? FLDesign.accent.opacity(0.08) : FLDesign.inset,
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(hovered ? FLDesign.accent.opacity(0.6) : FLDesign.line))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

private struct VideoSelection: Identifiable {
    let id = UUID()
    let url: URL
    let existing: VideoClip?
}

private struct VideoClipSheet: View {
    let selection: VideoSelection
    let onImport: (VideoClip) -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState private var info: VideoInfo?
    @ViewState private var player: AVPlayer
    @ViewState private var start: Double
    @ViewState private var length: Double
    @ViewState private var error: String?

    init(selection: VideoSelection, onImport: @escaping (VideoClip) -> Void) {
        self.selection = selection
        self.onImport = onImport
        _info = ViewState(initialValue: selection.existing?.info)
        _player = ViewState(initialValue: AVPlayer(url: selection.url))
        _start = ViewState(initialValue: selection.existing?.start ?? 0)
        _length = ViewState(initialValue: selection.existing?.duration ?? 15)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(selection.existing == nil ? "Import video" : "Edit video segment")
                .font(.title2.weight(.semibold))
            Text(selection.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(.secondary)
            VideoPlayer(player: player)
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            if let info {
                Text(String(format: "Video length: %.1f s · %d × %d px", info.duration,
                            Int(info.size.width), Int(info.size.height)))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                VStack(alignment: .leading) {
                    Text(String(format: "Start: %.1f s", start)).monospacedDigit()
                    Slider(value: $start, in: 0...max(0, info.duration - 0.1), step: 0.1)
                        .onChange(of: start) { value in
                            length = min(length, allowedLength(info))
                            player.seek(to: CMTime(seconds: value, preferredTimescale: 600))
                        }
                }
                VStack(alignment: .leading) {
                    Text(String(format: "Segment length: %.1f s", length)).monospacedDigit()
                    Slider(value: $length, in: min(0.1, allowedLength(info))...allowedLength(info), step: 0.1)
                }
                Text("Choose up to 30 seconds. The app extracts only this segment; your original video stays untouched.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            } else {
                ProgressView("Reading video…")
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(selection.existing == nil ? "Import" : "Apply") {
                    guard let info else { return }
                    onImport(VideoClip(info: info, start: start, duration: length))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(info == nil)
            }
        }
        .padding(24)
        .frame(width: 520, height: 640)
        .onDisappear { player.pause(); player.replaceCurrentItem(with: nil) }
        .task {
            guard info == nil else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try VideoPipeline.probe(selection.url)
                }.value
                guard !Task.isCancelled else { return }
                info = result
                length = min(15, result.duration)
            } catch { self.error = error.localizedDescription }
        }
    }

    private func allowedLength(_ info: VideoInfo) -> Double {
        max(0.01, min(VideoPipeline.maximumClipDuration, info.duration - start))
    }
}

private struct InspectorCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            Divider()
            VStack(alignment: .leading, spacing: 10) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 4)
    }
}

private struct AspectRatioGrid: View {
    @Binding var selection: CanvasFormat
    let originalRatio: Double
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(CanvasFormat.allCases) { format in
                let selected = selection == format
                let ratio = format.ratio(original: originalRatio)
                Button { selection = format } label: {
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .strokeBorder(selected ? FLDesign.accent : Color.secondary, lineWidth: 1.5)
                            .frame(width: ratio >= 1 ? 28 : 28 * ratio,
                                   height: ratio >= 1 ? 28 / ratio : 28)
                            .frame(height: 29)
                        Text(shortTitle(for: format))
                            .font(.caption2.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? FLDesign.accent : Color.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(selected ? FLDesign.accent.opacity(0.12) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(selected ? FLDesign.accent.opacity(0.65) : Color.clear))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(format.title)
                .accessibilityValue(selected ? "Selected" : "Not selected")
            }
        }
    }

    private func shortTitle(for format: CanvasFormat) -> String {
        switch format {
        case .original: return "Original"
        case .square: return "1:1"
        case .portrait: return "4:5"
        case .landscape: return "5:4"
        case .widescreen: return "16:9"
        case .vertical: return "9:16"
        }
    }
}

private enum InfoSheet: String, Identifiable {
    case help, license
    var id: Self { self }
}

private struct AppInfoSheet: View {
    let sheet: InfoSheet
    let version: String
    @Environment(\.dismiss) private var dismiss

    private var licenseText: String {
        guard let url = Bundle.main.url(forResource: "LICENSE", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "FotoLoop is open source under the MIT License. See LICENSE in the project source."
        }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(sheet == .help ? "FotoLoop Help" : "MIT License")
                        .font(.title2.weight(.semibold))
                    Text("FotoLoop v\(version) · Made by Evakdo")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            Divider()
            if sheet == .help {
                VStack(alignment: .leading, spacing: 16) {
                    Label("Add photos, a folder, or one video. MP4 and MOV work well for video.", systemImage: "plus.square.on.square")
                    Label("For video, choose a segment up to 30 seconds. FPS samples fewer frames; Hold each frame makes each one last longer.", systemImage: "film")
                    Label("Drag frames in the right list to change their order. Click a thumbnail below the preview to jump to it.", systemImage: "square.stack.3d.up")
                    Label("Set FPS, direction and export settings, then save a GIF or MP4.", systemImage: "slider.horizontal.3")
                    Divider()
                    Text("Shortcuts")
                        .font(.headline)
                    Text("⌘O  Add photos\n⇧⌘↩  Export MP4")
                        .font(.body.monospaced())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
            } else {
                ScrollView {
                    Text(licenseText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(24)
        .frame(width: 560, height: 420)
    }
}

private struct PlaybackKey: Hashable {
    let photos: [URL]
    let selected: URL?
    let fps: Int
    let direction: PlaybackDirection
    let repetitions: Int
    let holdFrames: Int
    let active: Bool
    let playing: Bool
    let session: UUID
}

// Only this small view updates on playback ticks; controls and photo rows remain untouched.
private struct AnimationPreview: View {
    let photos: [URL]
    let selected: URL?
    let fps: Int
    let direction: PlaybackDirection
    let repetitions: Int
    let holdFrames: Int
    let canvas: CGSize
    let framing: ImageFraming
    let active: Bool
    let store: PreviewImageStore
    let session: UUID
    let onSelect: (URL) -> Void
    @ViewState private var image: CGImage?
    @ViewState private var currentURL: URL?
    @ViewState private var invalidImage = false
    @ViewState private var isPlaying = true
    @ViewState private var pausedPosition: Int?
    @ViewState private var currentPosition = 0

    private var playback: PlaybackKey {
        PlaybackKey(photos: photos, selected: selected, fps: fps, direction: direction,
                    repetitions: repetitions, holdFrames: holdFrames,
                    active: active, playing: isPlaying, session: session)
    }
    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { geometry in
                let ratio = canvas.width / canvas.height
                let width = min(geometry.size.width, geometry.size.height * ratio)
                let height = width / ratio
                ZStack {
                    if photos.isEmpty {
                        FLDesign.inset
                    } else {
                        Color.black
                    }
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: framing == .fit ? .fit : .fill)
                            .frame(width: width, height: height)
                            .clipped()
                    } else if photos.isEmpty {
                        VStack(spacing: 11) {
                            Image(systemName: "photo.stack")
                                .font(.system(size: 34, weight: .ultraLight))
                                .foregroundStyle(.secondary)
                                .frame(width: 72, height: 72)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
                            Text("Your canvas is ready").font(.title3.weight(.medium))
                            Text("Drop photos, a folder or a video here, or use the import buttons on the left.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    } else if invalidImage {
                        Label("Could not open this photo", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.white.opacity(0.8))
                    } else { ProgressView().colorScheme(.dark) }
                }
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if !photos.isEmpty {
                HStack {
                    Text(currentURL?.lastPathComponent ?? "Preview")
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text("\(Int(canvas.width)) × \(Int(canvas.height)) px")
                    Text("· \(fps) FPS")
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if !photos.isEmpty {
                HStack(spacing: 10) {
                    Button {
                        if isPlaying { pausedPosition = currentPosition }
                        isPlaying.toggle()
                    } label: { Image(systemName: isPlaying ? "pause.fill" : "play.fill") }
                    .accessibilityLabel(isPlaying ? "Pause preview" : "Play preview")
                    .disabled(!active)
                    Text("FRAMES").font(.caption2.weight(.semibold)).tracking(1.2).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(photos.count) frames").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 7) {
                            ForEach(Array(photos.enumerated()), id: \.element) { index, url in
                                TimelineFrame(url: url, index: index, store: store, session: session,
                                              isCurrent: currentURL == url, isSelected: selected == url) {
                                    pausedPosition = nil
                                    onSelect(url)
                                }
                                .id(url)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                    .frame(height: 84)
                    .onChange(of: currentURL) { url in
                        if let url, let index = photos.firstIndex(of: url), index.isMultiple(of: 5) {
                            proxy.scrollTo(url, anchor: .center)
                        }
                    }
                }
            }
        }
        .onDisappear { image = nil; currentURL = nil }
        .onChange(of: selected) { _ in pausedPosition = nil }
        .task(id: playback) {
            let order = AnimationSequence.heldIndices(count: photos.count, direction: direction, hold: holdFrames)
            guard !order.isEmpty else { image = nil; currentURL = nil; return }
            let startIndex = selected.flatMap { photos.firstIndex(of: $0) } ?? 0
            let start = ProcessInfo.processInfo.systemUptime
            let initial = pausedPosition ?? order.firstIndex(of: startIndex) ?? 0
            let total = order.count * repetitions
            var lastURL: URL?
            while !Task.isCancelled {
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                let position = (initial + Int(elapsed * Double(fps))) % total
                currentPosition = position
                let url = photos[order[position % order.count]]
                if lastURL != url {
                    let loaded = await store.image(for: url)
                    guard !Task.isCancelled else { return }
                    image = loaded
                    currentURL = url
                    invalidImage = loaded == nil
                    lastURL = url
                }
                guard active && isPlaying else { return }
                // Predecode the next frame during idle time, with the same bounded cache.
                let next = photos[order[(position + 1) % order.count]]
                _ = await store.image(for: next)
                guard !Task.isCancelled else { return }
                let now = ProcessInfo.processInfo.systemUptime - start
                let nextTick = (floor(now * Double(fps)) + 1) / Double(fps)
                do { try await Task.sleep(nanoseconds: UInt64(max(0.001, nextTick - now) * 1_000_000_000)) }
                catch { return }
            }
        }
    }
}

private struct TimelineFrame: View {
    let url: URL
    let index: Int
    let store: PreviewImageStore
    let session: UUID
    let isCurrent: Bool
    let isSelected: Bool
    let action: () -> Void
    @ViewState private var thumbnail: CGImage?

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor))
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable().scaledToFill().frame(width: 78, height: 74).clipped()
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                        .frame(width: 78, height: 74)
                }
                Text(String(format: "%02d", index + 1))
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 4))
                    .padding(4)
            }
            .frame(width: 78, height: 74)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(
                isCurrent ? FLDesign.accent : (isSelected ? Color.primary.opacity(0.6) : Color.clear), lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Frame \(index + 1), \(url.lastPathComponent)")
        .help(url.lastPathComponent)
        .task(id: session) { thumbnail = await store.image(for: url, maximum: 160) }
    }
}

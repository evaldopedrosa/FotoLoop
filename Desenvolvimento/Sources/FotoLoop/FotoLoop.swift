import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Disambiguate the macOS 13 property wrapper from the SDK 27 macro of the same name.
private typealias ViewState<Value> = SwiftUI.State<Value>

enum AppAppearance: String, CaseIterable, Identifiable {
    case automatic, light, dark
    var id: Self { self }
    var title: String {
        switch self { case .automatic: return "Automático"; case .light: return "Claro"; case .dark: return "Escuro" }
    }
    var colorScheme: ColorScheme? {
        switch self { case .automatic: return nil; case .light: return .light; case .dark: return .dark }
    }
}

@main
struct FotoLoopApp: App {
    @AppStorage("appearance") private var appearance: AppAppearance = .automatic
    var body: some Scene {
        WindowGroup("FotoLoop") {
            ContentView()
                .frame(minWidth: 880, minHeight: 720)
                .preferredColorScheme(appearance.colorScheme)
        }
        .defaultSize(width: 1040, height: 780)
        .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    @StateObject private var model = FotoLoopModel()
    @AppStorage("appearance") private var appearance: AppAppearance = .automatic

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 20) {
                AnimationPreview(photos: model.photos, selected: model.selected, fps: model.fps,
                                 pingPong: model.pingPong, repetitions: model.repetitions,
                                 canvas: model.canvas, framing: model.framing,
                                 active: !model.isExporting, store: model.images, session: model.sessionID)
                    .id(model.sessionID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                controls.frame(width: 300)
            }
            .padding(20)
            .frame(maxHeight: .infinity)
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("FotoLoop").font(.title2.weight(.semibold))
                Text("Sequências de fotos em movimento").font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button { choosePhotos(folder: false) } label: { Label("Adicionar fotos…", systemImage: "plus") }
                .keyboardShortcut("o", modifiers: .command).disabled(model.busy)
            Button { choosePhotos(folder: true) } label: { Label("Importar pasta…", systemImage: "folder") }
                .disabled(model.busy)
            Button { model.clearSession() } label: { Label("Encerrar sessão", systemImage: "xmark.circle") }
                .disabled((model.photos.isEmpty && !model.isImporting) || model.isExporting)
                .help("Remover as fotos da sessão e voltar ao início. Os arquivos originais são preservados.")
            Menu {
                ForEach(AppAppearance.allCases) { choice in
                    Button { appearance = choice } label: {
                        if choice == appearance { Label(choice.title, systemImage: "checkmark") }
                        else { Text(choice.title) }
                    }
                }
            } label: { Image(systemName: "circle.lefthalf.filled") }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("Aparência").help("Aparência: \(appearance.title)")
        }
        .padding(20)
        .background(.bar)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Animação") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Velocidade", selection: $model.fps) {
                        ForEach(FotoLoopModel.frameRates, id: \.self) { Text("\($0) fotos/s").tag($0) }
                    }
                    .help("Fotos por segundo. No GIF, o tempo é aproximado em intervalos de 0,01 s.")
                    Toggle("Ping-pong", isOn: $model.pingPong)
                    Stepper(value: $model.repetitions, in: 1...20) {
                        HStack { Text("Repetições"); Spacer(); Text("\(model.repetitions)x").monospacedDigit() }
                    }
                    .accessibilityLabel("Repetições: \(model.repetitions)")
                    Text("\(model.photos.count) fotos · ≈ \(model.duration.formatted(.number.precision(.fractionLength(2)))) s")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.top, 6).frame(maxWidth: .infinity)
            }
            .disabled(model.busy)

            GroupBox("Exportação") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Proporção", selection: $model.format) {
                        ForEach(CanvasFormat.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Enquadramento", selection: $model.framing) {
                        ForEach(ImageFraming.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .help("Ajustar preserva a foto inteira com margens. Preencher recorta pelo centro, sem esticar.")
                    Picker("Resolução máxima", selection: $model.maximumDimension) {
                        ForEach([720, 1080, 1920], id: \.self) { Text("\($0) px").tag($0) }
                    }
                    Picker("Qualidade", selection: $model.quality) {
                        Text("Menor arquivo").tag(1)
                        Text("Equilibrada").tag(2)
                        Text("Mais alta").tag(3)
                    }
                }
                .padding(.top, 6).frame(maxWidth: .infinity)
            }
            .disabled(model.busy)

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Fotos").font(.headline)
                    Spacer()
                    Text("\(model.photos.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text("Arraste para reorganizar ou use as setas.").font(.caption).foregroundStyle(.secondary)
                NativePhotoList(model: model)
                .frame(minHeight: 110)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor).opacity(0.5)))
                .disabled(model.busy)
                HStack {
                    Button { model.moveSelected(-1) } label: { Image(systemName: "arrow.up") }
                        .accessibilityLabel("Mover foto para cima").help("Mover a foto selecionada para cima")
                        .disabled(selectedIndex == nil || selectedIndex == 0)
                    Button { model.moveSelected(1) } label: { Image(systemName: "arrow.down") }
                        .accessibilityLabel("Mover foto para baixo").help("Mover a foto selecionada para baixo")
                        .disabled(selectedIndex == nil || selectedIndex == model.photos.count - 1)
                    Spacer()
                    Button { model.removeSelected() } label: { Image(systemName: "trash") }
                        .accessibilityLabel("Remover foto").help("Remover a foto selecionada da sessão")
                        .disabled(model.selected == nil)
                }
                .disabled(model.busy)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var selectedIndex: Int? { model.selected.flatMap { model.photos.firstIndex(of: $0) } }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.isExporting {
                if model.exportProgress < 0.8 {
                    ProgressView(value: model.exportProgress / 0.8).frame(width: 70)
                        .accessibilityLabel("Preparando fotos")
                } else { ProgressView().controlSize(.small) }
            } else if model.isImporting { ProgressView().controlSize(.small) }
            Text(model.status).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 10)
            Button("Exportar GIF…") { chooseDestination(.gif) }
                .buttonStyle(.borderedProminent)
            Button("Exportar MP4…") { chooseDestination(.mp4) }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
        }
        .disabled(model.photos.isEmpty || model.busy)
        .padding(16)
        .background(.bar)
    }

    private func choosePhotos(folder: Bool) {
        let panel = NSOpenPanel()
        panel.title = folder ? "Escolha uma pasta com fotos" : "Escolha as fotos da sequência"
        panel.canChooseFiles = !folder
        panel.canChooseDirectories = folder
        panel.allowsMultipleSelection = !folder
        if !folder { panel.allowedContentTypes = [.jpeg, .png, .heic] }
        panel.begin { response in
            guard response == .OK else { return }
            model.importPhotos(panel.urls)
        }
    }
    private func chooseDestination(_ kind: OutputKind) {
        let panel = NSSavePanel()
        panel.title = kind == .gif ? "Exportar animação GIF" : "Exportar vídeo MP4"
        panel.nameFieldStringValue = kind == .gif ? "FotoLoop.gif" : "FotoLoop.mp4"
        panel.allowedContentTypes = [kind == .gif ? .gif : .mpeg4Movie]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            model.export(kind, to: url)
        }
    }
}

private struct PlaybackKey: Hashable {
    let photos: [URL]
    let selected: URL?
    let fps: Int
    let pingPong: Bool
    let repetitions: Int
    let active: Bool
    let session: UUID
}

// Only this small view updates on playback ticks; controls and photo rows remain untouched.
private struct AnimationPreview: View {
    let photos: [URL]
    let selected: URL?
    let fps: Int
    let pingPong: Bool
    let repetitions: Int
    let canvas: CGSize
    let framing: ImageFraming
    let active: Bool
    let store: PreviewImageStore
    let session: UUID
    @ViewState private var image: CGImage?
    @ViewState private var currentURL: URL?
    @ViewState private var invalidImage = false

    private var playback: PlaybackKey {
        PlaybackKey(photos: photos, selected: selected, fps: fps, pingPong: pingPong,
                    repetitions: repetitions, active: active, session: session)
    }
    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { geometry in
                let ratio = canvas.width / canvas.height
                let width = min(geometry.size.width, geometry.size.height * ratio)
                let height = width / ratio
                ZStack {
                    Color.black
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: framing == .fit ? .fit : .fill)
                            .frame(width: width, height: height)
                            .clipped()
                    } else if photos.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 38, weight: .light))
                            Text("Sua pré-visualização aparece aqui").font(.headline)
                            Text("Adicione fotos ou importe uma pasta.").font(.callout)
                        }
                        .foregroundStyle(.white.opacity(0.75))
                    } else if invalidImage {
                        Label("Não foi possível abrir esta foto", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.white.opacity(0.8))
                    } else { ProgressView().colorScheme(.dark) }
                }
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Text(currentURL?.lastPathComponent ?? "Pré-visualização")
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                if !photos.isEmpty {
                    Text("\(Int(canvas.width)) × \(Int(canvas.height)) px")
                    Text("· \(fps) fotos/s")
                }
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .onDisappear { image = nil; currentURL = nil }
        .task(id: playback) {
            let order = AnimationSequence.indices(count: photos.count, pingPong: pingPong)
            guard !order.isEmpty else { image = nil; currentURL = nil; return }
            let startIndex = selected.flatMap { photos.firstIndex(of: $0) } ?? 0
            let start = ProcessInfo.processInfo.systemUptime
            let initial = order.firstIndex(of: startIndex) ?? 0
            let total = order.count * repetitions
            var lastURL: URL?
            while !Task.isCancelled {
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                let position = (initial + Int(elapsed * Double(fps))) % total
                let url = photos[order[position % order.count]]
                if lastURL != url {
                    let loaded = await store.image(for: url)
                    guard !Task.isCancelled else { return }
                    image = loaded
                    currentURL = url
                    invalidImage = loaded == nil
                    lastURL = url
                }
                guard active else { return }
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

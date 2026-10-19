import Testing
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import FotoLoop

@Suite(.serialized)
final class FotoLoopTests {
    let root: URL
    init() throws {
        root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("work/tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func image(_ name: String, width: Int = 120, height: Int = 80, color: CGColor = CGColor(red: 1, green: 0, blue: 0, alpha: 1), orientation: Int = 1) throws -> URL {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = root.appendingPathComponent(name)
        let type: UTType = name.hasSuffix("png") ? .png : name.hasSuffix("heic") ? .heic : .jpeg
        let output = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, context.makeImage()!, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(output))
        return url
    }
    func photos() throws -> [URL] {
        try [CGColor(red: 1, green: 0, blue: 0, alpha: 1), CGColor(red: 0, green: 1, blue: 0, alpha: 1),
             CGColor(red: 0, green: 0, blue: 1, alpha: 1), CGColor(red: 1, green: 1, blue: 0, alpha: 1)]
            .enumerated().map { try image("foto\($0.offset).jpg", color: $0.element) }
    }
    func options(_ photos: [URL], fps: Int = 8, pingPong: Bool = false, repetitions: Int = 1, format: CanvasFormat = .original, framing: ImageFraming = .fit) -> ExportOptions {
        ExportOptions(photos: photos, fps: fps, maximumDimension: 720, quality: 2, pingPong: pingPong,
                      repetitions: repetitions, format: format, framing: framing)
    }
    @Test
    func testSequenceTimingAndEndpoints() {
        #expect((AnimationSequence.indices(count: 0, pingPong: true)) == ([]))
        #expect((AnimationSequence.indices(count: 1, pingPong: true)) == ([0]))
        #expect((AnimationSequence.indices(count: 2, pingPong: true)) == ([0, 1]))
        #expect((AnimationSequence.indices(count: 4, pingPong: true)) == ([0, 1, 2, 3, 2, 1]))
        #expect((AnimationSequence.indices(count: 4, pingPong: false)) == ([0, 1, 2, 3]))
        #expect((AnimationSequence.duration(count: 4, pingPong: false, repetitions: 4, fps: 4)) == (4))
        #expect((AnimationSequence.duration(count: 4, pingPong: true, repetitions: 4, fps: 6)) == (4))
    }
    @Test
    func testCanvasAndFraming() {
        for format in CanvasFormat.allCases {
            let ratio = format.ratio(original: 1.5)
            let canvas = AnimationSequence.dimensions(ratio: ratio, maximum: 1080, original: CGSize(width: 6000, height: 4000))
            #expect((max(canvas.width, canvas.height)) <= (1080))
            #expect((Int(canvas.width) % 2) == (0))
            #expect((Int(canvas.height) % 2) == (0))
            #expect(abs((canvas.width / canvas.height) - (ratio)) <= (0.005))
            for framing in ImageFraming.allCases {
                let rect = AnimationSequence.drawRect(image: CGSize(width: 6000, height: 4000), canvas: canvas, framing: framing)
                #expect(abs((rect.width / rect.height) - (1.5)) <= (0.00001))
                if framing == .fit {
                    #expect((rect.width) <= (canvas.width + 0.001))
                    #expect((rect.height) <= (canvas.height + 0.001))
                } else {
                    #expect((rect.width + 0.001) >= (canvas.width))
                    #expect((rect.height + 0.001) >= (canvas.height))
                }
            }
        }
        #expect((AnimationSequence.dimensions(ratio: 1.5, maximum: 1920, original: CGSize(width: 120, height: 80))) == (CGSize(width: 120, height: 80)))
    }
    @Test
    func testImportDedupNaturalOrderAndManualOrder() throws {
        let ten = try image("foto10.jpg"), two = try image("foto2.png"), one = try image("foto1.heic")
        let heic = try #require(PhotoImages.load(one, maximum: 80))
        #expect(heic.width == 80)
        #expect(heic.height <= 80)
        let folder = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder.jpg"), withIntermediateDirectories: true)
        try Data("ignored".utf8).write(to: folder.appendingPathComponent("readme.txt"))
        let nested = folder.appendingPathComponent("foto3.jpg")
        try FileManager.default.copyItem(at: ten, to: nested)
        #expect((try PhotoImport.collect([root, root, two], existing: [])) == ([one, two, nested, ten]))
        #expect((try PhotoImport.collect([root], existing: [ten, one])) == ([ten, one, two, nested]))
    }
    @Test
    func testImageOrientationAndBoundedDecode() throws {
        let url = try image("rotated.jpg", width: 1200, height: 800, orientation: 6)
        #expect((PhotoImages.dimensions(of: url)) == (CGSize(width: 800, height: 1200)))
        let loaded = try #require(PhotoImages.load(url, maximum: 160))
        #expect((loaded.height) == (160))
        #expect((loaded.width) < (loaded.height))
        let broken = root.appendingPathComponent("broken.jpg")
        try Data("bad".utf8).write(to: broken)
        #expect(PhotoImages.load(broken, maximum: 160) == nil)
    }
    @Test
    func testCacheBudgetReuseAndClear() async throws {
        let urls = try photos()
        let store = PreviewImageStore(limit: 80_000)
        _ = await store.image(for: urls[0], maximum: 120)
        _ = await store.image(for: urls[0], maximum: 120)
        let decodes = await store.decodes, hits = await store.hits
        #expect((decodes) == (1))
        #expect((hits) == (1))
        for url in urls { _ = await store.image(for: url, maximum: 120) }
        let cost = await store.cost
        #expect((cost) <= (80_000))
        await store.removeAll()
        let cleared = await store.cost
        #expect((cleared) == (0))
    }
    @MainActor
    @Test
    func testSessionClearCancelReimportAndReorder() async throws {
        let urls = try photos()
        let model = FotoLoopModel()
        model.importPhotos(urls)
        try await finishImport(model)
        #expect((model.photos) == (urls))
        let session = model.sessionID
        let old = model.images
        _ = await old.image(for: urls[0])
        model.selected = urls[0]
        model.moveSelected(1)
        #expect((model.photos) == ([urls[1], urls[0], urls[2], urls[3]]))
        model.move(from: IndexSet(integer: 3), to: 0)
        #expect((model.photos.first) == (urls[3]))
        #expect((model.selected) == (urls[0]))
        model.removeSelected()
        #expect(!(model.photos.contains(urls[0])))
        model.fps = 30; model.pingPong = true; model.repetitions = 4; model.format = .vertical
        model.clearSession()
        #expect(model.photos.isEmpty)
        #expect(model.selected == nil)
        #expect((model.fps) == (10))
        #expect((model.repetitions) == (1))
        #expect(!(model.pingPong))
        #expect((model.format) == (.original))
        #expect(!(old === model.images))
        // Clear while an import is queued, then start a fresh session.
        model.importPhotos(urls)
        model.clearSession()
        model.importPhotos([urls[2]])
        try await finishImport(model)
        #expect((model.photos) == ([urls[2]]))
        model.importPhotos([urls[0]])
        try await finishImport(model)
        let freshOrder = model.photos
        let coordinator = NativePhotoList.Coordinator(model: model)
        coordinator.sync(model)
        #expect(!coordinator.applyDrop("\(session.uuidString)|\(urls[2].absoluteString)", at: 2))
        #expect(model.photos == freshOrder)
        for _ in 0..<50 {
            if await old.cost == 0 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let cost = await old.cost
        #expect((cost) == (0))
    }
    @MainActor
    @Test
    func testNativeDragPasteboardAndInsertion() async throws {
        let urls = try photos()
        let model = FotoLoopModel()
        model.importPhotos(urls)
        try await finishImport(model)
        let coordinator = NativePhotoList.Coordinator(model: model)
        coordinator.sync(model)
        let table = NSTableView()
        let item = try #require(coordinator.tableView(table, pasteboardWriterForRow: 0) as? NSPasteboardItem)
        let token = try #require(item.string(forType: NativePhotoList.dragType))
        #expect(coordinator.applyDrop(token, at: 3))
        #expect(model.photos == [urls[1], urls[2], urls[0], urls[3]])
        #expect(model.selected == urls[0])
        #expect(!coordinator.applyDrop("external text", at: 0))
        #expect(!coordinator.applyDrop(token, at: 99))
        model.clearSession()
        model.importPhotos(urls)
        try await finishImport(model)
        #expect(!coordinator.applyDrop(token, at: 3))
        #expect(model.photos == urls)
    }
    @MainActor
    func finishImport(_ model: FotoLoopModel) async throws {
        for _ in 0..<500 {
            if !model.isImporting { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        Issue.record("Import timeout")
    }

    func probe(_ url: URL) throws -> [String: Any] {
        let ffmpeg = try #require(FotoExporter.ffmpegURL())
        let executable = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
        let process = Process(), output = Pipe()
        process.executableURL = executable
        process.arguments = ["-v", "error", "-count_frames", "-select_streams", "v:0", "-show_entries", "stream=codec_name,width,height,pix_fmt,color_range,avg_frame_rate,nb_read_frames,duration:format=duration", "-of", "json", url.path]
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect((process.terminationStatus) == (0))
        return try #require((JSONSerialization.jsonObject(with: data) as? [String: Any])?["streams"] as? [[String: Any]]).first!
    }
    @Test
    func testExportFormatAndFramingMatrix() throws {
        let urls = try photos()
        for format in CanvasFormat.allCases {
            for framing in ImageFraming.allCases {
                for kind in [OutputKind.gif, .mp4] {
                    let path = root.appendingPathComponent("\(format)-\(framing).\(kind == .gif ? "gif" : "mp4")")
                    try FotoExporter.write(options: options(urls, format: format, framing: framing), kind: kind, to: path)
                    let metadata = try probe(path)
                    let expected = AnimationSequence.dimensions(ratio: format.ratio(original: 1.5), maximum: 720, original: CGSize(width: 120, height: 80))
                    #expect((metadata["width"] as? Int) == (Int(expected.width)))
                    #expect((metadata["height"] as? Int) == (Int(expected.height)))
                    #expect((metadata["codec_name"] as? String) == (kind == .gif ? "gif" : "h264"))
                    if kind == .mp4 {
                        #expect((metadata["pix_fmt"] as? String) == ("yuv420p"))
                        #expect((metadata["avg_frame_rate"] as? String) == ("30/1"))
                        #expect((metadata["color_range"] as? String) == ("tv"))
                    }
                    if let time = (metadata["duration"] as? String).flatMap(Double.init) {
                        #expect(abs((time) - (0.5)) <= (kind == .gif ? 0.02 : 1.0 / 30))
                    } else { Issue.record("Missing duration") }
                }
            }
        }
    }
    @Test
    func testExportCadencePingPongAndRepetitions() throws {
        let urls = try photos()
        for fps in FotoLoopModel.frameRates {
            for kind in [OutputKind.gif, .mp4] {
                let path = root.appendingPathComponent("fps\(fps).\(kind == .gif ? "gif" : "mp4")")
                let config = options(urls, fps: fps, pingPong: true, repetitions: 4)
                try FotoExporter.write(options: config, kind: kind, to: path)
                let metadata = try probe(path)
                let duration = try #require((metadata["duration"] as? String).flatMap(Double.init))
                let expected = AnimationSequence.duration(count: 4, pingPong: true, repetitions: 4, fps: fps)
                #expect(abs((duration) - (expected)) <= (kind == .gif ? 0.02 : 1.0 / 30))
                if kind == .gif {
                    let source = try #require(CGImageSourceCreateWithURL(path as CFURL, nil))
                    #expect((CGImageSourceGetCount(source)) == (24))
                    let properties = try #require(CGImageSourceCopyProperties(source, nil) as? [CFString: Any])
                    let gif = try #require(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
                    #expect(((gif[kCGImagePropertyGIFLoopCount] as? NSNumber)?.intValue) == (0))
                    // Inspect all frames: red, green, blue, yellow, blue, green, repeated four times.
                    let expectedOrder = [0, 1, 2, 3, 2, 1]
                    for frame in 0..<24 {
                        let image = try #require(CGImageSourceCreateImageAtIndex(source, frame, nil))
                        let rgb = pixel(image, x: image.width / 2, y: image.height / 2)
                        let index = expectedOrder[frame % 6]
                        #expect((rgb.0 > 100) == (index == 0 || index == 3))
                        #expect((rgb.1 > 100) == (index == 1 || index == 3))
                        #expect((rgb.2 > 100) == (index == 2))
                    }
                }
            }
        }
    }
    func pixel(_ image: CGImage, x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
        var buffer = [UInt8](repeating: 0, count: 4)
        buffer.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: -x, y: -y, width: image.width, height: image.height))
        }
        return (buffer[0], buffer[1], buffer[2])
    }
    @Test
    func testFitMarginsFillAndAtomicOverwrite() throws {
        let url = try image("wide.jpg", width: 120, height: 40)
        let output = root.appendingPathComponent("with space.gif")
        for framing in ImageFraming.allCases {
            try FotoExporter.write(options: options([url], format: .square, framing: framing), kind: .gif, to: output)
            let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
            let frame = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let edge = pixel(frame, x: 60, y: 4)
            #expect((edge.0 > 100) == (framing == .fill))
        }
        let previous = try Data(contentsOf: output)
        let bad = root.appendingPathComponent("bad.jpg")
        try Data("bad".utf8).write(to: bad)
        #expect(throws: ExportError.self) { try FotoExporter.write(options: options([url, bad]), kind: .gif, to: output) }
        #expect((try Data(contentsOf: output)) == (previous))
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        #expect(!(files.contains { $0.lastPathComponent.hasPrefix(".FotoLoop-") }))
    }
}

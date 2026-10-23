import Foundation
import CoreGraphics
import ImageIO

// Shared by preview and export, so ordering, timing and framing cannot drift apart.
enum CanvasFormat: String, CaseIterable, Identifiable, Sendable {
    case original, square, portrait, landscape, widescreen, vertical
    var id: Self { self }
    var title: String {
        switch self {
        case .original: return "Original"
        case .square: return "Square · 1:1"
        case .portrait: return "Portrait · 4:5"
        case .landscape: return "Landscape · 5:4"
        case .widescreen: return "Widescreen · 16:9"
        case .vertical: return "Vertical · 9:16"
        }
    }
    func ratio(original: Double) -> Double {
        switch self {
        case .original: return original
        case .square: return 1
        case .portrait: return 4.0 / 5
        case .landscape: return 5.0 / 4
        case .widescreen: return 16.0 / 9
        case .vertical: return 9.0 / 16
        }
    }
}

enum ImageFraming: String, CaseIterable, Identifiable, Sendable {
    case fit, fill
    var id: Self { self }
    var title: String { self == .fit ? "Fit" : "Fill" }
}

enum PlaybackDirection: String, CaseIterable, Identifiable, Sendable {
    case forward, reverse, pingPong
    var id: Self { self }
    var title: String {
        switch self {
        case .forward: return "Forward"
        case .reverse: return "Reverse"
        case .pingPong: return "Ping-pong"
        }
    }
}

enum AnimationSequence {
    static func indices(count: Int, direction: PlaybackDirection) -> [Int] {
        guard count > 0 else { return [] }
        let forward = Array(0..<count)
        switch direction {
        case .forward: return forward
        case .reverse: return Array(forward.reversed())
        case .pingPong: return count > 2 ? forward + Array((1..<(count - 1)).reversed()) : forward
        }
    }
    static func duration(count: Int, direction: PlaybackDirection, repetitions: Int, fps: Int) -> Double {
        Double(indices(count: count, direction: direction).count * repetitions) / Double(fps)
    }
    static func heldIndices(count: Int, direction: PlaybackDirection, hold: Int) -> [Int] {
        indices(count: count, direction: direction).flatMap { Array(repeating: $0, count: max(1, hold)) }
    }
    static func duration(count: Int, direction: PlaybackDirection, repetitions: Int, fps: Int, hold: Int) -> Double {
        Double(heldIndices(count: count, direction: direction, hold: hold).count * repetitions) / Double(fps)
    }
    static func dimensions(ratio: Double, maximum: Int, original: CGSize) -> CGSize {
        // Avoid enlarging small originals; dimensions are even for H.264.
        let longest = min(Double(maximum), max(original.width, original.height))
        let width = ratio >= 1 ? longest : longest * ratio
        let height = ratio >= 1 ? longest / ratio : longest
        return CGSize(width: max(2, floor(width / 2) * 2), height: max(2, floor(height / 2) * 2))
    }
    static func drawRect(image: CGSize, canvas: CGSize, framing: ImageFraming) -> CGRect {
        let x = canvas.width / image.width, y = canvas.height / image.height
        let scale = framing == .fit ? min(x, y) : max(x, y)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}

enum PhotoImages {
    static func dimensions(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0 else { return nil }
        let rotated = [5, 6, 7, 8].contains((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1)
        return CGSize(width: rotated ? height.doubleValue : width.doubleValue,
                      height: rotated ? width.doubleValue : height.doubleValue)
    }
    static func load(_ url: URL, maximum: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(2, maximum),
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
}

// Serial decoding off the main actor; strict LRU byte and count limits, not a full-resolution cache.
actor PreviewImageStore {
    private struct Key: Hashable { let url: URL; let maximum: Int }
    private struct Entry { let image: CGImage; let cost: Int; var access: UInt64 }
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    private(set) var cost = 0
    private(set) var decodes = 0
    private(set) var hits = 0
    let limit: Int
    init(limit: Int = 64 * 1024 * 1024) { self.limit = limit }

    func image(for url: URL, maximum: Int = 960) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let key = Key(url: url, maximum: maximum)
        clock &+= 1
        if var entry = entries[key] {
            hits += 1
            entry.access = clock
            entries[key] = entry
            return entry.image
        }
        let image = autoreleasepool { PhotoImages.load(url, maximum: maximum) }
        guard !Task.isCancelled, let image else { return nil }
        decodes += 1
        let bytes = image.bytesPerRow * image.height
        guard bytes <= limit else { return image }
        while cost + bytes > limit || entries.count >= 128 {
            guard let oldest = entries.min(by: { $0.value.access < $1.value.access }) else { break }
            cost -= oldest.value.cost
            entries.removeValue(forKey: oldest.key)
        }
        entries[key] = Entry(image: image, cost: bytes, access: clock)
        cost += bytes
        return image
    }
    func removeAll() { entries.removeAll(); cost = 0 }
}

enum PhotoImport {
    static func collect(_ inputs: [URL], existing: [URL]) throws -> [URL] {
        let extensions: Set<String> = ["jpg", "jpeg", "png", "heic"]
        var known = Set(existing.map(\.standardizedFileURL))
        var added: [URL] = []
        func accept(_ url: URL) throws {
            try Task.checkCancellation()
            guard extensions.contains(url.pathExtension.lowercased()),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return }
            let normalized = url.standardizedFileURL
            if known.insert(normalized).inserted { added.append(normalized) }
        }
        for input in inputs {
            try Task.checkCancellation()
            if (try? input.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                guard let enumerator = FileManager.default.enumerator(at: input, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
                for case let url as URL in enumerator { try accept(url) }
            } else { try accept(input) }
        }
        added.sort {
            let order = $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
            return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
        }
        // Keep the user's manual order when adding to an existing session.
        return existing + added
    }
}

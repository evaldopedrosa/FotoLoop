// Compile with PhotoPipeline.swift; see PERFORMANCE.md. Only uses synthetic photos in work/.
import AppKit
import ImageIO
import UniformTypeIdentifiers
import Darwin

@main
struct PerformanceMeasurement {
    static func main() async throws {
        let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "cached-preview"
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("work/performance/photos")
        if mode == "generate" { try generate(root); return }
        let urls = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
        let store = PreviewImageStore()
        var samples: [Double] = [], largestBuffer = 0
        for _ in 0..<3 {
            for url in urls {
                let start = ProcessInfo.processInfo.systemUptime
                let image: CGImage
                if mode == "cached-preview" {
                    guard let loaded = await store.image(for: url) else { fatalError("Invalid synthetic image") }
                    image = loaded
                } else if mode == "preview-before" {
                    image = autoreleasepool {
                        let ns = NSImage(contentsOf: url)!
                        return ns.cgImage(forProposedRect: nil, context: nil, hints: nil)!
                    }
                } else {
                    guard let loaded = autoreleasepool(invoking: { PhotoImages.load(url, maximum: mode == "export-before" ? 16384 : 1080) }) else { fatalError("Invalid synthetic image") }
                    image = loaded
                }
                autoreleasepool {
                    let context = CGContext(data: nil, width: 1080, height: 720, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    context.draw(image, in: CGRect(x: 0, y: 0, width: 1080, height: 720))
                }
                largestBuffer = max(largestBuffer, image.bytesPerRow * image.height)
                samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            }
        }
        func stats(_ values: [Double]) -> [String: Double] {
            let sorted = values.sorted()
            return ["median_ms": sorted[sorted.count / 2], "p95_ms": sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))], "total_ms": sorted.reduce(0, +)]
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        var report: [String: Any] = ["mode": mode, "frames": samples.count, "all": stats(samples),
                                   "decoded_bytes_per_image": largestBuffer, "process_peak_rss_bytes": usage.ru_maxrss]
        if mode == "cached-preview" {
            report["warm"] = stats(Array(samples.dropFirst(urls.count)))
            report["cache_bytes"] = await store.cost
            report["decodes"] = await store.decodes
            report["hits"] = await store.hits
            await store.removeAll()
            report["cache_bytes_after_clear"] = await store.cost
        }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    static func generate(_ root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for i in 0..<24 {
            autoreleasepool {
                let context = CGContext(data: nil, width: 6000, height: 4000, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                let colors = [CGColor(red: 0.10 + Double(i) / 80, green: 0.23, blue: 0.55, alpha: 1),
                              CGColor(red: 0.88, green: 0.58 + Double(i % 4) / 20, blue: 0.32, alpha: 1)]
                let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
                context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 6000, y: 4000), options: [])
                for n in 0..<80 {
                    context.setFillColor(CGColor(red: Double((n * 7 + i) % 13) / 13, green: Double(n % 8) / 10, blue: 0.6, alpha: 0.5))
                    context.fillEllipse(in: CGRect(x: (n * 349 + i * 83) % 5800, y: (n * 173) % 3800, width: 200, height: 200))
                }
                let url = root.appendingPathComponent(String(format: "foto%02d.jpg", i))
                let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
                CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.94] as CFDictionary)
                precondition(CGImageDestinationFinalize(destination))
            }
        }
    }
}

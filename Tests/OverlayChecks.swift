import AppKit
import CoreImage
import CoreMedia
import Vision

/// Exercises the actual compositor with synthetic camera pixels, then reads the output with Vision.
/// No physical camera, permissions, meeting account, or activated extension is required.
@main
enum OverlayChecks {
    static var checks = 0
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw VideoError.message("FAIL: \(message)") }
        checks += 1
        print("PASS: \(message)")
    }

    static func codes(_ image: CGImage) throws -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([request])
        return request.results?.compactMap(\.payloadStringValue) ?? []
    }

    static func scaled(_ image: CGImage) -> CGImage {
        let context = CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: 640, height: 360))
        return context.makeImage()!
    }

    static func pixel(_ sample: CMSampleBuffer, x: Int, y: Int) -> (r: Int, b: Int) {
        let buffer = sample.imageBuffer!
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        return (Int(bytes[offset + 2]), Int(bytes[offset]))
    }

    static func run(root: String) throws {
        let logo = NSImage(contentsOfFile: root + "/Resources/MovemberMo.png")?
            .cgImage(forProposedRect: nil, context: nil, hints: nil)
        try check(logo != nil, "Official Movember logo loads")
        var config = OverlayConfiguration(qrURL: "https://movember.com/m/example?utm_source=video",
                                          displayURL: "mo.example/fundraiser")
        let compositor = try FrameCompositor(configuration: config, logo: logo)
        let pool = try VideoFormat.pool()
        var input: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &input)
        let camera = input!
        CVPixelBufferLockBaseAddress(camera, [])
        for y in 0..<VideoFormat.height {
            let row = CVPixelBufferGetBaseAddress(camera)!.advanced(by: y * CVPixelBufferGetBytesPerRow(camera))
                .assumingMemoryBound(to: UInt32.self)
            for x in 0..<VideoFormat.width { row[x] = x < 640 ? 0xFFFF0000 : 0xFF0000FF }
        }
        CVPixelBufferUnlockBaseAddress(camera, [])

        let time = CMTime(value: 12, timescale: 1)
        var sample = try compositor.render(camera, at: time)
        var image = compositor.preview(sample)!
        try check(image.width == 1280 && image.height == 720, "Composited output is 720p")
        try check(CMTimeCompare(sample.presentationTimeStamp, time) == 0, "Output preserves the host timestamp")
        try check(try codes(image) == [config.qrURL], "QR decodes to destination, independently of written URL")
        try check(try codes(scaled(image)) == [config.qrURL], "QR decodes after downscaling to 640 × 360")
        let recognition = VNRecognizeTextRequest()
        recognition.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: image).perform([recognition])
        let text = recognition.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") ?? ""
        try check(text.contains(config.displayURL), "Written URL is readable in rendered pixels")
        try check(text.uppercased().contains("MOVEMBER"), "Movember wordmark appears in rendered pixels")
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: root + "/build/verification/overlay.png"))

        for corner in OverlayConfiguration.Corner.allCases {
            config.corner = corner
            config.mirrorCamera = true
            try compositor.configure(config)
            sample = try compositor.render(camera, at: time)
            image = compositor.preview(sample)!
            try check(try codes(image) == [config.qrURL], "QR stays readable with mirroring and position \(corner.rawValue)")
            let left = pixel(sample, x: 400, y: 360)
            let right = pixel(sample, x: 900, y: 360)
            try check(left.b > 240 && right.r > 240, "Camera pixels are mirrored in position \(corner.rawValue)")
        }

        compositor.isOverlayEnabled = false
        sample = try compositor.render(camera, at: time)
        try check(try codes(compositor.preview(sample)!).isEmpty, "Menu bar bypass removes the QR overlay")
        let bypass = pixel(sample, x: 100, y: 100)
        try check(bypass.b > 240 && bypass.r < 10, "Bypass preserves the mirrored camera feed under the old overlay")
        compositor.isOverlayEnabled = true

        config.qrURL = "https://movember.com/m/updated"
        try compositor.configure(config)
        try check(try codes(compositor.preview(compositor.render(camera, at: time))!) == [config.qrURL],
                  "Applying settings replaces the old QR destination")
        var invalid = config
        invalid.qrURL = "javascript:alert(1)"
        var rejected = false
        do { try compositor.configure(invalid) } catch { rejected = true }
        try check(rejected && compositor.configuration == config, "Invalid settings leave the active overlay unchanged")

        config.qrURL = "https://example.com/" + String(repeating: "x", count: 200)
        try compositor.configure(config)
        image = compositor.preview(try compositor.render(camera, at: time))!
        try check(try codes(image) == [config.qrURL], "Long supported destinations still decode at 720p")
        try check(try codes(scaled(image)) == [config.qrURL], "Long supported destinations still decode at 360p")

        config = OverlayConfiguration()
        try compositor.configure(config)
        image = compositor.preview(try compositor.render(nil, at: time))!
        try check(try codes(image) == [config.qrURL], "Idle preview shows the configured overlay without a camera")
        let encoded = try JSONEncoder().encode(config)
        try check(try JSONDecoder().decode(OverlayConfiguration.self, from: encoded) == config,
                  "Saved configuration round-trips without changing either URL")
        let suite = "MovemberCam.checks.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let initial = OverlayPreferences.load(from: preferences)
        try check(initial.qrURL == "https://movember.com/t/musta-ch" && initial.displayURL == initial.qrURL,
                  "Both new preferences default to the musta-ch fundraiser")
        let custom = OverlayConfiguration(qrURL: "https://example.com/donate", displayURL: "example.com/my-fundraiser",
                                          corner: .left, mirrorCamera: true)
        OverlayPreferences.save(custom, to: preferences)
        let reopened = UserDefaults(suiteName: suite)!
        try check(OverlayPreferences.load(from: reopened) == custom,
                  "Reopening preferences preserves custom URLs, QR position and mirroring")
        OverlayPreferences.save(OverlayConfiguration(qrURL: "https://movember.com", displayURL: "movember.com"), to: preferences)
        try check(OverlayPreferences.load(from: preferences) == OverlayConfiguration(),
                  "Old homepage defaults migrate to the musta-ch fundraiser")
        try check(OverlayPreferences.load(from: reopened) == OverlayConfiguration(),
                  "Migrated defaults are saved to preferences")
        print("\n\(checks) checks passed. Render: build/verification/overlay.png")
    }

    static func main() {
        do { try run(root: CommandLine.arguments[1]) }
        catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    }
}
